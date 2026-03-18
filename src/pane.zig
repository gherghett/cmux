const std = @import("std");
const cc = @import("c.zig");
const c = cc.c;
const asWidget = cc.asWidget;
const uuid = @import("uuid.zig");

const runtime_dir = @import("runtime_dir.zig");
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
    /// dtach socket path for this pane's primary terminal
    dtach_path: [128]u8 = undefined,
    dtach_path_len: usize = 0,
    /// True once the shell/dtach process has started (onSpawnComplete fired).
    ready: bool = false,

    /// Index of this pane's node in the split tree (set after insertion).
    node_index: u16 = std.math.maxInt(u16),

    /// Called when the pane has no more tabs and should be removed.
    on_empty: ?*const fn (pane: *Pane, ctx: ?*anyopaque) void = null,
    on_empty_ctx: ?*anyopaque = null,

    /// Called when this pane receives keyboard focus.
    on_focus: ?*const fn (pane: *Pane, ctx: ?*anyopaque) void = null,
    on_focus_ctx: ?*anyopaque = null,

    /// Called when the terminal title changes (for workspace title auto-update).
    on_title: ?*const fn (title: [*:0]const u8, ctx: ?*anyopaque) void = null,
    on_title_ctx: ?*anyopaque = null,

    browser_tabs: [16]?BrowserTab = [_]?BrowserTab{null} ** 16,
    browser_tab_box: ?*c.GtkBox = null, // container for browser tab buttons in overlay

    /// Cached dtach master PID — avoids scanning all of /proc on every refresh.
    dtach_master_pid: std.c.pid_t = 0,
    /// Cached leaf (deepest child) PID + timestamp. Expires after 1 second.
    cached_leaf_pid: std.c.pid_t = 0,
    cached_leaf_time: i64 = 0,

    /// Ring buffer of recent distinct processes reported via shell integration.
    proc_history: [16][32]u8 = [_][32]u8{[_]u8{0} ** 32} ** 16,
    proc_history_lens: [16]u8 = [_]u8{0} ** 16,
    proc_history_idx: u8 = 0,
    proc_history_count: u8 = 0,

    pub const Tab = struct {
        id: uuid.Uuid,
        terminal: *c.VteTerminal,
        label: *c.GtkLabel,
        overlay: *c.GtkOverlay,
    };

    pub const BrowserTab = struct {
        target_id: [64]u8,
        target_id_len: usize,
        url: [256]u8,
        url_len: usize,
        button: ?*c.GtkWidget,
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

    /// Block until the spawn callback fires (process is running).
    /// Pumps the GTK main loop so async spawn can complete.
    /// Times out after ~2 seconds to avoid deadlock.
    pub fn waitReady(self: *Pane) void {
        var attempts: u32 = 0;
        while (!self.ready and attempts < 200) : (attempts += 1) {
            // Pump the GTK main loop so VTE's async spawn can complete
            _ = c.g_main_context_iteration(null, 0);
            std.time.sleep(10_000_000); // 10ms
        }
        if (!self.ready) {
            log.warn("pane spawn timed out after 2 seconds", .{});
        }
    }

    /// Disconnect signals only — dtach process stays alive for session persistence.
    /// Used when cmux is closing (window close, shutdown).
    pub fn deinit(self: *Pane) void {
        for (self.tabs.items) |tab| {
            _ = c.g_signal_handlers_disconnect_matched(@as(c.gpointer, @ptrCast(@alignCast(tab.terminal))), c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, @as(c.gpointer, @ptrCast(self)));
        }
        self.tabs.deinit();
        self.allocator.destroy(self);
    }

    /// Kill the dtach process and clean up the socket.
    /// Used when the USER explicitly closes a pane or workspace.
    pub fn killDtach(self: *Pane) void {
        if (self.dtach_path_len > 0) {
            const path = self.dtach_path[0..self.dtach_path_len];
            log.info("killing dtach at {s}", .{path});

            // Remove the socket file first — prevents dtach from accepting
            // new connections. Then send exit to the terminal which causes
            // the shell to exit, making dtach exit naturally.
            std.fs.deleteFileAbsolute(path) catch {};

            // Feed "exit\n" to our VTE terminal to kill the shell inside dtach
            if (self.currentTerminal()) |term| {
                c.vte_terminal_feed_child(term, "exit\n", 5);
            }
        }
    }

    /// Full close: kill dtach + deinit. For explicit user actions.
    pub fn close(self: *Pane) void {
        self.killDtach();
        self.deinit();
    }

    /// Add a new terminal tab. If dtach_socket is set, reattach to existing session.
    pub fn addTabDtach(self: *Pane, cwd: ?[*:0]const u8, dtach_socket: ?[]const u8) !*Tab {
        return self.addTabInner(cwd, dtach_socket);
    }

    pub fn addTab(self: *Pane, cwd: ?[*:0]const u8) !*Tab {
        return self.addTabInner(cwd, null);
    }

    fn addTabInner(self: *Pane, cwd: ?[*:0]const u8, dtach_socket: ?[]const u8) !*Tab {
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

        // Spawn shell (or reattach to existing dtach session)
        self.spawnShellDtach(terminal, cwd, dtach_socket);

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

    /// Spawn a shell via dtach for process persistence.
    /// If dtach_socket is provided, reattach to existing session.
    /// Otherwise create a new dtach session.
    fn spawnShell(self: *Pane, terminal: *c.VteTerminal, cwd: ?[*:0]const u8) void {
        self.spawnShellDtach(terminal, cwd, null);
    }

    fn spawnShellDtach(self: *Pane, terminal: *c.VteTerminal, cwd: ?[*:0]const u8, existing_dtach: ?[]const u8) void {
        // Initialize shell path once
        if (!shell_path_initialized) {
            const shell_env = std.posix.getenv("SHELL") orelse "/bin/bash";
            const slen = @min(shell_env.len, 255);
            @memcpy(shell_path_buf[0..slen], shell_env[0..slen]);
            shell_path_buf[slen] = 0;
            shell_path_initialized = true;
        }

        const effective_cwd = cwd orelse getDefaultCwd();

        // Set CMUX_* env vars
        const tab = self.currentTab();
        const surface_id = if (tab) |t| uuid.asSlice(&t.id) else "unknown";
        const workspace_id = uuid.asSlice(&self.workspace_id);

        // Prepend bin to PATH once (process-level, safe to share)
        prependBinToPath();

        // Build per-terminal env array with CMUX_* vars.
        // Must NOT use g_setenv (process-global — last pane wins).
        buildEnv(surface_id, workspace_id, self.socket_path);

        // Build dtach socket path
        var dtach_sock: [128]u8 = undefined;
        var dtach_sock_len: usize = 0;

        if (existing_dtach) |path| {
            // Reattach to existing dtach session
            dtach_sock_len = @min(path.len, 127);
            @memcpy(dtach_sock[0..dtach_sock_len], path[0..dtach_sock_len]);
            dtach_sock[dtach_sock_len] = 0;
        } else {
            // Create new dtach session in runtime dir
            const pane_id = uuid.asSlice(&self.id);
            const dp = runtime_dir.dtachPath(&dtach_sock, pane_id);
            dtach_sock_len = dp.len;
            dtach_sock[dtach_sock_len] = 0;
        }

        // Store on pane for serialization
        @memcpy(self.dtach_path[0..dtach_sock_len], dtach_sock[0..dtach_sock_len]);
        self.dtach_path_len = dtach_sock_len;

        // Build command: dtach -A <socket> -Ez bash --rcfile <cmux-bash>
        // --rcfile makes bash source our wrapper (which sources .bashrc + cmux shell init)
        // -E disables detach char, -z disables suspend
        const sock_path_z: [*:0]const u8 = dtach_sock[0..dtach_sock_len :0];
        const shell_z: [*:0]const u8 = &shell_path_buf;
        const rcfile_z: [*:0]const u8 = getRcfilePath();
        var argv = if (rcfile_z[0] != 0) [_:null]?[*:0]const u8{
            "dtach", "-A", sock_path_z, "-Ez", shell_z, "--rcfile", rcfile_z, null,
        } else [_:null]?[*:0]const u8{
            "dtach", "-A", sock_path_z, "-Ez", shell_z, null, null, null,
        };

        c.vte_terminal_spawn_async(
            terminal,
            c.VTE_PTY_DEFAULT,
            effective_cwd,
            @ptrCast(&argv),
            @ptrCast(&env_ptrs), // per-terminal env
            c.G_SPAWN_DEFAULT,
            null, null, null,
            -1,
            null,
            @ptrCast(&onSpawnComplete),
            self,
        );
    }

    var rcfile_buf: [512:0]u8 = undefined;
    var rcfile_initialized: bool = false;

    fn getRcfilePath() [*:0]const u8 {
        if (!rcfile_initialized) {
            rcfile_initialized = true;
            // Find cmux-bash next to our executable
            var exe_buf: [4096]u8 = undefined;
            const exe_path = std.fs.readLinkAbsolute("/proc/self/exe", &exe_buf) catch {
                rcfile_buf[0] = 0;
                return &rcfile_buf;
            };
            const d1 = std.fs.path.dirname(exe_path) orelse { rcfile_buf[0] = 0; return &rcfile_buf; };
            const d2 = std.fs.path.dirname(d1) orelse { rcfile_buf[0] = 0; return &rcfile_buf; };
            const dir = std.fs.path.dirname(d2) orelse { rcfile_buf[0] = 0; return &rcfile_buf; };
            const result = std.fmt.bufPrint(&rcfile_buf, "{s}/bin/cmux-bash", .{dir}) catch {
                rcfile_buf[0] = 0;
                return &rcfile_buf;
            };
            rcfile_buf[result.len] = 0;
        }
        return &rcfile_buf;
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

    // Per-terminal environment array. Static buffers so they live long enough
    // for VTE's async spawn to read them.
    var env_bufs: [16][512]u8 = undefined;
    var env_ptrs: [256:null]?[*:0]const u8 = undefined;

    fn buildEnv(surface_id: []const u8, workspace_id: []const u8, socket_path: []const u8) void {
        var idx: usize = 0;
        var buf_idx: usize = 0;

        // Copy parent env, skipping CMUX_* and TERM_PROGRAM (we'll add ours)
        const environ: ?[*:null]const ?[*:0]const u8 = @ptrCast(std.c.environ);
        if (environ) |env| {
            var i: usize = 0;
            while (env[i]) |entry| : (i += 1) {
                if (idx >= 240) break; // reserve space
                const s = std.mem.span(entry);
                // VTE requires every entry to contain '='
                if (std.mem.indexOfScalar(u8, s, '=') == null) continue;
                // Skip our vars (we'll re-add with correct per-terminal values)
                if (std.mem.startsWith(u8, s, "CMUX_")) continue;
                if (std.mem.startsWith(u8, s, "TERM_PROGRAM=")) continue;
                env_ptrs[idx] = entry;
                idx += 1;
            }
        }

        // Add CMUX_* vars using static buffers.
        // CMUX_SHELL_INIT triggers auto-sourcing of shell integration on first prompt.
        const vars = [_]struct { k: []const u8, v: []const u8 }{
            .{ .k = "CMUX_SURFACE_ID=", .v = surface_id },
            .{ .k = "CMUX_WORKSPACE_ID=", .v = workspace_id },
            .{ .k = "CMUX_PANEL_ID=", .v = surface_id },
            .{ .k = "CMUX_TAB_ID=", .v = surface_id },
            .{ .k = "CMUX_SOCKET_PATH=", .v = socket_path },
            .{ .k = "TERM_PROGRAM=", .v = "cmux" },
        };

        for (vars) |kv| {
            if (buf_idx >= env_bufs.len or idx >= 255) break;
            const total = kv.k.len + kv.v.len;
            if (total >= env_bufs[buf_idx].len) continue;
            @memcpy(env_bufs[buf_idx][0..kv.k.len], kv.k);
            @memcpy(env_bufs[buf_idx][kv.k.len..][0..kv.v.len], kv.v);
            env_bufs[buf_idx][total] = 0;
            env_ptrs[idx] = env_bufs[buf_idx][0..total :0];
            idx += 1;
            buf_idx += 1;
        }

        env_ptrs[idx] = null;
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

    /// Reattach the current terminal to an existing dtach session.
    /// Kills the auto-spawned shell and connects to the dtach socket.
    pub fn reattachDtach(self: *Pane, dtach_socket: []const u8) void {
        const term = self.currentTerminal() orelse return;

        // Store the dtach path
        const dlen = @min(dtach_socket.len, 127);
        @memcpy(self.dtach_path[0..dlen], dtach_socket[0..dlen]);
        self.dtach_path[dlen] = 0;
        self.dtach_path_len = dlen;

        // Feed a command to attach to the dtach socket
        // This replaces the current shell with dtach
        var cmd_buf: [256]u8 = undefined;
        const cmd = std.fmt.bufPrint(&cmd_buf, "exec dtach -a {s}\n", .{dtach_socket}) catch return;
        c.vte_terminal_feed_child(term, cmd.ptr, @intCast(cmd.len));

        log.info("reattached pane to dtach {s}", .{dtach_socket});
    }

    /// Get the currently focused terminal in this pane
    pub fn currentTerminal(self: *Pane) ?*c.VteTerminal {
        if (self.tabs.items.len == 0) return null;
        const page = c.gtk_notebook_get_current_page(self.notebook);
        if (page < 0) return null;
        const idx: usize = @intCast(page);
        if (idx >= self.tabs.items.len) return null;
        return self.tabs.items[idx].terminal;
    }

    /// Get the current tab
    pub fn currentTab(self: *Pane) ?*Tab {
        if (self.tabs.items.len == 0) return null;
        const page = c.gtk_notebook_get_current_page(self.notebook);
        if (page < 0) return null;
        const idx: usize = @intCast(page);
        if (idx >= self.tabs.items.len) return null;
        return &self.tabs.items[idx];
    }

    /// Get the CWD of the innermost foreground process via /proc.
    ///
    /// With dtach, VTE doesn't own the shell process — dtach daemonizes and
    /// VTE's child exits immediately after attaching. So TIOCGPGRP on VTE's
    /// PTY doesn't help. Instead we find the dtach master process by scanning
    /// /proc for our stored socket path, then walk its children to find the
    /// deepest (foreground) process.
    pub fn getCwd(self: *Pane) ?[*:0]const u8 {
        const leaf_pid = self.getLeafPid() orelse return null;
        return readProcCwd(leaf_pid);
    }

    /// Get the name of the active (deepest child) process in this pane.
    /// Returns the process name (e.g. "claude", "npm", "bash") or null.
    pub fn getActiveProcessName(self: *Pane) ?[]const u8 {
        const leaf_pid = self.getLeafPid() orelse return null;
        return readProcComm(leaf_pid);
    }

    /// Push a process name into the ring buffer (called from report_process socket command).
    pub fn pushProcessHistory(self: *Pane, name: []const u8) void {
        if (name.len == 0) return;
        const len = @min(name.len, 31);
        @memcpy(self.proc_history[self.proc_history_idx][0..len], name[0..len]);
        self.proc_history_lens[self.proc_history_idx] = @intCast(len);
        self.proc_history_idx = (self.proc_history_idx + 1) % 16;
        if (self.proc_history_count < 16) self.proc_history_count += 1;
    }

    /// Check if a process name appeared in recent history.
    pub fn hasRecentProcess(self: *const Pane, name: []const u8) bool {
        for (0..self.proc_history_count) |i| {
            const idx = (self.proc_history_idx + 16 - 1 - i) % 16;
            const plen = self.proc_history_lens[idx];
            if (plen > 0 and std.mem.eql(u8, self.proc_history[idx][0..plen], name)) {
                return true;
            }
        }
        return false;
    }

    fn getLeafPid(self: *Pane) ?std.c.pid_t {
        if (self.dtach_path_len == 0) return null;

        // Return cached leaf if fresh (within 1 second)
        const now = std.time.milliTimestamp();
        if (self.cached_leaf_pid > 0 and (now - self.cached_leaf_time) < 1000) {
            return self.cached_leaf_pid;
        }

        // Find dtach master PID (cached, rarely changes)
        if (self.dtach_master_pid <= 0) {
            const dtach_path = self.dtach_path[0..self.dtach_path_len];
            self.dtach_master_pid = findDtachPidBySocket(dtach_path) orelse return null;
        }

        // Walk children (cheap — just a few /proc reads down the tree)
        const leaf = findDeepestChild(self.dtach_master_pid);
        if (leaf <= 0) {
            // dtach might have died, clear cache
            self.dtach_master_pid = 0;
            self.cached_leaf_pid = 0;
            return null;
        }

        self.cached_leaf_pid = leaf;
        self.cached_leaf_time = now;
        return leaf;
    }

    /// Find the dtach master process PID by scanning /proc for a process
    /// whose cmdline contains our dtach socket path.
    fn findDtachPidBySocket(socket_path: []const u8) ?std.c.pid_t {
        var dir = std.fs.openDirAbsolute("/proc", .{ .iterate = true }) catch return null;
        defer dir.close();

        var iter = dir.iterate();
        while (iter.next() catch null) |entry| {
            // Only look at numeric directory names (PIDs)
            const pid = std.fmt.parseInt(std.c.pid_t, entry.name, 10) catch continue;
            if (pid <= 0) continue;

            // Read /proc/<pid>/cmdline
            var cmdline_path_buf: [32]u8 = undefined;
            const cmdline_path = std.fmt.bufPrint(&cmdline_path_buf, "/proc/{d}/cmdline", .{pid}) catch continue;

            const file = std.fs.openFileAbsolute(cmdline_path, .{}) catch continue;
            defer file.close();

            var cmdline_buf: [512]u8 = undefined;
            const n = file.read(&cmdline_buf) catch continue;
            if (n == 0) continue;

            // cmdline is null-separated. Check if it contains "dtach" and our socket path.
            const cmdline = cmdline_buf[0..n];
            if (std.mem.indexOf(u8, cmdline, "dtach") == null) continue;
            if (std.mem.indexOf(u8, cmdline, socket_path) != null) {
                return pid;
            }
        }
        return null;
    }

    /// Walk /proc/<pid>/task/<pid>/children repeatedly to find the leaf process.
    fn findDeepestChild(start_pid: std.c.pid_t) std.c.pid_t {
        var pid = start_pid;
        var depth: u8 = 0;
        while (depth < 8) : (depth += 1) {
            var children_path_buf: [64]u8 = undefined;
            const children_path = std.fmt.bufPrint(
                &children_path_buf,
                "/proc/{d}/task/{d}/children",
                .{ pid, pid },
            ) catch break;

            const file = std.fs.openFileAbsolute(children_path, .{}) catch break;
            defer file.close();

            var buf: [256]u8 = undefined;
            const n = file.read(&buf) catch break;
            if (n == 0) break; // no children — this is the leaf

            // Parse first child PID (space-separated)
            const content = std.mem.trim(u8, buf[0..n], " \n");
            const first_space = std.mem.indexOfScalar(u8, content, ' ') orelse content.len;
            const child_pid = std.fmt.parseInt(std.c.pid_t, content[0..first_space], 10) catch break;
            if (child_pid <= 0) break;

            pid = child_pid;
        }
        return pid;
    }

    /// Read /proc/<pid>/comm — the process name (e.g. "claude", "bash").
    /// Returns a slice into a static buffer, or null.
    fn readProcComm(pid: std.c.pid_t) ?[]const u8 {
        var path_buf: [32]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/comm", .{pid}) catch return null;
        const file = std.fs.openFileAbsolute(path, .{}) catch return null;
        defer file.close();
        const n = file.read(&comm_buf) catch return null;
        if (n == 0) return null;
        // comm has a trailing newline
        const name = std.mem.trim(u8, comm_buf[0..n], "\n ");
        if (name.len == 0) return null;
        return name;
    }

    var comm_buf: [64]u8 = undefined;

    fn readProcCwd(pid: std.c.pid_t) ?[*:0]const u8 {
        var proc_path_buf: [64]u8 = undefined;
        const proc_path = std.fmt.bufPrint(&proc_path_buf, "/proc/{d}/cwd", .{pid}) catch return null;

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

    fn openUrlAndTrack(url: []const u8, _: *c.VteTerminal, pane: ?*Pane) void {
        // Use CDP to open the URL: PUT /json/new?{url}
        // This creates a new tab AND returns the tab ID immediately.
        var cdp_url_buf: [2200]u8 = undefined;
        const cdp_url = std.fmt.bufPrint(&cdp_url_buf,
            "http://localhost:9222/json/new?{s}", .{url},
        ) catch return;
        var cdp_url_z: [2201]u8 = undefined;
        @memcpy(cdp_url_z[0..cdp_url.len], cdp_url);
        cdp_url_z[cdp_url.len] = 0;

        const pid = std.posix.fork() catch return;
        if (pid == 0) {
            const argv = [_:null]?[*:0]const u8{
                "curl", "-s", "-X", "PUT",
                cdp_url_z[0..cdp_url.len :0],
                "-o", "/tmp/cmux-cdp-new.json",
                null,
            };
            _ = std.posix.execvpeZ("curl", &argv, @ptrCast(std.c.environ)) catch {};
            std.posix.exit(1);
        }
        _ = std.posix.waitpid(pid, 0);

        // Read response — contains {"id": "TARGET_ID", "url": "...", ...}
        const file = std.fs.openFileAbsolute("/tmp/cmux-cdp-new.json", .{}) catch {
            fallbackOpen(url);
            return;
        };
        defer file.close();
        var buf: [4096]u8 = undefined;
        const n = file.read(&buf) catch { fallbackOpen(url); return; };
        if (n == 0) { fallbackOpen(url); return; }
        const json = buf[0..n];

        // Extract "id" from response
        const id_needle = "\"id\":";
        if (std.mem.indexOf(u8, json, id_needle)) |id_key| {
            const after = json[id_key + id_needle.len ..];
            const q1 = std.mem.indexOfScalar(u8, after, '"') orelse { fallbackOpen(url); return; };
            const content = after[q1 + 1 ..];
            const q2 = std.mem.indexOfScalar(u8, content, '"') orelse { fallbackOpen(url); return; };
            const target_id = content[0..q2];

            log.info("CDP: opened tab {s} for {s}", .{ target_id, url });
            if (pane) |p| storeBrowserTab(p, target_id, url);
        } else {
            log.info("CDP: no id in response, falling back", .{});
            fallbackOpen(url);
        }
    }

    fn fallbackOpen(url: []const u8) void {
        var url_z: [2048]u8 = undefined;
        const ulen = @min(url.len, 2047);
        @memcpy(url_z[0..ulen], url[0..ulen]);
        url_z[ulen] = 0;
        const display = c.gdk_display_get_default();
        const ctx: ?*c.GAppLaunchContext = if (display) |d|
            @ptrCast(@alignCast(c.gdk_display_get_app_launch_context(d)))
        else null;
        var err: ?*c.GError = null;
        _ = c.g_app_info_launch_default_for_uri(&url_z, ctx, &err);
        if (ctx) |lc| c.g_object_unref(@ptrCast(@alignCast(lc)));
        if (err) |e| c.g_error_free(e);
    }

    fn _dead_code_start_marker() void { // REMOVE THIS BLOCK
    }
    fn _unused_snapshotCdpTabIds(ids: *[64][64]u8, count: *usize) void {
        count.* = 0;
        const pid = std.posix.fork() catch return;
        if (pid == 0) {
            const argv = [_:null]?[*:0]const u8{
                "curl", "-s", "-o", "/tmp/cmux-cdp-before.json",
                "http://localhost:9222/json", null,
            };
            _ = std.posix.execvpeZ("curl", &argv, @ptrCast(std.c.environ)) catch {};
            std.posix.exit(1);
        }
        _ = std.posix.waitpid(pid, 0);

        const file = std.fs.openFileAbsolute("/tmp/cmux-cdp-before.json", .{}) catch return;
        defer file.close();
        var buf: [16384]u8 = undefined;
        const n = file.read(&buf) catch return;
        const json = buf[0..n];

        // Extract all "id": "XXX" values
        var pos: usize = 0;
        while (pos < json.len and count.* < 64) {
            const needle = "\"id\": \"";
            if (std.mem.indexOfPos(u8, json, pos, needle)) |key_pos| {
                const id_start = key_pos + needle.len;
                if (std.mem.indexOfScalarPos(u8, json, id_start, '"')) |id_end| {
                    const id = json[id_start..id_end];
                    const ilen = @min(id.len, 64);
                    @memcpy(ids[count.*][0..ilen], id[0..ilen]);
                    // Pad rest with 0 for comparison
                    if (ilen < 64) ids[count.*][ilen] = 0;
                    count.* += 1;
                    pos = id_end + 1;
                } else break;
            } else break;
        }
    }

    const CdpPollCtx = struct {
        url: [2048]u8,
        url_len: usize,
        attempts: u8,
        terminal: *c.VteTerminal,
        pane: ?*Pane,
        before_ids: [64][64]u8,
        before_count: usize,
    };

    fn onCdpPoll(user_data: ?*anyopaque) callconv(.C) c.gboolean {
        const ctx: *CdpPollCtx = @ptrCast(@alignCast(user_data orelse return 0));
        ctx.attempts += 1;

        // Fetch current tabs
        var after_ids: [64][64]u8 = undefined;
        var after_urls: [64][256]u8 = undefined;
        var after_count: usize = 0;
        snapshotCdpTabs(&after_ids, &after_urls, &after_count);

        // Find the NEW tab (in after but not in before)
        for (0..after_count) |i| {
            const id = after_ids[i];
            var is_new = true;
            for (0..ctx.before_count) |j| {
                if (std.mem.eql(u8, &id, &ctx.before_ids[j])) {
                    is_new = false;
                    break;
                }
            }
            if (is_new) {
                // Found the new tab!
                const id_slice = std.mem.sliceTo(&after_ids[i], 0);
                const url_slice = std.mem.sliceTo(&after_urls[i], 0);

                log.info("CDP: new tab {s} url={s}", .{ id_slice, url_slice });

                if (ctx.pane) |pane| {
                    // Use the actual browser URL (after redirect) for display
                    const display_url = if (url_slice.len > 0) url_slice else ctx.url[0..ctx.url_len];
                    storeBrowserTab(pane, id_slice, display_url);
                }

                std.heap.c_allocator.destroy(ctx);
                return 0;
            }
        }

        if (ctx.attempts >= 10) {
            log.info("CDP: gave up finding new tab", .{});
            std.heap.c_allocator.destroy(ctx);
            return 0;
        }
        return 1;
    }

    fn snapshotCdpTabs(ids: *[64][64]u8, urls: *[64][256]u8, count: *usize) void {
        count.* = 0;
        const pid = std.posix.fork() catch return;
        if (pid == 0) {
            const argv = [_:null]?[*:0]const u8{
                "curl", "-s", "-o", "/tmp/cmux-cdp.json",
                "http://localhost:9222/json", null,
            };
            _ = std.posix.execvpeZ("curl", &argv, @ptrCast(std.c.environ)) catch {};
            std.posix.exit(1);
        }
        _ = std.posix.waitpid(pid, 0);

        const file = std.fs.openFileAbsolute("/tmp/cmux-cdp.json", .{}) catch return;
        defer file.close();
        var buf: [32768]u8 = undefined;
        const n = file.read(&buf) catch return;
        const json = buf[0..n];

        // Extract "id" and "url" pairs from each entry
        const id_needle = "\"id\": \"";
        const url_needle = "\"url\": \"";
        var pos: usize = 0;

        while (count.* < 64) {
            // Find next "id"
            const id_pos = std.mem.indexOfPos(u8, json, pos, id_needle) orelse break;
            const id_start = id_pos + id_needle.len;
            const id_end = std.mem.indexOfScalarPos(u8, json, id_start, '"') orelse break;
            const id = json[id_start..id_end];

            // Find next "url" after this id
            const url_pos = std.mem.indexOfPos(u8, json, id_end, url_needle) orelse break;
            const url_start = url_pos + url_needle.len;
            const url_end = std.mem.indexOfScalarPos(u8, json, url_start, '"') orelse break;
            const url = json[url_start..url_end];

            const ilen = @min(id.len, 63);
            @memcpy(ids[count.*][0..ilen], id[0..ilen]);
            ids[count.*][ilen] = 0;

            const ulen = @min(url.len, 255);
            @memcpy(urls[count.*][0..ulen], url[0..ulen]);
            urls[count.*][ulen] = 0;

            count.* += 1;
            pos = url_end + 1;
        }
    }

    fn storeBrowserTab(pane: *Pane, target_id: []const u8, url: []const u8) void {
        // Find a free slot (or check for duplicate)
        var slot: ?usize = null;
        for (pane.browser_tabs, 0..) |bt_opt, i| {
            if (bt_opt) |bt| {
                // Skip if already tracking this URL
                if (std.mem.eql(u8, bt.url[0..bt.url_len], url[0..@min(url.len, 256)])) return;
            } else if (slot == null) {
                slot = i;
            }
        }
        const idx = slot orelse return; // all slots full

        const tid_len = @min(target_id.len, 63);
        const url_len = @min(url.len, 255);

        var bt = BrowserTab{
            .target_id = undefined,
            .target_id_len = tid_len,
            .url = undefined,
            .url_len = url_len,
            .button = null,
        };
        @memcpy(bt.target_id[0..tid_len], target_id[0..tid_len]);
        bt.target_id[tid_len] = 0;
        @memcpy(bt.url[0..url_len], url[0..url_len]);
        bt.url[url_len] = 0;

        pane.browser_tabs[idx] = bt;
        pane.rebuildBrowserButtons();
    }

    /// Rebuild the overlay button box from the browser_tabs list.
    fn rebuildBrowserButtons(self: *Pane) void {
        const tab = self.currentTab() orelse return;

        // Remove old button box
        if (self.browser_tab_box) |old_box| {
            c.gtk_overlay_remove_overlay(tab.overlay, asWidget(old_box));
            self.browser_tab_box = null;
        }

        // Count active tabs
        var count: usize = 0;
        for (self.browser_tabs) |bt_opt| {
            if (bt_opt != null) count += 1;
        }
        if (count == 0) return;

        // Create vertical box for buttons, anchored bottom-right
        const box: *c.GtkBox = @ptrCast(@alignCast(
            c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 2) orelse return,
        ));
        c.gtk_widget_set_halign(asWidget(box), c.GTK_ALIGN_END);
        c.gtk_widget_set_valign(asWidget(box), c.GTK_ALIGN_END);
        c.gtk_widget_set_margin_end(asWidget(box), 8);
        c.gtk_widget_set_margin_bottom(asWidget(box), 8);

        for (&self.browser_tabs) |*bt_opt| {
            if (bt_opt.*) |*bt| {
                var display_buf: [80]u8 = undefined;
                const ulen = bt.url_len;
                const display = if (ulen > 40)
                    std.fmt.bufPrint(&display_buf, "🌐 {s}...", .{bt.url[0..37]}) catch bt.url[0..ulen]
                else
                    std.fmt.bufPrint(&display_buf, "🌐 {s}", .{bt.url[0..ulen]}) catch bt.url[0..ulen];

                var label_z: [81]u8 = undefined;
                @memcpy(label_z[0..display.len], display);
                label_z[display.len] = 0;

                const btn = c.gtk_button_new_with_label(&label_z) orelse continue;
                c.gtk_widget_set_opacity(btn, 0.9);
                c.gtk_widget_add_css_class(btn, "suggested-action");

                // Store target_id on the button
                c.g_object_set_data(
                    @ptrCast(@alignCast(btn)),
                    "cmux-target-id",
                    @constCast(@ptrCast(&bt.target_id)),
                );

                _ = c.g_signal_connect_data(
                    @ptrCast(btn),
                    "clicked",
                    @ptrCast(&onBrowserTabClick),
                    null,
                    null,
                    0,
                );

                bt.button = btn;
                c.gtk_box_append(box, btn);
            }
        }

        c.gtk_overlay_add_overlay(tab.overlay, asWidget(box));
        self.browser_tab_box = box;
    }

    /// Called from the periodic sidebar refresh to check if CDP tabs are still open.
    pub fn pollBrowserTabs(self: *Pane) void {
        var has_tabs = false;
        for (self.browser_tabs) |bt_opt| {
            if (bt_opt != null) { has_tabs = true; break; }
        }
        if (!has_tabs) return;

        // Fetch current CDP tabs
        const pid = std.posix.fork() catch return;
        if (pid == 0) {
            const argv = [_:null]?[*:0]const u8{
                "curl", "-s", "-o", "/tmp/cmux-cdp-poll.json",
                "http://localhost:9222/json", null,
            };
            _ = std.posix.execvpeZ("curl", &argv, @ptrCast(std.c.environ)) catch {};
            std.posix.exit(1);
        }
        _ = std.posix.waitpid(pid, 0);

        const file = std.fs.openFileAbsolute("/tmp/cmux-cdp-poll.json", .{}) catch return;
        defer file.close();
        var buf: [32768]u8 = undefined;
        const n = file.read(&buf) catch return;
        const json = buf[0..n];

        // Check each tracked tab — remove if not found in CDP response
        var changed = false;
        for (&self.browser_tabs) |*bt_opt| {
            if (bt_opt.*) |bt| {
                const tid = bt.target_id[0..bt.target_id_len];
                if (std.mem.indexOf(u8, json, tid) == null) {
                    // Tab no longer exists in browser
                    log.info("CDP: tab {s} closed in browser, removing", .{tid});
                    bt_opt.* = null;
                    changed = true;
                }
            }
        }

        if (changed) self.rebuildBrowserButtons();
    }

    fn onBrowserTabClick(button: *c.GtkButton, _: ?*anyopaque) callconv(.C) void {
        const raw = c.g_object_get_data(@ptrCast(@alignCast(button)), "cmux-target-id") orelse return;
        const target_id: [*:0]const u8 = @ptrCast(raw);
        const tid = std.mem.span(target_id);

        log.info("CDP: activating tab {s}", .{tid});

        var script_buf: [512]u8 = undefined;
        const script = std.fmt.bufPrint(&script_buf,
            "curl -s http://localhost:9222/json/activate/{s} >/dev/null; xdotool search --name 'Brave' windowactivate 2>/dev/null",
            .{tid},
        ) catch return;
        var script_z: [513]u8 = undefined;
        @memcpy(script_z[0..script.len], script);
        script_z[script.len] = 0;

        const pid = std.posix.fork() catch return;
        if (pid == 0) {
            const argv = [_:null]?[*:0]const u8{
                "sh", "-c", script_z[0..script.len :0],
                null,
            };
            _ = std.posix.execvpeZ("sh", &argv, @ptrCast(std.c.environ)) catch {};
            std.posix.exit(1);
        }
    }

    // --- Signal handlers ---

    fn onFocusEnter(_: *c.GtkEventControllerFocus, pane: *Pane) callconv(.C) void {
        if (pane.on_focus) |callback| {
            callback(pane, pane.on_focus_ctx);
        }
    }

    fn onSpawnComplete(
        _: *c.VteTerminal,
        pid: c.GPid,
        err: ?*c.GError,
        user_data: ?*anyopaque,
    ) callconv(.C) void {
        if (err) |e| {
            log.err("spawn failed: {s}", .{@as([*:0]const u8, @ptrCast(e.message))});
        } else {
            log.info("shell spawned with pid {}", .{pid});
        }
        if (user_data) |ud| {
            const pane: *Pane = @ptrCast(@alignCast(ud));
            pane.ready = true;
        }
    }

    fn onChildExited(terminal: *c.VteTerminal, _: c.gint, pane: *Pane) callconv(.C) void {
        log.info("child exited in pane {s}", .{uuid.asSlice(&pane.id)});
        pane.closeTab(terminal);
    }

    fn onTitleChanged(terminal: *c.VteTerminal, pane: *Pane) callconv(.C) void {
        const title = c.vte_terminal_get_window_title(terminal) orelse return;

        // Update pane tab label
        for (pane.tabs.items) |tab| {
            if (tab.terminal == terminal) {
                c.gtk_label_set_text(tab.label, title);
                break;
            }
        }

        // Propagate to workspace title (if this is the focused terminal)
        if (pane.currentTerminal() == terminal) {
            if (pane.on_title) |callback| {
                callback(title, pane.on_title_ctx);
            }
        }
    }
};
