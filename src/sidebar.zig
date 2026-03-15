const std = @import("std");
const cc = @import("c.zig");
const c = cc.c;
const asWidget = cc.asWidget;
const uuid = @import("uuid.zig");
const TabManager = @import("tab_manager.zig").TabManager;
const Workspace = @import("workspace.zig").Workspace;
const Pane = @import("pane.zig").Pane;
const SplitTree = @import("split_tree.zig").SplitTree;

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

        // Row 4: minimap (text-based via Cairo)
        const minimap_area: *c.GtkDrawingArea = @ptrCast(@alignCast(
            c.gtk_drawing_area_new() orelse return,
        ));
        c.gtk_widget_set_size_request(asWidget(minimap_area), -1, 48);
        c.gtk_drawing_area_set_draw_func(minimap_area, @ptrCast(&onMinimapDraw), ws, null);
        c.gtk_box_append(row_box, asWidget(minimap_area));

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
            .minimap_area = minimap_area,
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

        // Minimap — queue redraw (text-based, works for all workspaces)
        c.gtk_widget_set_opacity(asWidget(sb.minimap_area), if (is_active) 0.9 else 0.6);
        c.gtk_widget_queue_draw(asWidget(sb.minimap_area));
    }

    // === Periodic timer ===

    fn onPeriodicRefresh(user_data: ?*anyopaque) callconv(.C) c.gboolean {
        const self: *Sidebar = @ptrCast(@alignCast(user_data orelse return 0));

        // Update all rows in-place (minimaps redraw via queue_draw)
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

    // === Text-based minimap drawing ===

    // Manual definition of VteCharAttributes — Zig's cImport makes it opaque
    // due to the bitfield members. Layout must match the C struct on x86_64.
    const PangoColor = extern struct { red: u16, green: u16, blue: u16 };
    const VteCharAttr = extern struct {
        row: c_long,
        column: c_long,
        fore: PangoColor,
        back: PangoColor,
        _bitfield: c_uint,
    };

    fn utf8SeqLen(byte: u8) usize {
        if (byte < 0x80) return 1;
        if (byte < 0xE0) return 2;
        if (byte < 0xF0) return 3;
        return 4;
    }

    const PaneLayout = struct {
        pane: *Pane,
        x: f64,
        y: f64,
        w: f64,
        h: f64,
    };

    fn onMinimapDraw(
        _: *c.GtkDrawingArea,
        cr: ?*c.cairo_t,
        width: c_int,
        height: c_int,
        user_data: ?*anyopaque,
    ) callconv(.C) void {
        const ws: *Workspace = @ptrCast(@alignCast(user_data orelse return));
        const cairo = cr orelse return;
        const w: f64 = @floatFromInt(width);
        const h: f64 = @floatFromInt(height);

        // Dark background
        c.cairo_set_source_rgb(cairo, 0.08, 0.08, 0.1);
        c.cairo_rectangle(cairo, 0, 0, w, h);
        c.cairo_fill(cairo);

        if (ws.split_tree.root == SplitTree.INVALID) return;

        // Collect pane layout rectangles from split tree
        var layouts: [16]PaneLayout = undefined;
        var layout_count: usize = 0;
        collectPaneLayouts(&ws.split_tree, ws.split_tree.root, 0, 0, w, h, &layouts, &layout_count);

        // Draw each pane
        for (layouts[0..layout_count]) |layout| {
            drawPaneMinimap(cairo, layout);
        }
    }

    fn collectPaneLayouts(
        tree: *const SplitTree,
        idx: SplitTree.NodeIndex,
        x: f64,
        y: f64,
        w: f64,
        h: f64,
        out: *[16]PaneLayout,
        count: *usize,
    ) void {
        if (idx == SplitTree.INVALID or idx >= tree.nodes.items.len) return;
        if (count.* >= 16) return;

        switch (tree.nodes.items[idx]) {
            .leaf => |leaf| {
                out[count.*] = .{ .pane = leaf.pane, .x = x, .y = y, .w = w, .h = h };
                count.* += 1;
            },
            .split => |s| {
                const ratio = getPanedRatio(s);
                switch (s.direction) {
                    .horizontal => {
                        // Horizontal split = panes stacked vertically
                        collectPaneLayouts(tree, s.first, x, y, w, h * ratio, out, count);
                        collectPaneLayouts(tree, s.second, x, y + h * ratio, w, h * (1.0 - ratio), out, count);
                    },
                    .vertical => {
                        // Vertical split = panes side by side
                        collectPaneLayouts(tree, s.first, x, y, w * ratio, h, out, count);
                        collectPaneLayouts(tree, s.second, x + w * ratio, y, w * (1.0 - ratio), h, out, count);
                    },
                }
            },
        }
    }

    fn getPanedRatio(s: SplitTree.SplitNode) f64 {
        const pos = c.gtk_paned_get_position(s.paned);
        if (pos <= 0) return 0.5;

        const total: c_int = switch (s.direction) {
            .horizontal => c.gtk_widget_get_height(asWidget(s.paned)),
            .vertical => c.gtk_widget_get_width(asWidget(s.paned)),
        };
        if (total <= 0) return 0.5;
        const r = @as(f64, @floatFromInt(pos)) / @as(f64, @floatFromInt(total));
        return std.math.clamp(r, 0.1, 0.9);
    }

    fn drawPaneMinimap(cairo: *c.cairo_t, layout: PaneLayout) void {
        const term = layout.pane.currentTerminal() orelse return;

        const cols = c.vte_terminal_get_column_count(term);
        const rows = c.vte_terminal_get_row_count(term);
        if (cols <= 0 or rows <= 0) return;

        // Inset slightly for pane borders
        const inset: f64 = 0.5;
        const px = layout.x + inset;
        const py = layout.y + inset;
        const pw = layout.w - inset * 2;
        const ph = layout.h - inset * 2;
        const char_h = ph / @as(f64, @floatFromInt(rows));

        // Get terminal text with per-character color attributes (deprecated API for colors)
        const attrs = c.g_array_new(0, 1, @sizeOf(VteCharAttr));
        defer c.g_array_unref(attrs);
        const text_ptr: ?[*:0]u8 = @ptrCast(c.vte_terminal_get_text(term, null, null, attrs));
        if (text_ptr == null) return;
        defer c.g_free(text_ptr);
        const text = std.mem.span(text_ptr.?);

        const has_attrs = attrs.*.len > 0 and attrs.*.data != null;
        const attr_data: ?[*]const VteCharAttr = if (has_attrs)
            @ptrCast(@alignCast(attrs.*.data))
        else
            null;
        const attr_count: usize = attrs.*.len;

        // Set up tiny monospace font scaled to cell height
        c.cairo_select_font_face(cairo, "monospace", c.CAIRO_FONT_SLANT_NORMAL, c.CAIRO_FONT_WEIGHT_NORMAL);
        const font_size = @max(char_h * 1.2, 1.5);
        c.cairo_set_font_size(cairo, font_size);

        // Horizontal squeeze: scale natural monospace advance to target cell width
        var font_ext: c.cairo_font_extents_t = undefined;
        c.cairo_font_extents(cairo, &font_ext);
        const natural_advance = font_ext.max_x_advance;
        const target_advance = pw / @as(f64, @floatFromInt(cols));
        const x_scale = if (natural_advance > 0) target_advance / natural_advance else 1.0;

        // Render row by row, character by character with colors
        var attr_idx: usize = 0;
        var row_start: usize = 0;
        var row: usize = 0;
        var i: usize = 0;

        while (i <= text.len) : (i += 1) {
            const at_end = i == text.len;
            const is_newline = !at_end and text[i] == '\n';

            if (at_end or is_newline) {
                if (row >= @as(usize, @intCast(rows))) break;
                const row_text = text[row_start..i];

                if (row_text.len > 0) {
                    c.cairo_save(cairo);
                    c.cairo_translate(cairo, px, py + @as(f64, @floatFromInt(row)) * char_h + char_h * 0.85);
                    c.cairo_scale(cairo, x_scale, 1.0);
                    c.cairo_move_to(cairo, 0, 0);

                    // Per-character rendering with color from attributes
                    var byte_pos: usize = 0;
                    var prev_r: u16 = std.math.maxInt(u16);
                    var prev_g: u16 = std.math.maxInt(u16);
                    var prev_b: u16 = std.math.maxInt(u16);

                    while (byte_pos < row_text.len) {
                        const seq_len = @min(utf8SeqLen(row_text[byte_pos]), row_text.len - byte_pos);

                        // Set color from VTE attributes
                        if (attr_data) |ad| {
                            if (attr_idx < attr_count) {
                                const a = ad[attr_idx];
                                if (a.fore.red != prev_r or a.fore.green != prev_g or a.fore.blue != prev_b) {
                                    c.cairo_set_source_rgba(cairo,
                                        @as(f64, @floatFromInt(a.fore.red)) / 65535.0,
                                        @as(f64, @floatFromInt(a.fore.green)) / 65535.0,
                                        @as(f64, @floatFromInt(a.fore.blue)) / 65535.0,
                                        0.85,
                                    );
                                    prev_r = a.fore.red;
                                    prev_g = a.fore.green;
                                    prev_b = a.fore.blue;
                                }
                            }
                        } else {
                            if (prev_r == std.math.maxInt(u16)) {
                                c.cairo_set_source_rgba(cairo, 0.68, 0.74, 0.82, 0.85);
                                prev_r = 0;
                            }
                        }

                        // Render single character
                        var char_buf: [5]u8 = undefined;
                        @memcpy(char_buf[0..seq_len], row_text[byte_pos..][0..seq_len]);
                        char_buf[seq_len] = 0;
                        c.cairo_show_text(cairo, &char_buf);

                        byte_pos += seq_len;
                        attr_idx += 1;
                    }

                    c.cairo_restore(cairo);
                }

                row += 1;
                row_start = i + 1;
            }
        }

        // Subtle pane border
        c.cairo_set_source_rgba(cairo, 0.3, 0.3, 0.4, 0.4);
        c.cairo_set_line_width(cairo, 0.5);
        c.cairo_rectangle(cairo, layout.x, layout.y, layout.w, layout.h);
        c.cairo_stroke(cairo);
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
