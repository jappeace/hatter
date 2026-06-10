# TODO — items not yet ported from kbeacon-ota-tool

## 1. Beacon configuration (GATT connect + write)

**Original**: `SetAdvPeriodState.kt` — connects to each beacon with
`beacon.connectEnhanced("0000000000000000", 5000, connPara, delegate)`,
then calls `beacon.modifyConfig(slotCfg)` to write the advertisement period.

**Blocked on**: hatter has no BLE connect / GATT API yet.

**Hatter issue**: https://github.com/jappeace/hatter/issues/108
"BLE: connection, GATT, and scan filtering"

When #108 lands, implement this as a new action that:
1. Connects to the beacon by `bsrDeviceAddress`
2. Discovers the KBeacon slot config characteristic
3. Writes the target advertisement period
4. Disconnects and records the result in the beacon list

---

## 2. HTTP result reporting

**Original**: `ReportAdvPeriodState.kt` — POSTs each `BeaconResult` (name,
mac, advPeriod, batteryPercent) to a user-supplied URL as JSON.

**Available in hatter**: `Hatter.Http.performRequest` already exists.

**What's needed**: wire up the URL TextInput + a "Report" mode switch, then
call `performRequest` after each beacon's configuration result is known.
Depends on item 1 (configuration) to have actual results worth reporting.

---

## 3. Battery percentage per beacon

**Original**: `BeaconResult.batteryPercent` — read from the KBeacon GATT
connection after `connectEnhanced`.

**Blocked on**: (a) BLE GATT connect (item 1 above), and (b) hatter's
`BleScanResult` doesn't expose battery level even from advertisement packets.

**Hatter issue**: https://github.com/jappeace/hatter/issues/78
"Platform integration: Battery status" (device battery — may not cover
peripheral BLE battery; the advertisement-level battery field is part of
https://github.com/jappeace/hatter/issues/108 scan-result extensions)

---

## 4. Scan result filtering by service UUID

**Original**: `Scanner.kt` only queues beacons that advertise `KBAdvType.EddyUID`
— i.e., it filters to KBeacon-specific beacons at the advertisement type level.

**Blocked on**: hatter #108 also covers scan filtering by service UUID.

When available, add a UUID filter to `startBleScan` so the scan returns only
KBeacon Pro devices instead of all nearby BLE peripherals.

---

## 5. npins setup

`nix/sources/` is currently a placeholder. Before running `nix-build`, pin
hatter with npins:

```
cd kbeacon-ota-hatter
npins init
npins add github jappeace hatter
```

This creates `nix/sources/` with the pinned hatter revision.
