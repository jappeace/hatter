#!/usr/bin/env bash
# Android BLE test: install BLE APK, launch app, verify adapter check
# runs and start/stop scan don't crash.
#
# When BLE_SIM=1 (API 33+ emulator with netsim virtual Bluetooth,
# see emulator-all.nix) the test additionally:
#   - starts a virtual BLE peripheral (ble_peripheral.py via bumble)
#     in the emulator's netsim radio scene,
#   - asserts the hatter scan callback receives its advertisement
#     ("BLE scan result: ... HatterBleSim ..."),
#   - connects to it from hatter code and asserts the connection
#     round trip (BleConnectionEstablished / BleConnectionClosed).
#
# Required env vars (set by emulator-all.nix harness):
#   ADB, EMULATOR_SERIAL, BLE_APK, PACKAGE, ACTIVITY, WORK_DIR
# Additionally when BLE_SIM=1:
#   BUMBLE_PYTHON: python interpreter with the bumble package
set -euo pipefail
source "$(dirname "$0")/helpers.sh"

EXIT_CODE=0
BLE_SIM="${BLE_SIM:-0}"
PERIPHERAL_PID=""

cleanup_peripheral() {
    if [ -n "$PERIPHERAL_PID" ] && kill -0 "$PERIPHERAL_PID" 2>/dev/null; then
        kill "$PERIPHERAL_PID" 2>/dev/null || true
        wait "$PERIPHERAL_PID" 2>/dev/null || true
    fi
}
trap cleanup_peripheral EXIT

# ensure_guest_bluetooth_on
# The netsim-backed adapter is normally on after boot, but the stack
# can wedge on a slow emulator (startup-timeout SIGABRT); a disable/
# enable cycle recovers it on the next test attempt.
ensure_guest_bluetooth_on() {
    local bt_on
    bt_on=$("$ADB" -s "$EMULATOR_SERIAL" shell settings get global bluetooth_on 2>/dev/null | tr -d '\r\n')
    if [ "$bt_on" != "1" ]; then
        echo "Bluetooth is off (bluetooth_on=$bt_on), enabling..."
        "$ADB" -s "$EMULATOR_SERIAL" shell cmd bluetooth_manager enable 2>/dev/null || true
        local elapsed=0
        while [ $elapsed -lt 60 ]; do
            bt_on=$("$ADB" -s "$EMULATOR_SERIAL" shell settings get global bluetooth_on 2>/dev/null | tr -d '\r\n')
            if [ "$bt_on" = "1" ]; then
                break
            fi
            sleep 5
            elapsed=$((elapsed + 5))
        done
    fi
    if [ "$bt_on" != "1" ]; then
        echo "FAIL: guest Bluetooth did not come on"
        return 1
    fi
    echo "Guest Bluetooth is on"
    return 0
}

if [ "$BLE_SIM" = "1" ]; then
    # Start the virtual peripheral first so it is already advertising
    # in the netsim scene when the app starts scanning.  The script
    # lives next to this one (dirname, like helpers.sh above): the
    # harness only exports BUMBLE_PYTHON, not the test-tree root.
    PERIPHERAL_LOG="$WORK_DIR/ble_peripheral.log"
    "$BUMBLE_PYTHON" "$(dirname "$0")/ble_peripheral.py" > "$PERIPHERAL_LOG" 2>&1 &
    PERIPHERAL_PID=$!
    PERIPHERAL_WAIT=0
    while [ $PERIPHERAL_WAIT -lt 30 ]; do
        if grep -q "ADVERTISING_STARTED" "$PERIPHERAL_LOG" 2>/dev/null; then
            break
        fi
        if ! kill -0 "$PERIPHERAL_PID" 2>/dev/null; then
            break
        fi
        sleep 1
        PERIPHERAL_WAIT=$((PERIPHERAL_WAIT + 1))
    done
    if ! grep -q "ADVERTISING_STARTED" "$PERIPHERAL_LOG" 2>/dev/null; then
        echo "FAIL: virtual BLE peripheral did not start advertising"
        cat "$PERIPHERAL_LOG"
        exit 1
    fi
    echo "Virtual BLE peripheral is advertising (pid $PERIPHERAL_PID)"

    ensure_guest_bluetooth_on || exit 1
fi

start_app "$BLE_APK" "ble"

if [ "$BLE_SIM" = "1" ]; then
    # BLUETOOTH_SCAN/CONNECT are runtime permissions on API 31+; the
    # manifest's BLUETOOTH_SCAN has no neverForLocation flag, so scan
    # results are also gated on fine location.
    for permission in android.permission.BLUETOOTH_SCAN \
                      android.permission.BLUETOOTH_CONNECT \
                      android.permission.ACCESS_FINE_LOCATION; do
        "$ADB" -s "$EMULATOR_SERIAL" shell pm grant "$PACKAGE" "$permission" 2>/dev/null \
            || echo "WARNING: could not grant $permission"
    done
fi

wait_for_logcat "setRoot" 120 || true
wait_for_logcat "BLE bridge" 30 || true

# Verify app rendered (setRoot logged)
collect_logcat "ble"

assert_logcat "$LOGCAT_FILE" "BLE bridge\|BleBridge" "BLE bridge log present"

# Tap Check Adapter button — triggers the BLE adapter FFI check
tap_button "Check Adapter" || { echo "WARNING: could not tap Check Adapter"; }
wait_for_logcat "BLE adapter:" 15 || true

# Re-dump logcat to capture adapter check result
LOGCAT_FILE1B="$WORK_DIR/ble_logcat1b.txt"
"$ADB" -s "$EMULATOR_SERIAL" logcat -d '*:I' > "$LOGCAT_FILE1B" 2>&1 || true
assert_logcat "$LOGCAT_FILE1B" "BLE adapter:" "BLE adapter check logged"
if [ "$BLE_SIM" = "1" ]; then
    # With netsim the virtual adapter must report as on.
    assert_logcat "$LOGCAT_FILE1B" "BLE adapter: BleAdapterOn" "BLE adapter is on (netsim)"
fi

# Tap Start Scan button — should not crash
tap_button "Start Scan" || { echo "WARNING: could not tap Start Scan"; }

if [ "$BLE_SIM" = "1" ]; then
    # The virtual peripheral advertises every ~100ms; scan results
    # normally arrive within a few seconds.
    wait_for_logcat "BLE scan result:.*HatterBleSim" 90 || true
    LOGCAT_SCAN="$WORK_DIR/ble_logcat_scan.txt"
    "$ADB" -s "$EMULATOR_SERIAL" logcat -d '*:I' > "$LOGCAT_SCAN" 2>&1 || true
    assert_logcat "$LOGCAT_SCAN" "BLE scan result:.*HatterBleSim" \
        "hatter received the simulated advertisement"

    # Connect to the discovered peripheral from hatter code.
    tap_button "Connect" || { echo "WARNING: could not tap Connect"; }
    wait_for_logcat "BLE connection event: BleConnectionEstablished" 60 || true
    LOGCAT_CONNECT="$WORK_DIR/ble_logcat_connect.txt"
    "$ADB" -s "$EMULATOR_SERIAL" logcat -d '*:I' > "$LOGCAT_CONNECT" 2>&1 || true
    assert_logcat "$LOGCAT_CONNECT" "BLE connection event: BleConnectionEstablished" \
        "hatter connected to the simulated peripheral"
    # Host-side proof: the peripheral saw the central connect.
    assert_logcat "$PERIPHERAL_LOG" "PERIPHERAL_CONNECTED" \
        "virtual peripheral registered the connection"

    # Discover the peripheral's GATT services from hatter code.
    # Android reports UUIDs lowercase, hence the lowercase patterns.
    tap_button "Discover" || { echo "WARNING: could not tap Discover"; }
    wait_for_logcat "BLE discovery complete:" 60 || true
    LOGCAT_DISCOVER="$WORK_DIR/ble_logcat_discover.txt"
    "$ADB" -s "$EMULATOR_SERIAL" logcat -d '*:I' > "$LOGCAT_DISCOVER" 2>&1 || true
    assert_logcat "$LOGCAT_DISCOVER" \
        "BLE discovered: 50db505c-8ac4-4738-8448-3b1d9cc09cc5 486f64c6-4b5f-4b3b-8aff-ede56a8b54f5" \
        "discovery reports the test service's read characteristic"
    assert_logcat "$LOGCAT_DISCOVER" \
        "BLE discovered: .*8cb7c0f4-3b97-4653-9e4f-6f02bf97c7fb .*BleCharacteristicNotify" \
        "discovery reports the echo characteristic with notify support"
    assert_logcat "$LOGCAT_DISCOVER" "BLE discovery complete:" \
        "discovery completed"

    # Negotiate a larger MTU (the granted value depends on the stack).
    tap_button "Request Mtu" || { echo "WARNING: could not tap Request Mtu"; }
    wait_for_logcat "BLE mtu granted:" 30 || true
    LOGCAT_MTU="$WORK_DIR/ble_logcat_mtu.txt"
    "$ADB" -s "$EMULATOR_SERIAL" logcat -d '*:I' > "$LOGCAT_MTU" 2>&1 || true
    assert_logcat "$LOGCAT_MTU" "BLE mtu granted:" \
        "MTU negotiation completed"

    # Subscribe to the echo characteristic's notifications, then write
    # to it: the peripheral echoes the bytes back as a notification, so
    # one round trip covers write, subscribe and notification dispatch.
    tap_button "Subscribe" || { echo "WARNING: could not tap Subscribe"; }
    wait_for_logcat "BLE subscribed" 30 || true
    LOGCAT_SUBSCRIBE="$WORK_DIR/ble_logcat_subscribe.txt"
    "$ADB" -s "$EMULATOR_SERIAL" logcat -d '*:I' > "$LOGCAT_SUBSCRIBE" 2>&1 || true
    assert_logcat "$LOGCAT_SUBSCRIBE" "BLE subscribed" \
        "hatter subscribed to the echo characteristic"

    # Read the fixed characteristic: bytes of "hatter".
    tap_button "Read" || { echo "WARNING: could not tap Read"; }
    wait_for_logcat "BLE read result: \[104,97,116,116,101,114\]" 30 || true
    LOGCAT_READ="$WORK_DIR/ble_logcat_read.txt"
    "$ADB" -s "$EMULATOR_SERIAL" logcat -d '*:I' > "$LOGCAT_READ" 2>&1 || true
    assert_logcat "$LOGCAT_READ" "BLE read result: \[104,97,116,116,101,114\]" \
        "hatter read the peripheral's characteristic value"

    # Write "hatter!" and expect it echoed back as a notification.
    tap_button "Write" || { echo "WARNING: could not tap Write"; }
    wait_for_logcat "BLE notification: \[104,97,116,116,101,114,33\]" 30 || true
    LOGCAT_WRITE="$WORK_DIR/ble_logcat_write.txt"
    "$ADB" -s "$EMULATOR_SERIAL" logcat -d '*:I' > "$LOGCAT_WRITE" 2>&1 || true
    assert_logcat "$LOGCAT_WRITE" "BLE write completed" \
        "hatter's characteristic write was acknowledged"
    assert_logcat "$LOGCAT_WRITE" "BLE notification: \[104,97,116,116,101,114,33\]" \
        "hatter received the echoed notification"
    # Host-side proof: the peripheral saw the write arrive.
    assert_logcat "$PERIPHERAL_LOG" "ECHO_WRITE: 68617474657221" \
        "virtual peripheral received the written bytes"

    # Disconnect again from hatter code.
    tap_button "Disconnect" || { echo "WARNING: could not tap Disconnect"; }
    wait_for_logcat "BLE connection event: BleConnectionClosed" 30 || true
    LOGCAT_DISCONNECT="$WORK_DIR/ble_logcat_disconnect.txt"
    "$ADB" -s "$EMULATOR_SERIAL" logcat -d '*:I' > "$LOGCAT_DISCONNECT" 2>&1 || true
    assert_logcat "$LOGCAT_DISCONNECT" "BLE connection event: BleConnectionClosed" \
        "hatter disconnected from the simulated peripheral"

    # Scan filtered by the test service UUID: the peripheral advertises
    # it (auto-restarted after the disconnect), so it must be found.
    tap_button "Filtered Scan" || { echo "WARNING: could not tap Filtered Scan"; }
    wait_for_logcat "BLE filtered scan result:.*HatterBleSim" 90 || true
    LOGCAT_FILTERED="$WORK_DIR/ble_logcat_filtered.txt"
    "$ADB" -s "$EMULATOR_SERIAL" logcat -d '*:I' > "$LOGCAT_FILTERED" 2>&1 || true
    assert_logcat "$LOGCAT_FILTERED" "BLE filtered scan result:.*HatterBleSim" \
        "service-UUID-filtered scan found the peripheral"
else
    sleep 1
fi

# Tap Stop Scan button — should not crash
tap_button "Stop Scan" || { echo "WARNING: could not tap Stop Scan"; }
sleep 1

# Verify no crash
LOGCAT_FILE2="$WORK_DIR/ble_logcat2.txt"
"$ADB" -s "$EMULATOR_SERIAL" logcat -d '*:E' > "$LOGCAT_FILE2" 2>&1 || true
if grep -qE "$FATAL_PATTERNS" "$LOGCAT_FILE2" 2>/dev/null; then
    echo "FAIL: Fatal crash detected during BLE test"
    # Dump crash context for CI debugging
    grep -E "$FATAL_PATTERNS" "$LOGCAT_FILE2" | tail -10
    EXIT_CODE=1
else
    echo "PASS: No crash during BLE test"
fi

"$ADB" -s "$EMULATOR_SERIAL" uninstall "$PACKAGE" 2>/dev/null || true

# A failed simulation attempt is usually a wedged guest Bluetooth stack
# (it can SIGABRT on startup timeouts under emulation).  bluetooth_on
# stays 1 in that state, so ensure_guest_bluetooth_on alone won't
# recover it, so cycle the stack now and the next run_with_retry attempt
# starts from a fresh one.
if [ "$BLE_SIM" = "1" ] && [ $EXIT_CODE -ne 0 ]; then
    echo "Cycling guest Bluetooth for the next attempt..."
    "$ADB" -s "$EMULATOR_SERIAL" shell cmd bluetooth_manager disable 2>/dev/null || true
    sleep 5
    "$ADB" -s "$EMULATOR_SERIAL" shell cmd bluetooth_manager enable 2>/dev/null || true
fi

exit $EXIT_CODE
