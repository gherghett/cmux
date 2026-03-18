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

# ── Helpers ──────────────────────────────────────────────

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

## Poll until a command succeeds or timeout (in seconds).
## Usage: wait_for 5 '$CLI ping >/dev/null 2>&1'
wait_for() {
    local timeout=$1; shift
    for i in $(seq 1 "$timeout"); do
        if eval "$@" 2>/dev/null; then return 0; fi
        sleep 1
    done
    return 1
}

## Wait until a PID is no longer running, with timeout.
wait_pid_gone() {
    local pid=$1 timeout=${2:-5}
    for i in $(seq 1 "$timeout"); do
        kill -0 "$pid" 2>/dev/null || return 0
        sleep 1
    done
    # Still alive after timeout — force kill
    kill -9 "$pid" 2>/dev/null
    return 1
}

# ── Lifecycle ────────────────────────────────────────────

full_cleanup() {
    # SIGTERM first (lets cmux save session), then SIGKILL if stuck
    if [ -n "$_CMUX_PID" ]; then
        kill "$_CMUX_PID" 2>/dev/null
        wait_pid_gone "$_CMUX_PID" 3
    fi
    [ -n "$_XVFB_PID" ] && kill -9 "$_XVFB_PID" 2>/dev/null
    _CMUX_PID=""
    _XVFB_PID=""

    # Kill dtach sessions spawned by test cmux (only in test runtime dir).
    # Must happen BEFORE removing the dir so the pattern still matches.
    if [ -n "$_TEST_RUNTIME_DIR" ]; then
        pkill -9 -f "dtach.*${_TEST_RUNTIME_DIR}" 2>/dev/null || true
        sleep 0.5
    fi

    rm -f "$_STDERR_FILE"
    rm -rf "$_TEST_RUNTIME_DIR"
    mkdir -p "$_TEST_RUNTIME_DIR"
    rm -rf "$HOME/.config/cmux/templates"
}

start_xvfb() {
    _TEST_DISPLAY=99
    Xvfb ":${_TEST_DISPLAY}" -screen 0 1280x1024x24 &>/dev/null &
    _XVFB_PID=$!
    sleep 0.5
    export DISPLAY=":${_TEST_DISPLAY}"
}

start_cmux() {
    _STDERR_FILE="/tmp/cmux-test-stderr-$$.log"
    DISPLAY=":${_TEST_DISPLAY}" "$PROJECT_DIR/zig-out/bin/cmux" >>"$TEST_LOG" 2>"$_STDERR_FILE" &
    _CMUX_PID=$!
    # Poll for socket instead of fixed sleep
    if ! wait_for 10 '$CLI ping >/dev/null 2>&1'; then
        echo "  ERROR: cmux failed to start (ping timeout)" >&2
        return 1
    fi
}

stop_cmux() {
    if [ -n "$_CMUX_PID" ]; then
        kill "$_CMUX_PID" 2>/dev/null  # SIGTERM — lets it save session
        wait_pid_gone "$_CMUX_PID" 5
        _CMUX_PID=""
    fi
}

# ── Assertions ───────────────────────────────────────────

# Check stderr for GTK/GLib warnings after a test run.
# Call after stop_cmux. Fails the test if any warnings found.
check_stderr_clean() {
    if [ -z "$_STDERR_FILE" ] || [ ! -f "$_STDERR_FILE" ]; then
        return
    fi
    local warnings
    # Filter out known-harmless GTK warnings before counting
    # - "last focus widget of GtkPaned" — fires when a VTE child exits in a split,
    #   GTK processes focus asynchronously and can't find the removed widget.
    warnings=$(grep "GLib-CRITICAL\|Gtk-CRITICAL\|Gtk-WARNING" "$_STDERR_FILE" 2>/dev/null \
        | grep -cv "last focus widget of GtkPaned")
    if [ "${warnings:-0}" -gt 0 ]; then
        echo "  stderr warnings:"
        grep "GLib-CRITICAL\|Gtk-CRITICAL\|Gtk-WARNING" "$_STDERR_FILE" \
            | grep -v "last focus widget of GtkPaned" | head -3 | sed 's/^/    /'
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
