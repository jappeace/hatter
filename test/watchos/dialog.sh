#!/usr/bin/env bash
# watchOS dialog test: install app, auto-tap Show Alert,
# assert that the callback fires with correct result.
#
# --autotest-buttons fires onUIEvent(0) at t+3s (Show Alert),
# exercising the dialog round-trip via SwiftUI .alert().
#
# Required env vars (set by watchos-simulator-all.nix harness):
#   SIM_UDID, BUNDLE_ID, DIALOG_APP, WORK_DIR, LOG_SUBSYSTEM
set -euo pipefail
source "$(dirname "$0")/helpers.sh"

EXIT_CODE=0

xcrun simctl install "$SIM_UDID" "$DIALOG_APP"
echo "Dialog app installed."

STREAM_LOG="$WORK_DIR/dialog_stream.txt"
> "$STREAM_LOG"
xcrun simctl spawn "$SIM_UDID" log stream \
    --level info \
    --predicate "subsystem == \"$LOG_SUBSYSTEM\"" \
    --style compact \
    > "$STREAM_LOG" 2>&1 &
LOG_STREAM_PID=$!
sleep 2

xcrun simctl launch "$SIM_UDID" "$BUNDLE_ID" --autotest-buttons

# Wait for the alert result
wait_for_log "$STREAM_LOG" "Dialog alert result" 60 || true

sleep 2
kill "$LOG_STREAM_PID" 2>/dev/null || true
sleep 1

assert_log "$STREAM_LOG" "Dialog alert result: DialogButton1" "alert callback fires with DialogButton1"

xcrun simctl uninstall "$SIM_UDID" "$BUNDLE_ID" 2>/dev/null || true

exit $EXIT_CODE
