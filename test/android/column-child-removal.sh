#!/usr/bin/env bash
# Android column-child-removal test: reproducer for child removal from Column.
#
# Tests diffContainer's handling of child removal:
#   State0 → State1: middle child removed (B gone, unstable path)
#   State1 → State2: tail child removed (C gone, stable path)
#
# Verifies that only the correct children remain after each transition.
#
# Required env vars (set by emulator-all.nix harness):
#   ADB, EMULATOR_SERIAL, COLUMN_CHILD_REMOVAL_APK, PACKAGE, ACTIVITY, WORK_DIR
set -euo pipefail
source "$(dirname "$0")/helpers.sh"

EXIT_CODE=0

start_app "$COLUMN_CHILD_REMOVAL_APK" "column-child-removal"
wait_for_render "column-child-removal"
sleep 5
collect_logcat "ccr-initial"

assert_logcat "$LOGCAT_FILE" "Column state: State0" "Initial state is State0"

# Verify all 3 children visible
DUMP="$WORK_DIR/ccr_0.xml"
dump_ok=0
for attempt in 1 2 3; do
    if "$ADB" -s "$EMULATOR_SERIAL" shell uiautomator dump /data/local/tmp/ui.xml 2>&1 | grep -q "dumped"; then
        "$ADB" -s "$EMULATOR_SERIAL" pull /data/local/tmp/ui.xml "$DUMP" 2>/dev/null
        dump_ok=1
        break
    fi
    sleep 5
done

if [ $dump_ok -eq 1 ]; then
    for child in CHILD_A CHILD_B CHILD_C; do
        if grep -q "$child" "$DUMP" 2>/dev/null; then
            echo "PASS: $child visible in State0"
        else
            echo "FAIL: $child not visible in State0"
            EXIT_CODE=1
        fi
    done
else
    echo "FAIL: Could not dump view hierarchy (State0)"
    EXIT_CODE=1
fi

# === Advance to State1 (middle removal: B gone) ===
echo "=== Advancing to State1 ==="
tap_button "Advance" || "$ADB" -s "$EMULATOR_SERIAL" shell input tap 540 100
sleep 5
collect_logcat "ccr-state1"
assert_logcat "$LOGCAT_FILE" "Column state: State1" "Advanced to State1"

DUMP1="$WORK_DIR/ccr_1.xml"
dump_ok1=0
for attempt in 1 2 3; do
    if "$ADB" -s "$EMULATOR_SERIAL" shell uiautomator dump /data/local/tmp/ui.xml 2>&1 | grep -q "dumped"; then
        "$ADB" -s "$EMULATOR_SERIAL" pull /data/local/tmp/ui.xml "$DUMP1" 2>/dev/null
        dump_ok1=1
        break
    fi
    sleep 5
done

if [ $dump_ok1 -eq 1 ]; then
    echo "=== State1 hierarchy ==="
    cat "$DUMP1"
    echo ""

    if grep -q 'CHILD_A' "$DUMP1" 2>/dev/null; then
        echo "PASS: CHILD_A visible in State1"
    else
        echo "FAIL: CHILD_A not visible in State1"
        EXIT_CODE=1
    fi

    if grep -q 'CHILD_B' "$DUMP1" 2>/dev/null; then
        echo "FAIL: CHILD_B still visible in State1 (should be removed)"
        EXIT_CODE=1
    else
        echo "PASS: CHILD_B removed in State1"
    fi

    if grep -q 'CHILD_C' "$DUMP1" 2>/dev/null; then
        echo "PASS: CHILD_C visible in State1"
    else
        echo "FAIL: CHILD_C not visible in State1"
        EXIT_CODE=1
    fi
else
    echo "FAIL: Could not dump view hierarchy (State1)"
    EXIT_CODE=1
fi

# === Advance to State2 (tail removal: C gone) ===
echo "=== Advancing to State2 ==="
tap_button "Advance" || "$ADB" -s "$EMULATOR_SERIAL" shell input tap 540 100
sleep 5
collect_logcat "ccr-state2"
assert_logcat "$LOGCAT_FILE" "Column state: State2" "Advanced to State2"

DUMP2="$WORK_DIR/ccr_2.xml"
dump_ok2=0
for attempt in 1 2 3; do
    if "$ADB" -s "$EMULATOR_SERIAL" shell uiautomator dump /data/local/tmp/ui.xml 2>&1 | grep -q "dumped"; then
        "$ADB" -s "$EMULATOR_SERIAL" pull /data/local/tmp/ui.xml "$DUMP2" 2>/dev/null
        dump_ok2=1
        break
    fi
    sleep 5
done

if [ $dump_ok2 -eq 1 ]; then
    echo "=== State2 hierarchy ==="
    cat "$DUMP2"
    echo ""

    if grep -q 'CHILD_A' "$DUMP2" 2>/dev/null; then
        echo "PASS: CHILD_A visible in State2"
    else
        echo "FAIL: CHILD_A not visible in State2"
        EXIT_CODE=1
    fi

    if grep -q 'CHILD_B' "$DUMP2" 2>/dev/null; then
        echo "FAIL: CHILD_B still visible in State2 (orphaned)"
        EXIT_CODE=1
    else
        echo "PASS: CHILD_B absent in State2"
    fi

    if grep -q 'CHILD_C' "$DUMP2" 2>/dev/null; then
        echo "FAIL: CHILD_C still visible in State2 (should be removed)"
        EXIT_CODE=1
    else
        echo "PASS: CHILD_C removed in State2"
    fi
else
    echo "FAIL: Could not dump view hierarchy (State2)"
    EXIT_CODE=1
fi

"$ADB" -s "$EMULATOR_SERIAL" uninstall "$PACKAGE" 2>/dev/null || true

exit $EXIT_CODE
