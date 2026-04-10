#!/usr/bin/env bash
# Android HTTP test: install HTTP demo APK, launch, assert bridge initializes.
#
# On the Android emulator, the demo app renders a "Send Request" button.
# We tap the button which fires a GET to http://localhost:8765/
# (exposed via adb reverse). A local Python HTTP server is started
# by the harness in emulator-all.nix.
#
# Required env vars (set by emulator-all.nix harness):
#   ADB, EMULATOR_SERIAL, HTTP_APK, PACKAGE, ACTIVITY, WORK_DIR
set -euo pipefail
source "$(dirname "$0")/helpers.sh"

EXIT_CODE=0

install_apk "$HTTP_APK" || { echo "FAIL: install_apk"; exit 1; }

"$ADB" -s "$EMULATOR_SERIAL" logcat -c
"$ADB" -s "$EMULATOR_SERIAL" shell am start -n "$PACKAGE/$ACTIVITY"

wait_for_logcat "setRoot" 120
WAIT_RC=$?
if [ $WAIT_RC -eq 2 ]; then
    dump_logcat "http"
    echo "FATAL: Native library failed to load — aborting"
    exit 1
fi
sleep 5

LOGCAT_FILE="$WORK_DIR/http_logcat.txt"
"$ADB" -s "$EMULATOR_SERIAL" logcat -d '*:I' > "$LOGCAT_FILE" 2>&1 || true

# Bridge initialized
assert_logcat "$LOGCAT_FILE" "HTTP bridge initialized" "HTTP bridge initialized"

# setRoot called (demo UI rendered)
assert_logcat "$LOGCAT_FILE" "setRoot" "setRoot called"

# Demo app registered
assert_logcat "$LOGCAT_FILE" "HTTP demo app registered" "demo app registered"

# Tap the "Send Request" button to fire an HTTP request
"$ADB" -s "$EMULATOR_SERIAL" logcat -c
tap_button "Send Request" || echo "WARNING: could not tap Send Request button"
sleep 5

LOGCAT_FILE2="$WORK_DIR/http_logcat2.txt"
"$ADB" -s "$EMULATOR_SERIAL" logcat -d '*:I' > "$LOGCAT_FILE2" 2>&1 || true

# HTTP response logged
assert_logcat "$LOGCAT_FILE2" "HTTP response: 200" "HTTP response 200"

"$ADB" -s "$EMULATOR_SERIAL" uninstall "$PACKAGE" 2>/dev/null || true

exit $EXIT_CODE
