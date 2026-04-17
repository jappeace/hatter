#!/usr/bin/env bash
# watchOS textinput_rerender test: verify that typing in a TextInput
# triggers a re-render so that a dependent Text widget updates.
#
# Uses --autotest-textinput to programmatically fire onUITextChange
# from Swift, bypassing the need for external keyboard injection.
#
# Required env vars (set by watchos-simulator-all.nix harness):
#   SIM_UDID, BUNDLE_ID, TEXTINPUT_RERENDER_APP, WORK_DIR
set -euo pipefail
source "$(dirname "$0")/helpers.sh"

EXIT_CODE=0

start_app "$TEXTINPUT_RERENDER_APP" "textinput-rerender" --autotest-textinput

wait_for_render "textinput-rerender"

# Wait for the autotest text change (fires 3s after render)
wait_for_log "$STREAM_LOG" "view rebuilt: Typed: hello" 30 || true

sleep 1
collect_logs "textinput-rerender"

assert_log "$FULL_LOG" "setRoot" "setRoot rendered"
assert_log "$FULL_LOG" "view rebuilt: Typed:" "Initial view shows Typed label"

# The key assertion: after the simulated text change, the view function
# should have re-rendered with the updated state.
assert_log "$FULL_LOG" "view rebuilt: Typed: hello" "View rebuilt with typed text after OnChange"

cleanup_app

exit $EXIT_CODE
