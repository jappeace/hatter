#!/usr/bin/env bash
# Android device info test: install device-info APK, launch app,
# verify device information is retrieved and logged.
#
# Required env vars (set by emulator-all.nix harness):
#   ADB, EMULATOR_SERIAL, DEVICE_INFO_APK, PACKAGE, ACTIVITY, WORK_DIR
set -euo pipefail
source "$(dirname "$0")/helpers.sh"

EXIT_CODE=0

install_apk "$DEVICE_INFO_APK" || { echo "FAIL: install_apk"; exit 1; }

"$ADB" -s "$EMULATOR_SERIAL" logcat -c
"$ADB" -s "$EMULATOR_SERIAL" shell am start -n "$PACKAGE/$ACTIVITY"

wait_for_logcat "setRoot" 120 || true
wait_for_logcat "DeviceInfo model:" 30 || true

LOGCAT_FILE="$WORK_DIR/deviceinfo_logcat.txt"
"$ADB" -s "$EMULATOR_SERIAL" logcat -d '*:I' > "$LOGCAT_FILE" 2>&1 || true
assert_logcat "$LOGCAT_FILE" "DeviceInfo model:" "DeviceInfo model retrieved"
assert_logcat "$LOGCAT_FILE" "DeviceInfo osVersion:" "DeviceInfo osVersion retrieved"
assert_logcat "$LOGCAT_FILE" "DeviceInfo screenDensity:" "DeviceInfo screenDensity retrieved"
assert_logcat "$LOGCAT_FILE" "DeviceInfo screenWidth:" "DeviceInfo screenWidth retrieved"
assert_logcat "$LOGCAT_FILE" "DeviceInfo screenHeight:" "DeviceInfo screenHeight retrieved"

# Verify no crash
LOGCAT_ERR="$WORK_DIR/deviceinfo_logcat_err.txt"
"$ADB" -s "$EMULATOR_SERIAL" logcat -d '*:E' > "$LOGCAT_ERR" 2>&1 || true
if grep -qE "$FATAL_PATTERNS" "$LOGCAT_ERR" 2>/dev/null; then
    echo "FAIL: Fatal crash detected during device info test"
    grep -E "$FATAL_PATTERNS" "$LOGCAT_ERR" | tail -10
    EXIT_CODE=1
else
    echo "PASS: No crash during device info test"
fi

"$ADB" -s "$EMULATOR_SERIAL" uninstall "$PACKAGE" 2>/dev/null || true

exit $EXIT_CODE
