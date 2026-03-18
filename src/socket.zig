const std = @import("std");
const cc = @import("c.zig");
const c = cc.c;
const uuid = @import("uuid.zig");
const TabManager = @import("tab_manager.zig").TabManager;
const Workspace = @import("workspace.zig").Workspace;
const Pane = @import("pane.zig").Pane;
const SplitTree = @import("split_tree.zig").SplitTree;
const session = @import("session.zig");

const log = std.log.scoped(.socket);
const posix = std.posix;

/// Unix socket server for external control (CLI, Claude Code hooks).
/// Uses GLib GSource on the main loop — no threads needed.
///
/// Protocol: v1 line-delimited text (matching macOS cmux)
///
///   REQUEST                          RESPONSE
///   ping                         →   PONG
///   list_workspaces              →   id\ttitle\n per workspace
///   new_workspace                →   id
///   select_workspace <id>        →   OK
///   close_workspace <id>         →   OK
///   current_workspace            →   id\ttitle
///   list_surfaces                →   id\tworkspace_id\n per surface
///   current_surface              →   id\tworkspace_id
///   new_split <h|v>              →   new_surface_id
///   send <text>                  →   OK (to focused surface)
///   send_surface <id> <text>     →   OK
///   notify <title> [body]        →   OK
///   ERROR format:                    ERROR: <message>
///
pub const SocketServer = struct {
    fd: posix.fd_t,
    path: []const u8,
    tab_manager: *TabManager,
    source_id: ?c_uint,
    client_sources: std.ArrayList(c_uint),
    allocator: std.mem.Allocator,

    /// Creates a heap-allocated SocketServer so callback pointers remain stable.
    pub fn create(
        allocator: std.mem.Allocator,
        path: []const u8,
        tab_manager: *TabManager,
    ) !*SocketServer {
        // Clean up stale socket
        tryCleanupStaleSocket(path);

        // Create Unix socket
        const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.NONBLOCK, 0);
        errdefer posix.close(fd);

        // Bind
        var addr: posix.sockaddr.un = .{ .family = posix.AF.UNIX, .path = undefined };
        const path_len = @min(path.len, addr.path.len - 1);
        @memcpy(addr.path[0..path_len], path[0..path_len]);
        addr.path[path_len] = 0;

        posix.bind(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)) catch |err| {
            log.err("bind failed: {}", .{err});
            return err;
        };

        try posix.listen(fd, 128);

        log.info("listening on {s}", .{path});

        const self = try allocator.create(SocketServer);
        self.* = .{
            .fd = fd,
            .path = path,
            .tab_manager = tab_manager,
            .source_id = null,
            .client_sources = std.ArrayList(c_uint).init(allocator),
            .allocator = allocator,
        };

        // Now self is heap-stable — safe for GLib callbacks
        self.addToMainLoop();

        return self;
    }

    pub fn destroy(self: *SocketServer) void {
        // Remove GLib sources. Use g_source_remove only if the source
        // is still active — GIOChannel sources may have been auto-removed
        // during GTK shutdown when channels were invalidated.
        if (self.source_id) |sid| {
            const src = c.g_main_context_find_source_by_id(c.g_main_context_default(), sid);
            if (src != null) _ = c.g_source_remove(sid);
            self.source_id = null;
        }
        for (self.client_sources.items) |sid| {
            const src = c.g_main_context_find_source_by_id(c.g_main_context_default(), sid);
            if (src != null) _ = c.g_source_remove(sid);
        }
        self.client_sources.deinit();
        posix.close(self.fd);
        std.fs.deleteFileAbsolute(self.path) catch {};
        self.allocator.destroy(self);
    }

    fn addToMainLoop(self: *SocketServer) void {
        // Use GLib's Unix FD source to watch the server socket for incoming connections
        const channel = c.g_io_channel_unix_new(self.fd);
        if (channel) |ch| {
            const sid = c.g_io_add_watch(ch, c.G_IO_IN, &onAcceptReady, self);
            self.source_id = sid;
            c.g_io_channel_unref(ch);
        }
    }

    fn onAcceptReady(
        _: ?*c.GIOChannel,
        _: c.GIOCondition,
        user_data: ?*anyopaque,
    ) callconv(.C) c.gboolean {
        const self: *SocketServer = @ptrCast(@alignCast(user_data));
        self.acceptClient() catch |err| {
            log.err("accept failed: {}", .{err});
        };
        return 1; // keep watching
    }

    fn acceptClient(self: *SocketServer) !void {
        const client_fd = try posix.accept(self.fd, null, null, 0);

        // Auth: check peer credentials
        if (!self.authClient(client_fd)) {
            posix.close(client_fd);
            return;
        }

        // Add client to main loop for reading
        const channel = c.g_io_channel_unix_new(client_fd);
        if (channel) |ch| {
            // Set encoding to null for binary/line mode
            _ = c.g_io_channel_set_encoding(ch, null, null);
            c.g_io_channel_set_buffered(ch, 0);

            const ctx = self.allocator.create(ClientContext) catch {
                posix.close(client_fd);
                return;
            };
            ctx.* = .{
                .server = self,
                .fd = client_fd,
                .channel = ch,
            };

            const sid = c.g_io_add_watch(ch, c.G_IO_IN | c.G_IO_HUP | c.G_IO_ERR, &onClientReady, ctx);
            self.client_sources.append(sid) catch {};
        }
    }

    fn authClient(self: *SocketServer, fd: posix.fd_t) bool {
        _ = self;
        // SO_PEERCRED: verify client is same user
        var cred: extern struct {
            pid: c.pid_t,
            uid: c.uid_t,
            gid: c.gid_t,
        } = undefined;
        var cred_len: posix.socklen_t = @sizeOf(@TypeOf(cred));

        const ret = std.c.getsockopt(
            fd,
            std.posix.SOL.SOCKET,
            std.posix.SO.PEERCRED,
            @ptrCast(&cred),
            &cred_len,
        );
        if (ret != 0) {
            log.warn("SO_PEERCRED failed", .{});
            return false;
        }

        const my_uid = std.os.linux.getuid();
        if (cred.uid != my_uid) {
            log.warn("rejected client with uid={} (expected {})", .{ cred.uid, my_uid });
            return false;
        }

        return true;
    }

    const ClientContext = struct {
        server: *SocketServer,
        fd: posix.fd_t,
        channel: *c.GIOChannel,
    };

    fn onClientReady(
        channel: ?*c.GIOChannel,
        condition: c.GIOCondition,
        user_data: ?*anyopaque,
    ) callconv(.C) c.gboolean {
        const ctx: *ClientContext = @ptrCast(@alignCast(user_data));

        if (condition & (c.G_IO_HUP | c.G_IO_ERR) != 0) {
            posix.close(ctx.fd);
            ctx.server.allocator.destroy(ctx);
            return 0; // remove source
        }

        _ = channel;

        // Read a line from the client
        var buf: [4096]u8 = undefined;
        const n = posix.read(ctx.fd, &buf) catch {
            posix.close(ctx.fd);
            ctx.server.allocator.destroy(ctx);
            return 0;
        };

        if (n == 0) {
            posix.close(ctx.fd);
            ctx.server.allocator.destroy(ctx);
            return 0;
        }

        // Process each line in the buffer
        var line_start: usize = 0;
        for (buf[0..n], 0..) |byte, i| {
            if (byte == '\n') {
                const line = buf[line_start..i];
                const response = ctx.server.processCommand(line);
                // Send response + newline
                _ = posix.write(ctx.fd, response) catch {};
                _ = posix.write(ctx.fd, "\n") catch {};
                line_start = i + 1;
            }
        }

        // Handle line without trailing newline
        if (line_start < n) {
            const line = buf[line_start..n];
            const response = ctx.server.processCommand(line);
            _ = posix.write(ctx.fd, response) catch {};
            _ = posix.write(ctx.fd, "\n") catch {};
        }

        return 1; // keep watching
    }

    /// Process a v1 command and return the response string.
    pub fn processCommand(self: *SocketServer, line: []const u8) []const u8 {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) return "ERROR: empty command";

        // Split into command + args
        var iter = std.mem.splitScalar(u8, trimmed, ' ');
        const cmd = iter.first();
        const args = iter.rest();

        return self.dispatch(cmd, args);
    }

    fn dispatch(self: *SocketServer, cmd: []const u8, args: []const u8) []const u8 {
        if (std.mem.eql(u8, cmd, "ping")) return "PONG";
        if (std.mem.eql(u8, cmd, "list_workspaces")) return self.cmdListWorkspaces();
        if (std.mem.eql(u8, cmd, "current_workspace")) return self.cmdCurrentWorkspace();
        if (std.mem.eql(u8, cmd, "new_workspace")) return self.cmdNewWorkspace();
        if (std.mem.eql(u8, cmd, "select_workspace")) return self.cmdSelectWorkspace(args);
        if (std.mem.eql(u8, cmd, "close_workspace")) return self.cmdCloseWorkspace(args);
        if (std.mem.eql(u8, cmd, "new_split")) return self.cmdNewSplit(args);
        if (std.mem.eql(u8, cmd, "send")) return self.cmdSend(args);
        if (std.mem.eql(u8, cmd, "notify")) return self.cmdNotify(args);
        if (std.mem.eql(u8, cmd, "set_status")) return self.cmdSetStatus(args);
        if (std.mem.eql(u8, cmd, "clear_status")) return self.cmdClearStatus(args);
        if (std.mem.eql(u8, cmd, "report_meta")) return self.cmdSetStatus(args); // alias
        if (std.mem.eql(u8, cmd, "clear_meta")) return self.cmdClearStatus(args); // alias
        if (std.mem.eql(u8, cmd, "rename_workspace")) return self.cmdRenameWorkspace(args);
        if (std.mem.eql(u8, cmd, "save_template")) return self.cmdSaveTemplate(args);
        if (std.mem.eql(u8, cmd, "load_template")) return self.cmdLoadTemplate(args);
        if (std.mem.eql(u8, cmd, "list_templates")) return session.listTemplates();
        if (std.mem.eql(u8, cmd, "report_process")) return self.cmdReportProcess(args);
        return "ERROR: unknown command";
    }

    // --- Command implementations ---
    // Note: these return static strings or use a response buffer.
    // For dynamic responses, we'd need a per-request allocator or
    // a shared response buffer. For MVP, use static responses where possible.

    var response_buf: [4096]u8 = undefined;

    fn cmdListWorkspaces(self: *SocketServer) []const u8 {
        var pos: usize = 0;
        for (self.tab_manager.workspaces.items) |ws| {
            const id = uuid.asSlice(&ws.id);
            const title = ws.displayTitle();

            if (pos + id.len + 1 + title.len + 1 > response_buf.len) break;
            @memcpy(response_buf[pos..][0..id.len], id);
            pos += id.len;
            response_buf[pos] = '\t';
            pos += 1;
            @memcpy(response_buf[pos..][0..title.len], title);
            pos += title.len;
            response_buf[pos] = '\n';
            pos += 1;
        }
        if (pos == 0) return "";
        return response_buf[0 .. pos - 1]; // trim trailing newline
    }

    fn cmdCurrentWorkspace(self: *SocketServer) []const u8 {
        const ws = self.tab_manager.current() orelse return "ERROR: no workspace";
        const id = uuid.asSlice(&ws.id);
        const title = ws.displayTitle();
        var pos: usize = 0;
        @memcpy(response_buf[pos..][0..id.len], id);
        pos += id.len;
        response_buf[pos] = '\t';
        pos += 1;
        @memcpy(response_buf[pos..][0..title.len], title);
        pos += title.len;
        return response_buf[0..pos];
    }

    fn cmdNewWorkspace(self: *SocketServer) []const u8 {
        const ws = self.tab_manager.createWorkspace() catch return "ERROR: failed to create workspace";
        const id = uuid.asSlice(&ws.id);
        @memcpy(response_buf[0..36], id);
        return response_buf[0..36];
    }

    fn cmdSelectWorkspace(self: *SocketServer, args: []const u8) []const u8 {
        if (args.len < 36) return "ERROR: invalid workspace id";
        var id: uuid.Uuid = undefined;
        @memcpy(&id, args[0..36]);
        if (self.tab_manager.selectWorkspace(&id)) return "OK";
        return "ERROR: workspace not found";
    }

    fn cmdCloseWorkspace(self: *SocketServer, args: []const u8) []const u8 {
        if (args.len < 36) return "ERROR: invalid workspace id";
        var id: uuid.Uuid = undefined;
        @memcpy(&id, args[0..36]);
        self.tab_manager.closeWorkspace(&id);
        return "OK";
    }

    fn cmdNewSplit(self: *SocketServer, args: []const u8) []const u8 {
        const ws = self.tab_manager.current() orelse return "ERROR: no workspace";
        const dir: SplitTree.Direction = if (std.mem.eql(u8, std.mem.trim(u8, args, " "), "h"))
            .horizontal
        else
            .vertical;
        ws.splitFocused(dir) catch return "ERROR: split failed";
        return "OK";
    }

    fn cmdSend(self: *SocketServer, args: []const u8) []const u8 {
        const ws = self.tab_manager.current() orelse return "ERROR: no workspace";
        const pane = ws.split_tree.focusedPane() orelse return "ERROR: no focused pane";
        const term = pane.currentTerminal() orelse return "ERROR: no terminal";

        // Unescape common sequences: \n \t \\ \r
        var buf: [4096]u8 = undefined;
        const unescaped = unescape(args, &buf);
        c.vte_terminal_feed_child(term, unescaped.ptr, @intCast(unescaped.len));
        return "OK";
    }

    fn unescape(input: []const u8, buf: []u8) []const u8 {
        var out: usize = 0;
        var i: usize = 0;
        while (i < input.len and out < buf.len) {
            if (i + 1 < input.len and input[i] == '\\') {
                switch (input[i + 1]) {
                    'n' => { buf[out] = '\n'; out += 1; i += 2; },
                    't' => { buf[out] = '\t'; out += 1; i += 2; },
                    'r' => { buf[out] = '\r'; out += 1; i += 2; },
                    '\\' => { buf[out] = '\\'; out += 1; i += 2; },
                    else => { buf[out] = input[i]; out += 1; i += 1; },
                }
            } else {
                buf[out] = input[i];
                out += 1;
                i += 1;
            }
        }
        return buf[0..out];
    }

    fn cmdNotify(self: *SocketServer, args: []const u8) []const u8 {
        if (args.len == 0) return "ERROR: missing title";

        // Split off --tab= flag if present
        var content = args;
        var target_ws_id: ?uuid.Uuid = null;
        if (std.mem.indexOf(u8, args, "--tab=")) |flag_pos| {
            content = std.mem.trim(u8, args[0..flag_pos], " ");
            const flag_rest = args[flag_pos + 6 ..];
            if (flag_rest.len >= 36) {
                var ws_id: uuid.Uuid = undefined;
                @memcpy(&ws_id, flag_rest[0..36]);
                target_ws_id = ws_id;
            }
        }

        // Skip desktop notification if the target workspace is active AND
        // the cmux window has focus (user is already looking at it)
        if (target_ws_id) |twid| {
            const target_ws = self.tab_manager.findWorkspace(&twid);
            if (target_ws != null and self.tab_manager.current() == target_ws.?) {
                const app = c.g_application_get_default();
                if (app) |a| {
                    const win = c.gtk_application_get_active_window(@ptrCast(@alignCast(a)));
                    if (win) |w| {
                        if (c.gtk_window_is_active(w) != 0) {
                            return "OK"; // suppressed — user is looking at this workspace
                        }
                    }
                }
            }
        }

        // Parse: title|body
        var title_z: [257]u8 = undefined;
        var body_z: [513]u8 = undefined;
        var title_len: usize = 0;
        var body_len: usize = 0;

        if (std.mem.indexOfScalar(u8, content, '|')) |pipe_pos| {
            title_len = @min(pipe_pos, 256);
            @memcpy(title_z[0..title_len], content[0..title_len]);
            title_z[title_len] = 0;

            const rest = content[pipe_pos + 1 ..];
            body_len = @min(rest.len, 512);
            @memcpy(body_z[0..body_len], rest[0..body_len]);
            body_z[body_len] = 0;
        } else {
            title_len = @min(content.len, 256);
            @memcpy(title_z[0..title_len], content[0..title_len]);
            title_z[title_len] = 0;
            body_z[0] = 0;
        }

        const n = c.notify_notification_new(&title_z, if (body_len > 0) &body_z else null, null);
        if (n) |notification| {
            // Add click action to switch to the workspace
            if (target_ws_id != null) {
                // Store the notification context for the click callback
                const ctx = self.allocator.create(NotifyClickCtx) catch {
                    _ = c.notify_notification_show(notification, null);
                    c.g_object_unref(notification);
                    return "OK";
                };
                ctx.* = .{
                    .tab_manager = self.tab_manager,
                    .ws_id = target_ws_id.?,
                    .notification = notification,
                };

                c.notify_notification_add_action(
                    notification,
                    "default",
                    "Open",
                    @ptrCast(&onNotifyClicked),
                    ctx,
                    @ptrCast(&onNotifyCtxFree),
                );
            }

            _ = c.notify_notification_show(notification, null);

            // Don't unref if we added an action — the callback needs it alive.
            // The ctx free callback will handle cleanup.
            if (target_ws_id == null) {
                c.g_object_unref(notification);
            }
        }

        return "OK";
    }

    const NotifyClickCtx = struct {
        tab_manager: *TabManager,
        ws_id: uuid.Uuid,
        notification: *c.NotifyNotification,
    };

    fn onNotifyClicked(
        _: *c.NotifyNotification,
        _: [*:0]const u8,
        user_data: ?*anyopaque,
    ) callconv(.C) void {
        const ctx: *NotifyClickCtx = @ptrCast(@alignCast(user_data orelse return));

        // Switch to the workspace
        _ = ctx.tab_manager.selectWorkspace(&ctx.ws_id);

        // Raise the window
        const gtk_app = c.g_application_get_default();
        if (gtk_app) |app| {
            const win = c.gtk_application_get_active_window(@ptrCast(@alignCast(app)));
            if (win) |w| {
                c.gtk_window_present(w);
            }
        }
    }

    fn onNotifyCtxFree(user_data: ?*anyopaque) callconv(.C) void {
        const ctx: *NotifyClickCtx = @ptrCast(@alignCast(user_data orelse return));
        c.g_object_unref(ctx.notification);
        ctx.tab_manager.allocator.destroy(ctx);
    }

    fn cmdSetStatus(self: *SocketServer, args: []const u8) []const u8 {
        // Parse: key value [--tab=workspace_id]
        var iter = std.mem.splitScalar(u8, args, ' ');
        const key = iter.first();
        if (key.len == 0) return "ERROR: missing key";

        // Collect value (everything that's not a --flag)
        var value_buf: [128]u8 = undefined;
        var value_len: usize = 0;
        var target_ws: ?*Workspace = null;
        var tab_specified = false;

        while (iter.next()) |part| {
            if (std.mem.startsWith(u8, part, "--tab=")) {
                tab_specified = true;
                // Find workspace by ID
                const ws_id_str = part[6..];
                if (ws_id_str.len >= 36) {
                    var ws_id: uuid.Uuid = undefined;
                    @memcpy(&ws_id, ws_id_str[0..36]);
                    target_ws = self.tab_manager.findWorkspace(&ws_id);
                }
            } else if (!std.mem.startsWith(u8, part, "--")) {
                if (value_len > 0 and value_len < value_buf.len) {
                    value_buf[value_len] = ' ';
                    value_len += 1;
                }
                const copy_len = @min(part.len, value_buf.len - value_len);
                @memcpy(value_buf[value_len..][0..copy_len], part[0..copy_len]);
                value_len += copy_len;
            }
        }

        // If --tab= was specified but workspace not found, don't silently
        // fall through to current workspace (causes wrong-tab routing).
        if (tab_specified and target_ws == null) return "ERROR: workspace not found";
        const ws = target_ws orelse self.tab_manager.current() orelse return "ERROR: no workspace";
        const value = value_buf[0..value_len];

        // Route claude_code and claude_message through dedicated API
        // "Active" means: this workspace is selected AND the cmux window has focus.
        // If cmux is in the background, we still want notifications.
        const is_selected = (self.tab_manager.current() == ws);
        const win_focused = blk: {
            const app = c.g_application_get_default() orelse break :blk false;
            const win = c.gtk_application_get_active_window(@ptrCast(@alignCast(app)));
            if (win) |w| break :blk c.gtk_window_is_active(w) != 0;
            break :blk false;
        };
        const is_active = is_selected and win_focused;
        if (std.mem.eql(u8, key, "claude_code")) {
            if (std.mem.eql(u8, value, "Running")) {
                ws.setClaudeStatus(.running);
            } else if (std.mem.eql(u8, value, "Unread")) {
                if (is_active) {
                    ws.setClaudeStatus(.none);
                } else {
                    ws.setClaudeStatus(.unread);
                }
            } else {
                // "Needs input", "Permission", etc. → attention
                // Only escalate if workspace is inactive AND not already running
                // (don't nag if user is looking at it, don't downgrade running)
                if (!is_active and ws.claude_status != .running) {
                    ws.setClaudeStatus(.attention);
                }
            }
        } else if (std.mem.eql(u8, key, "claude_message")) {
            ws.setClaudeMessage(value);
        }

        if (self.tab_manager.on_change) |cb| cb(self.tab_manager.on_change_data);
        return "OK";
    }

    fn cmdClearStatus(self: *SocketServer, args: []const u8) []const u8 {
        var iter = std.mem.splitScalar(u8, args, ' ');
        const key = iter.first();
        if (key.len == 0) return "ERROR: missing key";

        var target_ws: ?*Workspace = null;
        var tab_specified = false;
        while (iter.next()) |part| {
            if (std.mem.startsWith(u8, part, "--tab=")) {
                tab_specified = true;
                const ws_id_str = part[6..];
                if (ws_id_str.len >= 36) {
                    var ws_id: uuid.Uuid = undefined;
                    @memcpy(&ws_id, ws_id_str[0..36]);
                    target_ws = self.tab_manager.findWorkspace(&ws_id);
                }
            }
        }

        if (tab_specified and target_ws == null) return "ERROR: workspace not found";
        const ws = target_ws orelse self.tab_manager.current() orelse return "ERROR: no workspace";

        if (std.mem.eql(u8, key, "claude_code")) {
            const is_selected = (self.tab_manager.current() == ws);
            const win_focused = blk: {
                const app = c.g_application_get_default() orelse break :blk false;
                const win = c.gtk_application_get_active_window(@ptrCast(@alignCast(app)));
                if (win) |w| break :blk c.gtk_window_is_active(w) != 0;
                break :blk false;
            };
            ws.clearClaudeStatus(is_selected and win_focused);
        }

        if (self.tab_manager.on_change) |cb| cb(self.tab_manager.on_change_data);
        return "OK";
    }

    fn cmdRenameWorkspace(self: *SocketServer, args: []const u8) []const u8 {
        if (args.len < 37) return "ERROR: usage: rename_workspace <id> <title>";
        var ws_id: uuid.Uuid = undefined;
        @memcpy(&ws_id, args[0..36]);
        const ws = self.tab_manager.findWorkspace(&ws_id) orelse return "ERROR: workspace not found";
        const title = std.mem.trim(u8, args[37..], " ");
        if (title.len == 0) return "ERROR: empty title";
        ws.setTitle(title);

        if (self.tab_manager.on_change) |cb| cb(self.tab_manager.on_change_data);

        return "OK";
    }

    fn cmdReportProcess(self: *SocketServer, args: []const u8) []const u8 {
        // Parse: <process_name> [--tab=workspace_id] [--surface=surface_id]
        var iter = std.mem.splitScalar(u8, args, ' ');
        const proc_name = iter.first();
        if (proc_name.len == 0) return "OK";

        var surface_id: ?uuid.Uuid = null;
        var target_ws: ?*Workspace = null;

        while (iter.next()) |part| {
            if (std.mem.startsWith(u8, part, "--tab=")) {
                const ws_id_str = part[6..];
                if (ws_id_str.len >= 36) {
                    var ws_id: uuid.Uuid = undefined;
                    @memcpy(&ws_id, ws_id_str[0..36]);
                    target_ws = self.tab_manager.findWorkspace(&ws_id);
                }
            } else if (std.mem.startsWith(u8, part, "--surface=")) {
                const sid_str = part[10..];
                if (sid_str.len >= 36) {
                    var sid: uuid.Uuid = undefined;
                    @memcpy(&sid, sid_str[0..36]);
                    surface_id = sid;
                }
            }
        }

        // Try to find the exact pane by surface ID
        if (surface_id) |sid| {
            if (self.tab_manager.findSurface(&sid)) |found| {
                found.pane.pushProcessHistory(proc_name);
                return "OK";
            }
        }

        // Fallback: focused pane of target workspace
        const ws = target_ws orelse self.tab_manager.current() orelse return "OK";
        if (ws.split_tree.focusedPane()) |pane| {
            pane.pushProcessHistory(proc_name);
        }
        return "OK";
    }

    fn cmdSaveTemplate(self: *SocketServer, args: []const u8) []const u8 {
        const name = std.mem.trim(u8, args, " ");
        if (name.len == 0) return "ERROR: usage: save_template <name>";
        const ws = self.tab_manager.current() orelse return "ERROR: no workspace";
        return session.saveTemplate(ws, name);
    }

    fn cmdLoadTemplate(self: *SocketServer, args: []const u8) []const u8 {
        const name = std.mem.trim(u8, args, " ");
        if (name.len == 0) return "ERROR: usage: load_template <name>";
        const result = session.loadTemplate(self.tab_manager, name);
        if (self.tab_manager.on_change) |cb| cb(self.tab_manager.on_change_data);
        return result;
    }
};

fn tryCleanupStaleSocket(path: []const u8) void {
    // Try to connect. If we can, another instance is running.
    // If we can't, the socket is stale — unlink it.
    const fd = posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0) catch return;
    defer posix.close(fd);

    var addr: posix.sockaddr.un = .{ .family = posix.AF.UNIX, .path = undefined };
    const path_len = @min(path.len, addr.path.len - 1);
    @memcpy(addr.path[0..path_len], path[0..path_len]);
    addr.path[path_len] = 0;

    posix.connect(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)) catch {
        // Connection failed — socket is stale, remove it
        std.fs.deleteFileAbsolute(path) catch {};
        log.info("removed stale socket at {s}", .{path});
        return;
    };

    // Connection succeeded — another instance is running
    log.warn("another cmux instance is running on {s}", .{path});
}

// --- Tests ---

test "process command - ping" {
    // We can test command parsing without a real socket
    // by directly calling processCommand... but it needs a TabManager.
    // For now, just test the trimming/parsing logic.
    const trimmed = std.mem.trim(u8, "  ping  \n", " \t\r\n");
    try std.testing.expectEqualStrings("ping", trimmed);
}

test "process command - split into cmd and args" {
    const line = "select_workspace abc-def-123";
    var iter = std.mem.splitScalar(u8, line, ' ');
    const cmd = iter.first();
    const args = iter.rest();
    try std.testing.expectEqualStrings("select_workspace", cmd);
    try std.testing.expectEqualStrings("abc-def-123", args);
}
