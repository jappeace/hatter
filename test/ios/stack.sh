#!/usr/bin/env bash
# iOS stack test: install stack app, launch with --autotest, assert Stack renders and counter increments.
#
# Required env vars (set by simulator-all.nix harness):
#   SIM_UDID, BUNDLE_ID, STACK_APP, WORK_DIR
set -euo pipefail
source "$(dirname "$0")/helpers.sh"

EXIT_CODE=0

start_app "$STACK_APP" "stack" --autotest
wait_for_render "stack" --autotest

# Auto-tap fires 3s after render; poll stream log until counter appears or 30s timeout
wait_for_log "$STREAM_LOG" "Stack counter: 1" 30 || true
# Extra buffer so the persistent log store catches up before log show
sleep 5

collect_logs "stack"

assert_log "$FULL_LOG" 'createNode\(type=9\)' "createNode(type=9)"
assert_log "$FULL_LOG" "setRoot" "setRoot"
assert_log "$FULL_LOG" "Stack counter: 0" "Stack counter initial state"
assert_log "$FULL_LOG" "Stack counter: 1" "Stack counter incremented"

cleanup_app

exit $EXIT_CODE
