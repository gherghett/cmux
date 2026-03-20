const std = @import("std");
const cc = @import("c.zig");
const c = cc.c;
const asWidget = cc.asWidget;
const TabManager = @import("tab_manager.zig").TabManager;
const Sidebar = @import("sidebar.zig").Sidebar;
const SplitTree = @import("split_tree.zig").SplitTree;
const session = @import("session.zig");

const log = std.log.scoped(.window);

/// Main application window.
pub const Window = struct {
    window: *c.AdwApplicationWindow,
    tab_manager: TabManager,
    sidebar: Sidebar,
    stack: *c.GtkStack,
    allocator: std.mem.Allocator,

    /// Creates a heap-allocated Window so all internal pointers remain stable.
    pub fn create(app: *c.AdwApplication, allocator: std.mem.Allocator, socket_path: []const u8) !*Window {
        const self = try allocator.create(Window);
        errdefer allocator.destroy(self);

        const window: *c.AdwApplicationWindow = @ptrCast(@alignCast(
            c.adw_application_window_new(@ptrCast(@alignCast(app))) orelse
                return error.GtkWidgetCreateFailed,
        ));

        c.gtk_window_set_default_size(@ptrCast(@alignCast(window)), 1200, 800);
        c.gtk_window_set_title(@ptrCast(@alignCast(window)), "cmux");

        // Create the content stack
        const stack: *c.GtkStack = @ptrCast(@alignCast(
            c.gtk_stack_new() orelse return error.GtkWidgetCreateFailed,
        ));
        c.gtk_stack_set_transition_type(stack, c.GTK_STACK_TRANSITION_TYPE_NONE);

        // Initialize struct fields first so pointers are stable
        self.* = .{
            .window = window,
            .tab_manager = TabManager.init(allocator, stack, socket_path),
            .sidebar = undefined, // filled below
            .stack = stack,
            .allocator = allocator,
        };

        // Now &self.tab_manager is a stable heap pointer
        self.sidebar = try Sidebar.init(&self.tab_manager);
        // Wire up sidebar refresh callback (self.sidebar is now at its final heap location)
        self.sidebar.connectTabManager();

        // Layout: horizontal paned with sidebar on left, stack on right
        const paned: *c.GtkPaned = @ptrCast(@alignCast(
            c.gtk_paned_new(c.GTK_ORIENTATION_HORIZONTAL) orelse
                return error.GtkWidgetCreateFailed,
        ));

        c.gtk_paned_set_start_child(paned, self.sidebar.widget());
        c.gtk_paned_set_end_child(paned, asWidget(stack));
        c.gtk_paned_set_resize_start_child(paned, 0);
        c.gtk_paned_set_resize_end_child(paned, 1);
        c.gtk_paned_set_shrink_start_child(paned, 0);
        c.gtk_paned_set_shrink_end_child(paned, 0);
        c.gtk_paned_set_position(paned, 180);

        // Use AdwToolbarView for header bar + content
        const toolbar_view: *c.AdwToolbarView = @ptrCast(@alignCast(
            c.adw_toolbar_view_new() orelse return error.GtkWidgetCreateFailed,
        ));
        const header = c.adw_header_bar_new() orelse return error.GtkWidgetCreateFailed;
        c.adw_toolbar_view_add_top_bar(toolbar_view, header);
        c.adw_toolbar_view_set_content(toolbar_view, asWidget(paned));

        c.adw_application_window_set_content(window, asWidget(toolbar_view));

        // No workspace created here — onActivate calls session.reconcile()
        // which either restores workspaces or creates a fresh default.

        // Set up keyboard shortcuts
        self.setupShortcuts();

        // Save session on window close
        _ = c.g_signal_connect_data(
            @ptrCast(window),
            "close-request",
            @ptrCast(&onCloseRequest),
            self,
            null,
            0,
        );

        return self;
    }

    fn onCloseRequest(_: *c.GtkWindow, self_ptr: ?*anyopaque) callconv(.C) c.gboolean {
        const self: *Window = @ptrCast(@alignCast(self_ptr orelse return 0));
        session.save(&self.tab_manager);
        // Mark all workspaces as closing to suppress auto-respawn during GTK teardown
        for (self.tab_manager.workspaces.items) |ws| {
            ws.closing = true;
        }
        return 0;
    }


    pub fn destroy(self: *Window) void {
        self.tab_manager.deinit();
        self.allocator.destroy(self);
    }

    pub fn show(self: *Window) void {
        // Just make visible — don't steal focus from the user's current window.
        // The terminal gets focus when the user clicks into the cmux window.
        c.gtk_widget_set_visible(@ptrCast(@alignCast(self.window)), 1);
    }

    fn setupShortcuts(self: *Window) void {
        const window_widget = asWidget(self.window);
        const controller = c.gtk_event_controller_key_new() orelse return;

        // Capture phase: intercept keys BEFORE VTE consumes them
        c.gtk_event_controller_set_propagation_phase(controller, c.GTK_PHASE_CAPTURE);

        // Store stable pointer to self
        c.g_object_set_data(@ptrCast(@alignCast(window_widget)), "cmux-window", self);

        _ = c.g_signal_connect_data(
            @ptrCast(controller),
            "key-pressed",
            @ptrCast(&onKeyPressed),
            window_widget,
            null,
            0,
        );

        c.gtk_widget_add_controller(window_widget, controller);
    }

    fn onKeyPressed(
        _: *c.GtkEventControllerKey,
        keyval: c.guint,
        _: c.guint,
        state: c.GdkModifierType,
        window_widget: *c.GtkWidget,
    ) callconv(.C) c.gboolean {
        const raw = c.g_object_get_data(@ptrCast(@alignCast(window_widget)), "cmux-window") orelse return 0;
        const self: *Window = @ptrCast(@alignCast(raw));
        const tab_manager = &self.tab_manager;

        const ctrl_shift = c.GDK_CONTROL_MASK | c.GDK_SHIFT_MASK;
        const alt_mask = c.GDK_ALT_MASK;

        if (state & ctrl_shift == ctrl_shift) {
            switch (keyval) {
                c.GDK_KEY_C, c.GDK_KEY_c => {
                    // Copy
                    if (tab_manager.current()) |ws| {
                        if (ws.split_tree.focusedPane()) |pane| {
                            if (pane.currentTerminal()) |term| {
                                c.vte_terminal_copy_clipboard_format(term, c.VTE_FORMAT_TEXT);
                            }
                        }
                    }
                    return 1;
                },
                c.GDK_KEY_V, c.GDK_KEY_v => {
                    // Paste
                    if (tab_manager.current()) |ws| {
                        if (ws.split_tree.focusedPane()) |pane| {
                            if (pane.currentTerminal()) |term| {
                                c.vte_terminal_paste_clipboard(term);
                            }
                        }
                    }
                    return 1;
                },
                c.GDK_KEY_T, c.GDK_KEY_t => {
                    _ = tab_manager.createWorkspace() catch return 0;
                    return 1;
                },
                c.GDK_KEY_Q, c.GDK_KEY_q => {
                    // Close current workspace
                    if (tab_manager.current()) |ws| {
                        var ws_id = ws.id;
                        tab_manager.closeWorkspace(&ws_id);
                    }
                    return 1;
                },
                c.GDK_KEY_N, c.GDK_KEY_n => {
                    // New tab in current pane, inheriting CWD
                    if (tab_manager.current()) |ws| {
                        if (ws.split_tree.focusedPane()) |pane| {
                            const cwd = pane.getCwd();
                            _ = pane.addTab(cwd) catch {};
                        }
                    }
                    return 1;
                },
                c.GDK_KEY_E, c.GDK_KEY_e => {
                    if (tab_manager.current()) |ws| {
                        ws.splitFocused(.horizontal) catch {};
                    }
                    return 1;
                },
                c.GDK_KEY_O, c.GDK_KEY_o => {
                    if (tab_manager.current()) |ws| {
                        ws.splitFocused(.vertical) catch {};
                    }
                    return 1;
                },
                c.GDK_KEY_W, c.GDK_KEY_w => {
                    // Close current tab. If last tab in pane, closes the pane.
                    // If last pane in workspace, closes the workspace.
                    if (tab_manager.current()) |ws| {
                        if (ws.split_tree.focusedPane()) |pane| {
                            if (pane.currentTerminal()) |term| {
                                pane.closeTab(term);
                            }
                        }
                    }
                    return 1;
                },
                c.GDK_KEY_Page_Up => {
                    tab_manager.selectPrev();
                    return 1;
                },
                c.GDK_KEY_Page_Down => {
                    tab_manager.selectNext();
                    return 1;
                },
                c.GDK_KEY_Left => {
                    if (tab_manager.current()) |ws|
                        ws.split_tree.moveFocus(.vertical);
                    return 1;
                },
                c.GDK_KEY_Right => {
                    if (tab_manager.current()) |ws|
                        ws.split_tree.moveFocus(.vertical);
                    return 1;
                },
                c.GDK_KEY_Up => {
                    if (tab_manager.current()) |ws|
                        ws.split_tree.moveFocus(.horizontal);
                    return 1;
                },
                c.GDK_KEY_Down => {
                    if (tab_manager.current()) |ws|
                        ws.split_tree.moveFocus(.horizontal);
                    return 1;
                },
                else => {},
            }
        }

        // Ctrl only (no Shift) — zoom
        const ctrl_only = c.GDK_CONTROL_MASK;
        if (state & (ctrl_only | c.GDK_SHIFT_MASK) == ctrl_only) {
            switch (keyval) {
                c.GDK_KEY_plus, c.GDK_KEY_equal => {
                    // Ctrl+= or Ctrl++ → zoom in
                    if (tab_manager.current()) |ws| {
                        if (ws.split_tree.focusedPane()) |pane| {
                            if (pane.currentTab()) |tab| tab.zoomIn();
                        }
                    }
                    return 1;
                },
                c.GDK_KEY_minus => {
                    // Ctrl+- → zoom out
                    if (tab_manager.current()) |ws| {
                        if (ws.split_tree.focusedPane()) |pane| {
                            if (pane.currentTab()) |tab| tab.zoomOut();
                        }
                    }
                    return 1;
                },
                c.GDK_KEY_0 => {
                    // Ctrl+0 → reset zoom
                    if (tab_manager.current()) |ws| {
                        if (ws.split_tree.focusedPane()) |pane| {
                            if (pane.currentTab()) |tab| tab.zoomReset();
                        }
                    }
                    return 1;
                },
                else => {},
            }
        }

        if (state & alt_mask == alt_mask) {
            if (keyval >= c.GDK_KEY_1 and keyval <= c.GDK_KEY_9) {
                tab_manager.selectByIndex(keyval - c.GDK_KEY_1);
                return 1;
            }
        }

        return 0;
    }
};
