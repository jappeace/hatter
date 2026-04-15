#!/usr/bin/env bash
# iOS styled-type-change test: Styled wrapper with child type change.
#
# Tests that when a Styled wrapper's child changes type (Text→Button)
# but the style stays the same, the new native node receives the styling.
#
# State0: Styled redBackground (Text "STYLED_TEXT")
# State1: Styled redBackground (Button "STYLED_BUTTON")
#
# --autotest fires callbackId=0 (the switch button) after 3s.
#
# Required env vars (set by simulator-all.nix harness):
#   SIM_UDID, BUNDLE_ID, STYLED_TYPE_CHANGE_APP, WORK_DIR
set -euo pipefail
source "$(dirname "$0")/helpers.sh"

EXIT_CODE=0

start_app "$STYLED_TYPE_CHANGE_APP" "styled-type-change" --autotest
wait_for_render "styled-type-change" --autotest

# --autotest fires onUIEvent(0) at +3s — wait for the screen switch
wait_for_log "$STREAM_LOG" "Current screen: ScreenB" 30 || true
sleep 5

collect_logs "styled-type-change"

assert_log "$FULL_LOG" "setRoot" "setRoot called"
assert_log "$FULL_LOG" "Current screen: ScreenA" "Initial screen is ScreenA"
assert_log "$FULL_LOG" "Current screen: ScreenB" "Switched to ScreenB"

cleanup_app

exit $EXIT_CODE
