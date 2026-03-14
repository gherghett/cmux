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
    _ = std.posix.getenv("CMUX_SURFACE_ID") orelse "";

    // Read stdin (hook JSON payload) — extract message if present
    var stdin_buf: [4096]u8 = undefined;
    const stdin_len = std.io.getStdIn().read(&stdin_buf) catch 0;
    const stdin_data = stdin_buf[0..stdin_len];

    // Log to file (hook stderr is suppressed by 2>/dev/null)
    if (std.fs.createFileAbsolute("/tmp/cmux-hooks.log", .{ .truncate = false })) |file| {
        defer file.close();
        file.seekFromEnd(0) catch {};
        const w = file.writer();
        w.print("[cmux hook] {s} ws={s} stdin_len={}\n", .{
            subcommand, ws_id, stdin_len,
        }) catch {};
        if (stdin_len > 0) {
            const preview_len = @min(stdin_len, 500);
            w.print("[cmux hook] payload: {s}\n", .{stdin_data[0..preview_len]}) catch {};
        }
    } else |_| {}

    // Extract fields from hook JSON
    const last_msg = extractJsonField(stdin_data, "last_assistant_message");
    const hook_message = extractJsonField(stdin_data, "message");
    const notif_type = extractJsonField(stdin_data, "notification_type");
    const tool_name = extractJsonField(stdin_data, "tool_name");
    const hook_cwd = extractJsonField(stdin_data, "cwd");

    // Get workspace title for notification context
    var ws_title: []const u8 = "Terminal";
    var ws_title_buf: [256]u8 = undefined;
    if (ws_id.len > 0) {
        if (sendCommand("current_workspace")) |resp| {
            // Response is "uuid\ttitle" — extract title after tab
            if (std.mem.indexOfScalar(u8, resp, '\t')) |tab_pos| {
                const t = std.mem.trim(u8, resp[tab_pos + 1 ..], " \n\r");
                const tlen = @min(t.len, 256);
                @memcpy(ws_title_buf[0..tlen], t[0..tlen]);
                ws_title = ws_title_buf[0..tlen];
            }
        } else |_| {}
    }

    // Shorten CWD for display
    const home = std.posix.getenv("HOME") orelse "";
    var short_cwd: []const u8 = "";
    var short_cwd_buf: [128]u8 = undefined;
    if (hook_cwd) |cwd| {
        if (home.len > 0 and std.mem.startsWith(u8, cwd, home)) {
            const rest = cwd[home.len..];
            short_cwd_buf[0] = '~';
            const rlen = @min(rest.len, 127);
            @memcpy(short_cwd_buf[1..][0..rlen], rest[0..rlen]);
            short_cwd = short_cwd_buf[0 .. 1 + rlen];
        } else {
            const clen = @min(cwd.len, 128);
            @memcpy(short_cwd_buf[0..clen], cwd[0..clen]);
            short_cwd = short_cwd_buf[0..clen];
        }
    }

    if (std.mem.eql(u8, subcommand, "session-start") or std.mem.eql(u8, subcommand, "active")) {
        // PreToolUse — Claude is actively working. Set ✦ Running.
        var cmd_buf: [512]u8 = undefined;
        const cmd = std.fmt.bufPrint(&cmd_buf, "set_status claude_code Running --tab={s}", .{ws_id}) catch return;
        _ = sendCommand(cmd) catch {};

        // Show what tool Claude is using as message preview
        if (tool_name) |tn| {
            var msg_buf: [512]u8 = undefined;
            const msg_cmd = std.fmt.bufPrint(&msg_buf, "set_status claude_message Using {s}... --tab={s}", .{ tn, ws_id }) catch null;
            if (msg_cmd) |mc| _ = sendCommand(mc) catch {};
        }
    } else if (std.mem.eql(u8, subcommand, "stop") or std.mem.eql(u8, subcommand, "idle")) {
        // Stop — Claude finished its turn. Show last message + unread dot.
        // Payload has: last_assistant_message

        // Set the message preview from last_assistant_message
        if (last_msg) |m| {
            var msg_buf: [512]u8 = undefined;
            const msg_cmd = std.fmt.bufPrint(&msg_buf, "set_status claude_message {s} --tab={s}", .{ m[0..@min(m.len, 200)], ws_id }) catch null;
            if (msg_cmd) |mc| _ = sendCommand(mc) catch {};
        }

        // Set unread (blue dot) — will only show on inactive tabs
        var cmd_buf: [512]u8 = undefined;
        const cmd = std.fmt.bufPrint(&cmd_buf, "set_status claude_code Unread --tab={s}", .{ws_id}) catch return;
        _ = sendCommand(cmd) catch {};

        // Desktop notification: "Claude · ws-title · ~/cwd | last message"
        const notif_body = last_msg orelse "Claude finished";
        var notify_buf: [768]u8 = undefined;
        const notify = if (short_cwd.len > 0)
            std.fmt.bufPrint(&notify_buf, "notify Claude · {s} · {s}|{s} --tab={s}", .{ ws_title, short_cwd, notif_body[0..@min(notif_body.len, 200)], ws_id }) catch return
        else
            std.fmt.bufPrint(&notify_buf, "notify Claude · {s}|{s} --tab={s}", .{ ws_title, notif_body[0..@min(notif_body.len, 200)], ws_id }) catch return;
        _ = sendCommand(notify) catch {};
    } else if (std.mem.eql(u8, subcommand, "notification") or std.mem.eql(u8, subcommand, "notify")) {
        // Notification — Claude needs attention.
        // notification_type: "idle_prompt" (waiting) or "permission_prompt" (needs permission)
        const is_permission = if (notif_type) |nt| std.mem.eql(u8, nt, "permission_prompt") else false;

        if (is_permission) {
            // Permission needed — purple attention dot
            var cmd_buf: [512]u8 = undefined;
            const cmd = std.fmt.bufPrint(&cmd_buf, "set_status claude_code Needs input --tab={s}", .{ws_id}) catch return;
            _ = sendCommand(cmd) catch {};
        } else {
            // Idle prompt — unread dot (Claude finished, waiting for input)
            var cmd_buf: [512]u8 = undefined;
            const cmd = std.fmt.bufPrint(&cmd_buf, "set_status claude_code Unread --tab={s}", .{ws_id}) catch return;
            _ = sendCommand(cmd) catch {};
        }

        // Update message preview
        if (hook_message) |m| {
            var msg_buf: [512]u8 = undefined;
            const msg_cmd = std.fmt.bufPrint(&msg_buf, "set_status claude_message {s} --tab={s}", .{ m[0..@min(m.len, 200)], ws_id }) catch null;
            if (msg_cmd) |mc| _ = sendCommand(mc) catch {};
        }

        // Desktop notification
        // Desktop notification: "Claude · ws-title · ~/cwd | message"
        const notif_body = hook_message orelse "Claude needs attention";
        var notify_buf: [768]u8 = undefined;
        const notify = if (short_cwd.len > 0)
            std.fmt.bufPrint(&notify_buf, "notify Claude · {s} · {s}|{s} --tab={s}", .{ ws_title, short_cwd, notif_body[0..@min(notif_body.len, 200)], ws_id }) catch return
        else
            std.fmt.bufPrint(&notify_buf, "notify Claude · {s}|{s} --tab={s}", .{ ws_title, notif_body[0..@min(notif_body.len, 200)], ws_id }) catch return;
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
