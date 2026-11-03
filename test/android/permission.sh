#!/usr/bin/env bash
# Android permission test: install permission APK, pre-grant camera, tap button,
# assert that the permission result callback fires.
#
# Required env vars (set by emulator-all.nix harness):
#   ADB, EMULATOR_SERIAL, PERMISSION_APK, PACKAGE, ACTIVITY, WORK_DIR
set -euo pipefail
source "$(dirname "$0")/helpers.sh"

EXIT_CODE=0

start_app "$PERMISSION_APK" "permission"

# Pre-grant camera permission so the system dialog does not appear
"$ADB" -s "$EMULATOR_SERIAL" shell pm grant "$PACKAGE" android.permission.CAMERA

wait_for_logcat "setRoot" 120 || true
wait_for_logcat "setHandler" 30 || true

# Tap the "Request Camera" button
tap_button "Request Camera" || { echo "FAIL: could not tap Request Camera"; EXIT_CODE=1; }
wait_for_logcat "Permission result" 15 || true

collect_logcat "permission"

assert_logcat "$LOGCAT_FILE" "Permission result: PermissionGranted" "permission callback fires with PermissionGranted"
assert_logcat "$LOGCAT_FILE" "permission_request\|PermissionBridge" "permission bridge log present"

# Approximate location only, as a user may allow: that grants location.
"$ADB" -s "$EMULATOR_SERIAL" shell pm grant "$PACKAGE" android.permission.ACCESS_COARSE_LOCATION
tap_button "Request Location" || { echo "FAIL: could not tap Request Location"; EXIT_CODE=1; }
wait_for_logcat "Location permission result" 15 || true
collect_logcat "permission_location"
assert_logcat "$LOGCAT_FILE" "Location permission result: PermissionGranted" "approximate location grants PermissionLocation"

"$ADB" -s "$EMULATOR_SERIAL" uninstall "$PACKAGE" 2>/dev/null || true

exit $EXIT_CODE
