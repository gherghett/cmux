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
- **libnotify** for desktop notifications
- **CDP** (Chrome DevTools Protocol) for browser tab tracking (optional, requires Brave with `--remote-debugging-port=9222`)

## File structure

```
src/
  main.zig           — App entry, GTK Application lifecycle
  window.zig         — AdwApplicationWindow, sidebar + content layout, keyboard shortcuts
  tab_manager.zig    — Workspace list, selection, CRUD
  workspace.zig      — Workspace model, Claude status, split operations
  split_tree.zig     — Binary split tree with GtkPaned
  pane.zig           — GtkNotebook + VteTerminal tabs, URL click handling, CDP tracking
  sidebar.zig        — Rich 3-row workspace tabs with Claude status indicators
  socket.zig         — Unix socket IPC server, v1 protocol
  notification.zig   — Desktop notifications via libnotify
  uuid.zig           — UUID v4 generator
  c.zig              — Centralized C imports + helper casts
cli/
  main.zig           — Standalone CLI binary (cmux-cli)
bin/
  claude             — Claude Code wrapper (injects hooks)
  cmux-shell-init.sh — Shell integration (bashrc source)
```

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

Line-delimited text on `/tmp/cmux.sock`:
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
set_status <key> <value> [--tab=id] → OK
clear_status <key> [--tab=id] → OK
notify <title>|<body> [--tab=id] → OK
```

## Claude Code integration

Hooks in `~/.claude/settings.json` fire `cmux-cli claude-hook <event>`:
- `PreToolUse` → ✦ Running + "Using <tool>..."
- `Stop` → ● Unread + last assistant message
- `Notification` → ● Unread/Attention + message preview

## Testing

```bash
# Automated test with virtual display
xvfb-run --auto-servernum -- ./zig-out/bin/cmux &
./zig-out/bin/cmux-cli ping
./zig-out/bin/cmux-cli new_split h
./zig-out/bin/cmux-cli list_workspaces
```
