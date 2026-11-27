#!/usr/bin/env bash
# Android location test: install location APK, launch app, verify GPS
# updates flow through the bridge.
#
# Required env vars (set by emulator-all.nix harness):
#   ADB, EMULATOR_SERIAL, LOCATION_APK, PACKAGE, ACTIVITY, WORK_DIR
set -euo pipefail
source "$(dirname "$0")/helpers.sh"

EXIT_CODE=0

start_app "$LOCATION_APK" "location"

wait_for_logcat "setRoot" 120 || true
wait_for_logcat "setHandler" 30 || true

# Grant location permission
"$ADB" -s "$EMULATOR_SERIAL" shell pm grant "$PACKAGE" android.permission.ACCESS_FINE_LOCATION 2>/dev/null || true

# Tap Start Location button
tap_button "Start Location" || { echo "WARNING: could not tap Start Location"; }
sleep 1

# Inject GPS fix: geo fix takes lon lat alt (longitude first!)
"$ADB" -s "$EMULATOR_SERIAL" emu geo fix 4.90 52.37 0.0 2>/dev/null || true
wait_for_logcat "Location:.*52.3" 15 || true

# Re-dump logcat to capture location update
collect_logcat "location"
assert_logcat "$LOGCAT_FILE" "Location:.*52.3" "Latitude appears in log"
assert_logcat "$LOGCAT_FILE" "Location:.*4.9" "Longitude appears in log"

# Tap Stop Location button
tap_button "Stop Location" || { echo "WARNING: could not tap Stop Location"; }
sleep 1

# Inject another GPS fix with different coords
"$ADB" -s "$EMULATOR_SERIAL" emu geo fix 5.0 53.0 0.0 2>/dev/null || true
sleep 3

# Verify new coords do NOT appear (listener was stopped)
LOGCAT_FILE2="$WORK_DIR/location_logcat2.txt"
"$ADB" -s "$EMULATOR_SERIAL" logcat -d '*:I' > "$LOGCAT_FILE2" 2>&1 || true
if grep -q "Location:.*53.0" "$LOGCAT_FILE2" 2>/dev/null; then
    echo "WARNING: Location update received after stop (may be delayed delivery)"
fi

# Verify no crash
LOGCAT_ERR="$WORK_DIR/location_logcat_err.txt"
"$ADB" -s "$EMULATOR_SERIAL" logcat -d '*:E' > "$LOGCAT_ERR" 2>&1 || true
if grep -qE "$FATAL_PATTERNS" "$LOGCAT_ERR" 2>/dev/null; then
    echo "FAIL: Fatal crash detected during location test"
    grep -E "$FATAL_PATTERNS" "$LOGCAT_ERR" | tail -10
    EXIT_CODE=1
else
    echo "PASS: No crash during location test"
fi

# Stop from an OS thread other than the UI's, as an app's timeout does: no
# crash (CheckJNI aborts on a JNIEnv used from the wrong thread), and no fix
# after.
"$ADB" -s "$EMULATOR_SERIAL" logcat -c
tap_button "Start Location" || { echo "FAIL: could not tap Start Location"; EXIT_CODE=1; }
sleep 1
tap_button "Stop Location From Thread" || { echo "FAIL: could not tap Stop Location From Thread"; EXIT_CODE=1; }
wait_for_logcat "Location updates stopped from a thread" 15 || true
sleep 2
"$ADB" -s "$EMULATOR_SERIAL" emu geo fix 6.0 54.0 0.0 2>/dev/null || true
sleep 3
LOGCAT_FILE3="$WORK_DIR/location_logcat3.txt"
"$ADB" -s "$EMULATOR_SERIAL" logcat -d '*:I' > "$LOGCAT_FILE3" 2>&1 || true
assert_logcat "$LOGCAT_FILE3" "Location updates stopped from a thread" "Stopped from another thread"
if grep -q "Location:.*54.0" "$LOGCAT_FILE3"; then
    echo "FAIL: Location update received after stopping from another thread"
    EXIT_CODE=1
fi
if grep -qE "$FATAL_PATTERNS|JNI DETECTED ERROR" "$LOGCAT_FILE3"; then
    echo "FAIL: Crash stopping location updates from another thread"
    grep -E "$FATAL_PATTERNS|JNI DETECTED ERROR" "$LOGCAT_FILE3" | tail -10
    EXIT_CODE=1
fi

"$ADB" -s "$EMULATOR_SERIAL" uninstall "$PACKAGE" 2>/dev/null || true

exit $EXIT_CODE
