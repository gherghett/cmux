const std = @import("std");
const cc = @import("c.zig");
const c = cc.c;
const Window = @import("window.zig").Window;
const SocketServer = @import("socket.zig").SocketServer;
const NotificationManager = @import("notification.zig").NotificationManager;
const session = @import("session.zig");

const log = std.log.scoped(.main);

var g_window: ?*Window = null;
var g_socket: ?*SocketServer = null;
var g_notifications: ?NotificationManager = null;

const default_socket_path = "/tmp/cmux.sock";

pub fn main() !void {
    const allocator = std.heap.c_allocator;
    const socket_path = std.posix.getenv("CMUX_SOCKET_PATH") orelse default_socket_path;

    const app: *c.AdwApplication = c.adw_application_new(
        "dev.cmux.terminal",
        c.G_APPLICATION_DEFAULT_FLAGS,
    ) orelse {
        log.err("failed to create AdwApplication", .{});
        return error.ApplicationCreateFailed;
    };
    defer c.g_object_unref(app);

    const state = try allocator.create(AppState);
    defer allocator.destroy(state);
    state.* = .{ .allocator = allocator, .socket_path = socket_path };

    _ = c.g_signal_connect_data(
        @ptrCast(app), "activate", @ptrCast(&onActivate), state, null, 0,
    );

    // Save session on shutdown
    _ = c.g_signal_connect_data(
        @ptrCast(app), "shutdown", @ptrCast(&onShutdown), null, null, 0,
    );

    // Handle SIGTERM/SIGINT to save session before exit
    _ = c.g_unix_signal_add(15, @ptrCast(&onSignalQuit), app); // SIGTERM
    _ = c.g_unix_signal_add(2, @ptrCast(&onSignalQuit), app); // SIGINT

    const status = c.g_application_run(
        @ptrCast(app),
        @intCast(std.os.argv.len),
        @ptrCast(std.os.argv.ptr),
    );

    // Save session on normal exit too
    if (g_window) |win| session.save(&win.tab_manager);

    if (g_socket) |sock| sock.destroy();
    if (g_notifications) |*notifs| notifs.deinit();

    if (status != 0) {
        log.err("application exited with status {}", .{status});
    }
}

const AppState = struct {
    allocator: std.mem.Allocator,
    socket_path: []const u8,
};

fn onActivate(_: *c.GApplication, user_data: ?*anyopaque) callconv(.C) void {
    const state: *AppState = @ptrCast(@alignCast(user_data));

    g_notifications = NotificationManager.init(state.allocator);

    const app: *c.AdwApplication = @ptrCast(@alignCast(
        c.g_application_get_default() orelse return,
    ));

    const win = Window.create(app, state.allocator, state.socket_path) catch |err| {
        log.err("failed to create window: {}", .{err});
        return;
    };
    g_window = win;

    // Try to restore previous session
    const restored = session.restore(&win.tab_manager);
    if (restored) {
        // Remove the default empty workspace that Window.create made
        // (only if we restored workspaces successfully)
        if (win.tab_manager.workspaces.items.len > 1) {
            const first_id = win.tab_manager.workspaces.items[0].id;
            win.tab_manager.closeWorkspace(&first_id);
        }
    }

    if (SocketServer.create(
        state.allocator,
        state.socket_path,
        &win.tab_manager,
    )) |sock| {
        g_socket = sock;
    } else |err| {
        log.warn("socket server failed to start: {} — CLI control disabled", .{err});
    }

    win.show();
    log.info("cmux started (socket: {s})", .{state.socket_path});
}

fn onShutdown(_: *c.GApplication, _: ?*anyopaque) callconv(.C) void {
    if (g_window) |win| {
        session.save(&win.tab_manager);
    }
}

fn onSignalQuit(app: ?*anyopaque) callconv(.C) c.gboolean {
    // Save session then quit the GTK app
    if (g_window) |win| session.save(&win.tab_manager);
    if (app) |a| c.g_application_quit(@ptrCast(@alignCast(a)));
    return 0;
}
