#!/usr/bin/env bash
# Android buttons test: 5-tap sequence (+, +, -, -, -) verifying counter state transitions.
#
# Required env vars (set by emulator-all.nix harness):
#   ADB, EMULATOR_SERIAL, COUNTER_APK, PACKAGE, ACTIVITY, WORK_DIR
set -euo pipefail
source "$(dirname "$0")/helpers.sh"

EXIT_CODE=0

start_app "$COUNTER_APK" "buttons"

LOGCAT_STREAM_FILE="$WORK_DIR/buttons_log.txt"
: > "$LOGCAT_STREAM_FILE"
"$ADB" -s "$EMULATOR_SERIAL" logcat '*:I' > "$LOGCAT_STREAM_FILE" 2>&1 &
LOGCAT_STREAM_PID=$!

# Wait for initial render
wait_for_logcat "setRoot" 120
WAIT_RC=$?
if [ $WAIT_RC -eq 2 ]; then
    dump_logcat "buttons"
    echo "FATAL: Native library failed to load — aborting"
    kill "$LOGCAT_STREAM_PID" 2>/dev/null || true
    exit 1
fi

wait_for_ui_text "Counter: 0" 30 || true
assert_ui_text "Counter: 0" "Counter: 0 at start"

# tap BUTTON EXPECTED LABEL FALLBACK_X
tap() {
    echo "=== $3: $1 (expect $2) ==="
    tap_button "$1" || "$ADB" -s "$EMULATOR_SERIAL" shell input tap "$4" 600
    wait_for_ui_text "$2" 15 || true
    assert_ui_text "$2" "$2 after $3"
}

tap "+" "Counter: 1" "tap 1" 300
tap "+" "Counter: 2" "tap 2" 300
tap "-" "Counter: 1" "tap 3" 700
tap "-" "Counter: 0" "tap 4" 700
tap "-" "Counter: -1" "tap 5" 700

kill "$LOGCAT_STREAM_PID" 2>/dev/null || true
"$ADB" -s "$EMULATOR_SERIAL" uninstall "$PACKAGE" 2>/dev/null || true

exit $EXIT_CODE
