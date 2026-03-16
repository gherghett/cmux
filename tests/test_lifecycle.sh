#!/bin/bash
# Test: dtach lifecycle, dangling cleanup, env vars, clean shutdown
source "$(dirname "$0")/lib.sh"

full_cleanup
start_xvfb

echo "=== Lifecycle ==="

# --- Dangling dtach killed on startup ---
start_cmux
$CLI rename_workspace "$($CLI current_workspace | cut -f1)" "legit-ws" >/dev/null 2>&1

# Spawn an orphan dtach NOT tracked by any workspace
ORPHAN_SOCK="$CMUX_DIR/dtach-orphan-test-$$.sock"
dtach -n "$ORPHAN_SOCK" /bin/bash 2>/dev/null
sleep 1

stop_cmux

# Restart — reconciliation should kill the orphan
start_cmux
sleep 1

ORPHAN_AFTER=0
[ -S "$ORPHAN_SOCK" ] && ORPHAN_AFTER=1
[ "$ORPHAN_AFTER" = "0" ]; check $? "dangling dtach killed by reconciliation"

WS_LIST=$($CLI list_workspaces 2>/dev/null)
echo "$WS_LIST" | grep -q "legit-ws"; check $? "legitimate workspace preserved"

# --- Env vars correct ---
ENVFILE="/tmp/cmux-env-test-$$"
$CLI send "env | grep CMUX_ > $ENVFILE 2>/dev/null\n" >/dev/null 2>&1
sleep 2

if [ -f "$ENVFILE" ]; then
    TAB_ID=$(grep "CMUX_TAB_ID=" "$ENVFILE" | cut -d= -f2)
    SURFACE_ID=$(grep "CMUX_SURFACE_ID=" "$ENVFILE" | cut -d= -f2)
    WS_ID=$(grep "CMUX_WORKSPACE_ID=" "$ENVFILE" | cut -d= -f2)

    [ "$TAB_ID" = "$SURFACE_ID" ]; check $? "CMUX_TAB_ID equals CMUX_SURFACE_ID"
    [ "$TAB_ID" != "$WS_ID" ]; check $? "CMUX_TAB_ID differs from CMUX_WORKSPACE_ID"
    rm -f "$ENVFILE"
else
    check 1 "CMUX_TAB_ID equals CMUX_SURFACE_ID (env capture failed)"
    check 1 "CMUX_TAB_ID differs from CMUX_WORKSPACE_ID (env capture failed)"
fi

# --- Workspace UUID preserved across restart ---
WS_BEFORE=$($CLI current_workspace | cut -f1)
stop_cmux
start_cmux
WS_AFTER=$($CLI list_workspaces 2>/dev/null | grep "legit-ws" | cut -f1)
[ "$WS_BEFORE" = "$WS_AFTER" ]; check $? "workspace UUID preserved across restart"

# --- CMUX_WORKSPACE_ID valid in dtach after restart ---
ENVFILE2="/tmp/cmux-env-test2-$$"
$CLI send "echo CMUX_WORKSPACE_ID=\$CMUX_WORKSPACE_ID > $ENVFILE2\n" >/dev/null 2>&1
sleep 2

if [ -f "$ENVFILE2" ]; then
    SHELL_WS_ID=$(grep "CMUX_WORKSPACE_ID=" "$ENVFILE2" | cut -d= -f2)
    [ "$SHELL_WS_ID" = "$WS_AFTER" ]; check $? "CMUX_WORKSPACE_ID valid in dtach after restart"
    rm -f "$ENVFILE2"
else
    check 1 "CMUX_WORKSPACE_ID valid in dtach after restart (env capture failed)"
fi

# --- Clean shutdown (no GLib-CRITICAL) ---
stop_cmux
full_cleanup
start_xvfb

DISPLAY=:99 "$PROJECT_DIR/zig-out/bin/cmux" >/dev/null 2>/tmp/cmux-stderr-$$ &
sleep 3
$CLI ping >/dev/null 2>&1
$CLI new_workspace >/dev/null 2>&1
$CLI new_split h >/dev/null 2>&1
sleep 1
kill "$(pgrep -f "zig-out/bin/cmux" | head -1)" 2>/dev/null
sleep 3

GLIB_ERRORS=$(grep -c "GLib-CRITICAL\|Gtk-CRITICAL" /tmp/cmux-stderr-$$ 2>/dev/null)
[ "${GLIB_ERRORS:-0}" = "0" ]; check $? "no GLib/Gtk CRITICAL on shutdown"
rm -f /tmp/cmux-stderr-$$

full_cleanup
print_result
exit $FAIL
