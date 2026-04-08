#!/usr/bin/env bash
# iOS secure storage test: install app, tap Store Token, tap Read Token,
# assert that the write and read callbacks fire with correct results.
#
# Required env vars (set by simulator-all.nix harness):
#   SIM_UDID, BUNDLE_ID, SECURE_STORAGE_APP, WORK_DIR
set -euo pipefail
source "$(dirname "$0")/helpers.sh"

EXIT_CODE=0

# Install and launch
xcrun simctl install "$SIM_UDID" "$SECURE_STORAGE_APP"
xcrun simctl launch "$SIM_UDID" "$BUNDLE_ID" --autotest-securestorage &
sleep 2

# Start log stream
LOG_FILE="$WORK_DIR/securestorage_ios_log.txt"
xcrun simctl spawn "$SIM_UDID" log stream \
  --predicate 'subsystem == "me.jappie.haskellmobile"' \
  --level info > "$LOG_FILE" 2>&1 &
LOG_PID=$!

wait_for_log "setRoot" 120 || true
sleep 5

# Tap Store Token then Read Token via autotest (buttons dispatched by callback IDs)
# Button 0 = Store Token, Button 1 = Read Token
xcrun simctl launch "$SIM_UDID" "$BUNDLE_ID" --autotest-buttons 2>/dev/null || true
sleep 3

# Get full log
FULL_LOG="$WORK_DIR/securestorage_ios_full_log.txt"
get_full_log "$FULL_LOG"

kill "$LOG_PID" 2>/dev/null || true

# Check both the stream log and the full log
assert_log "$LOG_FILE" "SecureStorage write result: StorageSuccess" "write callback fires with StorageSuccess" || \
  assert_log "$FULL_LOG" "SecureStorage write result: StorageSuccess" "write callback (full log)"
assert_log "$LOG_FILE" "SecureStorage read result: StorageSuccess" "read callback fires with StorageSuccess" || \
  assert_log "$FULL_LOG" "SecureStorage read result: StorageSuccess" "read callback (full log)"
assert_log "$LOG_FILE" "test-token-12345" "read returns written token value" || \
  assert_log "$FULL_LOG" "test-token-12345" "token value (full log)"

xcrun simctl uninstall "$SIM_UDID" "$BUNDLE_ID" 2>/dev/null || true

exit $EXIT_CODE
