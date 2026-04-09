#!/usr/bin/env bash
# iOS location test: install location app, launch with --autotest, verify
# location bridge initialises and app doesn't crash.
#
# On simulator, location can be simulated via `xcrun simctl location`.
#
# Required env vars (set by simulator-all.nix harness):
#   SIM_UDID, BUNDLE_ID, LOCATION_APP, WORK_DIR
set -euo pipefail
source "$(dirname "$0")/helpers.sh"

EXIT_CODE=0

xcrun simctl install "$SIM_UDID" "$LOCATION_APP"
echo "Location app installed."

# Set simulated location before launch
xcrun simctl location "$SIM_UDID" set 52.37,4.90 2>/dev/null || true

LOC_START=$(date "+%Y-%m-%d %H:%M:%S")

STREAM_LOG="$WORK_DIR/location_stream.txt"
> "$STREAM_LOG"
xcrun simctl spawn "$SIM_UDID" log stream \
    --level info \
    --predicate "subsystem == \"$BUNDLE_ID\"" \
    --style compact \
    > "$STREAM_LOG" 2>&1 &
LOG_STREAM_PID=$!
sleep 5

xcrun simctl launch "$SIM_UDID" "$BUNDLE_ID" --autotest

render_done=0
wait_for_log "$STREAM_LOG" "setRoot" 60 && render_done=1 || true

if [ $render_done -eq 0 ]; then
    echo "WARNING: setRoot not found — retrying with relaunch"
    xcrun simctl terminate "$SIM_UDID" "$BUNDLE_ID" 2>/dev/null || true
    sleep 3
    > "$STREAM_LOG"
    xcrun simctl launch "$SIM_UDID" "$BUNDLE_ID" --autotest
    wait_for_log "$STREAM_LOG" "setRoot" 60 || true
fi

sleep 10

kill "$LOG_STREAM_PID" 2>/dev/null || true
sleep 1

FULL_LOG="$WORK_DIR/location_full.txt"
get_full_log "$LOC_START" "$FULL_LOG"

if ! grep -q "setRoot" "$FULL_LOG" 2>/dev/null; then
    echo "  'log show' empty/incomplete, using stream log"
    FULL_LOG="$STREAM_LOG"
fi

assert_log "$FULL_LOG" "Location demo app registered" "Location demo app started"
assert_log "$FULL_LOG" "createNode" "createNode called (app renders)"
assert_log "$FULL_LOG" "setRoot" "setRoot"

xcrun simctl uninstall "$SIM_UDID" "$BUNDLE_ID" 2>/dev/null || true

exit $EXIT_CODE
