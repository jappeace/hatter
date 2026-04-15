#!/usr/bin/env bash
# watchOS column-child-removal test: removing children from a Column.
#
# Tests the childrenStable optimization in diffContainer.
# Cycles: [A,B,C] → [A,C] → [A]
#
# --autotest fires callbackId=0 (the Advance button) after 3s.
#
# Required env vars (set by watchos-simulator-all.nix harness):
#   SIM_UDID, BUNDLE_ID, LOG_SUBSYSTEM, COLUMN_CHILD_REMOVAL_APP, WORK_DIR
set -euo pipefail
source "$(dirname "$0")/helpers.sh"

EXIT_CODE=0

start_app "$COLUMN_CHILD_REMOVAL_APP" "column-child-removal" --autotest
wait_for_render "column-child-removal" --autotest

# --autotest fires onUIEvent(0) at +3s — wait for State1
wait_for_log "$STREAM_LOG" "Column state: State1" 30 || true
sleep 5

collect_logs "column-child-removal"

assert_log "$FULL_LOG" "setRoot" "setRoot called"
assert_log "$FULL_LOG" "Column state: State0" "Initial state is State0"
assert_log "$FULL_LOG" "Column state: State1" "Advanced to State1"

cleanup_app

exit $EXIT_CODE
