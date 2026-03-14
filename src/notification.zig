const std = @import("std");
const cc = @import("c.zig");
const c = cc.c;
const uuid = @import("uuid.zig");

const log = std.log.scoped(.notification);

pub const Notification = struct {
    id: uuid.Uuid,
    title: [256]u8,
    title_len: usize,
    body: [512]u8,
    body_len: usize,
    workspace_id: uuid.Uuid,
    surface_id: ?uuid.Uuid,
    read: bool,
    timestamp: i64,
};

/// Manages notifications — in-memory store + desktop notifications via libnotify.
pub const NotificationManager = struct {
    notifications: std.ArrayList(Notification),
    initialized: bool,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) NotificationManager {
        const result = c.notify_init("cmux");
        return .{
            .notifications = std.ArrayList(Notification).init(allocator),
            .initialized = result != 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *NotificationManager) void {
        self.notifications.deinit();
        if (self.initialized) {
            c.notify_uninit();
        }
    }

    /// Create and show a notification.
    pub fn send(
        self: *NotificationManager,
        title: []const u8,
        body: []const u8,
        workspace_id: uuid.Uuid,
        surface_id: ?uuid.Uuid,
    ) !void {
        var notif = Notification{
            .id = uuid.generate(),
            .title = undefined,
            .title_len = @min(title.len, 256),
            .body = undefined,
            .body_len = @min(body.len, 512),
            .workspace_id = workspace_id,
            .surface_id = surface_id,
            .read = false,
            .timestamp = std.time.timestamp(),
        };
        @memcpy(notif.title[0..notif.title_len], title[0..notif.title_len]);
        @memcpy(notif.body[0..notif.body_len], body[0..notif.body_len]);

        try self.notifications.append(notif);

        // Show desktop notification via libnotify
        if (self.initialized) {
            var title_z: [257]u8 = undefined;
            @memcpy(title_z[0..notif.title_len], title[0..notif.title_len]);
            title_z[notif.title_len] = 0;

            var body_z: [513]u8 = undefined;
            const body_ptr: ?[*:0]const u8 = if (body.len > 0) blk: {
                @memcpy(body_z[0..notif.body_len], body[0..notif.body_len]);
                body_z[notif.body_len] = 0;
                break :blk &body_z;
            } else null;

            const n = c.notify_notification_new(&title_z, body_ptr, null);
            if (n) |notification| {
                _ = c.notify_notification_show(notification, null);
                c.g_object_unref(notification);
            }
        }

        log.info("notification: {s}", .{title[0..notif.title_len]});
    }

    /// Get unread count for a workspace
    pub fn unreadCount(self: *NotificationManager, workspace_id: *const uuid.Uuid) u32 {
        var count: u32 = 0;
        for (self.notifications.items) |n| {
            if (uuid.eql(&n.workspace_id, workspace_id) and !n.read) {
                count += 1;
            }
        }
        return count;
    }

    /// Clear all notifications
    pub fn clearAll(self: *NotificationManager) void {
        self.notifications.clearRetainingCapacity();
    }

    /// Mark all as read for a workspace
    pub fn markRead(self: *NotificationManager, workspace_id: *const uuid.Uuid) void {
        for (self.notifications.items) |*n| {
            if (uuid.eql(&n.workspace_id, workspace_id)) {
                n.read = true;
            }
        }
    }
};
