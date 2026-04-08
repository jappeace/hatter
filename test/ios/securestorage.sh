#!/usr/bin/env bash
# iOS secure storage test: install app, auto-tap Store Token + Read Token,
# assert that the write and read callbacks fire with correct results.
#
# --autotest-buttons fires onUIEvent(0) at t+3s (Store Token) and
# onUIEvent(1) at t+7s (Read Token), exercising the Keychain round-trip.
#
# Required env vars (set by simulator-all.nix harness):
#   SIM_UDID, BUNDLE_ID, SECURE_STORAGE_APP, WORK_DIR
set -euo pipefail
source "$(dirname "$0")/helpers.sh"

EXIT_CODE=0

xcrun simctl install "$SIM_UDID" "$SECURE_STORAGE_APP"
echo "SecureStorage app installed."

STREAM_LOG="$WORK_DIR/securestorage_stream.txt"
> "$STREAM_LOG"
xcrun simctl spawn "$SIM_UDID" log stream \
    --level info \
    --predicate "subsystem == \"$BUNDLE_ID\"" \
    --style compact \
    > "$STREAM_LOG" 2>&1 &
LOG_STREAM_PID=$!
sleep 2

xcrun simctl launch "$SIM_UDID" "$BUNDLE_ID" --autotest-buttons

# Wait for the read result (last meaningful log from the demo app)
wait_for_log "$STREAM_LOG" "SecureStorage read result" 60
WAIT_RC=$?
if [ $WAIT_RC -eq 2 ]; then
    dump_ios_log "$STREAM_LOG" "securestorage"
    echo "FATAL: Native library failed to load — aborting"
    exit 1
fi

# Give the stream a moment to flush
sleep 2
kill "$LOG_STREAM_PID" 2>/dev/null || true
sleep 1

# Dump the stream log for CI debugging
echo "=== Stream log contents (last 30 lines) ==="
tail -30 "$STREAM_LOG"
echo "=== End stream log ==="

# Assert against the stream log (log show often misses platformLog entries)
assert_log "$STREAM_LOG" "SecureStorage write result: StorageSuccess" "write callback fires with StorageSuccess"
assert_log "$STREAM_LOG" "SecureStorage read result: StorageSuccess" "read callback fires with StorageSuccess"
assert_log "$STREAM_LOG" "test-token-12345" "read returns written token value"

xcrun simctl uninstall "$SIM_UDID" "$BUNDLE_ID" 2>/dev/null || true

exit $EXIT_CODE
