const std = @import("std");
const cc = @import("c.zig");
const c = cc.c;
const asWidget = cc.asWidget;
const uuid = @import("uuid.zig");
const runtime_dir = @import("runtime_dir.zig");
const TabManager = @import("tab_manager.zig").TabManager;
const Workspace = @import("workspace.zig").Workspace;
const Pane = @import("pane.zig").Pane;
const SplitTree = @import("split_tree.zig").SplitTree;

const log = std.log.scoped(.session);
const posix = std.posix;

/// Check if a dtach socket is alive (a dtach process is listening).
fn socketAlive(path: []const u8) bool {
    const fd = posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0) catch return false;
    defer posix.close(fd);

    var addr: posix.sockaddr.un = .{ .family = posix.AF.UNIX, .path = undefined };
    const plen = @min(path.len, addr.path.len - 1);
    @memcpy(addr.path[0..plen], path[0..plen]);
    addr.path[plen] = 0;

    posix.connect(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)) catch return false;
    return true;
}

/// Kill a dtach process by connecting to its socket and sending exit,
/// then deleting the socket file.
fn killDtachBySocket(path: []const u8) void {
    // Connect and send exit to the shell inside dtach
    const fd = posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0) catch {
        // Can't connect — just remove the socket file
        std.fs.deleteFileAbsolute(path) catch {};
        return;
    };
    // Send "exit\n" through the dtach socket to kill the shell
    _ = posix.write(fd, "exit\n") catch {};
    posix.close(fd);
    std.fs.deleteFileAbsolute(path) catch {};
}

// ──────────────────────────────────────────────────────────
// Save
// ──────────────────────────────────────────────────────────

/// Save all workspace layouts to a JSON file.
/// Stores: workspace IDs, titles, full split tree with dtach sockets and CWDs.
pub fn save(tab_manager: *TabManager) void {
    const path = runtime_dir.sessionFile();

    const file = std.fs.createFileAbsolute(path, .{}) catch |err| {
        log.err("failed to create session file: {}", .{err});
        return;
    };
    defer file.close();

    const w = file.writer();
    w.writeAll("{\n  \"selected\": ") catch return;
    std.fmt.format(w, "{}", .{tab_manager.selected}) catch return;
    w.writeAll(",\n  \"workspaces\": [\n") catch return;

    for (tab_manager.workspaces.items, 0..) |ws, i| {
        if (i > 0) w.writeAll(",\n") catch return;
        writeWorkspace(w, ws);
    }

    w.writeAll("\n  ]\n}\n") catch return;
    log.info("session saved to {s}", .{path});
}

fn writeWorkspace(w: anytype, ws: *Workspace) void {
    w.writeAll("    {\n") catch return;

    // ID
    w.writeAll("      \"id\": \"") catch return;
    w.writeAll(uuid.asSlice(&ws.id)) catch return;
    w.writeAll("\",\n") catch return;

    // Title
    w.writeAll("      \"title\": \"") catch return;
    writeJsonEscaped(w, ws.displayTitle());
    w.writeAll("\"") catch return;

    // Custom title
    if (ws.custom_title != null) {
        w.writeAll(",\n      \"custom_title\": \"") catch return;
        writeJsonEscaped(w, ws.displayTitle());
        w.writeAll("\"") catch return;
    }

    // Split tree (recursive)
    w.writeAll(",\n      \"tree\": ") catch return;
    if (ws.split_tree.root != SplitTree.INVALID) {
        writeTreeNode(w, &ws.split_tree, ws.split_tree.root);
    } else {
        w.writeAll("null") catch return;
    }

    w.writeAll("\n    }") catch return;
}

fn writeTreeNode(w: anytype, tree: *const SplitTree, idx: SplitTree.NodeIndex) void {
    switch (tree.nodes.items[idx]) {
        .dead => return,
        .leaf => |leaf| {
            w.writeAll("{ \"dtach\": \"") catch return;
            if (leaf.pane.dtach_path_len > 0) {
                w.writeAll(leaf.pane.dtach_path[0..leaf.pane.dtach_path_len]) catch return;
            }
            w.writeAll("\", \"cwd\": \"") catch return;
            if (leaf.pane.getCwd()) |cwd_ptr| {
                writeJsonEscaped(w, std.mem.span(cwd_ptr));
            }
            w.writeAll("\" }") catch return;
        },
        .split => |s| {
            w.writeAll("{ \"split\": \"") catch return;
            w.writeAll(if (s.direction == .horizontal) "h" else "v") catch return;
            w.writeAll("\", \"first\": ") catch return;
            writeTreeNode(w, tree, s.first);
            w.writeAll(", \"second\": ") catch return;
            writeTreeNode(w, tree, s.second);
            w.writeAll(" }") catch return;
        },
    }
}

fn writeJsonEscaped(w: anytype, s: []const u8) void {
    for (s) |ch| {
        switch (ch) {
            '"' => w.writeAll("\\\"") catch return,
            '\\' => w.writeAll("\\\\") catch return,
            '\n' => w.writeAll("\\n") catch return,
            '\r' => w.writeAll("\\r") catch return,
            '\t' => w.writeAll("\\t") catch return,
            else => w.writeByte(ch) catch return,
        }
    }
}

// ──────────────────────────────────────────────────────────
// Reconcile — single entry point for startup
// ──────────────────────────────────────────────────────────

/// Startup reconciliation: scan disk for dtach sockets, compare with session
/// file, kill danglers, then restore workspaces or create a fresh default.
///
///   ┌─────────────────────┬───────────────┬────────────────────┐
///   │                     │ In session    │ Not in session     │
///   ├─────────────────────┼───────────────┼────────────────────┤
///   │ Socket alive        │ Reattach      │ Kill (dangler)     │
///   │ Socket dead         │ Fresh shell   │ Delete socket file │
///   └─────────────────────┴───────────────┴────────────────────┘
///
/// Returns true if workspaces were created (either restored or default).
pub fn reconcile(tab_manager: *TabManager) bool {
    const rd = runtime_dir.get();

    // Step 1: Read session file (if it exists)
    const session_path = runtime_dir.sessionFile();
    var session_json: ?[]const u8 = null;
    var session_buf: [32768]u8 = undefined;
    if (std.fs.openFileAbsolute(session_path, .{})) |file| {
        defer file.close();
        const n = file.read(&session_buf) catch 0;
        if (n > 0) session_json = session_buf[0..n];
    } else |_| {}

    // Step 2: Collect dtach paths referenced by the session file
    var tracked_paths: [64][256]u8 = undefined;
    var tracked_lens: [64]usize = undefined;
    var tracked_count: usize = 0;

    if (session_json) |json| {
        const needle = "\"dtach\": \"";
        var pos: usize = 0;
        while (tracked_count < 64) {
            if (std.mem.indexOfPos(u8, json, pos, needle)) |dp| {
                const ds = dp + needle.len;
                const de = std.mem.indexOfScalarPos(u8, json, ds, '"') orelse break;
                const path = json[ds..de];
                if (path.len > 0 and path.len <= 255) {
                    @memcpy(tracked_paths[tracked_count][0..path.len], path);
                    tracked_lens[tracked_count] = path.len;
                    tracked_count += 1;
                }
                pos = de + 1;
            } else break;
        }
    }

    // Step 3: Scan runtime dir for dtach socket files on disk
    var dir = std.fs.openDirAbsolute(rd, .{ .iterate = true }) catch {
        // Runtime dir doesn't exist or can't be opened — skip scan
        log.info("reconcile: runtime dir {s} not found, starting fresh", .{rd});
        return createDefaultWorkspace(tab_manager);
    };
    defer dir.close();

    var dangling_killed: usize = 0;
    var stale_deleted: usize = 0;
    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        // Match dtach socket files: dtach-*.sock (new) or cmux-dtach-*.sock (legacy /tmp)
        const is_dtach = (std.mem.startsWith(u8, entry.name, "dtach-") and
            std.mem.endsWith(u8, entry.name, ".sock"));
        if (!is_dtach) continue;

        // Build full path
        var path_buf: [512]u8 = undefined;
        const full_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ rd, entry.name }) catch continue;

        // Is this socket tracked by the session file?
        var is_tracked = false;
        for (0..tracked_count) |ti| {
            if (std.mem.eql(u8, tracked_paths[ti][0..tracked_lens[ti]], full_path)) {
                is_tracked = true;
                break;
            }
        }

        if (!is_tracked) {
            if (socketAlive(full_path)) {
                // Dangler: alive but not in session → kill it
                // TODO: in the future, offer user a "restore orphaned session?" dialog
                log.warn("reconcile: killing dangling dtach {s}", .{full_path});
                killDtachBySocket(full_path);
                dangling_killed += 1;
            } else {
                // Dead socket file → just clean up
                var del_buf: [513]u8 = undefined;
                const del_path_len = @min(full_path.len, 512);
                @memcpy(del_buf[0..del_path_len], full_path[0..del_path_len]);
                del_buf[del_path_len] = 0;
                std.fs.deleteFileAbsolute(del_buf[0..del_path_len :0]) catch {};
                stale_deleted += 1;
            }
        }
    }

    // Also scan /tmp for legacy cmux-dtach-*.sock files (from before XDG migration)
    if (!std.mem.eql(u8, rd, "/tmp")) {
        scanAndCleanLegacyDir(tracked_paths[0..tracked_count], tracked_lens[0..tracked_count], &dangling_killed, &stale_deleted);
    }

    if (dangling_killed > 0) log.info("reconcile: killed {d} dangling dtach session(s)", .{dangling_killed});
    if (stale_deleted > 0) log.info("reconcile: deleted {d} stale socket file(s)", .{stale_deleted});

    // Step 4: Restore from session file (or start fresh)
    if (session_json != null) {
        // Check if any tracked sockets are still alive
        var any_alive = false;
        for (0..tracked_count) |ti| {
            if (socketAlive(tracked_paths[ti][0..tracked_lens[ti]])) {
                any_alive = true;
                break;
            }
        }

        if (any_alive) {
            if (restore(tab_manager, session_json.?)) {
                log.info("reconcile: session restored ({d} workspaces)", .{tab_manager.workspaces.items.len});
                return true;
            }
        } else if (tracked_count > 0) {
            log.info("reconcile: all {d} tracked dtach sessions dead, starting fresh", .{tracked_count});
            std.fs.deleteFileAbsolute(runtime_dir.sessionFile()) catch {};
        }
    }

    // No session or restore failed → create default workspace
    return createDefaultWorkspace(tab_manager);
}

fn createDefaultWorkspace(tab_manager: *TabManager) bool {
    _ = tab_manager.createWorkspace() catch {
        log.err("reconcile: failed to create default workspace", .{});
        return false;
    };
    return true;
}

fn scanAndCleanLegacyDir(
    tracked_paths: [][256]u8,
    tracked_lens: []usize,
    dangling_killed: *usize,
    stale_deleted: *usize,
) void {
    var dir = std.fs.openDirAbsolute("/tmp", .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (!std.mem.startsWith(u8, entry.name, "cmux-dtach-")) continue;
        if (!std.mem.endsWith(u8, entry.name, ".sock")) continue;

        var path_buf: [256]u8 = undefined;
        const full_path = std.fmt.bufPrint(&path_buf, "/tmp/{s}", .{entry.name}) catch continue;

        var is_tracked = false;
        for (tracked_paths, tracked_lens) |tp, tl| {
            if (std.mem.eql(u8, tp[0..tl], full_path)) {
                is_tracked = true;
                break;
            }
        }

        if (!is_tracked) {
            if (socketAlive(full_path)) {
                log.warn("reconcile: killing legacy dangling dtach {s}", .{full_path});
                killDtachBySocket(full_path);
                dangling_killed.* += 1;
            } else {
                std.fs.deleteFileAbsolute(full_path) catch {};
                stale_deleted.* += 1;
            }
        }
    }
}

// ──────────────────────────────────────────────────────────
// Restore (internal — called by reconcile)
// ──────────────────────────────────────────────────────────

fn restore(tab_manager: *TabManager, json: []const u8) bool {
    log.info("restoring session from {s}", .{runtime_dir.sessionFile()});

    // Parse "selected":
    var selected: usize = 0;
    if (std.mem.indexOf(u8, json, "\"selected\":")) |sel_pos| {
        const after = json[sel_pos + 11 ..];
        const trimmed = std.mem.trim(u8, after[0..@min(after.len, 10)], " ");
        selected = std.fmt.parseInt(usize, trimmed[0 .. std.mem.indexOfScalar(u8, trimmed, ',') orelse trimmed.len], 10) catch 0;
    }

    var restored: usize = 0;

    // Find "workspaces": [
    const ws_array_start = std.mem.indexOf(u8, json, "\"workspaces\":") orelse return false;
    const array_open = std.mem.indexOfScalarPos(u8, json, ws_array_start, '[') orelse return false;

    // Walk through each workspace object in the array
    var pos = array_open + 1;
    while (pos < json.len) {
        while (pos < json.len and (json[pos] == ' ' or json[pos] == '\n' or json[pos] == '\r' or json[pos] == '\t' or json[pos] == ',')) : (pos += 1) {}
        if (pos >= json.len or json[pos] == ']') break;
        if (json[pos] != '{') break;

        const ws_end = findMatchingBrace(json, pos) orelse break;
        const ws_json = json[pos .. ws_end + 1];

        if (restoreWorkspace(tab_manager, ws_json)) {
            restored += 1;
        }

        pos = ws_end + 1;
    }

    if (restored > 0) {
        if (selected < tab_manager.workspaces.items.len) {
            tab_manager.selectByIndex(selected);
        }
        log.info("restored {} workspaces", .{restored});
        return true;
    }

    return false;
}

fn restoreWorkspace(tab_manager: *TabManager, ws_json: []const u8) bool {
    // Parse workspace ID
    const id_needle = "\"id\": \"";
    var ws_id: ?uuid.Uuid = null;
    if (std.mem.indexOf(u8, ws_json, id_needle)) |id_pos| {
        const id_start = id_pos + id_needle.len;
        if (id_start + 36 <= ws_json.len) {
            var id_buf: uuid.Uuid = undefined;
            @memcpy(&id_buf, ws_json[id_start..][0..36]);
            ws_id = id_buf;
        }
    }

    // Parse custom_title
    const title_needle = "\"custom_title\": \"";
    var ws_title: ?[]const u8 = null;
    if (std.mem.indexOf(u8, ws_json, title_needle)) |tp| {
        const title_start = tp + title_needle.len;
        if (std.mem.indexOfScalarPos(u8, ws_json, title_start, '"')) |title_end| {
            ws_title = ws_json[title_start..title_end];
        }
    }

    // Create workspace with preserved UUID (or generate new one)
    const ws = if (ws_id) |id|
        tab_manager.createWorkspaceWithId(id) catch return false
    else
        tab_manager.createWorkspace() catch return false;

    if (ws_title) |t| {
        if (t.len > 0) ws.setTitle(t);
    }

    // Try "tree" format first (new format with split directions)
    if (std.mem.indexOf(u8, ws_json, "\"tree\":")) |tree_key_pos| {
        var tpos = tree_key_pos + 7;
        while (tpos < ws_json.len and (ws_json[tpos] == ' ' or ws_json[tpos] == '\n' or ws_json[tpos] == '\t')) : (tpos += 1) {}

        if (tpos < ws_json.len and ws_json[tpos] == '{') {
            const tree_end = findMatchingBrace(ws_json, tpos) orelse return false;
            const tree_json = ws_json[tpos .. tree_end + 1];

            const root_idx = restoreTreeNode(tree_json, ws, tab_manager.allocator) catch return false;
            ws.split_tree.root = root_idx;
            ws.split_tree.focused = ws.split_tree.firstLeafFromRoot();

            const root_widget = ws.split_tree.getNodeWidget(root_idx);
            c.gtk_widget_set_vexpand(root_widget, 1);
            c.gtk_widget_set_hexpand(root_widget, 1);
            c.gtk_box_append(ws.container, root_widget);

            return true;
        }
    }

    // Fallback: "panes" format (old format, all splits vertical)
    return restoreWorkspaceLegacy(ws, ws_json, tab_manager.allocator);
}

/// Recursively restore a tree node from JSON.
fn restoreTreeNode(
    node_json: []const u8,
    ws: *Workspace,
    allocator: std.mem.Allocator,
) !SplitTree.NodeIndex {
    if (std.mem.indexOf(u8, node_json, "\"split\":")) |_| {
        // ── Split node ──
        const dir_str = extractJsonString(node_json, "split") orelse return error.ParseError;
        const direction: SplitTree.Direction = if (dir_str.len > 0 and dir_str[0] == 'h') .horizontal else .vertical;

        const first_json = extractJsonObject(node_json, "first") orelse return error.ParseError;
        const second_json = extractJsonObject(node_json, "second") orelse return error.ParseError;

        const first_idx = try restoreTreeNode(first_json, ws, allocator);
        const second_idx = try restoreTreeNode(second_json, ws, allocator);

        const orientation: c_uint = switch (direction) {
            .horizontal => c.GTK_ORIENTATION_VERTICAL,
            .vertical => c.GTK_ORIENTATION_HORIZONTAL,
        };
        const paned: *c.GtkPaned = @ptrCast(@alignCast(
            c.gtk_paned_new(orientation) orelse return error.GtkWidgetCreateFailed,
        ));

        c.gtk_paned_set_start_child(paned, ws.split_tree.getNodeWidget(first_idx));
        c.gtk_paned_set_end_child(paned, ws.split_tree.getNodeWidget(second_idx));
        c.gtk_paned_set_resize_start_child(paned, 1);
        c.gtk_paned_set_resize_end_child(paned, 1);
        SplitTree.requestEqualSplit(paned);

        const split_idx = try ws.split_tree.addSplit(direction, paned, first_idx, second_idx, SplitTree.INVALID);
        return split_idx;
    } else {
        // ── Leaf node ──
        const dtach_path = extractJsonString(node_json, "dtach") orelse "";
        const cwd_str = extractJsonString(node_json, "cwd") orelse "";

        const dtach: ?[]const u8 = if (dtach_path.len > 0 and socketAlive(dtach_path)) dtach_path else null;

        var cwd_z: [256:0]u8 = undefined;
        const cwd: ?[*:0]const u8 = if (dtach == null and cwd_str.len > 0) blk: {
            const cl = @min(cwd_str.len, 255);
            @memcpy(cwd_z[0..cl], cwd_str[0..cl]);
            cwd_z[cl] = 0;
            break :blk cwd_z[0..cl :0];
        } else null;

        const pane = try Pane.init(allocator, ws.id, ws.socket_path);
        pane.on_empty = Workspace.getOnPaneEmpty();
        pane.on_empty_ctx = ws;
        pane.on_focus = Workspace.getOnPaneFocus();
        pane.on_focus_ctx = ws;
        pane.on_title = Workspace.getOnPaneTitle();
        pane.on_title_ctx = ws;

        const leaf_idx = try ws.split_tree.addLeaf(pane, SplitTree.INVALID);
        pane.node_index = leaf_idx;
        _ = try pane.addTabDtach(cwd, dtach);

        return leaf_idx;
    }
}

/// Fallback: restore workspace from flat "panes" array (old session format).
fn restoreWorkspaceLegacy(ws: *Workspace, ws_json: []const u8, allocator: std.mem.Allocator) bool {
    const dtach_needle = "\"dtach\": \"";
    const cwd_needle = "\"cwd\": \"";

    var dtach_paths: [16][]const u8 = undefined;
    var cwd_paths: [16][]const u8 = undefined;
    var pane_count: usize = 0;

    var pane_pos: usize = 0;
    while (pane_count < 16) {
        if (std.mem.indexOfPos(u8, ws_json, pane_pos, dtach_needle)) |dp| {
            const ds = dp + dtach_needle.len;
            const de = std.mem.indexOfScalarPos(u8, ws_json, ds, '"') orelse break;
            dtach_paths[pane_count] = ws_json[ds..de];

            if (std.mem.indexOfPos(u8, ws_json, de, cwd_needle)) |cp| {
                const cs = cp + cwd_needle.len;
                const ce = std.mem.indexOfScalarPos(u8, ws_json, cs, '"') orelse break;
                cwd_paths[pane_count] = ws_json[cs..ce];
            } else {
                cwd_paths[pane_count] = "";
            }

            pane_count += 1;
            pane_pos = de + 1;
        } else break;
    }

    if (pane_count == 0) return false;

    const first_dtach: ?[]const u8 = if (dtach_paths[0].len > 0 and socketAlive(dtach_paths[0]))
        dtach_paths[0]
    else
        null;
    var first_cwd_z: [256:0]u8 = undefined;
    const first_cwd: ?[*:0]const u8 = if (first_dtach == null and cwd_paths[0].len > 0) blk: {
        const cl = @min(cwd_paths[0].len, 255);
        @memcpy(first_cwd_z[0..cl], cwd_paths[0][0..cl]);
        first_cwd_z[cl] = 0;
        break :blk first_cwd_z[0..cl :0];
    } else null;

    const first_pane = Pane.init(allocator, ws.id, ws.socket_path) catch return false;
    first_pane.on_empty = Workspace.getOnPaneEmpty();
    first_pane.on_empty_ctx = ws;
    first_pane.on_focus = Workspace.getOnPaneFocus();
    first_pane.on_focus_ctx = ws;
    first_pane.on_title = Workspace.getOnPaneTitle();
    first_pane.on_title_ctx = ws;

    ws.split_tree.setRoot(first_pane) catch return false;
    first_pane.node_index = 0;
    const pane_w = first_pane.widget();
    c.gtk_widget_set_vexpand(pane_w, 1);
    c.gtk_widget_set_hexpand(pane_w, 1);
    c.gtk_box_append(ws.container, pane_w);
    _ = first_pane.addTabDtach(first_cwd, first_dtach) catch return false;

    for (1..pane_count) |pi| {
        const dtach: ?[]const u8 = if (dtach_paths[pi].len > 0 and socketAlive(dtach_paths[pi]))
            dtach_paths[pi]
        else
            null;
        ws.splitFocusedDtach(.vertical, dtach) catch continue;
    }

    return true;
}

// ──────────────────────────────────────────────────────────
// JSON helpers
// ──────────────────────────────────────────────────────────

fn findMatchingBrace(json: []const u8, start: usize) ?usize {
    if (start >= json.len or json[start] != '{') return null;
    var depth: usize = 0;
    var in_string = false;
    var i = start;
    while (i < json.len) : (i += 1) {
        if (in_string) {
            if (json[i] == '\\') {
                i += 1;
                continue;
            }
            if (json[i] == '"') in_string = false;
            continue;
        }
        switch (json[i]) {
            '"' => in_string = true,
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) return i;
            },
            else => {},
        }
    }
    return null;
}

fn extractJsonString(json: []const u8, key: []const u8) ?[]const u8 {
    var needle_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\"", .{key}) catch return null;

    const key_pos = std.mem.indexOf(u8, json, needle) orelse return null;
    var pos = key_pos + needle.len;

    while (pos < json.len and (json[pos] == ' ' or json[pos] == ':' or json[pos] == '\t' or json[pos] == '\n')) : (pos += 1) {}
    if (pos >= json.len or json[pos] != '"') return null;
    pos += 1;

    const start = pos;
    while (pos < json.len) : (pos += 1) {
        if (json[pos] == '\\') {
            pos += 1;
            continue;
        }
        if (json[pos] == '"') break;
    }
    if (pos >= json.len) return null;
    return json[start..pos];
}

fn extractJsonObject(json: []const u8, key: []const u8) ?[]const u8 {
    var needle_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\"", .{key}) catch return null;

    const key_pos = std.mem.indexOf(u8, json, needle) orelse return null;
    var pos = key_pos + needle.len;

    while (pos < json.len and (json[pos] == ' ' or json[pos] == ':' or json[pos] == '\t' or json[pos] == '\n')) : (pos += 1) {}
    if (pos >= json.len or json[pos] != '{') return null;

    const end = findMatchingBrace(json, pos) orelse return null;
    return json[pos .. end + 1];
}
