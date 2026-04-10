#!/usr/bin/env bash
# watchOS bottom sheet test: install app, auto-tap Show Actions,
# assert that the callback fires with correct result.
#
# --autotest-buttons fires onUIEvent(0) at t+3s (Show Actions),
# exercising the bottom sheet round-trip via SwiftUI .confirmationDialog().
#
# Required env vars (set by watchos-simulator-all.nix harness):
#   SIM_UDID, BUNDLE_ID, BOTTOM_SHEET_APP, WORK_DIR, LOG_SUBSYSTEM
set -euo pipefail
source "$(dirname "$0")/helpers.sh"

EXIT_CODE=0

xcrun simctl install "$SIM_UDID" "$BOTTOM_SHEET_APP"
echo "BottomSheet app installed."

STREAM_LOG="$WORK_DIR/bottomsheet_stream.txt"
> "$STREAM_LOG"
xcrun simctl spawn "$SIM_UDID" log stream \
    --level info \
    --predicate "subsystem == \"$LOG_SUBSYSTEM\"" \
    --style compact \
    > "$STREAM_LOG" 2>&1 &
LOG_STREAM_PID=$!
sleep 2

xcrun simctl launch "$SIM_UDID" "$BUNDLE_ID" --autotest-buttons

# Wait for the bottom sheet result
wait_for_log "$STREAM_LOG" "BottomSheet result" 60 || true

sleep 2
kill "$LOG_STREAM_PID" 2>/dev/null || true
sleep 1

assert_log "$STREAM_LOG" "BottomSheet result: BottomSheetItemSelected 0" "bottom sheet callback fires with BottomSheetItemSelected 0"

xcrun simctl uninstall "$SIM_UDID" "$BUNDLE_ID" 2>/dev/null || true

exit $EXIT_CODE
