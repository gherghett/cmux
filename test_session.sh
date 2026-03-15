#!/bin/bash
CLI=./zig-out/bin/cmux-cli
LOG=/home/daniel/projekt/cmux-linux/cmux-session-test.log
PASS=0; FAIL=0
check() { if [ "$1" = "0" ]; then echo "  ✓ $2"; PASS=$((PASS+1)); else echo "  ✗ $2"; FAIL=$((FAIL+1)); fi; }

# Clean slate
pkill -9 -f Xvfb 2>/dev/null || true
pkill -9 -f "zig-out/bin/cmux" 2>/dev/null || true
pkill -f "dtach.*cmux-dtach" 2>/dev/null || true
rm -f /tmp/cmux.sock /tmp/cmux-session/layout.json /tmp/cmux-dtach-*.sock
sleep 1

echo "=== PHASE 1: Start, create workspaces ==="
Xvfb :99 -screen 0 1280x1024x24 &>/dev/null &
sleep 1
DISPLAY=:99 ./zig-out/bin/cmux >$LOG 2>&1 &
sleep 3

$CLI ping >/dev/null; check $? "cmux started"

WS1=$($CLI current_workspace | cut -f1)
$CLI rename_workspace "$WS1" "my-project" >/dev/null
$CLI new_workspace >/dev/null
WS2=$($CLI current_workspace | cut -f1)
$CLI rename_workspace "$WS2" "backend" >/dev/null
$CLI select_workspace "$WS1" >/dev/null
$CLI new_split h >/dev/null

DTACH_COUNT=$(ls /tmp/cmux-dtach-*.sock 2>/dev/null | wc -l)
echo "  dtach sockets: $DTACH_COUNT"
[ "$DTACH_COUNT" -ge 3 ]; check $? "3+ dtach sockets created"

WS_LIST=$($CLI list_workspaces)
echo "$WS_LIST" | grep -q "my-project"; check $? "workspace 'my-project' exists"
echo "$WS_LIST" | grep -q "backend"; check $? "workspace 'backend' exists"

echo ""
echo "=== PHASE 2: Close cmux ==="
kill $(pgrep -f "zig-out/bin/cmux" | head -1) 2>/dev/null
sleep 3

[ -f /tmp/cmux-session/layout.json ]; check $? "session file saved"

DTACH_ALIVE=$(ls /tmp/cmux-dtach-*.sock 2>/dev/null | wc -l)
echo "  dtach sockets still alive: $DTACH_ALIVE"
[ "$DTACH_ALIVE" -ge 3 ]; check $? "dtach sockets survived close"

DTACH_PROCS=$(ps aux | grep "dtach.*cmux-dtach" | grep -v grep | wc -l)
echo "  dtach processes: $DTACH_PROCS"
[ "$DTACH_PROCS" -ge 3 ]; check $? "dtach processes survived close"

echo ""
echo "  session.json:"
cat /tmp/cmux-session/layout.json 2>/dev/null | head -20

echo ""
echo "=== PHASE 3: Restart cmux ==="
DISPLAY=:99 ./zig-out/bin/cmux >>$LOG 2>&1 &
sleep 3

$CLI ping >/dev/null; check $? "cmux restarted"

WS_LIST2=$($CLI list_workspaces)
echo "$WS_LIST2" | grep -q "my-project"; check $? "workspace 'my-project' restored"
echo "$WS_LIST2" | grep -q "backend"; check $? "workspace 'backend' restored"

WS_COUNT=$(echo "$WS_LIST2" | wc -l)
echo "  restored workspace count: $WS_COUNT"

echo ""
echo "==========================="
echo "PASS: $PASS  FAIL: $FAIL"
echo "==========================="

pkill -9 -f Xvfb 2>/dev/null || true
pkill -9 -f "zig-out/bin/cmux" 2>/dev/null || true
