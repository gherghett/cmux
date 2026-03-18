#!/bin/bash
# Test: process history ring buffer and icon detection
source "$(dirname "$0")/lib.sh"

full_cleanup
start_xvfb

echo "=== Process history ==="

start_cmux

WS=$($CLI current_workspace | cut -f1)

# report_process should accept a process name
R=$($CLI report_process git "--tab=$WS" 2>&1)
[ "$R" = "OK" ]; check $? "report_process git returns OK"

# Report several git commands to reach 50% threshold
$CLI report_process git "--tab=$WS" >/dev/null 2>&1
$CLI report_process git "--tab=$WS" >/dev/null 2>&1
$CLI report_process ls "--tab=$WS" >/dev/null 2>&1

# At this point: 3 git + 1 ls = 75% git → should show icon
# We can't directly query the icon, but we can verify the socket command works
# and check that multiple report_process calls succeed
R=$($CLI report_process npm "--tab=$WS" 2>&1)
[ "$R" = "OK" ]; check $? "report_process npm returns OK"

# Verify report_process with unknown workspace returns OK (not error — it's fire-and-forget)
R=$($CLI report_process git "--tab=00000000-0000-0000-0000-000000000000" 2>&1)
[ "$R" = "OK" ]; check $? "report_process with unknown workspace returns OK"

# Verify report_process without --tab uses current workspace
R=$($CLI report_process make 2>&1)
[ "$R" = "OK" ]; check $? "report_process without --tab returns OK"

# Verify shell integration script exists and has the DEBUG trap
INIT_SCRIPT="$PROJECT_DIR/bin/cmux-shell-init.sh"
[ -f "$INIT_SCRIPT" ]; check $? "shell integration script exists"
grep -q "report_process" "$INIT_SCRIPT"; check $? "shell init has report_process hook"
grep -q "DEBUG" "$INIT_SCRIPT"; check $? "shell init uses DEBUG trap"

# Verify the shell integration is actually sourced in panes
# (CMUX_SHELL_INTEGRATION_DIR should be set, and bashrc should source it)
$CLI send 'echo CMUX_SID=$CMUX_SHELL_INTEGRATION_DIR > /tmp/cmux-proc-test-'$$'\n' >/dev/null 2>&1
wait_for 5 '[ -f /tmp/cmux-proc-test-'$$' ]'

if [ -f "/tmp/cmux-proc-test-$$" ]; then
    SID=$(grep "CMUX_SID=" "/tmp/cmux-proc-test-$$" | cut -d= -f2)
    [ -n "$SID" ]; check $? "CMUX_SHELL_INTEGRATION_DIR is set in pane"

    # Check if the init script is actually being sourced (DEBUG trap active)
    $CLI send 'trap -p DEBUG > /tmp/cmux-trap-test-'$$'\n' >/dev/null 2>&1
    wait_for 5 '[ -f /tmp/cmux-trap-test-'$$' ]'
    if [ -f "/tmp/cmux-trap-test-$$" ]; then
        grep -q "cmux" "/tmp/cmux-trap-test-$$" 2>/dev/null
        check $? "DEBUG trap with cmux hook is active in pane"
    else
        check 1 "DEBUG trap with cmux hook is active in pane (could not check)"
    fi
    rm -f "/tmp/cmux-proc-test-$$" "/tmp/cmux-trap-test-$$"
else
    check 1 "CMUX_SHELL_INTEGRATION_DIR is set in pane (send failed)"
    check 1 "DEBUG trap with cmux hook is active in pane (send failed)"
fi

stop_cmux
check_stderr_clean
full_cleanup
print_result
exit $FAIL
