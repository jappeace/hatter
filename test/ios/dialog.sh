#!/usr/bin/env bash
# iOS dialog test: install app, auto-tap Show Alert + Show Confirm,
# assert that the callbacks fire with correct results.
#
# --autotest-buttons fires onUIEvent(0) at t+3s (Show Alert) and
# onUIEvent(1) at t+7s (Show Confirm), exercising the dialog round-trip.
# The desktop stub auto-presses button 1, so both return DialogButton1.
# On the actual iOS simulator, UIAlertController is presented and the
# autotest taps the first action.
#
# Required env vars (set by simulator-all.nix harness):
#   SIM_UDID, BUNDLE_ID, DIALOG_APP, WORK_DIR
set -euo pipefail
source "$(dirname "$0")/helpers.sh"

EXIT_CODE=0

xcrun simctl install "$SIM_UDID" "$DIALOG_APP"
echo "Dialog app installed."

STREAM_LOG="$WORK_DIR/dialog_stream.txt"
> "$STREAM_LOG"
xcrun simctl spawn "$SIM_UDID" log stream \
    --level info \
    --predicate "subsystem == \"$BUNDLE_ID\"" \
    --style compact \
    > "$STREAM_LOG" 2>&1 &
LOG_STREAM_PID=$!
sleep 2

xcrun simctl launch "$SIM_UDID" "$BUNDLE_ID" --autotest-buttons

# Wait for the alert result (first callback from the demo app)
wait_for_log "$STREAM_LOG" "Dialog alert result" 60
WAIT_RC=$?
if [ $WAIT_RC -eq 2 ]; then
    dump_ios_log "$STREAM_LOG" "dialog"
    echo "FATAL: Native library failed to load — aborting"
    exit 1
fi

sleep 5
kill "$LOG_STREAM_PID" 2>/dev/null || true
sleep 1

assert_log "$STREAM_LOG" "Dialog alert result: DialogButton1" "alert callback fires with DialogButton1"

xcrun simctl uninstall "$SIM_UDID" "$BUNDLE_ID" 2>/dev/null || true

exit $EXIT_CODE
