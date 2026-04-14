#!/usr/bin/env bash
# Android stack test: install stack APK, assert Stack (FrameLayout) renders, tap overlay button.
#
# Required env vars (set by emulator-all.nix harness):
#   ADB, EMULATOR_SERIAL, STACK_APK, PACKAGE, ACTIVITY, WORK_DIR
set -euo pipefail
source "$(dirname "$0")/helpers.sh"

EXIT_CODE=0

start_app "$STACK_APK" "stack"
wait_for_render "stack"
sleep 5
collect_logcat "stack"

assert_logcat "$LOGCAT_FILE" "createNode.*type=9" "createNode(type=9) stack view"
assert_logcat "$LOGCAT_FILE" "setRoot" "setRoot"
assert_logcat "$LOGCAT_FILE" "Stack counter: 0" "Stack counter initial state"

# Verify FrameLayout in view hierarchy
STACK_DUMP="$WORK_DIR/stack_ui.xml"
stack_dump_ok=0
for attempt in 1 2 3; do
    if "$ADB" -s "$EMULATOR_SERIAL" shell uiautomator dump /data/local/tmp/ui.xml 2>&1 | grep -q "dumped"; then
        "$ADB" -s "$EMULATOR_SERIAL" pull /data/local/tmp/ui.xml "$STACK_DUMP" 2>/dev/null
        stack_dump_ok=1
        break
    fi
    echo "  uiautomator dump attempt $attempt failed, retrying in 5s..."
    sleep 5
done

if [ $stack_dump_ok -eq 1 ]; then
    if grep -q 'android.widget.FrameLayout' "$STACK_DUMP" 2>/dev/null; then
        echo "PASS: android.widget.FrameLayout in view hierarchy"
    else
        echo "FAIL: android.widget.FrameLayout not in view hierarchy"
        EXIT_CODE=1
    fi
else
    echo "FAIL: Could not dump stack view hierarchy"
    EXIT_CODE=1
fi

# Tap the overlay button
echo "=== Tap overlay button ==="
tap_done=0
if [ $stack_dump_ok -eq 1 ]; then
    tap_button "Tap overlay" && tap_done=1 || true
fi
if [ $tap_done -eq 0 ]; then
    echo "Using fallback tap at (540, 400)"
    "$ADB" -s "$EMULATOR_SERIAL" shell input tap 540 400
fi
sleep 5

collect_logcat "stack"
assert_logcat "$LOGCAT_FILE" "Stack counter: 1" "Stack counter incremented"

"$ADB" -s "$EMULATOR_SERIAL" uninstall "$PACKAGE" 2>/dev/null || true

exit $EXIT_CODE
