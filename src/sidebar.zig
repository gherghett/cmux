const std = @import("std");
const cc = @import("c.zig");
const c = cc.c;
const asWidget = cc.asWidget;
const uuid = @import("uuid.zig");
const TabManager = @import("tab_manager.zig").TabManager;

const log = std.log.scoped(.sidebar);

/// Vertical sidebar showing the list of workspaces.
/// Each row shows the workspace title and notification badge.
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

        // Set a minimum width for the sidebar
        c.gtk_widget_set_size_request(asWidget(scrolled), 160, -1);

        // Connect row-activated for workspace selection
        _ = c.g_signal_connect_data(
            @ptrCast(list_box),
            "row-activated",
            @ptrCast(&onRowActivated),
            tab_manager,
            null,
            0,
        );

        var sidebar = Sidebar{
            .list_box = list_box,
            .scrolled = scrolled,
            .tab_manager = tab_manager,
        };

        // Initial refresh
        sidebar.refresh();

        return sidebar;
    }

    /// Must be called after the Sidebar is stored at its final heap location.
    /// Wires up the tab manager change callback to this sidebar instance.
    pub fn connectTabManager(self: *Sidebar) void {
        self.tab_manager.on_change = &onTabManagerChange;
        self.tab_manager.on_change_data = self;
    }

    /// Returns the widget for embedding in the window layout
    pub fn widget(self: *Sidebar) *c.GtkWidget {
        return asWidget(self.scrolled);
    }

    /// Rebuild the sidebar list from the tab manager's workspaces
    pub fn refresh(self: *Sidebar) void {
        // Remove all existing rows
        while (c.gtk_list_box_get_row_at_index(self.list_box, 0)) |row| {
            c.gtk_list_box_remove(self.list_box, asWidget(row));
        }

        // Add a row for each workspace
        for (self.tab_manager.workspaces.items, 0..) |ws, i| {
            // Use vertical box for title + status
            const row_box: *c.GtkBox = @ptrCast(@alignCast(
                c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 2) orelse continue,
            ));

            // Title label
            var title_buf: [257]u8 = undefined;
            const title = ws.displayTitle();
            const tlen = @min(title.len, 256);
            @memcpy(title_buf[0..tlen], title[0..tlen]);
            title_buf[tlen] = 0;
            const label = c.gtk_label_new(&title_buf) orelse continue;
            c.gtk_label_set_xalign(@ptrCast(@alignCast(label)), 0);
            c.gtk_widget_set_hexpand(label, 1);
            c.gtk_box_append(row_box, label);

            // Status text (e.g., "⚡ Running" from Claude Code)
            if (ws.statusText()) |status| {
                var status_buf: [130]u8 = undefined;
                const slen = @min(status.len, 129);
                @memcpy(status_buf[0..slen], status[0..slen]);
                status_buf[slen] = 0;
                const status_label = c.gtk_label_new(&status_buf) orelse continue;
                c.gtk_label_set_xalign(@ptrCast(@alignCast(status_label)), 0);
                c.gtk_widget_add_css_class(status_label, "dim-label");
                c.gtk_box_append(row_box, status_label);
            }

            // Notification badge (if any)
            if (ws.notification_count > 0) {
                const hbox: *c.GtkBox = @ptrCast(@alignCast(
                    c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 4) orelse continue,
                ));
                var badge_buf: [16]u8 = undefined;
                const badge_text = std.fmt.bufPrint(&badge_buf, "{}", .{ws.notification_count}) catch continue;
                var badge_z: [17]u8 = undefined;
                @memcpy(badge_z[0..badge_text.len], badge_text);
                badge_z[badge_text.len] = 0;
                const badge = c.gtk_label_new(&badge_z);
                c.gtk_widget_add_css_class(badge, "badge");
                c.gtk_box_append(hbox, badge);
                c.gtk_box_append(row_box, asWidget(hbox));
            }

            // Add padding to the row
            const row_w = asWidget(row_box);
            c.gtk_widget_set_margin_start(row_w, 8);
            c.gtk_widget_set_margin_end(row_w, 8);
            c.gtk_widget_set_margin_top(row_w, 4);
            c.gtk_widget_set_margin_bottom(row_w, 4);

            c.gtk_list_box_append(self.list_box, row_w);

            // Select the current workspace row
            if (i == self.tab_manager.selected) {
                if (c.gtk_list_box_get_row_at_index(self.list_box, @intCast(i))) |row| {
                    c.gtk_list_box_select_row(self.list_box, row);
                }
            }
        }
    }

    fn onRowActivated(
        _: *c.GtkListBox,
        row: *c.GtkListBoxRow,
        tab_manager: *TabManager,
    ) callconv(.C) void {
        const index = c.gtk_list_box_row_get_index(row);
        if (index >= 0) {
            tab_manager.selectByIndex(@intCast(index));
        }
    }

    fn onTabManagerChange(data: ?*anyopaque) void {
        const self: *Sidebar = @ptrCast(@alignCast(data orelse return));
        self.refresh();
    }
};
