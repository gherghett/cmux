#!/bin/bash
# Run all cmux integration tests.
# Usage:
#   ./tests/run_all.sh              # run all
#   ./tests/run_all.sh basics       # run only test_basics.sh
#   ./tests/run_all.sh session life # run test_session.sh and test_lifecycle.sh
#
# Results: one-liner per suite, total at end.
# Detailed log: tests/test.log

set -o pipefail
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG="$TESTS_DIR/test.log"
> "$LOG"  # truncate

TOTAL_PASS=0
TOTAL_FAIL=0
SUITES_PASS=0
SUITES_FAIL=0

# Collect test files
if [ $# -gt 0 ]; then
    # Run specific tests by name fragment
    TEST_FILES=()
    for pattern in "$@"; do
        for f in "$TESTS_DIR"/test_*"$pattern"*.sh; do
            [ -f "$f" ] && TEST_FILES+=("$f")
        done
    done
else
    TEST_FILES=("$TESTS_DIR"/test_*.sh)
fi

if [ ${#TEST_FILES[@]} -eq 0 ]; then
    echo "No test files found."
    exit 1
fi

echo "=== cmux test runner ==="
echo ""

for test_file in "${TEST_FILES[@]}"; do
    name=$(basename "$test_file" .sh)
    echo -n "  $name ... "
    echo "=== $name ===" >> "$LOG"

    # Run test, capture output to log, extract pass/fail from last line
    output=$(bash "$test_file" 2>&1)
    exit_code=$?
    echo "$output" >> "$LOG"
    echo "" >> "$LOG"

    # Parse result from the print_result line
    pass=$(echo "$output" | grep -oP 'PASS=\K[0-9]+' | tail -1)
    fail=$(echo "$output" | grep -oP 'FAIL=\K[0-9]+' | tail -1)
    pass=${pass:-0}
    fail=${fail:-0}

    TOTAL_PASS=$((TOTAL_PASS + pass))
    TOTAL_FAIL=$((TOTAL_FAIL + fail))

    if [ "$fail" = "0" ]; then
        echo "✓ $pass passed"
        SUITES_PASS=$((SUITES_PASS + 1))
    else
        echo "✗ $pass passed, $fail FAILED"
        SUITES_FAIL=$((SUITES_FAIL + 1))
        # Show failing tests
        echo "$output" | grep "✗" | sed 's/^/    /'
    fi
done

echo ""
echo "==========================="
echo "  Suites: $SUITES_PASS passed, $SUITES_FAIL failed"
echo "  Tests:  $TOTAL_PASS passed, $TOTAL_FAIL failed"
echo "==========================="
echo "  Log: $LOG"

exit $TOTAL_FAIL
