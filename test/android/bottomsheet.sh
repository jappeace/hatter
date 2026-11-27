#!/usr/bin/env bash
# Android bottom sheet test: install APK, tap Show Actions, tap Edit item,
# and assert that the callback fires correctly.
#
# Required env vars (set by emulator-all.nix harness):
#   ADB, EMULATOR_SERIAL, BOTTOM_SHEET_APK, PACKAGE, ACTIVITY, WORK_DIR
set -euo pipefail
source "$(dirname "$0")/helpers.sh"

EXIT_CODE=0

start_app "$BOTTOM_SHEET_APK" "bottomsheet"

wait_for_logcat "setRoot" 120 || true
wait_for_logcat "setHandler" 30 || true

# Tap the "Show Actions" button
tap_button "Show Actions" || { echo "FAIL: could not tap Show Actions"; EXIT_CODE=1; }
sleep 1

# Tap "Edit" in the bottom sheet
tap_button "Edit" || { echo "FAIL: could not tap Edit"; EXIT_CODE=1; }
wait_for_logcat "BottomSheet result" 15 || true

collect_logcat "bottomsheet"

assert_logcat "$LOGCAT_FILE" "BottomSheet result: BottomSheetItemSelected 0" "bottom sheet callback fires with BottomSheetItemSelected 0"

# Turning the screen recreates the activity: the sheet stays and still answers.
"$ADB" -s "$EMULATOR_SERIAL" logcat -c
tap_button "Show Actions" || { echo "FAIL: could not tap Show Actions"; EXIT_CODE=1; }
sleep 1
turn_screen 1
wait_for_logcat "Android bottom sheet bridge initialized" 30 || true
sleep 2
tap_button "Edit" || { echo "FAIL: could not tap Edit after turning"; EXIT_CODE=1; }
wait_for_logcat "BottomSheet result" 15 || true
turn_screen 0

LOGCAT_FILE2="$WORK_DIR/bottomsheet_logcat2.txt"
"$ADB" -s "$EMULATOR_SERIAL" logcat -d '*:I' > "$LOGCAT_FILE2" 2>&1

assert_logcat "$LOGCAT_FILE2" "BottomSheet result: BottomSheetItemSelected 0" "bottom sheet answers after the activity is recreated"

"$ADB" -s "$EMULATOR_SERIAL" uninstall "$PACKAGE" 2>/dev/null || true

exit $EXIT_CODE
