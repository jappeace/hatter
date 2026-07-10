#!/usr/bin/env bash
# iOS BLE test: install BLE app, launch with --autotest --autotest-ble,
# verify adapter check runs, the connect bridge round-trips, and the
# app doesn't crash.
#
# The iOS simulator has no CoreBluetooth support (the adapter reports
# Unsupported and scans find nothing), so BLE traffic cannot be
# simulated here; that end-to-end path is covered by the Android
# emulator test (test/android/ble.sh + netsim + bumble).  What this
# test does prove: the connect API reaches the CoreBluetooth bridge
# and fails visibly with BleConnectionFailed instead of hanging or
# crashing.
#
# Required env vars (set by simulator-all.nix harness):
#   SIM_UDID, BUNDLE_ID, BLE_APP, WORK_DIR
set -euo pipefail
source "$(dirname "$0")/helpers.sh"

EXIT_CODE=0

start_app "$BLE_APP" "ble" --autotest --autotest-ble
wait_for_render "ble" --autotest
wait_for_log "$STREAM_LOG" "BLE adapter:" 30 || true
wait_for_log "$STREAM_LOG" "BLE connection event:" 60 || true
collect_logs "ble"

assert_log "$FULL_LOG" "BLE adapter:" "BLE adapter check logged"
assert_log "$FULL_LOG" "BLE connection event: BleConnectionFailed" \
    "connect on simulator fails visibly through the bridge"
assert_log "$FULL_LOG" "createNode" "createNode called (app renders)"
assert_log "$FULL_LOG" "setRoot" "setRoot"

cleanup_app

exit $EXIT_CODE
