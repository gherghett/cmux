# TODO — cmux-linux

## CDP / Browser Integration
- [ ] **Brave window focus on CDP activate** — `GET /json/activate/{id}` switches the tab but doesn't raise the Brave OS window. `xdotool` is unreliable across WMs/Wayland. Investigate: `wmctrl -a`, D-Bus activation, Wayland `xdg-activation-v1`, or CDP `Browser.setWindowBounds`.
- [ ] **Multiple tracked tabs per pane** — Currently stores one browser tab per pane. Should be a list of buttons, one per link opened via CDP.
- [ ] **Poll for closed tabs** — Periodically check CDP `/json` to see if tracked tabs still exist. Remove the button if the tab was closed.
- [ ] **Tab title in button** — Poll CDP for page `title` to update button text from URL to page title.

## Right-click context menu
- [ ] Add "Pin" option
- [ ] Add "Close" option
- [ ] Add "Change color" option (tint the workspace row)

## General
- [ ] Animated ✦ star for Claude running status (currently static)
- [ ] Session persistence — save/restore workspace layout on exit/start
- [ ] Config file for keyboard shortcuts
- [ ] Search/find overlay in terminals (VTE has built-in search)
- [ ] Multiple windows support
