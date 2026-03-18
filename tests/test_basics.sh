#!/bin/bash
# Test: socket connectivity, workspace CRUD, splits, send, notifications
source "$(dirname "$0")/lib.sh"

full_cleanup
start_xvfb
start_cmux

echo "=== Basics ==="

# Socket
R=$($CLI ping 2>&1); [ "$R" = "PONG" ]; check $? "ping"

# Workspaces
R=$($CLI list_workspaces 2>&1); [ -n "$R" ]; check $? "initial workspace exists"
WS1=$($CLI current_workspace | cut -f1)
R=$($CLI new_workspace 2>&1); echo "$R" | grep -qE '[0-9a-f-]{36}'; check $? "new_workspace returns UUID"
WS2=$R
R=$($CLI select_workspace "$WS1" 2>&1); [ "$R" = "OK" ]; check $? "select_workspace"
R=$($CLI current_workspace 2>&1); echo "$R" | grep -q "$WS1"; check $? "current_workspace matches"
R=$($CLI rename_workspace "$WS1" "MyProject" 2>&1); [ "$R" = "OK" ]; check $? "rename_workspace"
R=$($CLI current_workspace 2>&1); echo "$R" | grep -q "MyProject"; check $? "renamed title visible"
R=$($CLI close_workspace "$WS2" 2>&1); [ "$R" = "OK" ]; check $? "close_workspace"

# Splits
R=$($CLI new_split h 2>&1); [ "$R" = "OK" ]; check $? "split horizontal"
R=$($CLI new_split v 2>&1); [ "$R" = "OK" ]; check $? "split vertical"
R=$($CLI ping 2>&1); [ "$R" = "PONG" ]; check $? "alive after splits"

# Send
R=$($CLI send "echo hello\n" 2>&1); [ "$R" = "OK" ]; check $? "send text"

# Claude status
R=$($CLI set_status claude_code Running 2>&1); [ "$R" = "OK" ]; check $? "set claude running"
R=$($CLI set_status claude_message "Working" 2>&1); [ "$R" = "OK" ]; check $? "set claude message"
R=$($CLI clear_status claude_code 2>&1); [ "$R" = "OK" ]; check $? "clear claude status"

# Notification
R=$($CLI notify "Test|Hello world" 2>&1); [ "$R" = "OK" ]; check $? "notify"

# Unknown --tab= rejected
FAKE_UUID="deadbeef-dead-beef-dead-beefdeadbeef"
R=$($CLI set_status claude_code Running "--tab=$FAKE_UUID" 2>&1)
[ "$R" = "ERROR: workspace not found" ]; check $? "unknown --tab= returns error"

# Templates
$CLI new_split h >/dev/null 2>&1
R=$($CLI save_template test-tmpl 2>&1); [ "$R" = "OK" ]; check $? "save_template"
R=$($CLI list_templates 2>&1); echo "$R" | grep -q "test-tmpl"; check $? "list_templates shows saved template"
R=$($CLI load_template test-tmpl 2>&1); echo "$R" | grep -qE '[0-9a-f-]{36}'; check $? "load_template returns UUID"
R=$($CLI load_template nonexistent 2>&1); echo "$R" | grep -q "ERROR"; check $? "load unknown template returns error"
R=$($CLI save_template "../evil" 2>&1); echo "$R" | grep -q "ERROR"; check $? "save_template rejects path traversal"

stop_cmux
check_stderr_clean
full_cleanup
print_result
exit $FAIL
