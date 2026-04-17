#!/usr/bin/env bash
# Android network status test: install network-status APK, launch app,
# verify the network status bridge fires callbacks.
#
# The emulator always has network connectivity, so the bridge should
# report connected=True with some transport type.
#
# Required env vars (set by emulator-all.nix harness):
#   ADB, EMULATOR_SERIAL, NETWORK_STATUS_APK, PACKAGE, ACTIVITY, WORK_DIR
set -euo pipefail
source "$(dirname "$0")/helpers.sh"

EXIT_CODE=0

install_apk "$NETWORK_STATUS_APK" || { echo "FAIL: install_apk"; exit 1; }

"$ADB" -s "$EMULATOR_SERIAL" logcat -c
"$ADB" -s "$EMULATOR_SERIAL" shell am start -n "$PACKAGE/$ACTIVITY"

wait_for_logcat "setRoot" 120 || true
wait_for_logcat "setHandler" 30 || true

# Tap Start Monitoring button
tap_button "Start Monitoring" || { echo "WARNING: could not tap Start Monitoring"; }
wait_for_logcat "Network monitoring started" 15 || true

# Dump logcat to check for network status callback
LOGCAT_FILE="$WORK_DIR/networkstatus_logcat.txt"
"$ADB" -s "$EMULATOR_SERIAL" logcat -d '*:I' > "$LOGCAT_FILE" 2>&1 || true
assert_logcat "$LOGCAT_FILE" "Network monitoring started" "Network monitoring started"
assert_logcat "$LOGCAT_FILE" "Network:.*connected=" "Network status callback fired"

# Tap Stop Monitoring button
tap_button "Stop Monitoring" || { echo "WARNING: could not tap Stop Monitoring"; }
wait_for_logcat "Network monitoring stopped" 15 || true

LOGCAT_FILE2="$WORK_DIR/networkstatus_logcat2.txt"
"$ADB" -s "$EMULATOR_SERIAL" logcat -d '*:I' > "$LOGCAT_FILE2" 2>&1 || true
assert_logcat "$LOGCAT_FILE2" "Network monitoring stopped" "Network monitoring stopped"

# Verify no crash
LOGCAT_ERR="$WORK_DIR/networkstatus_logcat_err.txt"
"$ADB" -s "$EMULATOR_SERIAL" logcat -d '*:E' > "$LOGCAT_ERR" 2>&1 || true
if grep -qE "$FATAL_PATTERNS" "$LOGCAT_ERR" 2>/dev/null; then
    echo "FAIL: Fatal crash detected during network status test"
    grep -E "$FATAL_PATTERNS" "$LOGCAT_ERR" | tail -10
    EXIT_CODE=1
else
    echo "PASS: No crash during network status test"
fi

"$ADB" -s "$EMULATOR_SERIAL" uninstall "$PACKAGE" 2>/dev/null || true

exit $EXIT_CODE
