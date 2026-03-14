const std = @import("std");
const cc = @import("c.zig");
const c = cc.c;
const asWidget = cc.asWidget;
const uuid = @import("uuid.zig");

const log = std.log.scoped(.pane);

/// A Pane wraps a GtkNotebook containing one or more VteTerminal tabs.
/// Each terminal tab has its own UUID, PTY, and shell process.
pub const Pane = struct {
    id: uuid.Uuid,
    notebook: *c.GtkNotebook,
    tabs: std.ArrayList(Tab),
    allocator: std.mem.Allocator,
    workspace_id: uuid.Uuid,
    socket_path: []const u8,

    /// Index of this pane's node in the split tree (set after insertion).
    node_index: u16 = std.math.maxInt(u16),

    /// Called when the pane has no more tabs and should be removed.
    on_empty: ?*const fn (pane: *Pane, ctx: ?*anyopaque) void = null,
    on_empty_ctx: ?*anyopaque = null,

    /// Called when this pane receives keyboard focus.
    on_focus: ?*const fn (pane: *Pane, ctx: ?*anyopaque) void = null,
    on_focus_ctx: ?*anyopaque = null,

    pub const Tab = struct {
        id: uuid.Uuid,
        terminal: *c.VteTerminal,
        label: *c.GtkLabel,
        overlay: *c.GtkOverlay,
        /// Tracked browser tab for this terminal (if any)
        browser_target_id: [64]u8 = undefined,
        browser_target_id_len: usize = 0,
        browser_url: [256]u8 = undefined,
        browser_url_len: usize = 0,
        browser_button: ?*c.GtkWidget = null,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        workspace_id: uuid.Uuid,
        socket_path: []const u8,
    ) !*Pane {
        const pane = try allocator.create(Pane);
        errdefer allocator.destroy(pane);

        const notebook: *c.GtkNotebook = @ptrCast(@alignCast(
            c.gtk_notebook_new() orelse return error.GtkWidgetCreateFailed,
        ));
        c.gtk_notebook_set_scrollable(notebook, 1);
        c.gtk_notebook_set_show_tabs(notebook, 0);
        c.gtk_widget_set_vexpand(asWidget(notebook), 1);
        c.gtk_widget_set_hexpand(asWidget(notebook), 1);

        pane.* = .{
            .id = uuid.generate(),
            .notebook = notebook,
            .tabs = std.ArrayList(Tab).init(allocator),
            .allocator = allocator,
            .workspace_id = workspace_id,
            .socket_path = socket_path,
        };

        return pane;
    }

    pub fn deinit(self: *Pane) void {
        // Disconnect all signal handlers BEFORE destroying terminals
        // to prevent child-exited callbacks into freed memory.
        for (self.tabs.items) |tab| {
            _ = c.g_signal_handlers_disconnect_matched(@as(c.gpointer, @ptrCast(@alignCast(tab.terminal))), c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, @as(c.gpointer, @ptrCast(self)));
        }
        self.tabs.deinit();
        self.allocator.destroy(self);
    }

    /// Add a new terminal tab to this pane. Spawns a shell.
    pub fn addTab(self: *Pane, cwd: ?[*:0]const u8) !*Tab {
        const tab_id = uuid.generate();

        const terminal: *c.VteTerminal = @ptrCast(@alignCast(
            c.vte_terminal_new() orelse return error.VteTerminalCreateFailed,
        ));
        c.gtk_widget_set_vexpand(asWidget(terminal), 1);
        c.gtk_widget_set_hexpand(asWidget(terminal), 1);

        // Wrap terminal in GtkOverlay for floating browser-tab buttons
        const overlay: *c.GtkOverlay = @ptrCast(@alignCast(
            c.gtk_overlay_new() orelse return error.GtkWidgetCreateFailed,
        ));
        c.gtk_overlay_set_child(overlay, asWidget(terminal));
        c.gtk_widget_set_vexpand(asWidget(overlay), 1);
        c.gtk_widget_set_hexpand(asWidget(overlay), 1);

        const label: *c.GtkLabel = @ptrCast(@alignCast(
            c.gtk_label_new("Terminal") orelse return error.GtkWidgetCreateFailed,
        ));

        // Add overlay (not bare terminal) to notebook
        const page_num = c.gtk_notebook_append_page(
            self.notebook,
            asWidget(overlay),
            asWidget(label),
        );
        if (page_num < 0) return error.NotebookAppendFailed;

        // Show tabs when we have 2+
        const n_pages = c.gtk_notebook_get_n_pages(self.notebook);
        c.gtk_notebook_set_show_tabs(self.notebook, if (n_pages > 1) 1 else 0);

        // Store tab
        try self.tabs.append(.{
            .id = tab_id,
            .terminal = terminal,
            .label = label,
            .overlay = overlay,
        });
        const tab = &self.tabs.items[self.tabs.items.len - 1];

        // Connect child-exited signal for auto-close
        _ = c.g_signal_connect_data(
            @ptrCast(terminal),
            "child-exited",
            @ptrCast(&onChildExited),
            self,
            null,
            0,
        );

        // Connect window-title-changed for tab label update
        _ = c.g_signal_connect_data(
            @ptrCast(terminal),
            "window-title-changed",
            @ptrCast(&onTitleChanged),
            self,
            null,
            0,
        );

        // Track focus: when user clicks this terminal, update split_tree.focused
        const focus_controller = c.gtk_event_controller_focus_new();
        _ = c.g_signal_connect_data(
            @ptrCast(focus_controller),
            "enter",
            @ptrCast(&onFocusEnter),
            self,
            null,
            0,
        );
        c.gtk_widget_add_controller(asWidget(terminal), focus_controller);

        // URL matching: make URLs clickable
        setupUrlMatching(terminal, self);

        // Spawn shell
        self.spawnShell(terminal, cwd);

        // Make new tab visible and focused
        c.gtk_notebook_set_current_page(self.notebook, page_num);
        _ = c.gtk_widget_grab_focus(asWidget(terminal));

        return tab;
    }

    // Static shell path — lives for the entire program
    var shell_path_buf: [256:0]u8 = undefined;
    var shell_path_initialized: bool = false;

    var home_buf: [256:0]u8 = undefined;
    var home_initialized: bool = false;

    fn getDefaultCwd() [*:0]const u8 {
        if (!home_initialized) {
            const home = std.posix.getenv("HOME") orelse "/tmp";
            const hlen = @min(home.len, 255);
            @memcpy(home_buf[0..hlen], home[0..hlen]);
            home_buf[hlen] = 0;
            home_initialized = true;
        }
        return &home_buf;
    }

    fn spawnShell(self: *Pane, terminal: *c.VteTerminal, cwd: ?[*:0]const u8) void {
        // Initialize shell path once (static lifetime)
        if (!shell_path_initialized) {
            const shell_env = std.posix.getenv("SHELL") orelse "/bin/bash";
            const slen = @min(shell_env.len, 255);
            @memcpy(shell_path_buf[0..slen], shell_env[0..slen]);
            shell_path_buf[slen] = 0;
            shell_path_initialized = true;
        }

        const shell_z: [*:0]const u8 = &shell_path_buf;
        var argv = [_:null]?[*:0]const u8{ shell_z, null };

        // Default to $HOME if no CWD specified (like other terminals)
        const effective_cwd = cwd orelse getDefaultCwd();

        // Set CMUX_* env vars in the current process before spawn.
        // VTE inherits the parent environment when envv=null.
        // We set them here so all child shells get them.
        const tab = self.currentTab();
        const surface_id = if (tab) |t| uuid.asSlice(&t.id) else "unknown";
        const workspace_id = uuid.asSlice(&self.workspace_id);

        setEnvZ("CMUX_SURFACE_ID", surface_id);
        setEnvZ("CMUX_WORKSPACE_ID", workspace_id);
        setEnvZ("CMUX_PANEL_ID", surface_id);
        setEnvZ("CMUX_TAB_ID", workspace_id);
        setEnvZ("CMUX_SOCKET_PATH", self.socket_path);
        _ = c.g_setenv("TERM_PROGRAM", "cmux", 1);

        // Prepend cmux's bin/ dir to PATH so `cmux-cli` is found,
        // and set CMUX_SHELL_INTEGRATION_DIR so .bashrc can source the init script.
        prependBinToPath();

        c.vte_terminal_spawn_async(
            terminal,
            c.VTE_PTY_DEFAULT,
            effective_cwd,
            @ptrCast(&argv),
            null, // env=null → inherit parent (with our CMUX vars)
            c.G_SPAWN_DEFAULT,
            null, null, null, // child setup
            -1, // timeout
            null, // cancellable
            @ptrCast(&onSpawnComplete),
            null,
        );
    }

    var path_prepended: bool = false;
    fn prependBinToPath() void {
        if (path_prepended) return;
        path_prepended = true;

        // Find our own executable path, then derive bin/ dir
        var exe_buf: [4096]u8 = undefined;
        const exe_path = std.fs.readLinkAbsolute("/proc/self/exe", &exe_buf) catch return;

        // exe_path is like /home/user/projekt/cmux-linux/zig-out/bin/cmux
        // We want /home/user/projekt/cmux-linux/bin (the wrapper scripts dir)
        // Go up: zig-out/bin/cmux -> zig-out/bin -> zig-out -> project_root
        const d1 = std.fs.path.dirname(exe_path) orelse return; // strip filename
        const d2 = std.fs.path.dirname(d1) orelse return; // strip "bin"
        const dir = std.fs.path.dirname(d2) orelse return; // strip "zig-out"

        var new_path_buf: [8192]u8 = undefined;
        const old_path = std.posix.getenv("PATH") orelse "/usr/bin";

        // Also include zig-out/bin so cmux-cli is found
        const exe_bin = std.fs.path.dirname(exe_path) orelse "";

        const new_path = std.fmt.bufPrint(&new_path_buf, "{s}/bin:{s}:{s}", .{ dir, exe_bin, old_path }) catch return;

        var new_path_z: [8193]u8 = undefined;
        @memcpy(new_path_z[0..new_path.len], new_path);
        new_path_z[new_path.len] = 0;
        _ = c.g_setenv("PATH", &new_path_z, 1);

        // Set integration dir so shells can source the init script
        var init_dir_buf: [4097]u8 = undefined;
        const init_dir = std.fmt.bufPrint(&init_dir_buf, "{s}/bin", .{dir}) catch return;
        init_dir_buf[init_dir.len] = 0;
        _ = c.g_setenv("CMUX_SHELL_INTEGRATION_DIR", &init_dir_buf, 1);
    }

    var setenv_buf: [8][512]u8 = undefined;
    fn setEnvZ(name: [*:0]const u8, value: []const u8) void {
        // setenv needs null-terminated value
        const s = struct {
            var idx: usize = 0;
        };
        const bi = s.idx % 8;
        s.idx += 1;
        const vlen = @min(value.len, 511);
        @memcpy(setenv_buf[bi][0..vlen], value[0..vlen]);
        setenv_buf[bi][vlen] = 0;
        _ = c.g_setenv(name, &setenv_buf[bi], 1);
    }

    /// Close a tab by finding the VteTerminal in the notebook.
    pub fn closeTab(self: *Pane, terminal: *c.VteTerminal) void {
        // Disconnect signals from this terminal to prevent re-entrant callbacks
        _ = c.g_signal_handlers_disconnect_matched(@as(c.gpointer, @ptrCast(@alignCast(terminal))), c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, @as(c.gpointer, @ptrCast(self)));

        // Find the overlay (notebook page) for this terminal
        var page_widget: *c.GtkWidget = asWidget(terminal);
        for (self.tabs.items) |tab| {
            if (tab.terminal == terminal) {
                page_widget = asWidget(tab.overlay);
                break;
            }
        }
        const page_num = c.gtk_notebook_page_num(self.notebook, page_widget);
        if (page_num >= 0) {
            c.gtk_notebook_remove_page(self.notebook, page_num);
        }

        // Remove from our tab list
        var found = false;
        for (self.tabs.items, 0..) |tab, i| {
            if (tab.terminal == terminal) {
                _ = self.tabs.orderedRemove(i);
                found = true;
                break;
            }
        }
        if (!found) return; // Already removed (e.g. during deinit)

        // Update tab visibility
        const n_pages = c.gtk_notebook_get_n_pages(self.notebook);
        c.gtk_notebook_set_show_tabs(self.notebook, if (n_pages > 1) 1 else 0);

        // If no tabs left, signal pane is empty
        if (self.tabs.items.len == 0) {
            if (self.on_empty) |callback| {
                callback(self, self.on_empty_ctx);
            }
        }
    }

    /// Returns the widget for embedding in split tree
    pub fn widget(self: *Pane) *c.GtkWidget {
        return asWidget(self.notebook);
    }

    /// Get the currently focused terminal in this pane
    pub fn currentTerminal(self: *Pane) ?*c.VteTerminal {
        const page = c.gtk_notebook_get_current_page(self.notebook);
        if (page < 0) return null;
        const idx: usize = @intCast(page);
        if (idx >= self.tabs.items.len) return null;
        return self.tabs.items[idx].terminal;
    }

    /// Get the current tab
    pub fn currentTab(self: *Pane) ?*Tab {
        const page = c.gtk_notebook_get_current_page(self.notebook);
        if (page < 0) return null;
        const idx: usize = @intCast(page);
        if (idx >= self.tabs.items.len) return null;
        return &self.tabs.items[idx];
    }

    /// Get the CWD of the current terminal's child process via /proc/pid/cwd.
    /// Returns a null-terminated path in a static buffer, or null if unavailable.
    pub fn getCwd(self: *Pane) ?[*:0]const u8 {
        const term = self.currentTerminal() orelse return null;
        // VTE provides the child PID through the pty
        const pty = c.vte_terminal_get_pty(term) orelse return null;
        const fd = c.vte_pty_get_fd(pty);
        if (fd < 0) return null;

        // Get the child PID via the PTY's foreground process group
        // Simpler: use /proc/self/fd/<fd> to find the pty, then pgrp
        // Actually, just use vte_terminal_get_child_pid if available,
        // or read /proc/<pid>/cwd. VTE doesn't expose child PID directly
        // in all versions, so let's use the pty fd approach.

        // Alternative: get the foreground process from the pty
        var pgrp: std.c.pid_t = undefined;
        const ret = std.c.ioctl(fd, std.os.linux.T.IOCGPGRP, @intFromPtr(&pgrp));
        if (ret != 0 or pgrp <= 0) return null;

        // Read /proc/<pgrp>/cwd
        var proc_path_buf: [64]u8 = undefined;
        const proc_path = std.fmt.bufPrint(&proc_path_buf, "/proc/{d}/cwd", .{pgrp}) catch return null;
        var proc_z: [65]u8 = undefined;
        @memcpy(proc_z[0..proc_path.len], proc_path);
        proc_z[proc_path.len] = 0;

        var link_buf: [std.fs.max_path_bytes]u8 = undefined;
        const link = std.fs.readLinkAbsolute(proc_path, &link_buf) catch return null;
        const len = @min(link.len, cwd_buf.len - 1);
        @memcpy(cwd_buf[0..len], link[0..len]);
        cwd_buf[len] = 0;
        return cwd_buf[0..len :0];
    }

    var cwd_buf: [4096:0]u8 = undefined;

    /// Focus this pane's current terminal
    pub fn focus(self: *Pane) void {
        if (self.currentTerminal()) |term| {
            _ = c.gtk_widget_grab_focus(asWidget(term));
        }
    }

    // --- URL matching ---

    fn setupUrlMatching(terminal: *c.VteTerminal, pane: *Pane) void {
        // URL regex pattern: matches http(s), localhost, and common URLs
        const url_pattern = "https?://[\\w\\-.]+(:\\d+)?(/[\\w\\-.~:/?#\\[\\]@!$&'()*+,;=%]*)?";
        var err: ?*c.GError = null;
        const PCRE2_MULTILINE = 0x00000400; // from pcre2.h
        const regex = c.vte_regex_new_for_match(url_pattern, -1, PCRE2_MULTILINE, &err);
        if (regex == null) return;

        const tag = c.vte_terminal_match_add_regex(terminal, regex, 0);
        c.vte_terminal_match_set_cursor_name(terminal, tag, "pointer");

        // Allow OSC 8 hyperlinks too
        c.vte_terminal_set_allow_hyperlink(terminal, 1);

        // Handle clicks via a GtkGestureClick on the terminal
        const click = c.gtk_gesture_click_new() orelse return;
        c.gtk_gesture_single_set_button(@ptrCast(@alignCast(click)), 1); // left click

        // Store pane pointer on terminal for click handler
        c.g_object_set_data(@ptrCast(@alignCast(terminal)), "cmux-pane", pane);

        _ = c.g_signal_connect_data(
            @ptrCast(click),
            "pressed",
            @ptrCast(&onTerminalClick),
            terminal,
            null,
            0,
        );
        c.gtk_widget_add_controller(asWidget(terminal), @ptrCast(@alignCast(click)));
    }

    fn onTerminalClick(
        _: *c.GtkGestureClick,
        _: c.gint,
        x: c.gdouble,
        y: c.gdouble,
        terminal: *c.VteTerminal,
    ) callconv(.C) void {
        var url: ?[*:0]u8 = null;

        url = c.vte_terminal_check_hyperlink_at(terminal, x, y);
        if (url == null) {
            var tag: c_int = 0;
            url = c.vte_terminal_check_match_at(terminal, x, y, &tag);
        }

        if (url) |u| {
            const url_str = std.mem.span(u);
            log.info("URL clicked: {s}", .{url_str});

            // Get the pane from the terminal
            const pane_raw = c.g_object_get_data(@ptrCast(@alignCast(terminal)), "cmux-pane");
            const pane: ?*Pane = if (pane_raw) |p| @ptrCast(@alignCast(p)) else null;

            openUrlAndTrack(url_str, terminal, pane);
            c.g_free(u);
        }
    }

    fn openUrlAndTrack(url: []const u8, terminal: *c.VteTerminal, pane: ?*Pane) void {
        var url_z: [2048]u8 = undefined;
        const ulen = @min(url.len, 2047);
        @memcpy(url_z[0..ulen], url[0..ulen]);
        url_z[ulen] = 0;

        // Open URL via GLib launcher with display context for focus
        const display = c.gdk_display_get_default();
        const launch_ctx: ?*c.GAppLaunchContext = if (display) |d|
            @ptrCast(@alignCast(c.gdk_display_get_app_launch_context(d)))
        else
            null;

        var err: ?*c.GError = null;
        _ = c.g_app_info_launch_default_for_uri(&url_z, launch_ctx, &err);
        if (launch_ctx) |ctx| c.g_object_unref(@ptrCast(@alignCast(ctx)));
        if (err) |e| {
            log.err("failed to open URL: {s}", .{@as([*:0]const u8, @ptrCast(e.message))});
            c.g_error_free(e);
            return;
        }

        // Poll CDP to find the new browser tab
        const ctx = std.heap.c_allocator.create(CdpPollCtx) catch return;
        ctx.url_len = ulen;
        @memcpy(ctx.url[0..ulen], url[0..ulen]);
        ctx.url[ulen] = 0;
        ctx.attempts = 0;
        ctx.terminal = terminal;
        ctx.pane = pane;

        _ = c.g_timeout_add(500, @ptrCast(&onCdpPoll), ctx);
    }

    const CdpPollCtx = struct {
        url: [2048]u8,
        url_len: usize,
        attempts: u8,
        terminal: *c.VteTerminal,
        pane: ?*Pane,
    };

    fn onCdpPoll(user_data: ?*anyopaque) callconv(.C) c.gboolean {
        const ctx: *CdpPollCtx = @ptrCast(@alignCast(user_data orelse return 0));
        ctx.attempts += 1;

        // Shell out to curl to query CDP
        const pid = std.posix.fork() catch {
            std.heap.c_allocator.destroy(ctx);
            return 0;
        };
        if (pid == 0) {
            const argv = [_:null]?[*:0]const u8{
                "curl", "-s", "-o", "/tmp/cmux-cdp.json",
                "http://localhost:9222/json",
                null,
            };
            _ = std.posix.execvpeZ("curl", &argv, @ptrCast(std.c.environ)) catch {};
            std.posix.exit(1);
        }
        _ = std.posix.waitpid(pid, 0);

        // Read and search for the URL
        const file = std.fs.openFileAbsolute("/tmp/cmux-cdp.json", .{}) catch {
            if (ctx.attempts >= 10) { std.heap.c_allocator.destroy(ctx); return 0; }
            return 1;
        };
        defer file.close();
        var buf: [16384]u8 = undefined;
        const n = file.read(&buf) catch {
            if (ctx.attempts >= 10) { std.heap.c_allocator.destroy(ctx); return 0; }
            return 1;
        };
        const json = buf[0..n];

        // Log CDP response on first attempt for debugging
        if (ctx.attempts == 1) {
            if (std.fs.createFileAbsolute("/tmp/cmux-cdp-debug.log", .{ .truncate = false })) |dbg| {
                defer dbg.close();
                dbg.seekFromEnd(0) catch {};
                const w = dbg.writer();
                w.print("[cdp] looking for: {s}\n", .{ctx.url[0..ctx.url_len]}) catch {};
                w.print("[cdp] response ({} bytes): {s}\n", .{ n, json[0..@min(n, 500)] }) catch {};
            } else |_| {}
        }

        // Find our URL in the CDP response — match flexibly (URL may have trailing slash)
        const url_str = ctx.url[0..ctx.url_len];
        // Strip trailing slash for matching
        const match_url = if (url_str.len > 0 and url_str[url_str.len - 1] == '/')
            url_str[0 .. url_str.len - 1]
        else
            url_str;

        if (std.mem.indexOf(u8, json, match_url)) |url_pos| {
            // Search backwards for "id" field — handle both "id":"X" and "id": "X"
            const before = json[0..url_pos];
            const id_key = std.mem.lastIndexOf(u8, before, "\"id\":") orelse {
                if (ctx.attempts >= 10) { std.heap.c_allocator.destroy(ctx); return 0; }
                return 1;
            };
            // Skip "id": and any whitespace, find the opening quote
            var id_scan = id_key + 5; // skip `"id":`
            while (id_scan < json.len and (json[id_scan] == ' ' or json[id_scan] == '"')) : (id_scan += 1) {}
            // Now id_scan points to first char of the ID value (we skipped the opening quote)
            // Actually, let's just find the quotes properly
            const after_key = json[id_key + 5 ..]; // after `"id":`
            const quote1 = std.mem.indexOfScalar(u8, after_key, '"') orelse {
                if (ctx.attempts >= 10) { std.heap.c_allocator.destroy(ctx); return 0; }
                return 1;
            };
            const id_start_rel = quote1 + 1;
            const id_content = after_key[id_start_rel..];
            if (std.mem.indexOfScalar(u8, id_content, '"')) |id_end| {
                const target_id = id_content[0..id_end];
                log.info("CDP: found tab {s} for {s}", .{ target_id, url_str });

                if (ctx.pane) |pane| {
                    storeBrowserTab(pane, target_id, url_str);
                }

                std.heap.c_allocator.destroy(ctx);
                return 0;
            }
        }

        if (ctx.attempts >= 10) {
            log.info("CDP: gave up finding tab for {s}", .{url_str});
            std.heap.c_allocator.destroy(ctx);
            return 0;
        }
        return 1; // keep polling
    }

    fn storeBrowserTab(pane: *Pane, target_id: []const u8, url: []const u8) void {
        const tab = pane.currentTab() orelse return;

        // Store the target ID
        const tid_len = @min(target_id.len, 64);
        @memcpy(tab.browser_target_id[0..tid_len], target_id[0..tid_len]);
        tab.browser_target_id_len = tid_len;

        const url_len = @min(url.len, 256);
        @memcpy(tab.browser_url[0..url_len], url[0..url_len]);
        tab.browser_url_len = url_len;

        // Create overlay button in bottom-right
        if (tab.browser_button != null) {
            // Remove old button
            c.gtk_overlay_remove_overlay(tab.overlay, tab.browser_button.?);
        }

        // Shorten URL for display
        var display_buf: [64]u8 = undefined;
        const display = if (url_len > 50)
            std.fmt.bufPrint(&display_buf, "🌐 {s}...", .{url[0..47]}) catch url[0..url_len]
        else
            std.fmt.bufPrint(&display_buf, "🌐 {s}", .{url[0..url_len]}) catch url[0..url_len];

        var label_z: [65]u8 = undefined;
        @memcpy(label_z[0..display.len], display);
        label_z[display.len] = 0;

        const btn = c.gtk_button_new_with_label(&label_z) orelse return;
        c.gtk_widget_set_halign(btn, c.GTK_ALIGN_END);
        c.gtk_widget_set_valign(btn, c.GTK_ALIGN_END);
        c.gtk_widget_set_margin_end(btn, 8);
        c.gtk_widget_set_margin_bottom(btn, 8);
        c.gtk_widget_set_opacity(btn, 0.9);
        c.gtk_widget_add_css_class(btn, "suggested-action");

        // Store target_id on the button for the click handler
        c.g_object_set_data(@ptrCast(@alignCast(btn)), "cmux-target-id", @constCast(@ptrCast(tab.browser_target_id[0..tid_len :0].ptr)));

        _ = c.g_signal_connect_data(
            @ptrCast(btn),
            "clicked",
            @ptrCast(&onBrowserTabClick),
            null,
            null,
            0,
        );

        c.gtk_overlay_add_overlay(tab.overlay, btn);
        tab.browser_button = btn;
    }

    fn onBrowserTabClick(button: *c.GtkButton, _: ?*anyopaque) callconv(.C) void {
        const raw = c.g_object_get_data(@ptrCast(@alignCast(button)), "cmux-target-id") orelse return;
        const target_id: [*:0]const u8 = @ptrCast(raw);
        const tid = std.mem.span(target_id);

        log.info("CDP: activating tab {s}", .{tid});

        // GET http://localhost:9222/json/activate/{target_id}
        var activate_url: [256]u8 = undefined;
        const url = std.fmt.bufPrint(&activate_url, "http://localhost:9222/json/activate/{s}", .{tid}) catch return;
        var url_z: [257]u8 = undefined;
        @memcpy(url_z[0..url.len], url);
        url_z[url.len] = 0;

        const pid = std.posix.fork() catch return;
        if (pid == 0) {
            const argv = [_:null]?[*:0]const u8{
                "curl", "-s", url_z[0..url.len :0],
                null,
            };
            _ = std.posix.execvpeZ("curl", &argv, @ptrCast(std.c.environ)) catch {};
            std.posix.exit(1);
        }
        // Don't wait — fire and forget
    }

    // --- Signal handlers ---

    fn onFocusEnter(_: *c.GtkEventControllerFocus, pane: *Pane) callconv(.C) void {
        if (pane.on_focus) |callback| {
            callback(pane, pane.on_focus_ctx);
        }
    }

    fn onSpawnComplete(
        terminal: *c.VteTerminal,
        pid: c.GPid,
        err: ?*c.GError,
        _: ?*anyopaque,
    ) callconv(.C) void {
        _ = terminal;
        if (err) |e| {
            log.err("spawn failed: {s}", .{@as([*:0]const u8, @ptrCast(e.message))});
        } else {
            log.info("shell spawned with pid {}", .{pid});
        }
    }

    fn onChildExited(terminal: *c.VteTerminal, _: c.gint, pane: *Pane) callconv(.C) void {
        log.info("child exited in pane {s}", .{uuid.asSlice(&pane.id)});
        pane.closeTab(terminal);
    }

    fn onTitleChanged(terminal: *c.VteTerminal, pane: *Pane) callconv(.C) void {
        const title = c.vte_terminal_get_window_title(terminal);
        if (title == null) return;

        for (pane.tabs.items) |tab| {
            if (tab.terminal == terminal) {
                c.gtk_label_set_text(tab.label, title);
                break;
            }
        }
    }
};
