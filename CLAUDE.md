# cmux-linux

Linux terminal multiplexer with Claude Code integration, built with Zig + GTK4 + VTE.

## Build

```bash
# Install deps (Debian/Ubuntu)
sudo apt install libgtk-4-dev libadwaita-1-dev libvte-2.91-gtk4-dev libnotify-dev pkg-config xvfb

# Install Zig 0.14.1
# See https://ziglang.org/download/

# Build
zig build

# Run
./zig-out/bin/cmux
```

## Architecture

- **VTE** (libvte-2.91-gtk4) for terminal rendering
- **GTK4 + libadwaita** for UI
- **Zig** as language and build system
- **dtach** for terminal session persistence across cmux restarts
- **libnotify** for desktop notifications
- **CDP** (Chrome DevTools Protocol) for browser tab tracking (optional, requires Brave with `--remote-debugging-port=9222`)

## File structure

```
src/
  main.zig           — App entry, GTK lifecycle, logging, shutdown
  window.zig         — AdwApplicationWindow, sidebar + content layout, keyboard shortcuts
  tab_manager.zig    — Workspace list, selection, CRUD
  workspace.zig      — Workspace model, Claude status, split operations, pane lifecycle
  split_tree.zig     — Binary split tree with GtkPaned, .dead node marker
  pane.zig           — GtkNotebook + VteTerminal tabs, dtach spawn/kill, URL click, CDP
  sidebar.zig        — Rich 3-row workspace tabs with Claude status indicators
  session.zig        — Session save/restore, startup reconciliation, dangling dtach cleanup
  runtime_dir.zig    — Centralized runtime directory ($XDG_RUNTIME_DIR/cmux or /tmp/cmux-<uid>)
  socket.zig         — Unix socket IPC server, v1 protocol
  notification.zig   — Desktop notifications via libnotify
  uuid.zig           — UUID v4 generator
  c.zig              — Centralized C imports + helper casts
cli/
  main.zig           — Standalone CLI binary (cmux-cli)
bin/
  claude             — Claude Code wrapper (injects hooks)
  cmux-shell-init.sh — Shell integration (bashrc source)
tests/
  run_all.sh         — Test runner: ./tests/run_all.sh [name...]
  lib.sh             — Shared test helpers (start/stop cmux, check, cleanup)
  test_basics.sh     — Socket, workspaces, splits, send, claude status, notifications
  test_session.sh    — Session save/restore, double-restart, split direction persistence
  test_lifecycle.sh  — Dangling dtach cleanup, env vars, UUID preservation, clean shutdown
```

## Runtime directory

All sockets, session files, and logs live in a single directory:
- `$XDG_RUNTIME_DIR/cmux/` (typically `/run/user/1000/cmux/`)
- Fallback: `/tmp/cmux-<uid>/`

Files within:
- `cmux.sock` — IPC socket for CLI
- `session.json` — workspace layout + dtach paths
- `cmux.log` — persistent log (512KB rotation)
- `dtach-<uuid>.sock` — one per terminal pane

## Startup lifecycle

```
main() → onActivate
  ├─ Window.create()          — GTK window shell, no workspace yet
  ├─ session.reconcile()      — single entry point:
  │    ├─ scan runtime dir for dtach-*.sock files
  │    ├─ read session.json
  │    ├─ kill untracked dtach (danglers)
  │    ├─ delete dead socket files
  │    ├─ restore workspaces (reattach alive, fresh for dead)
  │    └─ OR create default workspace if no session
  ├─ SocketServer.create()
  └─ win.show()
```

## Shutdown lifecycle

All shutdown paths (window close, SIGTERM, SIGINT) converge:
- Save session while VTE terminals are alive
- Mark all workspaces as closing (suppresses pane respawn)
- Destroy socket server
- dtach processes survive intentionally (session persistence)

## Keyboard shortcuts

- `Ctrl+Shift+T` — new workspace
- `Ctrl+Shift+Q` — close workspace
- `Ctrl+Shift+N` — new tab in pane
- `Ctrl+Shift+W` — close pane tab
- `Ctrl+Shift+E` — split horizontal
- `Ctrl+Shift+O` — split vertical
- `Ctrl+Shift+C` — copy
- `Ctrl+Shift+V` — paste
- `Ctrl+Shift+Arrow` — navigate panes
- `Ctrl+Shift+PageUp/Down` — prev/next workspace
- `Alt+1..9` — go to workspace N

## Socket protocol (v1)

Line-delimited text on `$XDG_RUNTIME_DIR/cmux/cmux.sock`:
```
ping → PONG
list_workspaces → id\ttitle per line
current_workspace → id\ttitle
new_workspace → id
select_workspace <id> → OK
close_workspace <id> → OK
rename_workspace <id> <title> → OK
new_split <h|v> → OK
send <text> → OK (supports \n \t \r \\)
set_status <key> <value> [--tab=id] → OK | ERROR: workspace not found
clear_status <key> [--tab=id] → OK | ERROR: workspace not found
notify <title>|<body> [--tab=id] → OK
```

## Claude Code integration

Hooks in `~/.claude/settings.json` fire `cmux-cli claude-hook <event>`:
- `PreToolUse` → ✦ Running + "Using <tool>..."
- `Stop` → ● Unread + last assistant message
- `Notification` → ● Unread/Attention + message preview

Status routes to workspace via `--tab=<workspace-uuid>`. Unknown UUIDs return an error (no silent fallback).

## Testing

```bash
# Run all tests
./tests/run_all.sh

# Run specific suite
./tests/run_all.sh basics
./tests/run_all.sh session
./tests/run_all.sh lifecycle

# Detailed log
cat tests/test.log
```
