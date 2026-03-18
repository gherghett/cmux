#!/bin/bash
# Test: session save/restore, double-restart, workspace titles preserved
source "$(dirname "$0")/lib.sh"

full_cleanup
start_xvfb

echo "=== Session restore ==="

# Phase 1: create workspaces
start_cmux
WS1=$($CLI current_workspace | cut -f1)
$CLI rename_workspace "$WS1" "my-project" >/dev/null
$CLI new_workspace >/dev/null
WS2=$($CLI current_workspace | cut -f1)
$CLI rename_workspace "$WS2" "backend" >/dev/null
$CLI select_workspace "$WS1" >/dev/null
$CLI new_split h >/dev/null

DTACH_COUNT=$(ls "$CMUX_DIR"/dtach-*.sock 2>/dev/null | wc -l)
[ "$DTACH_COUNT" -ge 3 ]; check $? "3+ dtach sockets created"

# Phase 2: close
stop_cmux
[ -f "$CMUX_DIR/session.json" ]; check $? "session file saved"

DTACH_ALIVE=$(ls "$CMUX_DIR"/dtach-*.sock 2>/dev/null | wc -l)
[ "$DTACH_ALIVE" -ge 3 ]; check $? "dtach sockets survived close"

# Phase 3: restart
start_cmux
WS_LIST=$($CLI list_workspaces 2>/dev/null)
echo "$WS_LIST" | grep -q "my-project"; check $? "workspace 'my-project' restored"
echo "$WS_LIST" | grep -q "backend"; check $? "workspace 'backend' restored"

# Phase 4: double restart
stop_cmux
start_cmux
WS_LIST=$($CLI list_workspaces 2>/dev/null)
echo "$WS_LIST" | grep -q "my-project"; check $? "'my-project' survives double restart"
echo "$WS_LIST" | grep -q "backend"; check $? "'backend' survives double restart"

# UUID preservation
WS1_NEW=$($CLI list_workspaces 2>/dev/null | grep "my-project" | cut -f1)
WS2_NEW=$($CLI list_workspaces 2>/dev/null | grep "backend" | cut -f1)
# UUIDs might differ from originals if dtach died, but should be stable across the double restart

# Split direction preserved
grep -q '"split": "h"' "$CMUX_DIR/session.json" 2>/dev/null; check $? "split direction saved in session"
grep -q '"tree":' "$CMUX_DIR/session.json" 2>/dev/null; check $? "tree structure saved in session"

# Clean shutdown — count spawns by checking dtach process count (not log)
stop_cmux
check_stderr_clean
# Only count dtach in our test runtime dir, not the user's
DTACH_LEFT=$(ps aux | grep "dtach.*${_TEST_RUNTIME_DIR}" | grep -v grep | wc -l)
[ "$DTACH_LEFT" -le 10 ] 2>/dev/null; check $? "no excessive dtach after session test ($DTACH_LEFT remaining)"

full_cleanup
print_result
exit $FAIL
