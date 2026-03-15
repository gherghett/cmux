const std = @import("std");
const uuid = @import("uuid.zig");
const TabManager = @import("tab_manager.zig").TabManager;
const Workspace = @import("workspace.zig").Workspace;
const Pane = @import("pane.zig").Pane;
const SplitTree = @import("split_tree.zig").SplitTree;

const log = std.log.scoped(.session);

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

        // The workspace already has one pane from creation.
        // Reattach first pane to its dtach socket.
        if (ws.split_tree.focusedPane()) |first_pane| {
            if (dtach_paths[0].len > 0) {
                // Check if dtach socket still exists
                std.fs.accessAbsolute(dtach_paths[0], .{}) catch {};
                // If we got here without error, socket exists
                first_pane.reattachDtach(dtach_paths[0]);
            }
        }

        // Additional panes: create splits
        for (1..pane_count) |pi| {
            ws.splitFocused(.vertical) catch continue;
            if (ws.split_tree.focusedPane()) |new_pane| {
                if (dtach_paths[pi].len > 0) {
                    std.fs.accessAbsolute(dtach_paths[pi], .{}) catch continue;
                    new_pane.reattachDtach(dtach_paths[pi]);
                }
            }
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
