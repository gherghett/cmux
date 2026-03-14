const std = @import("std");
const cc = @import("c.zig");
const c = cc.c;
const asWidget = cc.asWidget;
const uuid = @import("uuid.zig");
const TabManager = @import("tab_manager.zig").TabManager;
const Workspace = @import("workspace.zig").Workspace;
const Pane = @import("pane.zig").Pane;

const log = std.log.scoped(.sidebar);

/// Vertical sidebar showing workspaces as rich 3-row tabs.
///
///   ┌─────────────────────────────┐
///   │ ✦ My Project                │  Row 1: indicator + title
///   │ Fixed the auth bug and...   │  Row 2: Claude message (dim)
///   │ ~/proj  ~/dotfiles          │  Row 3: pane CWDs (dim)
///   └─────────────────────────────┘
///
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

        sidebar.refresh();
        return sidebar;
    }

    pub fn connectTabManager(self: *Sidebar) void {
        self.tab_manager.on_change = &onTabManagerChange;
        self.tab_manager.on_change_data = self;
    }

    pub fn widget(self: *Sidebar) *c.GtkWidget {
        return asWidget(self.scrolled);
    }

    /// Rebuild the sidebar from workspace state.
    pub fn refresh(self: *Sidebar) void {
        // Remove all existing rows
        while (c.gtk_list_box_get_row_at_index(self.list_box, 0)) |row| {
            c.gtk_list_box_remove(self.list_box, asWidget(row));
        }

        for (self.tab_manager.workspaces.items, 0..) |ws, i| {
            const row_box: *c.GtkBox = @ptrCast(@alignCast(
                c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 1) orelse continue,
            ));

            // === Row 1: Indicator + Title ===
            const title_row: *c.GtkBox = @ptrCast(@alignCast(
                c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 4) orelse continue,
            ));

            // Status indicator
            const indicator = getIndicator(ws.claude_status);
            if (indicator.text) |ind_text| {
                const ind_label = c.gtk_label_new(ind_text) orelse continue;
                if (indicator.css_class) |css| {
                    c.gtk_widget_add_css_class(ind_label, css);
                }
                c.gtk_box_append(title_row, ind_label);
            }

            // Title
            var title_buf: [257]u8 = undefined;
            const title = ws.displayTitle();
            const tlen = @min(title.len, 256);
            @memcpy(title_buf[0..tlen], title[0..tlen]);
            title_buf[tlen] = 0;
            const title_label = c.gtk_label_new(&title_buf) orelse continue;
            c.gtk_label_set_xalign(@ptrCast(@alignCast(title_label)), 0);
            c.gtk_widget_set_hexpand(title_label, 1);
            c.gtk_label_set_ellipsize(@ptrCast(@alignCast(title_label)), c.PANGO_ELLIPSIZE_END);
            c.gtk_box_append(title_row, title_label);

            c.gtk_box_append(row_box, asWidget(title_row));

            // === Row 2: Claude message preview ===
            if (ws.claudeMessage()) |msg| {
                var msg_buf: [257]u8 = undefined;
                const mlen = @min(msg.len, 256);
                // Replace newlines with spaces
                for (0..mlen) |j| {
                    msg_buf[j] = if (msg[j] == '\n' or msg[j] == '\r') ' ' else msg[j];
                }
                msg_buf[mlen] = 0;
                const msg_label = c.gtk_label_new(&msg_buf) orelse continue;
                c.gtk_label_set_xalign(@ptrCast(@alignCast(msg_label)), 0);
                c.gtk_label_set_ellipsize(@ptrCast(@alignCast(msg_label)), c.PANGO_ELLIPSIZE_END);
                c.gtk_widget_add_css_class(msg_label, "dim-label");
                c.gtk_widget_add_css_class(msg_label, "caption");
                c.gtk_box_append(row_box, msg_label);
            }

            // === Row 3: Pane CWDs ===
            var cwd_text_buf: [512]u8 = undefined;
            const cwd_text = self.buildCwdText(ws, &cwd_text_buf);
            if (cwd_text.len > 0) {
                var cwd_z: [513]u8 = undefined;
                @memcpy(cwd_z[0..cwd_text.len], cwd_text);
                cwd_z[cwd_text.len] = 0;
                const cwd_label = c.gtk_label_new(&cwd_z) orelse continue;
                c.gtk_label_set_xalign(@ptrCast(@alignCast(cwd_label)), 0);
                c.gtk_label_set_ellipsize(@ptrCast(@alignCast(cwd_label)), c.PANGO_ELLIPSIZE_END);
                c.gtk_widget_add_css_class(cwd_label, "dim-label");
                c.gtk_widget_add_css_class(cwd_label, "caption");
                c.gtk_box_append(row_box, cwd_label);
            }

            // Row padding
            const row_w = asWidget(row_box);
            c.gtk_widget_set_margin_start(row_w, 8);
            c.gtk_widget_set_margin_end(row_w, 8);
            c.gtk_widget_set_margin_top(row_w, 6);
            c.gtk_widget_set_margin_bottom(row_w, 6);

            // Right-click menu
            const click = c.gtk_gesture_click_new() orelse continue;
            c.gtk_gesture_single_set_button(@ptrCast(@alignCast(click)), 3); // right click
            const menu_ctx = self.tab_manager.allocator.create(MenuCtx) catch continue;
            menu_ctx.* = .{ .sidebar = self, .ws_index = i };
            _ = c.g_signal_connect_data(
                @ptrCast(click),
                "pressed",
                @ptrCast(&onRightClick),
                menu_ctx,
                @ptrCast(&onMenuCtxFree),
                0,
            );
            c.gtk_widget_add_controller(row_w, @ptrCast(@alignCast(click)));

            c.gtk_list_box_append(self.list_box, row_w);

            // Select current workspace
            if (i == self.tab_manager.selected) {
                if (c.gtk_list_box_get_row_at_index(self.list_box, @intCast(i))) |row| {
                    c.gtk_list_box_select_row(self.list_box, row);
                }
            }
        }
    }

    const Indicator = struct {
        text: ?[*:0]const u8,
        css_class: ?[*:0]const u8,
    };

    fn getIndicator(status: Workspace.ClaudeStatus) Indicator {
        return switch (status) {
            .none => .{ .text = null, .css_class = null },
            .running => .{ .text = "✦", .css_class = null },
            .unread => .{ .text = "●", .css_class = "accent" }, // blue
            .attention => .{ .text = "●", .css_class = "warning" }, // purple/orange
        };
    }

    fn buildCwdText(self: *Sidebar, ws: *Workspace, buf: []u8) []const u8 {
        var pane_list = std.ArrayList(*Pane).init(self.tab_manager.allocator);
        defer pane_list.deinit();
        ws.allPanes(&pane_list) catch return "";

        const home = std.posix.getenv("HOME") orelse "";

        // Collect unique shortened CWDs
        var cwds: [16][128]u8 = undefined;
        var cwd_lens: [16]usize = undefined;
        var cwd_count: usize = 0;

        for (pane_list.items) |pane| {
            const cwd_ptr = pane.getCwd() orelse continue;
            const cwd = std.mem.span(cwd_ptr);
            if (cwd.len == 0) continue;

            // Shorten: replace $HOME with ~
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

            // Deduplicate
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

        // Build output string
        var pos: usize = 0;
        for (0..cwd_count) |i| {
            if (pos > 0 and pos + 2 < buf.len) {
                buf[pos] = ' ';
                buf[pos + 1] = ' ';
                pos += 2;
            }
            const slen = cwd_lens[i];
            if (pos + slen >= buf.len) break;
            @memcpy(buf[pos..][0..slen], cwds[i][0..slen]);
            pos += slen;
        }

        return buf[0..pos];
    }

    const MenuCtx = struct {
        sidebar: *Sidebar,
        ws_index: usize,
    };

    fn onMenuCtxFree(data: ?*anyopaque, _: ?*anyopaque) callconv(.C) void {
        const ctx: *MenuCtx = @ptrCast(@alignCast(data orelse return));
        ctx.sidebar.tab_manager.allocator.destroy(ctx);
    }

    fn onRightClick(
        _: *c.GtkGestureClick,
        _: c.gint,
        _: c.gdouble,
        _: c.gdouble,
        user_data: ?*anyopaque,
    ) callconv(.C) void {
        const ctx: *MenuCtx = @ptrCast(@alignCast(user_data orelse return));
        const sidebar = ctx.sidebar;
        const ws_index = ctx.ws_index;
        if (ws_index >= sidebar.tab_manager.workspaces.items.len) return;

        const ws = sidebar.tab_manager.workspaces.items[ws_index];

        // Get the row widget to anchor the popover
        const row = c.gtk_list_box_get_row_at_index(sidebar.list_box, @intCast(ws_index)) orelse return;

        // Create popover menu
        const popover: *c.GtkPopover = @ptrCast(@alignCast(
            c.gtk_popover_new() orelse return,
        ));
        c.gtk_widget_set_parent(asWidget(popover), asWidget(row));

        // Content: vertical box with menu items
        const menu_box: *c.GtkBox = @ptrCast(@alignCast(
            c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0) orelse return,
        ));

        // "Rename" button
        const rename_btn = c.gtk_button_new_with_label("Rename") orelse return;
        c.gtk_button_set_has_frame(@ptrCast(@alignCast(rename_btn)), 0);
        c.gtk_box_append(menu_box, rename_btn);

        // Store context on the button for the callback
        c.g_object_set_data(@ptrCast(@alignCast(rename_btn)), "cmux-popover", popover);
        c.g_object_set_data(@ptrCast(@alignCast(rename_btn)), "cmux-sidebar", sidebar);

        // Store workspace ID on the button
        c.g_object_set_data(@ptrCast(@alignCast(rename_btn)), "cmux-ws", ws);

        _ = c.g_signal_connect_data(
            @ptrCast(rename_btn),
            "clicked",
            @ptrCast(&onRenameClicked),
            null,
            null,
            0,
        );

        c.gtk_popover_set_child(popover, asWidget(menu_box));
        c.gtk_popover_popup(popover);
    }

    fn onRenameClicked(button: *c.GtkButton, _: ?*anyopaque) callconv(.C) void {
        const btn_widget = asWidget(button);
        const popover_raw = c.g_object_get_data(@ptrCast(@alignCast(btn_widget)), "cmux-popover") orelse return;
        const popover: *c.GtkPopover = @ptrCast(@alignCast(popover_raw));
        const sidebar_raw = c.g_object_get_data(@ptrCast(@alignCast(btn_widget)), "cmux-sidebar") orelse return;
        const sidebar: *Sidebar = @ptrCast(@alignCast(sidebar_raw));
        const ws_raw = c.g_object_get_data(@ptrCast(@alignCast(btn_widget)), "cmux-ws") orelse return;
        const ws: *Workspace = @ptrCast(@alignCast(ws_raw));

        // Close the popover
        c.gtk_popover_popdown(popover);

        // Show a rename dialog
        const app = c.g_application_get_default() orelse return;
        const win = c.gtk_application_get_active_window(@ptrCast(@alignCast(app))) orelse return;

        const dialog: *c.GtkWindow = @ptrCast(@alignCast(
            c.gtk_window_new() orelse return,
        ));
        c.gtk_window_set_title(dialog, "Rename Workspace");
        c.gtk_window_set_modal(dialog, 1);
        c.gtk_window_set_transient_for(dialog, win);
        c.gtk_window_set_default_size(dialog, 300, -1);

        const vbox: *c.GtkBox = @ptrCast(@alignCast(
            c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 8) orelse return,
        ));
        const vbox_w = asWidget(vbox);
        c.gtk_widget_set_margin_start(vbox_w, 16);
        c.gtk_widget_set_margin_end(vbox_w, 16);
        c.gtk_widget_set_margin_top(vbox_w, 16);
        c.gtk_widget_set_margin_bottom(vbox_w, 16);

        // Entry with current title
        var current_title_z: [257]u8 = undefined;
        const current_title = ws.displayTitle();
        const ctlen = @min(current_title.len, 256);
        @memcpy(current_title_z[0..ctlen], current_title[0..ctlen]);
        current_title_z[ctlen] = 0;

        const entry: *c.GtkEntry = @ptrCast(@alignCast(c.gtk_entry_new() orelse return));
        const entry_buf = c.gtk_entry_get_buffer(entry);
        c.gtk_entry_buffer_set_text(entry_buf, &current_title_z, @intCast(ctlen));
        c.gtk_box_append(vbox, asWidget(entry));

        // Store workspace + sidebar on the entry for the activate callback
        c.g_object_set_data(@ptrCast(@alignCast(entry)), "cmux-ws", ws);
        c.g_object_set_data(@ptrCast(@alignCast(entry)), "cmux-sidebar", sidebar);
        c.g_object_set_data(@ptrCast(@alignCast(entry)), "cmux-dialog", dialog);

        // Enter key confirms rename
        _ = c.g_signal_connect_data(
            @ptrCast(entry),
            "activate",
            @ptrCast(&onRenameConfirmed),
            null,
            null,
            0,
        );

        c.gtk_window_set_child(@ptrCast(@alignCast(dialog)), vbox_w);
        c.gtk_window_present(dialog);
        _ = c.gtk_widget_grab_focus(asWidget(entry));
    }

    fn onRenameConfirmed(entry: *c.GtkEntry, _: ?*anyopaque) callconv(.C) void {
        const entry_w = asWidget(entry);
        const ws_raw = c.g_object_get_data(@ptrCast(@alignCast(entry_w)), "cmux-ws") orelse return;
        const ws: *Workspace = @ptrCast(@alignCast(ws_raw));
        const sidebar_raw = c.g_object_get_data(@ptrCast(@alignCast(entry_w)), "cmux-sidebar") orelse return;
        const sidebar: *Sidebar = @ptrCast(@alignCast(sidebar_raw));
        const dialog_raw = c.g_object_get_data(@ptrCast(@alignCast(entry_w)), "cmux-dialog") orelse return;
        const dialog: *c.GtkWindow = @ptrCast(@alignCast(dialog_raw));

        // Get the text
        const buf = c.gtk_entry_get_buffer(entry);
        const text = c.gtk_entry_buffer_get_text(buf);
        if (text) |t| {
            const new_title = std.mem.span(t);
            if (new_title.len > 0) {
                ws.setTitle(new_title);
                sidebar.refresh();
            }
        }

        c.gtk_window_close(dialog);
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
