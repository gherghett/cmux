#!/bin/bash
# Full integration test suite for cmux-linux
LOG=/home/daniel/projekt/cmux-linux/cmux-test.log
CLI=./zig-out/bin/cmux-cli
PASS=0
FAIL=0

check() {
    if [ "$1" = "0" ]; then
        echo "  ✓ $2"
        PASS=$((PASS+1))
    else
        echo "  ✗ $2"
        FAIL=$((FAIL+1))
    fi
}

pkill -9 -f Xvfb 2>/dev/null || true
pkill -9 -f "zig-out/bin/cmux" 2>/dev/null || true
pkill -f "dtach.*cmux-dtach" 2>/dev/null || true
rm -f /tmp/cmux.sock /tmp/cmux-session/layout.json /tmp/cmux-dtach-*.sock
sleep 1

Xvfb :99 -screen 0 1280x1024x24 &>/dev/null &
sleep 1
DISPLAY=:99 ./zig-out/bin/cmux >$LOG 2>&1 &
sleep 2

echo "=== cmux-linux test suite ==="
echo ""

echo "--- Socket ---"
R=$($CLI ping 2>&1); [ "$R" = "PONG" ]; check $? "ping → PONG"

echo ""
echo "--- Workspaces ---"
R=$($CLI list_workspaces 2>&1); echo "$R" | grep -q "Terminal"; check $? "initial workspace exists"
WS1=$(echo "$R" | cut -f1)
R=$($CLI new_workspace 2>&1); echo "$R" | grep -qE '[0-9a-f-]{36}'; check $? "new_workspace returns UUID"
WS2=$R
R=$($CLI list_workspaces 2>&1); echo "$R" | grep -c "Terminal" | grep -q 2; check $? "2 workspaces listed"
R=$($CLI select_workspace "$WS1" 2>&1); [ "$R" = "OK" ]; check $? "select_workspace"
R=$($CLI current_workspace 2>&1); echo "$R" | grep -q "$WS1"; check $? "current_workspace matches"
R=$($CLI rename_workspace "$WS1" "MyProject" 2>&1); [ "$R" = "OK" ]; check $? "rename_workspace"
R=$($CLI current_workspace 2>&1); echo "$R" | grep -q "MyProject"; check $? "renamed title visible"
R=$($CLI close_workspace "$WS2" 2>&1); [ "$R" = "OK" ]; check $? "close_workspace"
R=$($CLI list_workspaces 2>&1); echo "$R" | grep -c "." | grep -q 1; check $? "1 workspace remaining"

echo ""
echo "--- Splits ---"
R=$($CLI new_split h 2>&1); [ "$R" = "OK" ]; check $? "split horizontal"
R=$($CLI new_split v 2>&1); [ "$R" = "OK" ]; check $? "split vertical"
R=$($CLI new_split h 2>&1); [ "$R" = "OK" ]; check $? "split horizontal again"
R=$($CLI ping 2>&1); [ "$R" = "PONG" ]; check $? "alive after 3 splits"

echo ""
echo "--- Send ---"
R=$($CLI send "echo hello\n" 2>&1); [ "$R" = "OK" ]; check $? "send text with newline"

echo ""
echo "--- Claude Status ---"
R=$($CLI set_status claude_code Running 2>&1); [ "$R" = "OK" ]; check $? "set claude running"
R=$($CLI set_status claude_message "Working on auth fix" 2>&1); [ "$R" = "OK" ]; check $? "set claude message"
R=$($CLI clear_status claude_code 2>&1); [ "$R" = "OK" ]; check $? "clear claude status"

echo ""
echo "--- Notifications ---"
R=$($CLI notify "Test|Hello world" 2>&1); [ "$R" = "OK" ]; check $? "notify"

echo ""
echo "--- Stability ---"
for i in $(seq 1 5); do
    $CLI new_split h >/dev/null 2>&1
    $CLI send "exit\n" >/dev/null 2>&1
    sleep 1
done
R=$($CLI ping 2>&1); [ "$R" = "PONG" ]; check $? "alive after 5 split+close cycles"

echo ""
echo "--- Dtach cleanup ---"
# Count dtach sockets — should match number of live panes
DTACH_SOCKS=$(ls /tmp/cmux-dtach-*.sock 2>/dev/null | wc -l)
DTACH_PROCS=$(ps aux | grep "dtach.*cmux-dtach" | grep -v grep | wc -l)
echo "  dtach sockets: $DTACH_SOCKS, processes: $DTACH_PROCS"

# Close the workspace (should kill its dtach processes)
WS=$($CLI current_workspace 2>/dev/null | cut -f1)
$CLI close_workspace "$WS" >/dev/null 2>&1
sleep 1

# After closing, only the fresh default workspace's dtach should remain
DTACH_AFTER=$(ps aux | grep "dtach.*cmux-dtach" | grep -v grep | wc -l)
echo "  dtach after close: $DTACH_AFTER"
# Expect <=2: 1 for the fresh default workspace + possibly 1 lingering from stability test
[ "$DTACH_AFTER" -le 2 ]; check $? "no orphaned dtach after close_workspace"

# Close cmux and verify ALL dtach are cleaned or intentionally alive
kill $(pgrep -f "zig-out/bin/cmux" | head -1) 2>/dev/null
sleep 2
DTACH_FINAL=$(ps aux | grep "dtach.*cmux-dtach" | grep -v grep | wc -l)
SOCK_FINAL=$(ls /tmp/cmux-dtach-*.sock 2>/dev/null | wc -l)
echo "  dtach after cmux exit: $DTACH_FINAL procs, $SOCK_FINAL sockets"
# After cmux exit, dtach SHOULD still be alive (session persistence)
[ "$DTACH_FINAL" -ge 1 ]; check $? "dtach survives cmux exit (persistence)"

# Now kill dtach and verify clean
pkill -f "dtach.*cmux-dtach" 2>/dev/null || true
sleep 1
DTACH_CLEANED=$(ps aux | grep "dtach.*cmux-dtach" | grep -v grep | wc -l)
[ "$DTACH_CLEANED" -eq 0 ]; check $? "dtach fully cleaned after kill"

echo ""
echo "==========================="
echo "PASS: $PASS  FAIL: $FAIL"
echo "==========================="

pkill -9 -f Xvfb 2>/dev/null || true
pkill -9 -f "zig-out/bin/cmux" 2>/dev/null || true
rm -f /tmp/cmux-dtach-*.sock /tmp/cmux-session/layout.json
