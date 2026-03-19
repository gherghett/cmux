# TODO — cmux-linux

## Session / dtach

- [x] Session persistence — save/restore workspace layout on exit/start
- [x] Preserve workspace UUIDs across restarts
- [x] Preserve split directions in session file
- [x] Move sockets from /tmp to $XDG_RUNTIME_DIR/cmux
- [x] Kill dangling dtach on startup reconciliation
- [ ] **Restore orphaned session dialog** — when reconciliation finds an untracked-but-alive dtach, show a GTK dialog asking "Found orphaned terminal session. Restore or kill?" instead of auto-killing. Useful when Claude is running in an orphaned dtach.
- [ ] **Cursor blink after dtach reattach** — after session restore, the cursor blinks even in TUI apps (like Claude Code) where it shouldn't. dtach reattach may not fully restore terminal state. Investigate: VTE cursor blink settings, or sending a terminal reset sequence after reattach.
- [ ] **Screen content not restored on reattach** — dtach preserves the process but not the terminal scrollback/screen. After restart, TUI apps show a blank screen (the process is alive — pressing Enter continues). This is a dtach limitation. Investigate: `dtach -r` vs `-a`, abduco (dtach alternative with screen redraw), or sending a SIGWINCH to force TUI redraw.
- [ ] **Minimap not updated for restored workspaces until focused** — after session restore, workspace minimaps stay blank/stale until you switch to that workspace at least once. VTE probably doesn't render content until the widget is visible in the GtkStack. Might need to force a snapshot after restore or mark minimap dirty.
- [ ] **Session file >32KB** — restore uses a 32KB static buffer. Large sessions (many workspaces, long CWD paths) could be truncated. Switch to heap allocation or streaming read.

## Workspace lifetime

A workspace is a live instance (vert-tab + split tree + panes with dtach sessions). A template is a saved blueprint (title + layout + CWDs, no processes). Templates live on disk as JSON files.

- [ ] **`save-workspace <name>`** — serialize current workspace's layout + CWDs to `~/.config/cmux/templates/<name>.json`. No dtach paths, no process state — just shape and directories. Format: `{ "title": "...", "tree": { "split": "h", "first": { "cwd": "..." }, "second": { "cwd": "..." } } }`
- [ ] **`open-workspace <name>`** — read template, create a new workspace with that split layout, spawn fresh shells in the saved CWDs. Socket protocol: `open_workspace <name> → id` and `save_workspace <name> → OK`.
- [ ] **Template storage** — `~/.config/cmux/templates/` directory, one JSON file per template. Human-readable, hand-editable.
- [ ] **`list-templates`** — list available templates. Socket protocol: `list_templates → name per line`.
- [ ] **Close workspace kills processes** — already works (killDtach on all panes). Document this as the expected behavior.

### Pane tabs (multiple terminals per pane)

- [ ] **Pane tabs are broken** — `Ctrl+Shift+N` creates a new VTE terminal tab within a pane, but all tabs share one `dtach_path` on the Pane struct. The second tab overwrites the first's dtach socket path, and the static `env_bufs`/`env_ptrs` get overwritten before VTE's async spawn completes. Result: tabs appear to share the same terminal or show stale content. Fix: move `dtach_path` to the Tab struct, give each tab its own dtach session, and update session save/restore to serialize per-tab dtach paths. Until fixed, `Ctrl+Shift+N` should be disabled or the feature removed.

### Future — workspace operations

- [ ] **Move pane between workspaces** — detach a pane's dtach socket from one workspace's split tree, reattach in another. The process keeps running. dtach makes this possible.
- [ ] **Create workspace from pane** — take a pane out of a split and promote it to its own workspace (vert-tab). Inverse of the above.
- [ ] **Layout templates** — separate the layout shape from the CWDs. Apply a layout template to an existing workspace (rearrange panes without killing them). Tentative.
- [ ] **Multiple OS windows** — open additional GTK windows showing different workspaces from the same instance. Most GUI apps do this. Shared workspace list, shared Claude status/notifications.
- [ ] **Template in menus** — right-click sidebar → "New from template..." dropdown. Requires config/UI for managing templates. Comes after CLI-first approach works.

## Claude Code integration

- [x] Fix Claude messages appearing on wrong workspace
- [x] Fix CMUX_TAB_ID env var (was set to workspace ID)
- [x] Reject unknown --tab= UUIDs instead of silent fallback
- [ ] **Animated ✦ star** for Claude running status (currently static)
- [ ] **CSS class switching** for Claude status indicator colors (sidebar.zig:190 TODO)

## CDP / Browser Integration

- [ ] **Brave window focus on CDP activate** — `GET /json/activate/{id}` switches the tab but doesn't raise the Brave OS window. `xdotool` is unreliable across WMs/Wayland. Investigate: `wmctrl -a`, D-Bus activation, Wayland `xdg-activation-v1`, or CDP `Browser.setWindowBounds`.
- [ ] **Tab title in button** — Poll CDP for page `title` to update button text from URL to page title.

## Right-click context menu

- [ ] Add "Pin" option
- [x] Add "Close" option
- [ ] Add "Change color" option (tint the workspace row)

## General

- [ ] Config file for keyboard shortcuts
- [ ] Search/find overlay in terminals (VTE has built-in search)
- [ ] Multiple windows support

## Notifications

- [ ] Bell sound
- [ ] A bell symbol we can click to turn on and off notifications
- [ ] Right click on vert-tab (workspace) and see "silence notifications" — a crossed out bell appears on vert-tab, and is silenced, dropdown now shows "enable notifications", removes crossed out bell symbol.

## Maybe

- [ ] In vert-tabs show how long since a workspace was active (that is in focus). Maybe show if it was more than some amount of time like 30 minutes.
- [ ] Showing in vert-tabs small icons of what is running or has run: 3 classes of processes, 1) running like htop or npm run dev, 2) transient like git or cat 3) oneoffs like apt install or rsync. Showing like that theres git activity at all is interesting — like the list of cwds, a small array of icons.
- [ ] Parsing terminal, scraping it for data — find progressbars and lift that information.
- [ ] User-widgets: let users box-select area of pane, and put somewhere else (in vert-tab?) like the % of a loadingscreen, or some crucial value in a process.
