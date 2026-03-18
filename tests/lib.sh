#!/bin/bash
# Shared test helpers for cmux integration tests.
# Source this from any test file: source "$(dirname "$0")/lib.sh"

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
_STDERR_FILE=""

# Fully isolated runtime dir so tests NEVER touch the user's live session.
# All cmux paths (socket, session.json, dtach sockets, logs) derive from
# XDG_RUNTIME_DIR via runtime_dir.zig, so overriding it isolates everything.
_REAL_XDG="${XDG_RUNTIME_DIR:-}"
_TEST_RUNTIME_DIR="/tmp/cmux-test-$$"
mkdir -p "$_TEST_RUNTIME_DIR"
export XDG_RUNTIME_DIR="$_TEST_RUNTIME_DIR"
CMUX_DIR="$_TEST_RUNTIME_DIR/cmux"

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

    # Kill dtach sessions spawned by test cmux (only in test runtime dir)
    if [ -n "$_TEST_RUNTIME_DIR" ]; then
        pkill -f "dtach.*${_TEST_RUNTIME_DIR}" 2>/dev/null || true
    fi
    sleep 1

    rm -f "$_STDERR_FILE"
    rm -rf "$_TEST_RUNTIME_DIR"
    mkdir -p "$_TEST_RUNTIME_DIR"
    rm -rf "$HOME/.config/cmux/templates"
}

start_xvfb() {
    # Use a high display number unlikely to conflict
    _TEST_DISPLAY=99
    Xvfb ":${_TEST_DISPLAY}" -screen 0 1280x1024x24 &>/dev/null &
    _XVFB_PID=$!
    sleep 1
    export DISPLAY=":${_TEST_DISPLAY}"
}

start_cmux() {
    _STDERR_FILE="/tmp/cmux-test-stderr-$$.log"
    # Explicitly set DISPLAY to ensure cmux opens on Xvfb, not the user's screen
    DISPLAY=":${_TEST_DISPLAY}" "$PROJECT_DIR/zig-out/bin/cmux" >>"$TEST_LOG" 2>"$_STDERR_FILE" &
    _CMUX_PID=$!
    sleep 3
    $CLI ping >/dev/null 2>&1
}

stop_cmux() {
    [ -n "$_CMUX_PID" ] && kill "$_CMUX_PID" 2>/dev/null
    sleep 3
    _CMUX_PID=""
}

# Check stderr for GTK/GLib warnings after a test run.
# Call after stop_cmux. Fails the test if any warnings found.
check_stderr_clean() {
    if [ -z "$_STDERR_FILE" ] || [ ! -f "$_STDERR_FILE" ]; then
        return
    fi
    local warnings
    warnings=$(grep -c "GLib-CRITICAL\|Gtk-CRITICAL\|Gtk-WARNING" "$_STDERR_FILE" 2>/dev/null)
    if [ "${warnings:-0}" -gt 0 ]; then
        echo "  stderr warnings:"
        grep "GLib-CRITICAL\|Gtk-CRITICAL\|Gtk-WARNING" "$_STDERR_FILE" | head -3 | sed 's/^/    /'
    fi
    [ "${warnings:-0}" = "0" ]; check $? "no GTK/GLib warnings on stderr"
    rm -f "$_STDERR_FILE"
    _STDERR_FILE=""
}

print_result() {
    echo ""
    echo "--- $TEST_NAME: PASS=$PASS FAIL=$FAIL ---"
    log "--- $TEST_NAME: PASS=$PASS FAIL=$FAIL ---"
}

# Ensure cleanup on exit even if test crashes
trap full_cleanup EXIT
