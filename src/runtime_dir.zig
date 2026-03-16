const std = @import("std");
const posix = std.posix;

const log = std.log.scoped(.runtime_dir);

/// Resolved runtime directory for all cmux files (sockets, session, logs).
///
/// Priority:
///   1. $XDG_RUNTIME_DIR/cmux     (e.g. /run/user/1000/cmux)
///   2. /tmp/cmux-<uid>           (fallback)
///
/// The directory is created on first access if it doesn't exist.
var dir_buf: [256]u8 = undefined;
var dir_len: usize = 0;
var initialized: bool = false;

/// Get the runtime directory path (e.g. "/run/user/1000/cmux").
/// Initializes on first call, cached thereafter.
pub fn get() []const u8 {
    if (!initialized) init();
    return dir_buf[0..dir_len];
}

fn init() void {
    if (posix.getenv("XDG_RUNTIME_DIR")) |xdg| {
        dir_len = (std.fmt.bufPrint(&dir_buf, "{s}/cmux", .{xdg}) catch return).len;
    } else {
        const uid = std.os.linux.getuid();
        dir_len = (std.fmt.bufPrint(&dir_buf, "/tmp/cmux-{d}", .{uid}) catch return).len;
        log.info("XDG_RUNTIME_DIR not set, using {s}", .{dir_buf[0..dir_len]});
    }
    initialized = true;

    // Ensure directory exists
    std.fs.makeDirAbsolute(dir_buf[0..dir_len]) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => log.err("failed to create runtime dir {s}: {}", .{ dir_buf[0..dir_len], err }),
    };
}

// ── Path builders ───────────────────────────────────────
// Each has its own static buffer so callers can hold multiple
// results simultaneously without aliasing.

var socket_buf: [512]u8 = undefined;
var session_buf: [512]u8 = undefined;
var log_buf: [512]u8 = undefined;

/// Socket path for the IPC server (e.g. "/run/user/1000/cmux/cmux.sock").
pub fn socketPath() []const u8 {
    const base = get();
    const len = (std.fmt.bufPrint(&socket_buf, "{s}/cmux.sock", .{base}) catch return base).len;
    return socket_buf[0..len];
}

/// Dtach socket path for a pane. Caller provides buffer (path is per-pane, can't be static).
pub fn dtachPath(buf: []u8, pane_id: []const u8) []const u8 {
    const base = get();
    const result = std.fmt.bufPrint(buf, "{s}/dtach-{s}.sock", .{ base, pane_id }) catch return "";
    return result;
}

/// Session file path (e.g. "/run/user/1000/cmux/session.json").
pub fn sessionFile() []const u8 {
    const base = get();
    const len = (std.fmt.bufPrint(&session_buf, "{s}/session.json", .{base}) catch return base).len;
    return session_buf[0..len];
}

/// Log file path (e.g. "/run/user/1000/cmux/cmux.log").
pub fn logFile() []const u8 {
    const base = get();
    const len = (std.fmt.bufPrint(&log_buf, "{s}/cmux.log", .{base}) catch return base).len;
    return log_buf[0..len];
}
