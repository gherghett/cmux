#!/bin/bash
# Test: multiple tabs per pane (each tab has its own dtach session)
source "$(dirname "$0")/lib.sh"

full_cleanup
start_xvfb

echo "=== Pane tabs ==="

start_cmux

# --- new_tab creates a second tab in the focused pane ---
R=$($CLI new_tab 2>&1); [ "$R" = "OK" ]; check $? "new_tab returns OK"

# Both tabs should have their own dtach sockets
wait_for 5 '[ $(ls "$CMUX_DIR"/dtach-*.sock 2>/dev/null | wc -l) -ge 2 ]'
DTACH_COUNT=$(ls "$CMUX_DIR"/dtach-*.sock 2>/dev/null | wc -l)
[ "$DTACH_COUNT" -ge 2 ]; check $? "2+ dtach sockets after new_tab ($DTACH_COUNT found)"

# --- close_tab removes one tab, pane stays ---
R=$($CLI close_tab 2>&1); [ "$R" = "OK" ]; check $? "close_tab returns OK"
R=$($CLI ping 2>&1); [ "$R" = "PONG" ]; check $? "cmux alive after close_tab"

# --- Add multiple tabs, close all but one ---
$CLI new_tab >/dev/null 2>&1
$CLI new_tab >/dev/null 2>&1
$CLI close_tab >/dev/null 2>&1
$CLI close_tab >/dev/null 2>&1
R=$($CLI ping 2>&1); [ "$R" = "PONG" ]; check $? "alive after adding and closing tabs"

# --- Session save/restore with multiple tabs ---
$CLI new_tab >/dev/null 2>&1
sleep 1

# Save session
stop_cmux

# Check session file has tabs array
[ -f "$CMUX_DIR/session.json" ]; check $? "session file exists"
grep -q '"tabs":' "$CMUX_DIR/session.json" 2>/dev/null; check $? "session file has tabs array"

# Count tabs in session file (count dtach entries)
TAB_ENTRIES=$(grep -o '"dtach"' "$CMUX_DIR/session.json" 2>/dev/null | wc -l)
[ "$TAB_ENTRIES" -ge 2 ]; check $? "session file has 2+ tab entries ($TAB_ENTRIES found)"

# Restore
start_cmux
R=$($CLI ping 2>&1); [ "$R" = "PONG" ]; check $? "cmux restored with tabs"

# --- Each tab has its own environment ---
$CLI new_tab >/dev/null 2>&1
sleep 1
ENVFILE="/tmp/cmux-tab-env-$$"
$CLI send "echo CMUX_SURFACE_ID=\$CMUX_SURFACE_ID > $ENVFILE\n" >/dev/null 2>&1
wait_for 5 '[ -f "$ENVFILE" ] && [ -s "$ENVFILE" ]'
if [ -f "$ENVFILE" ]; then
    SID=$(grep "CMUX_SURFACE_ID=" "$ENVFILE" | cut -d= -f2)
    [ -n "$SID" ]; check $? "tab has CMUX_SURFACE_ID set"
    rm -f "$ENVFILE"
else
    check 1 "tab has CMUX_SURFACE_ID set (env capture failed)"
fi

stop_cmux
check_stderr_clean
full_cleanup
print_result
exit $FAIL
