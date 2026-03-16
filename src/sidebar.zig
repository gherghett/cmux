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
        // Skip if shutting down — widgets may already be destroyed by GTK
        if (self.tab_manager.workspaces.items.len > 0 and
            self.tab_manager.workspaces.items[0].closing) return;

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

        // Stop if GTK is shutting down — check if any workspace is closing
        // (set before GTK teardown), or if there are no workspaces at all.
        if (c.g_application_get_default() == null) return 0;
        if (self.tab_manager.workspaces.items.len == 0) return 0;
        if (self.tab_manager.workspaces.items[0].closing) return 0;

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

    const Color = struct { r: f64, g: f64, b: f64 };
    const default_color = Color{ .r = 0.68, .g = 0.74, .b = 0.82 };

    fn parseHexColor(hex: []const u8) ?Color {
        if (hex.len < 7 or hex[0] != '#') return null;
        const r = std.fmt.parseInt(u8, hex[1..3], 16) catch return null;
        const g = std.fmt.parseInt(u8, hex[3..5], 16) catch return null;
        const b = std.fmt.parseInt(u8, hex[5..7], 16) catch return null;
        return .{
            .r = @as(f64, @floatFromInt(r)) / 255.0,
            .g = @as(f64, @floatFromInt(g)) / 255.0,
            .b = @as(f64, @floatFromInt(b)) / 255.0,
        };
    }

    /// Extract foreground color from an HTML tag.
    /// Handles both <font color="#rrggbb"> and <span style="color:#rrggbb">.
    fn extractFgColor(tag: []const u8) ?Color {
        // <font color="#rrggbb">
        if (std.mem.indexOf(u8, tag, "color=\"#")) |idx| {
            const after = tag[idx + 7 ..];
            if (after.len >= 7) return parseHexColor(after[0..7]);
        }
        // <span style="color:#rrggbb"> (but not background-color:)
        const needle = "color:";
        var search_pos: usize = 0;
        while (std.mem.indexOfPos(u8, tag, search_pos, needle)) |idx| {
            if (idx > 0 and tag[idx - 1] == '-') {
                search_pos = idx + needle.len;
                continue;
            }
            const after = tag[idx + needle.len ..];
            if (after.len >= 7 and after[0] == '#') {
                return parseHexColor(after[0..7]);
            }
            break;
        }
        return null;
    }

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
            .dead => {},
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

        // Get HTML-formatted terminal text (includes color via <span style="color:#rrggbb">)
        const html_ptr: ?[*:0]u8 = @ptrCast(c.vte_terminal_get_text_format(term, c.VTE_FORMAT_HTML));
        if (html_ptr == null) return;
        defer c.g_free(html_ptr);
        const html = std.mem.span(html_ptr.?);
        if (html.len < 10) return;

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

        // Skip <pre> wrapper and its trailing newline
        var content: []const u8 = html;
        if (std.mem.startsWith(u8, content, "<pre>")) {
            content = content[5..];
            if (content.len > 0 and content[0] == '\n') content = content[1..];
        }
        // Strip trailing </pre>
        if (std.mem.endsWith(u8, content, "</pre>")) {
            content = content[0 .. content.len - 6];
        }
        if (content.len > 0 and content[content.len - 1] == '\n') {
            content = content[0 .. content.len - 1];
        }

        // Parse HTML and render character by character with colors
        var cur_color = default_color;
        var row: usize = 0;
        var row_open = false;
        var pos: usize = 0;
        var color_set = false;

        while (pos < content.len and row < @as(usize, @intCast(rows))) {
            if (content[pos] == '<') {
                // HTML tag — find closing '>'
                const end = std.mem.indexOfScalarPos(u8, content, pos + 1, '>') orelse break;
                const tag = content[pos .. end + 1];

                if (std.mem.startsWith(u8, tag, "<font") or std.mem.startsWith(u8, tag, "<span")) {
                    if (extractFgColor(tag)) |col| {
                        cur_color = col;
                        color_set = false;
                    }
                } else if (std.mem.startsWith(u8, tag, "</font") or std.mem.startsWith(u8, tag, "</span")) {
                    cur_color = default_color;
                    color_set = false;
                }
                // <b>, </b>, etc. — just skip
                pos = end + 1;
            } else if (content[pos] == '&') {
                // HTML entity → decode to single character
                const semi = std.mem.indexOfScalarPos(u8, content, pos + 1, ';') orelse {
                    pos += 1;
                    continue;
                };
                const entity = content[pos .. semi + 1];
                const decoded: u8 = if (std.mem.eql(u8, entity, "&amp;"))
                    '&'
                else if (std.mem.eql(u8, entity, "&lt;"))
                    '<'
                else if (std.mem.eql(u8, entity, "&gt;"))
                    '>'
                else if (std.mem.eql(u8, entity, "&quot;"))
                    '"'
                else
                    '?';

                if (!row_open) {
                    c.cairo_save(cairo);
                    c.cairo_translate(cairo, px, py + @as(f64, @floatFromInt(row)) * char_h + char_h * 0.85);
                    c.cairo_scale(cairo, x_scale, 1.0);
                    c.cairo_move_to(cairo, 0, 0);
                    row_open = true;
                }
                if (!color_set) {
                    c.cairo_set_source_rgba(cairo, cur_color.r, cur_color.g, cur_color.b, 0.85);
                    color_set = true;
                }
                var buf = [2]u8{ decoded, 0 };
                c.cairo_show_text(cairo, &buf);
                pos = semi + 1;
            } else if (content[pos] == '\n') {
                if (row_open) {
                    c.cairo_restore(cairo);
                    row_open = false;
                }
                row += 1;
                pos += 1;
            } else {
                // Regular text character (possibly multi-byte UTF-8)
                if (!row_open) {
                    c.cairo_save(cairo);
                    c.cairo_translate(cairo, px, py + @as(f64, @floatFromInt(row)) * char_h + char_h * 0.85);
                    c.cairo_scale(cairo, x_scale, 1.0);
                    c.cairo_move_to(cairo, 0, 0);
                    row_open = true;
                }
                if (!color_set) {
                    c.cairo_set_source_rgba(cairo, cur_color.r, cur_color.g, cur_color.b, 0.85);
                    color_set = true;
                }

                const seq_len = @min(utf8SeqLen(content[pos]), content.len - pos);
                var char_buf: [5]u8 = undefined;
                @memcpy(char_buf[0..seq_len], content[pos..][0..seq_len]);
                char_buf[seq_len] = 0;
                c.cairo_show_text(cairo, &char_buf);
                pos += seq_len;
            }
        }

        if (row_open) c.cairo_restore(cairo);

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
