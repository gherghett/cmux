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

    // Read stdin (hook JSON payload) — extract message if present
    var stdin_buf: [4096]u8 = undefined;
    const stdin_len = std.io.getStdIn().read(&stdin_buf) catch 0;
    const stdin_data = stdin_buf[0..stdin_len];

    // Try to extract a message from the hook JSON (look for "message" field)
    const hook_message = extractJsonField(stdin_data, "message");
    _ = surface_id;

    if (std.mem.eql(u8, subcommand, "session-start") or std.mem.eql(u8, subcommand, "active")) {
        // Claude started — set status to Running
        var cmd_buf: [512]u8 = undefined;
        const cmd = std.fmt.bufPrint(&cmd_buf, "set_status claude_code Running --tab={s}", .{ws_id}) catch return;
        _ = sendCommand(cmd) catch {};
    } else if (std.mem.eql(u8, subcommand, "stop") or std.mem.eql(u8, subcommand, "idle")) {
        // Claude stopped — set message, clear status, notify

        // Set the last message if we got one from notification, otherwise "Completed"
        var msg_cmd_buf: [512]u8 = undefined;
        const msg = if (hook_message) |m|
            std.fmt.bufPrint(&msg_cmd_buf, "set_status claude_message {s} --tab={s}", .{ m, ws_id }) catch null
        else
            std.fmt.bufPrint(&msg_cmd_buf, "set_status claude_message Completed --tab={s}", .{ws_id}) catch null;
        if (msg) |m| _ = sendCommand(m) catch {};

        var cmd_buf: [512]u8 = undefined;
        const clear = std.fmt.bufPrint(&cmd_buf, "clear_status claude_code --tab={s}", .{ws_id}) catch return;
        _ = sendCommand(clear) catch {};

        var notify_buf: [512]u8 = undefined;
        const notify = std.fmt.bufPrint(&notify_buf, "notify Claude Code|Completed|Task finished", .{}) catch return;
        _ = sendCommand(notify) catch {};
    } else if (std.mem.eql(u8, subcommand, "notification") or std.mem.eql(u8, subcommand, "notify")) {
        // Claude sent a notification. Update message preview but keep ✦ running.
        // Only show ● attention for explicit permission/input requests.
        const hook_type = extractJsonField(stdin_data, "type") orelse
            extractJsonField(stdin_data, "event") orelse "";

        const needs_attention = std.mem.indexOf(u8, hook_type, "permission") != null or
            std.mem.indexOf(u8, hook_type, "input") != null or
            std.mem.indexOf(u8, hook_type, "question") != null;

        if (needs_attention) {
            var cmd_buf: [512]u8 = undefined;
            const cmd = std.fmt.bufPrint(&cmd_buf, "set_status claude_code Needs input --tab={s}", .{ws_id}) catch return;
            _ = sendCommand(cmd) catch {};
        }

        // Always update the message preview
        if (hook_message) |m| {
            var msg_buf: [512]u8 = undefined;
            const msg_cmd = std.fmt.bufPrint(&msg_buf, "set_status claude_message {s} --tab={s}", .{ m, ws_id }) catch null;
            if (msg_cmd) |mc| _ = sendCommand(mc) catch {};
        }

        // Send desktop notification
        const notif_text = hook_message orelse "Claude needs attention";
        var notify_buf: [512]u8 = undefined;
        const notify = std.fmt.bufPrint(&notify_buf, "notify Claude Code|{s}", .{notif_text[0..@min(notif_text.len, 200)]}) catch return;
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

/// Simple JSON field extractor — finds "key": "value" and returns value.
/// No full JSON parser needed; just string matching for simple hook payloads.
fn extractJsonField(json: []const u8, key: []const u8) ?[]const u8 {
    // Search for "key": "value" or "key":"value"
    var search_buf: [128]u8 = undefined;
    const search = std.fmt.bufPrint(&search_buf, "\"{s}\"", .{key}) catch return null;

    const key_pos = std.mem.indexOf(u8, json, search) orelse return null;
    const after_key = key_pos + search.len;
    if (after_key >= json.len) return null;

    // Skip whitespace and colon
    var pos = after_key;
    while (pos < json.len and (json[pos] == ' ' or json[pos] == ':' or json[pos] == '\t')) : (pos += 1) {}
    if (pos >= json.len) return null;

    // Expect opening quote
    if (json[pos] != '"') return null;
    pos += 1;

    // Find closing quote (handle escaped quotes)
    const start = pos;
    while (pos < json.len) : (pos += 1) {
        if (json[pos] == '\\') {
            pos += 1; // skip escaped char
            continue;
        }
        if (json[pos] == '"') break;
    }
    if (pos >= json.len) return null;

    const value = json[start..pos];
    // Truncate to reasonable display length
    return value[0..@min(value.len, 200)];
}
