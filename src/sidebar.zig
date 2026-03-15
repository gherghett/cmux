const std = @import("std");
const cc = @import("c.zig");
const c = cc.c;
const asWidget = cc.asWidget;
const uuid = @import("uuid.zig");
const TabManager = @import("tab_manager.zig").TabManager;
const Workspace = @import("workspace.zig").Workspace;
const Pane = @import("pane.zig").Pane;

const log = std.log.scoped(.sidebar);

/// Vertical sidebar with stable widget references per workspace.
/// Rows are built once and updated in-place — no teardown/rebuild cycle.
pub const Sidebar = struct {
    list_box: *c.GtkListBox,
    scrolled: *c.GtkScrolledWindow,
    tab_manager: *TabManager,

    pub fn init(tab_manager: *TabManager) !Sidebar {
        const list_box: *c.GtkListBox = @ptrCast(@alignCast(c.gtk_list_box_new() orelse
            return error.GtkWidgetCreateFailed));
        c.gtk_list_box_set_selection_mode(list_box, c.GTK_SELECTION_SINGLE);

        const scrolled: *c.GtkScrolledWindow = @ptrCast(@alignCast(
            c.gtk_scrolled_window_new() orelse return error.GtkWidgetCreateFailed,
        ));
        c.gtk_scrolled_window_set_child(scrolled, asWidget(list_box));
        c.gtk_scrolled_window_set_policy(scrolled, c.GTK_POLICY_NEVER, c.GTK_POLICY_AUTOMATIC);
        c.gtk_widget_set_size_request(asWidget(scrolled), 200, -1);
        c.gtk_widget_set_vexpand(asWidget(scrolled), 1);

        _ = c.g_signal_connect_data(
            @ptrCast(list_box), "row-activated", @ptrCast(&onRowActivated), tab_manager, null, 0,
        );

        return .{ .list_box = list_box, .scrolled = scrolled, .tab_manager = tab_manager };
    }

    pub fn connectTabManager(self: *Sidebar) void {
        self.tab_manager.on_change = &onTabManagerChange;
        self.tab_manager.on_change_data = self;
        _ = c.g_timeout_add(2000, @ptrCast(&onPeriodicRefresh), self);
    }

    pub fn widget(self: *Sidebar) *c.GtkWidget {
        return asWidget(self.scrolled);
    }

    // === Core: sync rows with workspace list ===

    /// Ensure each workspace has a row. Add missing rows, update all.
    pub fn sync(self: *Sidebar) void {
        // Add rows for new workspaces (that don't have sidebar widgets yet)
        for (self.tab_manager.workspaces.items) |ws| {
            if (ws.sidebar == null) {
                self.buildRow(ws);
                if (ws.sidebar) |sb| {
                    c.gtk_list_box_append(self.list_box, asWidget(sb.row_box));
                }
            }
        }

        // Remove rows for deleted workspaces:
        // Walk the listbox and remove any row whose workspace is gone.
        var row_idx: c_int = 0;
        while (c.gtk_list_box_get_row_at_index(self.list_box, row_idx)) |row| {
            const row_w = asWidget(row);
            const child = c.gtk_widget_get_first_child(row_w);
            if (child == null) {
                c.gtk_list_box_remove(self.list_box, row_w);
                continue;
            }
            // Check if this row's workspace still exists
            var found = false;
            for (self.tab_manager.workspaces.items) |ws| {
                if (ws.sidebar) |sb| {
                    if (asWidget(sb.row_box) == child) {
                        found = true;
                        break;
                    }
                }
            }
            if (!found) {
                c.gtk_list_box_remove(self.list_box, row_w);
            } else {
                row_idx += 1;
            }
        }

        self.updateAll();
    }

    /// Update all row contents in-place (no widget creation/destruction).
    fn updateAll(self: *Sidebar) void {
        for (self.tab_manager.workspaces.items, 0..) |ws, i| {
            self.updateRow(ws, i == self.tab_manager.selected);
        }

        // Update selection highlight
        if (self.tab_manager.selected < self.tab_manager.workspaces.items.len) {
            if (c.gtk_list_box_get_row_at_index(self.list_box, @intCast(self.tab_manager.selected))) |row| {
                c.gtk_list_box_select_row(self.list_box, row);
            }
        }
    }

    /// Build a row for a workspace (called once per workspace lifetime).
    fn buildRow(self: *Sidebar, ws: *Workspace) void {
        const row_box: *c.GtkBox = @ptrCast(@alignCast(
            c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 1) orelse return,
        ));
        const row_w = asWidget(row_box);
        c.gtk_widget_set_margin_start(row_w, 8);
        c.gtk_widget_set_margin_end(row_w, 8);
        c.gtk_widget_set_margin_top(row_w, 6);
        c.gtk_widget_set_margin_bottom(row_w, 6);

        // Row 1: indicator + title
        const title_row: *c.GtkBox = @ptrCast(@alignCast(
            c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 4) orelse return,
        ));
        const indicator_label: *c.GtkLabel = @ptrCast(@alignCast(c.gtk_label_new("") orelse return));
        c.gtk_box_append(title_row, asWidget(indicator_label));

        const title_label: *c.GtkLabel = @ptrCast(@alignCast(c.gtk_label_new("") orelse return));
        c.gtk_label_set_xalign(title_label, 0);
        c.gtk_widget_set_hexpand(asWidget(title_label), 1);
        c.gtk_label_set_ellipsize(title_label, c.PANGO_ELLIPSIZE_END);
        c.gtk_box_append(title_row, asWidget(title_label));

        c.gtk_box_append(row_box, asWidget(title_row));

        // Row 2: Claude message
        const message_label: *c.GtkLabel = @ptrCast(@alignCast(c.gtk_label_new("") orelse return));
        c.gtk_label_set_xalign(message_label, 0);
        c.gtk_label_set_ellipsize(message_label, c.PANGO_ELLIPSIZE_END);
        c.gtk_widget_add_css_class(asWidget(message_label), "dim-label");
        c.gtk_widget_add_css_class(asWidget(message_label), "caption");
        c.gtk_box_append(row_box, asWidget(message_label));

        // Row 3: CWDs
        const cwd_label: *c.GtkLabel = @ptrCast(@alignCast(c.gtk_label_new("") orelse return));
        c.gtk_label_set_xalign(cwd_label, 0);
        c.gtk_label_set_ellipsize(cwd_label, c.PANGO_ELLIPSIZE_END);
        c.gtk_widget_add_css_class(asWidget(cwd_label), "dim-label");
        c.gtk_widget_add_css_class(asWidget(cwd_label), "caption");
        c.gtk_box_append(row_box, asWidget(cwd_label));

        // Row 4: minimap
        const minimap_picture: *c.GtkPicture = @ptrCast(@alignCast(
            c.gtk_picture_new() orelse return,
        ));
        c.gtk_picture_set_content_fit(minimap_picture, c.GTK_CONTENT_FIT_CONTAIN);
        c.gtk_widget_set_size_request(asWidget(minimap_picture), -1, 48);
        c.gtk_box_append(row_box, asWidget(minimap_picture));

        // Right-click menu
        const click = c.gtk_gesture_click_new() orelse return;
        c.gtk_gesture_single_set_button(@ptrCast(@alignCast(click)), 3);
        c.g_object_set_data(@ptrCast(@alignCast(row_w)), "cmux-sidebar", self);
        c.g_object_set_data(@ptrCast(@alignCast(row_w)), "cmux-ws", ws);
        _ = c.g_signal_connect_data(
            @ptrCast(click), "pressed", @ptrCast(&onRightClick), row_w, null, 0,
        );
        c.gtk_widget_add_controller(row_w, @ptrCast(@alignCast(click)));

        // Store on workspace
        ws.sidebar = .{
            .row_box = row_box,
            .indicator_label = indicator_label,
            .title_label = title_label,
            .message_label = message_label,
            .cwd_label = cwd_label,
            .minimap_picture = minimap_picture,
        };
    }

    /// Update a row's content in-place.
    fn updateRow(self: *Sidebar, ws: *Workspace, is_active: bool) void {
        const sb = ws.sidebar orelse return;

        // Indicator
        const ind = getIndicator(ws.claude_status);
        c.gtk_label_set_text(sb.indicator_label, ind.text orelse "");
        // TODO: CSS class switching for colors

        // Title
        var title_buf: [257]u8 = undefined;
        const title = ws.displayTitle();
        const tlen = @min(title.len, 256);
        @memcpy(title_buf[0..tlen], title[0..tlen]);
        title_buf[tlen] = 0;
        c.gtk_label_set_text(sb.title_label, &title_buf);

        // Claude message
        if (ws.claudeMessage()) |msg| {
            var msg_buf: [257]u8 = undefined;
            const mlen = @min(msg.len, 256);
            for (0..mlen) |j| {
                msg_buf[j] = if (msg[j] == '\n' or msg[j] == '\r') ' ' else msg[j];
            }
            msg_buf[mlen] = 0;
            c.gtk_label_set_text(sb.message_label, &msg_buf);
            c.gtk_widget_set_visible(asWidget(sb.message_label), 1);
        } else {
            c.gtk_label_set_text(sb.message_label, "");
            c.gtk_widget_set_visible(asWidget(sb.message_label), 0);
        }

        // CWDs
        var cwd_text_buf: [512]u8 = undefined;
        const cwd_text = self.buildCwdText(ws, &cwd_text_buf);
        if (cwd_text.len > 0) {
            var cwd_z: [513]u8 = undefined;
            @memcpy(cwd_z[0..cwd_text.len], cwd_text);
            cwd_z[cwd_text.len] = 0;
            c.gtk_label_set_text(sb.cwd_label, &cwd_z);
            c.gtk_widget_set_visible(asWidget(sb.cwd_label), 1);
        } else {
            c.gtk_widget_set_visible(asWidget(sb.cwd_label), 0);
        }

        // Minimap
        if (ws.minimap_paintable) |p| {
            c.gtk_picture_set_paintable(sb.minimap_picture, @ptrCast(@alignCast(p)));
            c.gtk_widget_set_opacity(asWidget(sb.minimap_picture), if (is_active) 0.8 else 0.6);
            c.gtk_widget_set_visible(asWidget(sb.minimap_picture), 1);
        } else {
            c.gtk_widget_set_visible(asWidget(sb.minimap_picture), 0);
        }
    }

    // === Periodic timer ===

    fn onPeriodicRefresh(user_data: ?*anyopaque) callconv(.C) c.gboolean {
        const self: *Sidebar = @ptrCast(@alignCast(user_data orelse return 0));

        // Snapshot minimap for active workspace
        if (self.tab_manager.current()) |ws| {
            updateMinimapSnapshot(ws);
        }

        // Update all rows in-place (no rebuild)
        self.updateAll();

        // Poll CDP
        var pane_list = std.ArrayList(*Pane).init(self.tab_manager.allocator);
        defer pane_list.deinit();
        for (self.tab_manager.workspaces.items) |ws| {
            ws.allPanes(&pane_list) catch continue;
        }
        for (pane_list.items) |pane| pane.pollBrowserTabs();

        return 1;
    }

    fn updateMinimapSnapshot(ws: *Workspace) void {
        const live = c.gtk_widget_paintable_new(ws.containerWidget());
        if (live) |live_p| {
            defer c.g_object_unref(live_p);
            const paintable: *c.GdkPaintable = @ptrCast(@alignCast(live_p));
            const w = c.gdk_paintable_get_intrinsic_width(paintable);
            const h = c.gdk_paintable_get_intrinsic_height(paintable);
            if (w > 0 and h > 0) {
                const snap = c.gtk_snapshot_new();
                c.gdk_paintable_snapshot(paintable, @ptrCast(@alignCast(snap)), @floatFromInt(w), @floatFromInt(h));
                const size = c.graphene_size_t{ .width = @floatFromInt(w), .height = @floatFromInt(h) };
                const static_p = c.gtk_snapshot_free_to_paintable(snap, &size);
                if (static_p) |sp| {
                    if (ws.minimap_paintable) |old| c.g_object_unref(@ptrCast(@alignCast(old)));
                    ws.minimap_paintable = @ptrCast(sp);
                }
            }
        }
    }

    // === Helpers ===

    const Indicator = struct { text: ?[*:0]const u8, css_class: ?[*:0]const u8 };

    fn getIndicator(status: Workspace.ClaudeStatus) Indicator {
        return switch (status) {
            .none => .{ .text = null, .css_class = null },
            .running => .{ .text = "✦", .css_class = null },
            .unread => .{ .text = "●", .css_class = "accent" },
            .attention => .{ .text = "●", .css_class = "warning" },
        };
    }

    fn buildCwdText(self: *Sidebar, ws: *Workspace, buf: []u8) []const u8 {
        var pane_list = std.ArrayList(*Pane).init(self.tab_manager.allocator);
        defer pane_list.deinit();
        ws.allPanes(&pane_list) catch return "";
        const home = std.posix.getenv("HOME") orelse "";
        var cwds: [16][128]u8 = undefined;
        var cwd_lens: [16]usize = undefined;
        var cwd_count: usize = 0;

        for (pane_list.items) |pane| {
            const cwd_ptr = pane.getCwd() orelse continue;
            const cwd = std.mem.span(cwd_ptr);
            if (cwd.len == 0) continue;
            var short_buf: [128]u8 = undefined;
            var short_len: usize = 0;
            if (home.len > 0 and std.mem.startsWith(u8, cwd, home)) {
                short_buf[0] = '~';
                const rest = cwd[home.len..];
                const rlen = @min(rest.len, 127);
                @memcpy(short_buf[1..][0..rlen], rest[0..rlen]);
                short_len = 1 + rlen;
            } else {
                short_len = @min(cwd.len, 128);
                @memcpy(short_buf[0..short_len], cwd[0..short_len]);
            }
            var is_dup = false;
            for (0..cwd_count) |j| {
                if (cwd_lens[j] == short_len and std.mem.eql(u8, cwds[j][0..short_len], short_buf[0..short_len])) {
                    is_dup = true;
                    break;
                }
            }
            if (is_dup) continue;
            if (cwd_count >= 16) break;
            cwds[cwd_count] = short_buf;
            cwd_lens[cwd_count] = short_len;
            cwd_count += 1;
        }

        var pos: usize = 0;
        for (0..cwd_count) |i| {
            if (pos > 0 and pos + 2 < buf.len) { buf[pos] = ' '; buf[pos + 1] = ' '; pos += 2; }
            const slen = cwd_lens[i];
            if (pos + slen >= buf.len) break;
            @memcpy(buf[pos..][0..slen], cwds[i][0..slen]);
            pos += slen;
        }
        return buf[0..pos];
    }

    // === Right-click menu ===

    fn onRightClick(
        _: *c.GtkGestureClick, _: c.gint, _: c.gdouble, _: c.gdouble, row_widget: *c.GtkWidget,
    ) callconv(.C) void {
        const sidebar: *Sidebar = @ptrCast(@alignCast(
            c.g_object_get_data(@ptrCast(@alignCast(row_widget)), "cmux-sidebar") orelse return,
        ));
        const ws: *Workspace = @ptrCast(@alignCast(
            c.g_object_get_data(@ptrCast(@alignCast(row_widget)), "cmux-ws") orelse return,
        ));

        // Find the GtkListBoxRow parent
        const parent = c.gtk_widget_get_parent(row_widget) orelse return;

        const popover: *c.GtkPopover = @ptrCast(@alignCast(c.gtk_popover_new() orelse return));
        c.gtk_widget_set_parent(asWidget(popover), parent);

        _ = c.g_signal_connect_data(
            @ptrCast(popover), "closed", @ptrCast(&onPopoverClosed), null, null, 0,
        );

        const menu_box: *c.GtkBox = @ptrCast(@alignCast(
            c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0) orelse return,
        ));

        // Rename
        const rename_btn = c.gtk_button_new_with_label("Rename") orelse return;
        c.gtk_button_set_has_frame(@ptrCast(@alignCast(rename_btn)), 0);
        c.g_object_set_data(@ptrCast(@alignCast(rename_btn)), "cmux-popover", popover);
        c.g_object_set_data(@ptrCast(@alignCast(rename_btn)), "cmux-sidebar", sidebar);
        c.g_object_set_data(@ptrCast(@alignCast(rename_btn)), "cmux-ws", ws);
        _ = c.g_signal_connect_data(@ptrCast(rename_btn), "clicked", @ptrCast(&onRenameClicked), null, null, 0);
        c.gtk_box_append(menu_box, rename_btn);

        // Close
        const close_btn = c.gtk_button_new_with_label("Close") orelse return;
        c.gtk_button_set_has_frame(@ptrCast(@alignCast(close_btn)), 0);
        c.g_object_set_data(@ptrCast(@alignCast(close_btn)), "cmux-popover", popover);
        c.g_object_set_data(@ptrCast(@alignCast(close_btn)), "cmux-sidebar", sidebar);
        c.g_object_set_data(@ptrCast(@alignCast(close_btn)), "cmux-ws", ws);
        _ = c.g_signal_connect_data(@ptrCast(close_btn), "clicked", @ptrCast(&onCloseClicked), null, null, 0);
        c.gtk_box_append(menu_box, close_btn);

        c.gtk_popover_set_child(popover, asWidget(menu_box));
        c.gtk_popover_popup(popover);
    }

    fn onPopoverClosed(popover: *c.GtkPopover, _: ?*anyopaque) callconv(.C) void {
        c.gtk_widget_unparent(asWidget(popover));
    }

    fn onCloseClicked(button: *c.GtkButton, _: ?*anyopaque) callconv(.C) void {
        const btn_w = asWidget(button);
        const popover: *c.GtkPopover = @ptrCast(@alignCast(c.g_object_get_data(@ptrCast(@alignCast(btn_w)), "cmux-popover") orelse return));
        const sidebar: *Sidebar = @ptrCast(@alignCast(c.g_object_get_data(@ptrCast(@alignCast(btn_w)), "cmux-sidebar") orelse return));
        const ws: *Workspace = @ptrCast(@alignCast(c.g_object_get_data(@ptrCast(@alignCast(btn_w)), "cmux-ws") orelse return));
        c.gtk_popover_popdown(popover);
        var ws_id = ws.id;
        sidebar.tab_manager.closeWorkspace(&ws_id);
        sidebar.sync();
    }

    fn onRenameClicked(button: *c.GtkButton, _: ?*anyopaque) callconv(.C) void {
        const btn_w = asWidget(button);
        const popover: *c.GtkPopover = @ptrCast(@alignCast(c.g_object_get_data(@ptrCast(@alignCast(btn_w)), "cmux-popover") orelse return));
        const ws: *Workspace = @ptrCast(@alignCast(c.g_object_get_data(@ptrCast(@alignCast(btn_w)), "cmux-ws") orelse return));
        c.gtk_popover_popdown(popover);

        const app = c.g_application_get_default() orelse return;
        const win = c.gtk_application_get_active_window(@ptrCast(@alignCast(app))) orelse return;
        const dialog: *c.GtkWindow = @ptrCast(@alignCast(c.gtk_window_new() orelse return));
        c.gtk_window_set_title(dialog, "Rename Workspace");
        c.gtk_window_set_modal(dialog, 1);
        c.gtk_window_set_transient_for(dialog, win);
        c.gtk_window_set_default_size(dialog, 300, -1);

        const vbox: *c.GtkBox = @ptrCast(@alignCast(c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 8) orelse return));
        const vbox_w = asWidget(vbox);
        c.gtk_widget_set_margin_start(vbox_w, 16);
        c.gtk_widget_set_margin_end(vbox_w, 16);
        c.gtk_widget_set_margin_top(vbox_w, 16);
        c.gtk_widget_set_margin_bottom(vbox_w, 16);

        var title_z: [257]u8 = undefined;
        const t = ws.displayTitle();
        const tl = @min(t.len, 256);
        @memcpy(title_z[0..tl], t[0..tl]);
        title_z[tl] = 0;

        const entry: *c.GtkEntry = @ptrCast(@alignCast(c.gtk_entry_new() orelse return));
        c.gtk_entry_buffer_set_text(c.gtk_entry_get_buffer(entry), &title_z, @intCast(tl));
        c.gtk_box_append(vbox, asWidget(entry));

        c.g_object_set_data(@ptrCast(@alignCast(entry)), "cmux-ws", ws);
        c.g_object_set_data(@ptrCast(@alignCast(entry)), "cmux-dialog", dialog);
        _ = c.g_signal_connect_data(@ptrCast(entry), "activate", @ptrCast(&onRenameConfirmed), null, null, 0);

        c.gtk_window_set_child(@ptrCast(@alignCast(dialog)), vbox_w);
        c.gtk_window_present(dialog);
        _ = c.gtk_widget_grab_focus(asWidget(entry));
    }

    fn onRenameConfirmed(entry: *c.GtkEntry, _: ?*anyopaque) callconv(.C) void {
        const entry_w = asWidget(entry);
        const ws: *Workspace = @ptrCast(@alignCast(c.g_object_get_data(@ptrCast(@alignCast(entry_w)), "cmux-ws") orelse return));
        const dialog: *c.GtkWindow = @ptrCast(@alignCast(c.g_object_get_data(@ptrCast(@alignCast(entry_w)), "cmux-dialog") orelse return));
        const text = c.gtk_entry_buffer_get_text(c.gtk_entry_get_buffer(entry));
        if (text) |txt| {
            const new_title = std.mem.span(txt);
            if (new_title.len > 0) ws.setTitle(new_title);
        }
        c.gtk_window_close(dialog);
    }

    // === Callbacks ===

    fn onRowActivated(_: *c.GtkListBox, row: *c.GtkListBoxRow, tab_manager: *TabManager) callconv(.C) void {
        const index = c.gtk_list_box_row_get_index(row);
        if (index >= 0) tab_manager.selectByIndex(@intCast(index));
    }

    fn onTabManagerChange(data: ?*anyopaque) void {
        const self: *Sidebar = @ptrCast(@alignCast(data orelse return));
        self.sync();
    }
};
