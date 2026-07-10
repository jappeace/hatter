# BLE simulation in the emulator integration tests

The Android emulator job does not just check that the BLE code paths
avoid crashing: it places a simulated peripheral on a virtual radio,
scans for it from hatter code, connects to it, and disconnects again.
This document explains the moving parts.

## Architecture

```
 host                                         guest (emulator)
 ─────────────────────────────────────        ──────────────────────────
 ble_peripheral.py                            hatter BLE demo app
   (bumble BLE stack,                           (test/BleDemoMain.hs)
    "HatterBleSim",                                  │ Haskell callbacks
    connectable GATT server)                    Hatter.Ble / BleBridge
        │ HCI over gRPC                              │ JNI
        ▼                                       HatterActivity
     netsimd  ◄──────── HCI over gRPC ───────  virtual BT controller
   (virtual radio,
    spawned by the emulator)
```

- **netsim** is the Android emulator's virtual radio environment
  (successor of rootcanal).  Passing `-packet-streamer-endpoint
  default` to the emulator spawns a `netsimd` daemon and gives the
  guest a working virtual Bluetooth controller.  `netsimd` publishes
  its gRPC port in `netsim.ini` inside `XDG_RUNTIME_DIR` (falling back
  to `TMPDIR`); the harness pins both to the session work directory so
  every process agrees on the discovery location.
- **bumble** (Google's Python BLE stack, packaged in nixpkgs) connects
  to the same `netsimd` as a second virtual controller and runs a
  complete BLE device on it: `test/android/ble_peripheral.py`
  advertises as a connectable peripheral named `HatterBleSim` with a
  small GATT service.
- The guest's Bluetooth stack receives those advertisements exactly as
  it would from a physical device, so the whole hatter path is
  exercised for real: `BluetoothLeScanner` → JNI (`onBleScanResult`)
  → C bridge → `haskellOnBleScanResult` → the app's Haskell callback,
  and for connections `connectGatt` → `onConnectionStateChange` → JNI
  → `haskellOnBleConnectionEvent`.

The test (`test/android/ble.sh`, `BLE_SIM=1`) asserts through logcat:

1. `BLE adapter: BleAdapterOn`: the netsim-backed adapter is up.
2. `BLE scan result: ... HatterBleSim ...`: the Haskell scan callback
   received the simulated advertisement.
3. `BLE connection event: BleConnectionEstablished`: hatter connected
   to the peripheral (the peripheral's log independently confirms with
   `PERIPHERAL_CONNECTED`).
4. `BLE connection event: BleConnectionClosed`: hatter disconnected.

## Platform coverage

| platform            | BLE simulation | reason |
|---------------------|----------------|--------|
| Android aarch64 job (API 34 image) | yes | netsim needs an API 33+ image |
| Android armv7a job (API 30 image)  | no  | guest lacks the virtio BT chip; old adapter-check-only test |
| iOS / watchOS simulator            | no  | Apple removed CoreBluetooth support from the simulator; there is no virtual HCI to inject into |

On the iOS simulator the adapter reports `Unsupported`; the iOS test
asserts the connect attempt still round-trips through the bridge and
fails visibly (`BleConnectionFailed`) instead of hanging.

## Guest Bluetooth stack flakiness

The guest Bluetooth stack aborts with `assertion 'init_status ==
std::future_status::ready' failed` when its module startup exceeds a
fixed deadline, which can happen on a starved emulator (observed under
software emulation without KVM; CI runners have KVM).  Recovery
handling lives in `ble.sh`: `ensure_guest_bluetooth_on` before the
test, and a `cmd bluetooth_manager disable`/`enable` cycle after a
failed attempt so the next `run_with_retry` attempt starts with a
fresh stack.

## Running it locally

```
nix-build nix/ci.nix -A emulator-all -o result-emulator-all
./result-emulator-all/bin/test-all
```

To poke at the pieces by hand: boot the emulator with
`-packet-streamer-endpoint default`, point `XDG_RUNTIME_DIR` at the
emulator's temp dir, and run
`python3 test/android/ble_peripheral.py` with bumble available
(`nix-shell -p 'python3.withPackages (p: [p.bumble])'`).  netsimd's
logs land in `$TMPDIR/android-$USER/netsimd/netsim_stderr.log`, and its
per-device TX/RX counters in `netsim_session_stats.json` next to it;
that file is the quickest way to see whether advertisement packets are
actually flowing.
