const std = @import("std");
const cc = @import("c.zig");
const c = cc.c;
const Window = @import("window.zig").Window;
const SocketServer = @import("socket.zig").SocketServer;
const NotificationManager = @import("notification.zig").NotificationManager;
const session = @import("session.zig");
const runtime_dir = @import("runtime_dir.zig");

const log = std.log.scoped(.main);

var g_window: ?*Window = null;
var g_socket: ?*SocketServer = null;
var g_notifications: ?NotificationManager = null;

// ──────────────────────────────────────────────────────────
// Persistent file logging
// ──────────────────────────────────────────────────────────

const log_max_size: u64 = 512 * 1024; // 512 KB, rotate when exceeded

var g_log_file: ?std.fs.File = null;

fn openLogFile() void {
    const path = runtime_dir.logFile();

    // Rotate if too large
    var old_buf: [520]u8 = undefined;
    const old_path = std.fmt.bufPrint(&old_buf, "{s}.old", .{path}) catch path;

    if (std.fs.openFileAbsolute(path, .{})) |f| {
        const stat = f.stat() catch {
            f.close();
            return;
        };
        f.close();
        if (stat.size > log_max_size) {
            std.fs.deleteFileAbsolute(old_path) catch {};
            std.fs.renameAbsolute(path, old_path) catch {};
        }
    } else |_| {}

    g_log_file = std.fs.createFileAbsolute(path, .{ .truncate = false }) catch null;
    if (g_log_file) |f| f.seekFromEnd(0) catch {};
}

pub const std_options: std.Options = .{
    .logFn = cmuxLog,
    .log_level = .info,
};

fn cmuxLog(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    const level_txt = comptime level.asText();
    const prefix = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";

    // Write to stderr
    const stderr = std.io.getStdErr();
    nosuspend stderr.writer().print(level_txt ++ prefix ++ format ++ "\n", args) catch {};

    // Write to log file with timestamp
    if (g_log_file) |file| {
        const w = file.writer();
        const ts = std.time.timestamp();
        nosuspend w.print("[{d}] " ++ level_txt ++ prefix ++ format ++ "\n", .{ts} ++ args) catch {};
    }
}

// ──────────────────────────────────────────────────────────
// Application
// ──────────────────────────────────────────────────────────

pub fn main() !void {
    // Initialize runtime dir first (creates directory, needed for log file)
    _ = runtime_dir.get();
    openLogFile();
    defer if (g_log_file) |f| f.close();

    const allocator = std.heap.c_allocator;
    const socket_path = std.posix.getenv("CMUX_SOCKET_PATH") orelse runtime_dir.socketPath();

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

    // Post g_application_run: GTK widgets are destroyed. Don't save session
    // (use-after-free on VTE terminals). Session was already saved in
    // onCloseRequest or onSignalQuit.
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

    // Create window shell (no workspace yet — reconcile will decide)
    const win = Window.create(app, state.allocator, state.socket_path) catch |err| {
        log.err("failed to create window: {}", .{err});
        return;
    };
    g_window = win;

    // Reconcile: scan dtach sockets, kill danglers, restore session or create default.
    // This is the single entry point for workspace creation at startup.
    _ = session.reconcile(&win.tab_manager);

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

/// Mark all workspaces as closing to suppress pane respawn during GTK teardown.
fn markAllClosing() void {
    if (g_window) |win| {
        for (win.tab_manager.workspaces.items) |ws| {
            ws.closing = true;
        }
    }
}

/// Destroy the socket server while GLib sources are still valid.
fn destroySocket() void {
    if (g_socket) |sock| {
        sock.destroy();
        g_socket = null;
    }
}

fn onShutdown(_: *c.GApplication, _: ?*anyopaque) callconv(.C) void {
    // onShutdown fires after GTK teardown — don't save (use-after-free).
    // Session was already saved in onCloseRequest or onSignalQuit.
    markAllClosing();
    destroySocket();
}

fn onSignalQuit(app: ?*anyopaque) callconv(.C) c.gboolean {
    // Save session while data is still valid, then shut down cleanly.
    if (g_window) |win| session.save(&win.tab_manager);
    markAllClosing();
    destroySocket();
    if (app) |a| c.g_application_quit(@ptrCast(@alignCast(a)));
    return 0;
}
