const std = @import("std");
const cc = @import("c.zig");
const c = cc.c;
const asWidget = cc.asWidget;
const uuid = @import("uuid.zig");
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

const session_dir = "/tmp/cmux-session";
const session_file = "/tmp/cmux-session/layout.json";

/// Save all workspace layouts to a JSON file.
/// Stores: workspace titles, split structure, dtach socket paths, CWDs.
pub fn save(tab_manager: *TabManager) void {
    // Ensure directory exists
    std.fs.makeDirAbsolute(session_dir) catch {};

    const file = std.fs.createFileAbsolute(session_file, .{}) catch |err| {
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
        writeWorkspace(w, ws, tab_manager.allocator);
    }

    w.writeAll("\n  ]\n}\n") catch return;
    log.info("session saved to {s}", .{session_file});
}

fn writeWorkspace(w: anytype, ws: *Workspace, allocator: std.mem.Allocator) void {
    w.writeAll("    {\n") catch return;

    // Title
    w.writeAll("      \"id\": \"") catch return;
    w.writeAll(uuid.asSlice(&ws.id)) catch return;
    w.writeAll("\",\n      \"title\": \"") catch return;
    writeJsonEscaped(w, ws.displayTitle());
    w.writeAll("\"") catch return;

    // Custom title
    if (ws.custom_title != null) {
        w.writeAll(",\n      \"custom_title\": \"") catch return;
        writeJsonEscaped(w, ws.displayTitle());
        w.writeAll("\"") catch return;
    }

    // Panes with dtach paths and CWDs
    var pane_list = std.ArrayList(*Pane).init(allocator);
    defer pane_list.deinit();
    ws.allPanes(&pane_list) catch {};

    w.writeAll(",\n      \"panes\": [\n") catch return;
    for (pane_list.items, 0..) |pane, pi| {
        if (pi > 0) w.writeAll(",\n") catch return;
        w.writeAll("        { \"dtach\": \"") catch return;
        if (pane.dtach_path_len > 0) {
            w.writeAll(pane.dtach_path[0..pane.dtach_path_len]) catch return;
        }
        w.writeAll("\", \"cwd\": \"") catch return;
        if (pane.getCwd()) |cwd_ptr| {
            writeJsonEscaped(w, std.mem.span(cwd_ptr));
        }
        w.writeAll("\" }") catch return;
    }
    w.writeAll("\n      ]\n    }") catch return;
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

/// Restore workspaces from session file.
/// Returns true if restoration was successful.
pub fn restore(tab_manager: *TabManager) bool {
    const file = std.fs.openFileAbsolute(session_file, .{}) catch return false;
    defer file.close();

    var buf: [32768]u8 = undefined;
    const n = file.read(&buf) catch return false;
    if (n == 0) return false;
    const json = buf[0..n];

    log.info("restoring session from {s}", .{session_file});

    // Parse workspaces — simple JSON extraction
    var ws_count: usize = 0;
    var pos: usize = 0;

    // Find "selected":
    var selected: usize = 0;
    if (std.mem.indexOf(u8, json, "\"selected\":")) |sel_pos| {
        const after = json[sel_pos + 11 ..];
        const trimmed = std.mem.trim(u8, after[0..@min(after.len, 10)], " ");
        selected = std.fmt.parseInt(usize, trimmed[0 .. std.mem.indexOfScalar(u8, trimmed, ',') orelse trimmed.len], 10) catch 0;
    }

    // Find each workspace block
    while (std.mem.indexOfPos(u8, json, pos, "\"custom_title\"")) |_| {
        pos += 1;
        ws_count += 1;
    }

    // Simpler: find dtach paths and create workspaces
    pos = 0;
    var restored: usize = 0;
    const dtach_needle = "\"dtach\": \"";
    const cwd_needle = "\"cwd\": \"";
    const title_needle = "\"custom_title\": \"";

    // Find workspace boundaries by looking for title fields
    var ws_starts: [32]usize = undefined;
    var ws_start_count: usize = 0;
    var search_pos: usize = 0;
    while (ws_start_count < 32) {
        if (std.mem.indexOfPos(u8, json, search_pos, "\"panes\":")) |p| {
            ws_starts[ws_start_count] = p;
            ws_start_count += 1;
            search_pos = p + 1;
        } else break;
    }

    for (0..ws_start_count) |wi| {
        const ws_start = ws_starts[wi];
        const ws_end = if (wi + 1 < ws_start_count) ws_starts[wi + 1] else json.len;
        const ws_json = json[ws_start..ws_end];

        // Find custom_title for this workspace (search backwards from ws_start)
        var ws_title: ?[]const u8 = null;
        const before_ws = json[0..ws_start];
        if (std.mem.lastIndexOf(u8, before_ws, title_needle)) |tp| {
            const title_start = tp + title_needle.len;
            if (std.mem.indexOfScalarPos(u8, json, title_start, '"')) |title_end| {
                ws_title = json[title_start..title_end];
            }
        }

        // Collect dtach+cwd pairs for this workspace
        var dtach_paths: [16][]const u8 = undefined;
        var cwd_paths: [16][]const u8 = undefined;
        var pane_count: usize = 0;

        var pane_pos: usize = 0;
        while (pane_count < 16) {
            if (std.mem.indexOfPos(u8, ws_json, pane_pos, dtach_needle)) |dp| {
                const ds = dp + dtach_needle.len;
                const de = std.mem.indexOfScalarPos(u8, ws_json, ds, '"') orelse break;
                dtach_paths[pane_count] = ws_json[ds..de];

                // Find matching cwd
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

        if (pane_count == 0) continue;

        // Create workspace
        const ws = tab_manager.createWorkspace() catch continue;

        // Set title
        if (ws_title) |t| {
            if (t.len > 0) ws.setTitle(t);
        }

        // The workspace already has one pane from creation — but it spawned
        // a fresh dtach. We need to close it and respawn with the saved socket.
        // Simpler: the workspace was created with addTab(null) which spawned a
        // new dtach. We can't easily replace it. Instead, let's create workspaces
        // WITHOUT the default pane and add panes with the right dtach socket.
        //
        // For now: the first pane is already spawned. Kill its VTE child and
        // reattach. Actually, just close the workspace's default pane and
        // recreate with the right dtach path.

        // Close the auto-created pane
        if (ws.split_tree.focusedPane()) |auto_pane| {
            auto_pane.deinit();
        }
        // Reset the split tree
        ws.split_tree = SplitTree.init(tab_manager.allocator);

        // Remove all children from the container
        const container_w = ws.containerWidget();
        while (c.gtk_widget_get_first_child(container_w)) |child| {
            c.gtk_box_remove(ws.container, child);
        }

        // Add first pane — reattach if dtach socket is alive, else fresh shell in saved CWD
        const first_dtach: ?[]const u8 = if (dtach_paths[0].len > 0 and socketAlive(dtach_paths[0]))
            dtach_paths[0]
        else
            null;
        // Use saved CWD if starting fresh
        var first_cwd_z: [256:0]u8 = undefined;
        const first_cwd: ?[*:0]const u8 = if (first_dtach == null and cwd_paths[0].len > 0) blk: {
            const cl = @min(cwd_paths[0].len, 255);
            @memcpy(first_cwd_z[0..cl], cwd_paths[0][0..cl]);
            first_cwd_z[cl] = 0;
            break :blk first_cwd_z[0..cl :0];
        } else null;
        const first_pane = Pane.init(tab_manager.allocator, ws.id, ws.socket_path) catch continue;
        first_pane.on_empty = Workspace.getOnPaneEmpty();
        first_pane.on_empty_ctx = ws;
        first_pane.on_focus = Workspace.getOnPaneFocus();
        first_pane.on_focus_ctx = ws;
        first_pane.on_title = Workspace.getOnPaneTitle();
        first_pane.on_title_ctx = ws;

        ws.split_tree.setRoot(first_pane) catch continue;
        first_pane.node_index = 0;
        const pane_w = first_pane.widget();
        c.gtk_widget_set_vexpand(pane_w, 1);
        c.gtk_widget_set_hexpand(pane_w, 1);
        c.gtk_box_append(ws.container, pane_w);
        _ = first_pane.addTabDtach(first_cwd, first_dtach) catch continue;

        // Additional panes: create splits with saved dtach sockets
        for (1..pane_count) |pi| {
            const dtach: ?[]const u8 = if (dtach_paths[pi].len > 0 and socketAlive(dtach_paths[pi]))
                dtach_paths[pi]
            else
                null;
            ws.splitFocusedDtach(.vertical, dtach) catch continue;
        }

        restored += 1;
    }

    if (restored > 0) {
        // Remove the initial empty workspace (created by default)
        // Select the restored workspace
        if (selected < tab_manager.workspaces.items.len) {
            tab_manager.selectByIndex(selected);
        }
        log.info("restored {} workspaces", .{restored});
        return true;
    }

    return false;
}
