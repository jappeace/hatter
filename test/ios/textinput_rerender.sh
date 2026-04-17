#!/usr/bin/env bash
# iOS textinput_rerender test: verify that typing in a TextInput
# triggers a re-render so that a dependent Text widget updates.
#
# Reproduces jappeace/prrrrrrrrr#47.
#
# Uses --autotest-textinput to programmatically fire onUITextChange
# from Swift, bypassing the need for external keyboard injection.
# The Android test verifies the full adb-keyevent path.
#
# Required env vars (set by simulator-all.nix harness):
#   SIM_UDID, BUNDLE_ID, TEXTINPUT_RERENDER_APP, WORK_DIR
set -euo pipefail
source "$(dirname "$0")/helpers.sh"

EXIT_CODE=0

start_app "$TEXTINPUT_RERENDER_APP" "textinput-rerender" --autotest-textinput

wait_for_render "textinput-rerender"

# Wait for the autotest text change (fires 3s after render)
wait_for_log "$STREAM_LOG" "view rebuilt: Typed: hello" 30
WAIT_RC=$?
if [ $WAIT_RC -eq 2 ]; then
    dump_ios_log "$STREAM_LOG" "textinput-rerender"
    echo "FATAL: Native library failed to load — aborting"
    exit 1
fi

sleep 1
collect_logs "textinput-rerender"

# Verify app started and rendered
assert_log "$FULL_LOG" "setRoot" "setRoot rendered"
assert_log "$FULL_LOG" "view rebuilt: Typed:" "Initial render shows empty Typed label"

# Verify the TextInput node was created
assert_log "$FULL_LOG" "createNode.*type=4" "TextInput node created"

# The key assertion: after the simulated text change, the view function
# should have re-rendered with the updated state.
assert_log "$FULL_LOG" "view rebuilt: Typed: hello" "View rebuilt with typed text after OnChange"
assert_log "$FULL_LOG" "setStrProp.*Typed: hello" "Text widget updated to show typed text"

cleanup_app

exit $EXIT_CODE
