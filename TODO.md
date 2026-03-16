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
- [ ] **Session file >32KB** — restore uses a 32KB static buffer. Large sessions (many workspaces, long CWD paths) could be truncated. Switch to heap allocation or streaming read.

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
