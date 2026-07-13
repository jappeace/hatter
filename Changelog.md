# Change log for hatter

## Unreleased

### Added

- Scan results now carry the advertisement's service data and
  manufacturer data (issue #238): `BleScanResult` gained
  `bsrAdvertisement :: Either AdvertisementParseErrors
  BleAdvertisement`, parsed by the new `Hatter.BleAdvertisement`
  module (re-exported from `Hatter.Ble`) with `serviceDataForUuid`
  for keyed lookup; service data is keyed by `NormalizedBleUuid`,
  which moved into that module. Malformed advertisements report
  every defect with its byte offset instead of being silently
  dropped, and the scan dispatch logs them while still delivering
  the result. UUID rendering uses the `uuid-types` package (new
  dependency, also in the cross builds). Android passes `ScanRecord.getBytes()` through
  the bridge; iOS re-encodes CoreBluetooth's parsed dictionary into
  the same AD structure format. This unblocks identifying devices
  that only advertise service data (e.g. KBeacons' 0x2080) or
  manufacturer data (iBeacon) without connecting to them.

- `Hatter.Ble` GATT operations, completing the core of issue #108 and
  unblocking the kbeacon OTA tool: `discoverBleServices`,
  `readBleCharacteristic`, `writeBleCharacteristic` (with or without
  response), `subscribeBleCharacteristic` /
  `unsubscribeBleCharacteristic` with streaming notification
  callbacks, and `requestBleMtu`.  One GATT operation may be in
  flight at a time; a second one fails immediately with
  `BleGattBusy`, and every operation completes exactly once with
  `Either BleGattError`.  New types: `BleServiceUuid`,
  `BleCharacteristicUuid`, `BleCharacteristicValue`, `BleMtu`,
  `NormalizedBleUuid`, `BleCharacteristicKey`,
  `BleDiscoveredCharacteristic`, `BleCharacteristicProperty`,
  `BleWriteMode`, `BleGattOperation`, `BleGattError`.  The UUID,
  address and value newtypes derive `IsString`, so constants can be
  written as string literals.
- `startFilteredBleScan`: scan filtered by an advertised service
  UUID.
- The emulator BLE integration test now covers the full GATT surface
  against the virtual peripheral: discovery listing the test service,
  MTU negotiation, characteristic read, subscribe, a write echoed
  back as a notification (asserted on both ends of the radio), and a
  service-UUID-filtered scan.

- `Hatter.Ble` connection API (issue #108, first slice):
  `connectBleDevice`, `disconnectBleDevice`, and the
  `BleConnectionEvent` sum type (`BleConnectionEstablished`,
  `BleConnectionClosed`, `BleConnectionFailed`) with streaming
  connection-state callbacks.  Implemented on Android
  (`BluetoothGatt`) and iOS (`CBCentralManager`); the desktop stub
  fails connections visibly.  GATT service discovery,
  characteristic read/write/subscribe, and scan filtering remain
  open in #108.
- `BleDeviceAddress` newtype: `bsrDeviceAddress` and
  `connectBleDevice` use it instead of a bare `Text` (breaking for
  existing `BleScanResult` consumers).
- The Android emulator CI job now simulates real BLE traffic: the
  emulator boots with a netsim virtual radio and a bumble-based
  virtual peripheral (`test/android/ble_peripheral.py`) advertises
  into it.  The BLE test asserts hatter's scan callback receives the
  advertisement and that hatter code can connect to and disconnect
  from the peripheral.  See docs/ble-emulator-simulation.md.

## Version 0.3.0 2026.04.19

### Breaking changes

- `Column` and `Row` constructors now take `LayoutSettings` instead of
  `[Widget]`.  Use the `column`, `row`, `scrollColumn`, `scrollRow`
  smart constructors for the old behaviour.
- `ScrollView` constructor removed.  Scrolling is now a property of
  `Column`/`Row` via the `lsScrollable` field in `LayoutSettings`,
  or use `scrollColumn`/`scrollRow`.
- Container children are now wrapped in `LayoutItem` (with optional
  `WidgetKey`) for key-based diffing.
- `Easing`-based tween animations replaced with CSS-like keyframe
  animations.  Use `linearAnimation`, `easeIn`, `easeOut`,
  `easeInOut`, `andThen`, and `lerpStyle` for the new API.
- Removed configurable `soName` from `mkAndroidLib`.

### Added

- `Hatter.Widget.Stack` — z-order overlay container (maps to
  FrameLayout on Android, UIView overlay on iOS, ZStack on watchOS).
  Includes `wsTouchPassthrough` style field for controlling touch
  interception on overlay layers.
- Smart constructors: `column`, `row`, `scrollColumn`, `scrollRow`,
  `stack`, `item`, `keyedItem`.
- `LayoutSettings`, `LayoutItem`, `WidgetKey` types for keyed
  container children with key-based child matching in `diffContainer`.
- Keyframe animation API: `linearAnimation`, `easeIn`, `easeOut`,
  `easeInOut`, `andThen`, `lerpStyle` for composable CSS-like
  animation sequences.
- `requestRedraw` API (`Hatter.Render`) for triggering UI re-renders
  from background threads.  Uses C pthread timer on Android
  (non-threaded RTS safe) and platform-native dispatch elsewhere.
- `tiAutoFocus` field on `TextInputConfig` — auto-focus on render
  (deferred on Android via `View.post` for attachment safety).
- `Hatter.DeviceInfo` — query device model, OS version, and screen
  dimensions on all platforms.
- Re-render UI automatically after `TextInput` value changes.
- `hatter_hs_init` with `RtsConfig` for reliable RTS initialisation
  on iOS/watchOS (fixes `hs_init` hang).
- RTS heap limit (`-xr`) on iOS/watchOS real devices to avoid 1TB
  `mmap` rejection.
- Build hatter as a normal cross-compiled Haskell package via
  `collect-deps.nix` / `cross-deps.nix`.
- Share pre-compiled hatter objects across all Android ABI builds.
- `-split-sections` + `--gc-sections` for smaller Android `.so` files.
- Node ID reclamation via free stack on all platforms.

### Fixed

- First-render animation bug: tweens now register from zero origin
  on initial render, not only on re-render.
- Animated widget toggle-back bug: animation config preserved when
  toggling an `Animated` wrapper off then back on.
- Key-based child diffing prevents cascading native view destruction
  when inserting/removing children mid-list.
- Index-based default keys replace content-based `inferKey`, avoiding
  hash collisions for identical widgets.
- `Styled` wrapper now reapplies style when the child widget changes
  type (e.g. `Text` to `Button`).
- Android `destroy_node` detaches view from parent before freeing JNI
  refs (fixes orphaned native views).
- ScrollView SIGABRT on Android when mixing `TextInput` with other
  widgets — children now wrapped in inner `LinearLayout`.
- Android `TextWatcher` re-entry crash prevented by guarding against
  redundant `setText` calls.
- In-place diff for `Text`/`Button` widgets preserves native IME
  connection on Android.
- armv7a OOM from duplicated `registerForeignExports` `.init_array`
  entries.
- iOS/watchOS cross-build: drop `deriving stock` on `WidgetKey`.
- iOS `hs_init` hang resolved via `hatter_hs_init` with explicit
  `RtsConfig` and null-terminated argv.
- Swift type inference errors on Xcode 16.4.
- `os_log` `CVarArg` conformance on iOS — use `String(describing:)`
  for pointer values.
- GNU `libffi` built from source for static iOS/watchOS bundling.

## Version 0.2.0

### Breaking changes

- Platform-specific types are no longer re-exported from `Hatter`.
  Import them from their own modules instead:
  `Hatter.Permission`, `Hatter.SecureStorage`, `Hatter.Ble`,
  `Hatter.Dialog`, `Hatter.Location`, `Hatter.AuthSession`,
  `Hatter.Camera`, `Hatter.BottomSheet`, `Hatter.Http`,
  `Hatter.NetworkStatus`, `Hatter.Locale`, `Hatter.I18n`,
  `Hatter.FilesDir`.
- `AppContext`, `derefAppContext`, `freeAppContext`, and `newAppContext`
  moved to `Hatter.AppContext` (no longer re-exported from `Hatter`).
- `newMobileContext` and `freeMobileContext` are no longer re-exported
  from `Hatter` (available from `Hatter.Lifecycle`).
- FFI dispatch functions (`haskellOnPermissionResult`,
  `haskellOnBleScanResult`, etc.) are no longer in the Haskell export
  list.  They remain available as C symbols via `foreign export ccall`.
- Removed `haskellGreet` (dead hello-world smoke test, unused by any
  app code).

### Added

- `Hatter.PlatformSignIn` — native platform sign-in (Sign in with Apple
  on iOS/watchOS, Google identity via AccountManager on Android/Wear OS).
- `Hatter` module now has a haddock header with overview, usage example,
  and a directory of platform subsystem modules.
- Export list organised under haddock section headers: App setup, Widget,
  Actions, Animation, Lifecycle, Error handling, Internal.
- Full `Hatter.Widget` re-exports in the main module: `WidgetStyle`,
  `defaultStyle`, `Color`, `colorFromText`, `colorToHex`, `ImageConfig`,
  `ImageSource`, `ResourceName`, `ScaleType`, `TextAlignment`,
  `TextInputConfig`, `InputType`, `WebViewConfig`, `MapViewConfig`,
  `button`, `text`.

## Version 0.1.0

Initial release of hatter (renamed from haskell-mobile).
