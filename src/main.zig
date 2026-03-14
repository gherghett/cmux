const std = @import("std");
const cc = @import("c.zig");
const c = cc.c;
const Window = @import("window.zig").Window;
const SocketServer = @import("socket.zig").SocketServer;
const NotificationManager = @import("notification.zig").NotificationManager;

const log = std.log.scoped(.main);

/// Global state — accessible from callbacks
var g_window: ?*Window = null;
var g_socket: ?*SocketServer = null;
var g_notifications: ?NotificationManager = null;

const default_socket_path = "/tmp/cmux.sock";

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

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
    state.* = .{
        .allocator = allocator,
        .socket_path = socket_path,
    };

    _ = c.g_signal_connect_data(
        @ptrCast(app),
        "activate",
        @ptrCast(&onActivate),
        state,
        null,
        0,
    );

    const status = c.g_application_run(
        @ptrCast(app),
        @intCast(std.os.argv.len),
        @ptrCast(std.os.argv.ptr),
    );

    // Cleanup: socket and notifications only.
    // Don't destroy window/tab_manager/panes — GTK already killed the
    // VTE terminals during shutdown, triggering child-exited → pane.deinit().
    // Calling deinit again would double-free.
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

    // Start socket server — pointer to win.tab_manager is stable (heap-allocated)
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
