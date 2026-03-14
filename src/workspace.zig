const std = @import("std");
const cc = @import("c.zig");
const c = cc.c;
const asWidget = cc.asWidget;
const uuid = @import("uuid.zig");
const split_tree_mod = @import("split_tree.zig");
const SplitTree = split_tree_mod.SplitTree;
const Pane = @import("pane.zig").Pane;

const log = std.log.scoped(.workspace);

pub const Workspace = struct {
    id: uuid.Uuid,
    title: [256]u8,
    title_len: usize,
    custom_title: ?[256]u8,
    custom_title_len: usize,
    split_tree: SplitTree,
    notification_count: u32,
    container: *c.GtkBox,
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    status_entries: [8]?StatusEntry = [_]?StatusEntry{null} ** 8,

    pub const StatusEntry = struct {
        key: [64]u8,
        key_len: usize,
        value: [128]u8,
        value_len: usize,
    };

    pub fn init(allocator: std.mem.Allocator, socket_path: []const u8) !*Workspace {
        const ws = try allocator.create(Workspace);
        errdefer allocator.destroy(ws);

        const box: *c.GtkBox = @ptrCast(@alignCast(
            c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0) orelse
                return error.GtkWidgetCreateFailed,
        ));

        const id = uuid.generate();
        const default_title = "Terminal";

        var title_buf: [256]u8 = undefined;
        @memcpy(title_buf[0..default_title.len], default_title);

        ws.* = .{
            .id = id,
            .title = title_buf,
            .title_len = default_title.len,
            .custom_title = null,
            .custom_title_len = 0,
            .split_tree = SplitTree.init(allocator),
            .notification_count = 0,
            .container = box,
            .allocator = allocator,
            .socket_path = socket_path,
        };

        // Create initial pane with one terminal tab
        const pane = try Pane.init(allocator, id, socket_path);
        pane.on_empty = &onPaneEmpty;
        pane.on_empty_ctx = ws;

        try ws.split_tree.setRoot(pane);
        pane.node_index = 0; // root node
        pane.on_focus = &onPaneFocus;
        pane.on_focus_ctx = ws;
        const pane_w = pane.widget();
        c.gtk_widget_set_vexpand(pane_w, 1);
        c.gtk_widget_set_hexpand(pane_w, 1);
        c.gtk_box_append(box, pane_w);

        _ = try pane.addTab(null);

        log.info("created workspace {s}", .{uuid.asSlice(&id)});
        return ws;
    }

    pub fn deinit(self: *Workspace) void {
        self.split_tree.deinit();
        self.allocator.destroy(self);
    }

    pub fn containerWidget(self: *Workspace) *c.GtkWidget {
        return asWidget(self.container);
    }

    pub fn displayTitle(self: *const Workspace) []const u8 {
        if (self.custom_title) |ct| {
            return ct[0..self.custom_title_len];
        }
        return self.title[0..self.title_len];
    }

    /// Get the status string for sidebar display (e.g., "⚡ Running")
    pub fn statusText(self: *const Workspace) ?[]const u8 {
        for (self.status_entries) |entry_opt| {
            if (entry_opt) |entry| {
                return entry.value[0..entry.value_len];
            }
        }
        return null;
    }

    pub fn setStatus(self: *Workspace, key: []const u8, value: []const u8) void {
        // Find existing or first empty slot
        var slot: ?usize = null;
        for (self.status_entries, 0..) |entry_opt, i| {
            if (entry_opt) |entry| {
                if (std.mem.eql(u8, entry.key[0..entry.key_len], key)) {
                    slot = i;
                    break;
                }
            } else if (slot == null) {
                slot = i;
            }
        }
        const idx = slot orelse return;

        var entry = StatusEntry{
            .key = undefined, .key_len = @min(key.len, 64),
            .value = undefined, .value_len = @min(value.len, 128),
        };
        @memcpy(entry.key[0..entry.key_len], key[0..entry.key_len]);
        @memcpy(entry.value[0..entry.value_len], value[0..entry.value_len]);
        self.status_entries[idx] = entry;
    }

    pub fn clearStatus(self: *Workspace, key: []const u8) void {
        for (self.status_entries, 0..) |entry_opt, i| {
            if (entry_opt) |entry| {
                if (std.mem.eql(u8, entry.key[0..entry.key_len], key)) {
                    self.status_entries[i] = null;
                    return;
                }
            }
        }
    }

    pub fn setTitle(self: *Workspace, title: []const u8) void {
        const len = @min(title.len, 256);
        var buf: [256]u8 = undefined;
        @memcpy(buf[0..len], title[0..len]);
        self.custom_title = buf;
        self.custom_title_len = len;
    }

    pub fn splitFocused(self: *Workspace, direction: SplitTree.Direction) !void {
        if (self.split_tree.focused == SplitTree.INVALID) return;

        // Inherit CWD from the focused terminal
        const cwd = if (self.split_tree.focusedPane()) |pane| pane.getCwd() else null;

        const new_pane = try Pane.init(self.allocator, self.id, self.socket_path);
        new_pane.on_empty = &onPaneEmpty;
        new_pane.on_empty_ctx = self;
        new_pane.on_focus = &onPaneFocus;
        new_pane.on_focus_ctx = self;

        const new_idx = try self.split_tree.split(self.split_tree.focused, direction, new_pane);
        new_pane.node_index = new_idx;
        self.updateContainer();
        _ = try new_pane.addTab(cwd);
    }

    pub fn closeFocused(self: *Workspace) void {
        if (self.split_tree.focused == SplitTree.INVALID) return;
        self.split_tree.close(self.split_tree.focused);
        self.updateContainer();
    }

    pub fn focus(self: *Workspace) void {
        if (self.split_tree.focusedPane()) |pane| {
            pane.focus();
        }
    }

    pub fn allPanes(self: *Workspace, out: *std.ArrayList(*Pane)) !void {
        try self.split_tree.allPanes(out);
    }

    fn updateContainer(self: *Workspace) void {
        const new_root = self.split_tree.rootWidget();
        const container_w = asWidget(self.container);
        const current_child = c.gtk_widget_get_first_child(container_w);

        // If the root widget is already the container's child, nothing to do.
        // split() handles internal GtkPaned reparenting itself.
        if (new_root != null and current_child == new_root.?) return;

        // Root changed (or tree is now empty) — swap the container content.
        // Ref the new root so it survives removal from any old parent.
        if (new_root) |root| {
            _ = c.g_object_ref(@ptrCast(@alignCast(root)));
        }

        // Remove old children
        while (c.gtk_widget_get_first_child(container_w)) |child| {
            _ = c.g_object_ref(@ptrCast(@alignCast(child)));
            c.gtk_box_remove(self.container, child);
            c.g_object_unref(@ptrCast(@alignCast(child)));
        }

        // Add the new root widget
        if (new_root) |root| {
            if (c.gtk_widget_get_parent(root)) |old_parent| {
                SplitTree.removeFromParent(old_parent, root);
            }
            c.gtk_box_append(self.container, root);
            c.gtk_widget_set_vexpand(root, 1);
            c.gtk_widget_set_hexpand(root, 1);
            c.g_object_unref(@ptrCast(@alignCast(root)));
        }
    }

    fn onPaneFocus(pane: *Pane, ctx: ?*anyopaque) void {
        const self: *Workspace = @ptrCast(@alignCast(ctx orelse return));
        if (pane.node_index != SplitTree.INVALID) {
            self.split_tree.focused = pane.node_index;
        }
    }

    fn onPaneEmpty(pane: *Pane, ctx: ?*anyopaque) void {
        const self: *Workspace = @ptrCast(@alignCast(ctx orelse return));

        // Find this pane in the split tree and close it
        for (self.split_tree.nodes.items, 0..) |node, i| {
            switch (node) {
                .leaf => |leaf| {
                    if (leaf.pane == pane) {
                        log.info("closing empty pane idx={}", .{i});
                        self.split_tree.close(@intCast(i));
                        self.updateContainer();

                        // If tree is now empty, create a fresh pane
                        if (self.split_tree.root == SplitTree.INVALID) {
                            self.createInitialPane() catch {
                                log.err("failed to create replacement pane", .{});
                            };
                        }
                        return;
                    }
                },
                .split => {},
            }
        }
    }

    fn createInitialPane(self: *Workspace) !void {
        const pane = try Pane.init(self.allocator, self.id, self.socket_path);
        pane.on_empty = &onPaneEmpty;
        pane.on_empty_ctx = self;
        pane.on_focus = &onPaneFocus;
        pane.on_focus_ctx = self;

        try self.split_tree.setRoot(pane);
        pane.node_index = @intCast(self.split_tree.nodes.items.len - 1);

        const pane_w = pane.widget();
        c.gtk_widget_set_vexpand(pane_w, 1);
        c.gtk_widget_set_hexpand(pane_w, 1);
        c.gtk_box_append(self.container, pane_w);

        _ = try pane.addTab(null);
    }
};
