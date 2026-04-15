#!/usr/bin/env bash
# watchOS stack-zorder test: Stack (FrameLayout) z-order after child mutations.
#
# Tests that Stack renders with correct z-order and buttons are tappable.
#
# State0: Stack [BG_LAYER, TAP_TARGET] — button on top, tappable
#
# --autotest fires callbackId=0 (the TAP_TARGET button) after 3s,
# which increments the tap counter and logs the count.
#
# Required env vars (set by watchos-simulator-all.nix harness):
#   SIM_UDID, BUNDLE_ID, LOG_SUBSYSTEM, STACK_ZORDER_APP, WORK_DIR
set -euo pipefail
source "$(dirname "$0")/helpers.sh"

EXIT_CODE=0

start_app "$STACK_ZORDER_APP" "stack-zorder" --autotest
wait_for_render "stack-zorder" --autotest

# --autotest fires onUIEvent(0) at +3s — the tap action, logs "Stack button tapped: 1"
wait_for_log "$STREAM_LOG" "Stack button tapped: 1" 30 || true
sleep 5

collect_logs "stack-zorder"

assert_log "$FULL_LOG" "setRoot" "setRoot called"
assert_log "$FULL_LOG" "Stack state: ButtonOnTop" "Initial state is ButtonOnTop"
assert_log "$FULL_LOG" "Stack button tapped: 1" "TAP_TARGET button tapped successfully"

cleanup_app

exit $EXIT_CODE
