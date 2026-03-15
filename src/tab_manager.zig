const std = @import("std");
const cc = @import("c.zig");
const c = cc.c;
const uuid = @import("uuid.zig");
const Workspace = @import("workspace.zig").Workspace;
const Pane = @import("pane.zig").Pane;

const log = std.log.scoped(.tab_manager);

/// Manages an ordered list of workspaces (the "tabs" in the sidebar).
/// Owns the GtkStack that shows the active workspace's content.
pub const TabManager = struct {
    workspaces: std.ArrayList(*Workspace),
    selected: usize,
    stack: *c.GtkStack,
    allocator: std.mem.Allocator,
    socket_path: []const u8,

    /// Called when workspace list changes (for sidebar refresh)
    on_change: ?*const fn (?*anyopaque) void = null,
    on_change_data: ?*anyopaque = null,

    pub fn init(
        allocator: std.mem.Allocator,
        stack: *c.GtkStack,
        socket_path: []const u8,
    ) TabManager {
        return .{
            .workspaces = std.ArrayList(*Workspace).init(allocator),
            .selected = 0,
            .stack = stack,
            .allocator = allocator,
            .socket_path = socket_path,
        };
    }

    pub fn deinit(self: *TabManager) void {
        for (self.workspaces.items) |ws| {
            ws.deinit();
        }
        self.workspaces.deinit();
    }

    /// Create a new workspace and select it.
    pub fn createWorkspace(self: *TabManager) !*Workspace {
        const ws = try Workspace.init(self.allocator, self.socket_path);
        try self.workspaces.append(ws);

        // Add workspace container to the GtkStack
        var name_buf: [37]u8 = undefined;
        @memcpy(name_buf[0..36], uuid.asSlice(&ws.id));
        name_buf[36] = 0;
        _ = c.gtk_stack_add_named(self.stack, ws.containerWidget(), &name_buf);

        // Select the new workspace
        self.selected = self.workspaces.items.len - 1;
        self.showSelected();

        if (self.on_change) |cb| cb(self.on_change_data);

        log.info("created workspace {s} (total: {})", .{
            uuid.asSlice(&ws.id),
            self.workspaces.items.len,
        });

        return ws;
    }

    /// Close a workspace by ID.
    pub fn closeWorkspace(self: *TabManager, id: *const uuid.Uuid) void {
        for (self.workspaces.items, 0..) |ws, i| {
            if (uuid.eql(&ws.id, id)) {
                // Mark as closing to suppress auto-respawn
                ws.closing = true;
                // Kill dtach + disconnect signals for all panes
                var pane_list = std.ArrayList(*Pane).init(self.allocator);
                defer pane_list.deinit();
                ws.allPanes(&pane_list) catch {};
                for (pane_list.items) |pane| pane.close();

                // Remove from stack (GTK destroys the widget tree)
                c.gtk_stack_remove(self.stack, ws.containerWidget());
                self.allocator.destroy(ws);
                _ = self.workspaces.orderedRemove(i);

                // Adjust selection
                if (self.workspaces.items.len == 0) {
                    // Create a fresh default workspace
                    _ = self.createWorkspace() catch {
                        log.err("failed to create default workspace", .{});
                        return;
                    };
                } else if (self.selected >= self.workspaces.items.len) {
                    self.selected = self.workspaces.items.len - 1;
                    self.showSelected();
                } else {
                    self.showSelected();
                }

                if (self.on_change) |cb| cb(self.on_change_data);
                return;
            }
        }
    }

    /// Select a workspace by ID.
    pub fn selectWorkspace(self: *TabManager, id: *const uuid.Uuid) bool {
        for (self.workspaces.items, 0..) |ws, i| {
            if (uuid.eql(&ws.id, id)) {
                self.selected = i;
                self.showSelected();
                ws.markRead(); // clear unread indicator
                ws.focus();
                if (self.on_change) |cb| cb(self.on_change_data);
                return true;
            }
        }
        return false;
    }

    /// Select workspace by index (for Alt+1..9)
    pub fn selectByIndex(self: *TabManager, index: usize) void {
        if (index < self.workspaces.items.len) {
            self.selected = index;
            self.showSelected();
            self.workspaces.items[index].markRead(); // clear unread indicator
            self.workspaces.items[index].focus();
            if (self.on_change) |cb| cb(self.on_change_data);
        }
    }

    /// Select next workspace
    pub fn selectNext(self: *TabManager) void {
        if (self.workspaces.items.len <= 1) return;
        self.selected = (self.selected + 1) % self.workspaces.items.len;
        self.showSelected();
        self.workspaces.items[self.selected].focus();
    }

    /// Select previous workspace
    pub fn selectPrev(self: *TabManager) void {
        if (self.workspaces.items.len <= 1) return;
        if (self.selected == 0) {
            self.selected = self.workspaces.items.len - 1;
        } else {
            self.selected -= 1;
        }
        self.showSelected();
        self.workspaces.items[self.selected].focus();
    }

    /// Get the currently selected workspace
    pub fn current(self: *TabManager) ?*Workspace {
        if (self.workspaces.items.len == 0) return null;
        return self.workspaces.items[self.selected];
    }

    /// Find workspace by ID
    pub fn findWorkspace(self: *TabManager, id: *const uuid.Uuid) ?*Workspace {
        for (self.workspaces.items) |ws| {
            if (uuid.eql(&ws.id, id)) return ws;
        }
        return null;
    }

    /// Find a surface (pane tab) by ID across all workspaces
    pub fn findSurface(self: *TabManager, id: *const uuid.Uuid) ?struct {
        workspace: *Workspace,
        pane: *Pane,
        tab: *Pane.Tab,
    } {
        var pane_list = std.ArrayList(*Pane).init(self.allocator);
        defer pane_list.deinit();

        for (self.workspaces.items) |ws| {
            pane_list.clearRetainingCapacity();
            ws.allPanes(&pane_list) catch continue;
            for (pane_list.items) |pane| {
                for (pane.tabs.items) |*tab| {
                    if (uuid.eql(&tab.id, id)) {
                        return .{
                            .workspace = ws,
                            .pane = pane,
                            .tab = tab,
                        };
                    }
                }
            }
        }
        return null;
    }

    fn showSelected(self: *TabManager) void {
        if (self.workspaces.items.len == 0) return;
        const ws = self.workspaces.items[self.selected];
        var name_buf: [37]u8 = undefined;
        @memcpy(name_buf[0..36], uuid.asSlice(&ws.id));
        name_buf[36] = 0;
        c.gtk_stack_set_visible_child_name(self.stack, &name_buf);
    }
};
