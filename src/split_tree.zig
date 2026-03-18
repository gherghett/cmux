const std = @import("std");
const cc = @import("c.zig");
const c = cc.c;
const asWidget = cc.asWidget;
const uuid = @import("uuid.zig");
const Pane = @import("pane.zig").Pane;

const log = std.log.scoped(.split_tree);

/// Binary tree of split panes. Internal nodes are GtkPaned (horizontal or
/// vertical dividers). Leaf nodes are Panes (GtkNotebook with VteTerminals).
///
///  Example layout:
///
///      Split(V, 0.5)
///      /            \
///   Pane(A)     Split(H, 0.5)
///               /          \
///           Pane(B)      Pane(C)
///
///  Renders as:
///  ┌──────────┬──────────┐
///  │          │ Pane B   │
///  │ Pane A   ├──────────┤
///  │          │ Pane C   │
///  └──────────┴──────────┘
///
pub const SplitTree = struct {
    pub const Direction = enum { horizontal, vertical };

    pub const NodeIndex = u16;
    pub const INVALID: NodeIndex = std.math.maxInt(NodeIndex);

    pub const Node = union(enum) {
        leaf: LeafNode,
        split: SplitNode,
        dead: void, // freed node — pane memory released, skip during iteration
    };

    pub const LeafNode = struct {
        pane: *Pane,
    };

    pub const SplitNode = struct {
        direction: Direction,
        paned: *c.GtkPaned,
        first: NodeIndex,
        second: NodeIndex,
    };

    nodes: std.ArrayList(Node),
    parents: std.ArrayList(NodeIndex),
    /// Index of the root node, or INVALID if tree is empty
    root: NodeIndex,
    /// The currently focused pane
    focused: NodeIndex,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) SplitTree {
        return .{
            .nodes = std.ArrayList(Node).init(allocator),
            .parents = std.ArrayList(NodeIndex).init(allocator),
            .root = INVALID,
            .focused = INVALID,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SplitTree) void {
        // Clean up panes
        for (self.nodes.items) |node| {
            switch (node) {
                .leaf => |leaf| leaf.pane.deinit(),
                .split, .dead => {},
            }
        }
        self.nodes.deinit();
        self.parents.deinit();
    }

    /// Add the initial pane to an empty tree.
    pub fn setRoot(self: *SplitTree, pane: *Pane) !void {
        const idx = try self.addNode(.{ .leaf = .{ .pane = pane } }, INVALID);
        self.root = idx;
        self.focused = idx;
    }

    /// Split the pane at `target_idx` in the given direction.
    /// Returns the new pane's node index.
    pub fn split(
        self: *SplitTree,
        target_idx: NodeIndex,
        direction: Direction,
        new_pane: *Pane,
    ) !NodeIndex {
        if (target_idx >= self.nodes.items.len) return error.InvalidIndex;

        const target_node = self.nodes.items[target_idx];
        if (target_node != .leaf) return error.CanOnlySplitLeaf;

        // Create GtkPaned
        const orientation: c_uint = switch (direction) {
            .horizontal => c.GTK_ORIENTATION_VERTICAL, // H split = panes stacked vertically
            .vertical => c.GTK_ORIENTATION_HORIZONTAL, // V split = panes side by side
        };
        const paned: *c.GtkPaned = @ptrCast(@alignCast(
            c.gtk_paned_new(orientation) orelse return error.GtkWidgetCreateFailed,
        ));

        // Create new leaf node for the new pane
        const new_leaf_idx = try self.addNode(.{ .leaf = .{ .pane = new_pane } }, INVALID);

        // The old leaf stays at target_idx but we need to update the tree:
        // 1. The target's parent now points to a new split node
        // 2. The split node has the old leaf as first child, new leaf as second

        // Create split node (replaces target in the tree)
        const split_idx = try self.addNode(.{ .split = .{
            .direction = direction,
            .paned = paned,
            .first = target_idx,
            .second = new_leaf_idx,
        } }, self.parents.items[target_idx]);

        // Update parent references
        self.parents.items[target_idx] = split_idx;
        self.parents.items[new_leaf_idx] = split_idx;

        // If target was the root, update root
        if (self.root == target_idx) {
            self.root = split_idx;
        } else {
            // Update the grandparent's child reference
            const parent_idx = self.parents.items[split_idx];
            var parent = &self.nodes.items[parent_idx].split;
            if (parent.first == target_idx) {
                parent.first = split_idx;
            } else {
                parent.second = split_idx;
            }
        }

        // Set up GtkPaned children.
        // CRITICAL: Must use gtk_paned_set_start/end_child(NULL) to remove
        // from a GtkPaned parent — gtk_widget_unparent does NOT update the
        // paned's internal child pointers, causing layout crashes.
        const target_widget = self.nodeWidget(target_idx);
        const new_widget = self.nodeWidget(new_leaf_idx);

        // Ref to keep alive during reparent
        _ = c.g_object_ref(@ptrCast(@alignCast(target_widget)));

        // Remove from old parent using the correct container API
        if (c.gtk_widget_get_parent(target_widget)) |old_parent| {
            removeFromParent(old_parent, target_widget);
        }

        c.gtk_paned_set_start_child(paned, target_widget);
        c.gtk_paned_set_end_child(paned, new_widget);

        // Release our extra ref now that the paned owns it
        c.g_object_unref(@ptrCast(@alignCast(target_widget)));
        c.gtk_paned_set_resize_start_child(paned, 1);
        c.gtk_paned_set_resize_end_child(paned, 1);

        // Set initial 50/50 split position. We need the parent's size
        // to calculate, but the paned might not be allocated yet.
        // Use a one-shot idle callback to set position after layout.
        requestEqualSplit(paned);

        // If there was a parent split, update its widget
        if (self.parents.items[split_idx] != INVALID) {
            const gp_idx = self.parents.items[split_idx];
            const gp = &self.nodes.items[gp_idx].split;
            const paned_widget = asWidget(paned);
            if (gp.first == split_idx) {
                c.gtk_paned_set_start_child(gp.paned, paned_widget);
            } else {
                c.gtk_paned_set_end_child(gp.paned, paned_widget);
            }
        }

        // Focus the new pane
        self.focused = new_leaf_idx;

        log.info("split idx={} dir={s} new_leaf={} split_node={} root={}", .{
            target_idx, @tagName(direction), new_leaf_idx, split_idx, self.root,
        });

        return new_leaf_idx;
    }

    /// Close the pane at `idx`, collapsing the parent split.
    /// If kill_dtach is true, kills the dtach process (user-initiated close).
    /// If false, dtach stays alive (cmux shutdown / session persistence).
    pub fn close(self: *SplitTree, idx: NodeIndex) void {
        self.closeInner(idx, true);
    }

    pub fn closeSoft(self: *SplitTree, idx: NodeIndex) void {
        self.closeInner(idx, false);
    }

    fn closeInner(self: *SplitTree, idx: NodeIndex, kill_dtach: bool) void {
        if (idx >= self.nodes.items.len) return;
        if (self.nodes.items[idx] != .leaf) return;

        const parent_idx = self.parents.items[idx];

        // If this is the only node (root leaf), just mark tree empty
        if (parent_idx == INVALID) {
            if (kill_dtach) self.nodes.items[idx].leaf.pane.close() else self.nodes.items[idx].leaf.pane.deinit();
            self.nodes.items[idx] = .dead;
            self.root = INVALID;
            self.focused = INVALID;
            return;
        }

        // Find the sibling
        const parent = self.nodes.items[parent_idx].split;
        const sibling_idx = if (parent.first == idx) parent.second else parent.first;

        // The sibling takes the parent's position in the tree
        const grandparent_idx = self.parents.items[parent_idx];
        self.parents.items[sibling_idx] = grandparent_idx;

        // Get widget refs BEFORE freeing the pane
        const closed_widget = self.nodeWidget(idx);
        const old_paned = parent.paned;

        // Remove closed widget from GtkPaned BEFORE freeing the pane.
        if (c.gtk_paned_get_start_child(old_paned) == closed_widget) {
            c.gtk_paned_set_start_child(old_paned, null);
        } else if (c.gtk_paned_get_end_child(old_paned) == closed_widget) {
            c.gtk_paned_set_end_child(old_paned, null);
        }

        // Now safe to free the pane. Kill dtach if user-initiated.
        if (kill_dtach) self.nodes.items[idx].leaf.pane.close() else self.nodes.items[idx].leaf.pane.deinit();
        self.nodes.items[idx] = .dead;

        // Update tree structure: sibling replaces parent in the tree.
        // The old GtkPaned stays in the widget hierarchy as a pass-through
        // container with one child. Visually transparent.
        if (grandparent_idx == INVALID) {
            self.root = sibling_idx;
        } else {
            var gp = &self.nodes.items[grandparent_idx].split;
            if (gp.first == parent_idx) {
                gp.first = sibling_idx;
            } else {
                gp.second = sibling_idx;
            }
        }
        self.parents.items[sibling_idx] = grandparent_idx;

        // Focus the sibling (or its first leaf if it's a split)
        self.focused = self.firstLeaf(sibling_idx);

        log.info("closed pane idx={} sibling={} focused={} root={}", .{
            idx, sibling_idx, self.focused, self.root,
        });
    }

    /// Get the root widget for embedding in a container.
    pub fn rootWidget(self: *SplitTree) ?*c.GtkWidget {
        if (self.root == INVALID) return null;
        return self.nodeWidget(self.root);
    }

    /// Get the currently focused pane.
    pub fn focusedPane(self: *SplitTree) ?*Pane {
        if (self.focused == INVALID) return null;
        if (self.focused >= self.nodes.items.len) return null;
        return switch (self.nodes.items[self.focused]) {
            .leaf => |leaf| leaf.pane,
            .split, .dead => null,
        };
    }

    /// Navigate focus in a direction.
    pub fn moveFocus(self: *SplitTree, direction: Direction) void {
        if (self.focused == INVALID) return;

        // Walk up the tree to find a split node matching the direction,
        // then walk down the opposite branch to find a leaf.
        var current = self.focused;
        while (self.parents.items[current] != INVALID) {
            const parent_idx = self.parents.items[current];
            const parent = self.nodes.items[parent_idx].split;

            if (parent.direction == direction) {
                // We found a relevant split. Navigate to the other side.
                const other = if (parent.first == current) parent.second else parent.first;
                // Find the nearest leaf on that side
                self.focused = self.firstLeaf(other);

                if (self.focusedPane()) |pane| {
                    pane.focus();
                }
                return;
            }
            current = parent_idx;
        }
        // No matching split found — focus stays where it is
    }

    /// Collect all LIVE panes by traversing from root (skips dead nodes).
    pub fn allPanes(self: *SplitTree, out: *std.ArrayList(*Pane)) !void {
        if (self.root == INVALID) return;
        try self.collectPanes(self.root, out);
    }

    fn collectPanes(self: *SplitTree, idx: NodeIndex, out: *std.ArrayList(*Pane)) !void {
        if (idx >= self.nodes.items.len) return;
        switch (self.nodes.items[idx]) {
            .leaf => |leaf| try out.append(leaf.pane),
            .split => |s| {
                try self.collectPanes(s.first, out);
                try self.collectPanes(s.second, out);
            },
            .dead => {},
        }
    }

    const EqualSplitCtx = struct {
        paned: *c.GtkPaned,
        attempts: u16,
    };

    fn onSetEqualSplit(user_data: ?*anyopaque) callconv(.C) c.gboolean {
        const ctx: *EqualSplitCtx = @ptrCast(@alignCast(user_data orelse return 0));
        const orientation = c.gtk_orientable_get_orientation(@ptrCast(@alignCast(ctx.paned)));
        const total: c_int = if (orientation == c.GTK_ORIENTATION_HORIZONTAL)
            c.gtk_widget_get_width(asWidget(ctx.paned))
        else
            c.gtk_widget_get_height(asWidget(ctx.paned));

        if (total > 0) {
            c.gtk_paned_set_position(ctx.paned, @divTrunc(total, 2));
            std.heap.c_allocator.destroy(ctx);
            return 0; // done
        }
        ctx.attempts += 1;
        if (ctx.attempts > 100) {
            // Give up — pane is probably on a hidden workspace.
            // Position will be set when the workspace becomes visible.
            std.heap.c_allocator.destroy(ctx);
            return 0;
        }
        return 1; // try again next idle
    }

    pub fn nullLogHandler(_: [*c]const u8, _: c.GLogLevelFlags, _: [*c]const u8, _: ?*anyopaque) callconv(.C) void {}

    // --- Tree construction helpers (for session restore) ---

    /// Add a leaf node directly. Returns its index.
    pub fn addLeaf(self: *SplitTree, pane: *Pane, parent: NodeIndex) !NodeIndex {
        return self.addNode(.{ .leaf = .{ .pane = pane } }, parent);
    }

    /// Add a split node directly, linking two existing children. Returns its index.
    pub fn addSplit(
        self: *SplitTree,
        direction: Direction,
        paned: *c.GtkPaned,
        first: NodeIndex,
        second: NodeIndex,
        parent: NodeIndex,
    ) !NodeIndex {
        const idx = try self.addNode(.{ .split = .{
            .direction = direction,
            .paned = paned,
            .first = first,
            .second = second,
        } }, parent);
        self.parents.items[first] = idx;
        self.parents.items[second] = idx;
        return idx;
    }

    /// Get the widget for a node by index.
    pub fn getNodeWidget(self: *SplitTree, idx: NodeIndex) *c.GtkWidget {
        return self.nodeWidget(idx);
    }

    /// Request a 50/50 split position once the paned is laid out.
    pub fn requestEqualSplit(paned: *c.GtkPaned) void {
        const ctx = std.heap.c_allocator.create(EqualSplitCtx) catch return;
        ctx.* = .{ .paned = paned, .attempts = 0 };
        _ = c.g_idle_add(@ptrCast(&onSetEqualSplit), ctx);
    }

    /// Get the first leaf starting from the root (for session restore focus).
    pub fn firstLeafFromRoot(self: *SplitTree) NodeIndex {
        if (self.root == INVALID) return INVALID;
        return self.firstLeaf(self.root);
    }

    // --- Internal helpers ---

    /// Remove a child widget from its parent using the correct container API.
    /// GtkPaned needs set_start/end_child(NULL); GtkBox needs gtk_box_remove.
    pub fn removeFromParent(parent: *c.GtkWidget, child: *c.GtkWidget) void {
        // Check if parent is a GtkPaned by using GTK's type checking
        if (c.g_type_check_instance_is_a(
            @ptrCast(@alignCast(parent)),
            c.gtk_paned_get_type(),
        ) != 0) {
            const as_paned: *c.GtkPaned = @ptrCast(@alignCast(parent));
            if (c.gtk_paned_get_start_child(as_paned) == child) {
                c.gtk_paned_set_start_child(as_paned, null);
            } else {
                c.gtk_paned_set_end_child(as_paned, null);
            }
        } else {
            // Assume GtkBox
            c.gtk_box_remove(@ptrCast(@alignCast(parent)), child);
        }
    }

    fn addNode(self: *SplitTree, node: Node, parent: NodeIndex) !NodeIndex {
        const idx: NodeIndex = @intCast(self.nodes.items.len);
        try self.nodes.append(node);
        try self.parents.append(parent);
        return idx;
    }

    fn nodeWidget(self: *SplitTree, idx: NodeIndex) *c.GtkWidget {
        return switch (self.nodes.items[idx]) {
            .leaf => |leaf| leaf.pane.widget(),
            .split => |s| asWidget(s.paned),
            .dead => unreachable, // dead nodes should never be accessed for widgets
        };
    }

    fn firstLeaf(self: *SplitTree, idx: NodeIndex) NodeIndex {
        var current = idx;
        while (true) {
            switch (self.nodes.items[current]) {
                .leaf => return current,
                .split => |s| current = s.first,
                .dead => return INVALID,
            }
        }
    }
};

// --- Tests ---

test "split tree basic operations" {
    // These tests verify tree structure without GTK (they'll crash on
    // nodeWidget calls, but the logic is testable with mock nodes).
    // For real integration tests, use a running GTK application.
    const allocator = std.testing.allocator;
    var tree = SplitTree.init(allocator);
    defer tree.deinit();

    // Initially empty
    try std.testing.expectEqual(SplitTree.INVALID, tree.root);
    try std.testing.expectEqual(SplitTree.INVALID, tree.focused);
}
