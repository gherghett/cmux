#!/bin/bash
# Shared test helpers for cmux integration tests.
# Source this from any test file: source "$(dirname "$0")/lib.sh"

CMUX_DIR="${XDG_RUNTIME_DIR:-/tmp}/cmux"
CLI="$(dirname "$0")/../zig-out/bin/cmux-cli"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_LOG="${PROJECT_DIR}/tests/test.log"
PASS=0
FAIL=0
TEST_NAME="${TEST_NAME:-$(basename "$0" .sh)}"

# PIDs we started — only kill these, never pkill globally
_XVFB_PID=""
_CMUX_PID=""
_TEST_DISPLAY=""

# Use a separate socket so tests never interfere with the user's running cmux
TEST_SOCKET="$CMUX_DIR/cmux-test-$$.sock"
export CMUX_SOCKET_PATH="$TEST_SOCKET"

log() {
    echo "$@" >> "$TEST_LOG"
}

check() {
    if [ "$1" = "0" ]; then
        echo "  ✓ $2"
        log "  ✓ $2"
        PASS=$((PASS+1))
    else
        echo "  ✗ $2"
        log "  ✗ $2"
        FAIL=$((FAIL+1))
    fi
}

full_cleanup() {
    # Only kill processes WE started, not the user's cmux
    [ -n "$_CMUX_PID" ] && kill -9 "$_CMUX_PID" 2>/dev/null
    [ -n "$_XVFB_PID" ] && kill -9 "$_XVFB_PID" 2>/dev/null
    _CMUX_PID=""
    _XVFB_PID=""

    # Kill dtach sessions spawned by test cmux (in the test socket dir)
    # Use the socket prefix to only match test dtach, not user's
    pkill -f "dtach.*dtach-" 2>/dev/null || true
    sleep 1

    rm -f "$TEST_SOCKET"
    rm -f "$CMUX_DIR"/session.json "$CMUX_DIR"/dtach-*.sock
    rm -f /tmp/cmux-session/layout.json /tmp/cmux-dtach-*.sock
}

start_xvfb() {
    # Use --auto-servernum to avoid conflicts with existing displays
    Xvfb -screen 0 1280x1024x24 --auto-servernum &>/tmp/xvfb-test-$$.log &
    _XVFB_PID=$!
    sleep 1
    # Read which display was assigned
    _TEST_DISPLAY=$(grep -oP 'screen \K[0-9]+' /tmp/xvfb-test-$$.log 2>/dev/null)
    if [ -z "$_TEST_DISPLAY" ]; then
        # Fallback: try a high display number
        _TEST_DISPLAY=99
        kill "$_XVFB_PID" 2>/dev/null
        Xvfb :99 -screen 0 1280x1024x24 &>/dev/null &
        _XVFB_PID=$!
        sleep 1
    fi
    rm -f /tmp/xvfb-test-$$.log
    export DISPLAY=":${_TEST_DISPLAY}"
}

start_cmux() {
    "$PROJECT_DIR/zig-out/bin/cmux" >>"$TEST_LOG" 2>&1 &
    _CMUX_PID=$!
    sleep 3
    $CLI ping >/dev/null 2>&1
}

stop_cmux() {
    [ -n "$_CMUX_PID" ] && kill "$_CMUX_PID" 2>/dev/null
    sleep 3
    _CMUX_PID=""
}

print_result() {
    echo ""
    echo "--- $TEST_NAME: PASS=$PASS FAIL=$FAIL ---"
    log "--- $TEST_NAME: PASS=$PASS FAIL=$FAIL ---"
}

# Ensure cleanup on exit even if test crashes
trap full_cleanup EXIT
