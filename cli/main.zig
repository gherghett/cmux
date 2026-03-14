const std = @import("std");
const posix = std.posix;

const default_socket_path = "/tmp/cmux.sock";

pub fn main() !void {
    const args = std.os.argv;

    if (args.len < 2) {
        printUsage();
        return;
    }

    const first_arg = std.mem.span(args[1]);

    // Handle claude-hook subcommand specially — reads JSON from stdin
    if (std.mem.eql(u8, first_arg, "claude-hook")) {
        return handleClaudeHook(args);
    }

    // Build command string from remaining args
    var cmd_buf: [4096]u8 = undefined;
    var pos: usize = 0;

    for (args[1..]) |arg_ptr| {
        const arg = std.mem.span(arg_ptr);
        if (pos > 0) {
            cmd_buf[pos] = ' ';
            pos += 1;
        }
        if (pos + arg.len >= cmd_buf.len) {
            std.debug.print("error: command too long\n", .{});
            std.process.exit(1);
        }
        @memcpy(cmd_buf[pos..][0..arg.len], arg);
        pos += arg.len;
    }

    const response = sendCommand(cmd_buf[0..pos]) catch |err| {
        std.debug.print("error: {}\n", .{err});
        std.process.exit(1);
    };
    const stdout = std.io.getStdOut().writer();
    stdout.writeAll(response) catch {};
    if (response.len > 0 and response[response.len - 1] != '\n') {
        stdout.writeAll("\n") catch {};
    }
}

fn sendCommand(cmd: []const u8) ![]const u8 {
    const socket_path = std.posix.getenv("CMUX_SOCKET_PATH") orelse default_socket_path;

    const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer posix.close(fd);

    var addr: posix.sockaddr.un = .{ .family = posix.AF.UNIX, .path = undefined };
    const path_len = @min(socket_path.len, addr.path.len - 1);
    @memcpy(addr.path[0..path_len], socket_path[0..path_len]);
    addr.path[path_len] = 0;

    posix.connect(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)) catch {
        std.debug.print("error: cmux is not running (cannot connect to {s})\n", .{socket_path});
        std.process.exit(1);
    };

    // Send command + newline
    var send_buf: [4098]u8 = undefined;
    @memcpy(send_buf[0..cmd.len], cmd);
    send_buf[cmd.len] = '\n';
    _ = try posix.write(fd, send_buf[0 .. cmd.len + 1]);

    // Read response
    const n = try posix.read(fd, &response_storage);
    return response_storage[0..n];
}

var response_storage: [8192]u8 = undefined;

/// Handle `cmux-cli claude-hook <subcommand>`
/// Claude Code calls this via hooks with JSON on stdin.
fn handleClaudeHook(args: [][*:0]u8) void {
    if (args.len < 3) {
        std.debug.print("usage: cmux-cli claude-hook <session-start|stop|notification>\n", .{});
        std.process.exit(1);
    }

    const subcommand = std.mem.span(args[2]);
    const ws_id = std.posix.getenv("CMUX_WORKSPACE_ID") orelse "";
    const surface_id = std.posix.getenv("CMUX_SURFACE_ID") orelse "";

    // Read stdin (hook JSON payload) — we don't parse it fully for now
    var stdin_buf: [4096]u8 = undefined;
    const stdin_len = std.io.getStdIn().read(&stdin_buf) catch 0;
    _ = stdin_len;
    _ = surface_id;

    if (std.mem.eql(u8, subcommand, "session-start") or std.mem.eql(u8, subcommand, "active")) {
        // Claude started — set status to "Running"
        var cmd_buf: [512]u8 = undefined;
        const cmd = std.fmt.bufPrint(&cmd_buf, "set_status claude_code Running --tab={s}", .{ws_id}) catch return;
        _ = sendCommand(cmd) catch {};
    } else if (std.mem.eql(u8, subcommand, "stop") or std.mem.eql(u8, subcommand, "idle")) {
        // Claude stopped — clear status + send notification
        var cmd_buf: [512]u8 = undefined;
        const clear = std.fmt.bufPrint(&cmd_buf, "clear_status claude_code --tab={s}", .{ws_id}) catch return;
        _ = sendCommand(clear) catch {};

        var notify_buf: [512]u8 = undefined;
        const notify = std.fmt.bufPrint(&notify_buf, "notify Claude Code|Completed|Task finished", .{}) catch return;
        _ = sendCommand(notify) catch {};
    } else if (std.mem.eql(u8, subcommand, "notification") or std.mem.eql(u8, subcommand, "notify")) {
        // Claude needs input — set status + notification
        var cmd_buf: [512]u8 = undefined;
        const cmd = std.fmt.bufPrint(&cmd_buf, "set_status claude_code Needs input --tab={s}", .{ws_id}) catch return;
        _ = sendCommand(cmd) catch {};

        var notify_buf: [512]u8 = undefined;
        const notify = std.fmt.bufPrint(&notify_buf, "notify Claude Code|Needs input|Waiting for your response", .{}) catch return;
        _ = sendCommand(notify) catch {};
    } else {
        std.debug.print("unknown claude-hook subcommand: {s}\n", .{subcommand});
        std.process.exit(1);
    }
}

fn printUsage() void {
    const stderr = std.io.getStdErr().writer();
    stderr.writeAll(
        \\Usage: cmux-cli <command> [args...]
        \\
        \\Commands:
        \\  ping                          Test connection
        \\  list_workspaces               List all workspaces
        \\  current_workspace             Show current workspace
        \\  new_workspace                 Create a new workspace
        \\  select_workspace <id>         Switch to workspace
        \\  close_workspace <id>          Close workspace
        \\  rename_workspace <id> <title> Rename workspace
        \\  new_split <h|v>               Split current pane
        \\  send <text>                   Send text to focused terminal
        \\  set_status <key> <value>      Set sidebar status
        \\  clear_status <key>            Clear sidebar status
        \\  notify <title>|<subtitle>|<body>  Send notification
        \\  claude-hook <subcommand>      Claude Code hook handler
        \\
        \\Environment:
        \\  CMUX_SOCKET_PATH              Socket path (default: /tmp/cmux.sock)
        \\
    ) catch {};
}
