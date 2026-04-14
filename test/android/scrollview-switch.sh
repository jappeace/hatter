#!/usr/bin/env bash
# Android scrollview-switch test: reproducer for issue #168.
#
# Installs the ScrollView switch demo APK, verifies ScreenA renders,
# taps "Switch screen" to go to ScreenB, then asserts:
#   1. ScreenB items are present in the view hierarchy
#   2. ScreenA items are ABSENT (the bug: leftover views from old screen)
#
# Required env vars (set by emulator-all.nix harness):
#   ADB, EMULATOR_SERIAL, SCROLLVIEW_SWITCH_APK, PACKAGE, ACTIVITY, WORK_DIR
set -euo pipefail
source "$(dirname "$0")/helpers.sh"

EXIT_CODE=0

start_app "$SCROLLVIEW_SWITCH_APK" "scrollview-switch"
wait_for_render "scrollview-switch"
sleep 5
collect_logcat "scrollview-switch-initial"

assert_logcat "$LOGCAT_FILE" "Current screen: ScreenA" "Initial screen is ScreenA"
assert_logcat "$LOGCAT_FILE" "setRoot" "setRoot"

# Verify ScreenA items visible in view hierarchy
DUMP_A="$WORK_DIR/svswitch_a.xml"
dump_ok=0
for attempt in 1 2 3; do
    if "$ADB" -s "$EMULATOR_SERIAL" shell uiautomator dump /data/local/tmp/ui.xml 2>&1 | grep -q "dumped"; then
        "$ADB" -s "$EMULATOR_SERIAL" pull /data/local/tmp/ui.xml "$DUMP_A" 2>/dev/null
        dump_ok=1
        break
    fi
    sleep 5
done

if [ $dump_ok -eq 1 ]; then
    if grep -q 'SCREENA_ITEM1' "$DUMP_A" 2>/dev/null; then
        echo "PASS: ScreenA items visible before switch"
    else
        echo "FAIL: ScreenA items not visible before switch"
        EXIT_CODE=1
    fi
else
    echo "FAIL: Could not dump view hierarchy (pre-switch)"
    EXIT_CODE=1
fi

# === Switch to ScreenB ===
echo "=== Tapping Switch screen ==="
tap_done=0
if [ $dump_ok -eq 1 ]; then
    tap_button "Switch screen" && tap_done=1 || true
fi
if [ $tap_done -eq 0 ]; then
    echo "Using fallback tap at (540, 100)"
    "$ADB" -s "$EMULATOR_SERIAL" shell input tap 540 100
fi
sleep 5

collect_logcat "scrollview-switch-after"
assert_logcat "$LOGCAT_FILE" "Current screen: ScreenB" "Switched to ScreenB"

# Dump view hierarchy AFTER switch
DUMP_B="$WORK_DIR/svswitch_b.xml"
dump_ok_b=0
for attempt in 1 2 3; do
    if "$ADB" -s "$EMULATOR_SERIAL" shell uiautomator dump /data/local/tmp/ui.xml 2>&1 | grep -q "dumped"; then
        "$ADB" -s "$EMULATOR_SERIAL" pull /data/local/tmp/ui.xml "$DUMP_B" 2>/dev/null
        dump_ok_b=1
        break
    fi
    sleep 5
done

if [ $dump_ok_b -eq 1 ]; then
    echo "=== Post-switch view hierarchy ==="
    cat "$DUMP_B"
    echo ""
    echo "=== End hierarchy ==="

    # ScreenB items must be present
    if grep -q 'SCREENB_ITEM1' "$DUMP_B" 2>/dev/null; then
        echo "PASS: ScreenB items visible after switch"
    else
        echo "FAIL: ScreenB items not visible after switch"
        EXIT_CODE=1
    fi

    # ScreenA items must be GONE — this is the bug check
    if grep -q 'SCREENA_ITEM' "$DUMP_B" 2>/dev/null; then
        echo "FAIL: ScreenA items still visible after switch (BUG #168)"
        EXIT_CODE=1
    else
        echo "PASS: ScreenA items removed after switch"
    fi
else
    echo "FAIL: Could not dump view hierarchy (post-switch)"
    EXIT_CODE=1
fi

"$ADB" -s "$EMULATOR_SERIAL" uninstall "$PACKAGE" 2>/dev/null || true

exit $EXIT_CODE
