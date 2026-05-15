# Hatter vs miso-lynx: Technical Comparison

A technical comparison of the two native Haskell mobile frameworks, focused on architecture, device API access, and what it takes to ship a Bluetooth scan.

---

## Executive Summary

Hatter and miso-lynx take fundamentally different approaches to putting Haskell on mobile:

- **Hatter** cross-compiles Haskell to native ARM binaries via GHC. The Haskell runtime runs natively on the device. Device APIs are accessed through a C FFI bridge that dispatches to JNI (Android) or Objective-C (iOS).
- **miso-lynx** compiles Haskell to JavaScript via GHC 9.12's JS backend. The code runs inside a JS interpreter embedded in LynxJS (ByteDance's cross-platform engine, used in production by TikTok). Native views are created through LynxJS's Element PAPI.

| Concern | Hatter | miso-lynx |
|---|---|---|
| Execution model | Native ARM binary (GHC RTS on device) | JavaScript in LynxJS interpreter |
| UI toolkit | Platform-native (UIKit, Android Views, SwiftUI) | LynxJS native views via Element PAPI |
| Language boundary | C FFI (direct function calls) | GHC JS backend → LynxJS PAPI |
| Layout engine | Platform-native (Auto Layout, LinearLayout) | LynxJS CSS engine (flexbox/grid/linear) |
| Device APIs | 10+ working (BLE, Camera, Location, HTTP, etc.) | None yet (blocked on dual-thread PR) |
| Platforms | Android, iOS, watchOS, Wear OS | iOS, Android, HarmonyOS, Web |
| Build system | Nix cross-compilation | Nix + forked GHC JS backend + BigInt polyfill |
| Maturity | Working apps deployed | Experimental, under heavy development |

---

## Part 1: Architecture

### 1.1 Hatter's Call Stack

```
Haskell (pure Widget tree + IO)
    ↓  foreign import ccall / foreign export ccall
C FFI bridge (platform-agnostic dispatchers)
    ↓  function pointer dispatch
C FFI bridge (platform-specific implementations)
    ↓  JNI (Android) / Objective-C (iOS) / Swift (watchOS)
Native platform APIs and views
```

Haskell is cross-compiled to ARM machine code by GHC. The resulting `.so` (Android) or static library (iOS) contains the full GHC runtime. The Haskell binary runs natively — no interpreter, no serialization, no intermediate language.

Each device subsystem (UI, BLE, Camera, Location, etc.) follows a three-tier C bridge pattern:

1. **Haskell FFI declarations** — `foreign import ccall` for Haskell-to-C, `foreign export ccall` for callbacks.
2. **Platform-agnostic C dispatcher** — Stores function pointers, returns safe defaults when no platform is registered (enabling desktop `cabal test`).
3. **Platform-specific implementation** — JNI calls on Android, Objective-C on iOS, Swift on watchOS.

### 1.2 miso-lynx's Call Stack

```
Haskell (Elm Architecture via miso)
    ↓  GHC 9.12 JavaScript backend
miso virtual DOM diffing (in JavaScript)
    ↓  DrawingContext<Node> / EventContext<Node>
LynxJS TypeScript context (lynx.ts)
    ↓  __CreateView, __AppendElement, __SetAttribute, etc.
LynxJS Element PAPI (C++ engine)
    ↓  platform-specific renderers
Native UIView (iOS) / View (Android) / HarmonyOS views
```

Haskell code compiles to JavaScript. The miso framework's virtual DOM runs in JS, producing diff patches. A TypeScript adapter layer (`lynx.ts`) translates miso's abstract drawing operations into LynxJS Element PAPI calls. The PAPI is a C++ engine that creates actual native views on each platform.

The key architectural abstraction is miso's `DrawingContext<T>` and `EventContext<T>` interfaces. In a browser `T = HTMLElement`; in miso-lynx `T = Node` (a Lynx PAPI node reference). This allows miso to target LynxJS without modifying its core reconciliation logic.

### 1.3 Execution Model Comparison

| | Hatter | miso-lynx |
|---|---|---|
| Haskell compilation target | ARM machine code | JavaScript |
| Runtime | GHC RTS (native) | PrimJS (QuickJS-based interpreter) |
| Function call overhead | C FFI (nanoseconds) | JS interop + PAPI bridge |
| Memory model | GHC heap (native malloc) | JS garbage collector |
| Concurrency | GHC green threads, STM, MVars | JS event loop (single-threaded per interpreter) |
| Numeric types | Native machine integers | BigInt polyfill required (LynxJS lacks native BigInt) |

Hatter's native execution means the full power of GHC is available: green threads, STM, unboxed arrays, direct memory access. miso-lynx is constrained by what the GHC JS backend can express and what the LynxJS JS interpreter supports.

### 1.4 Threading

**Hatter**: Haskell code runs in its own thread managed by the GHC RTS. UI callbacks cross the FFI boundary synchronously. Platform APIs that require the main thread (most of Android's UI APIs) are dispatched via `runOnUiThread` from JNI.

**miso-lynx**: LynxJS runs two separate JS interpreters in separate threads:

- **MTS (Main Thread Script)** — Rendering thread. PrimJS interpreter handles the pixel pipeline.
- **BTS (Background Thread Script)** — Application logic thread. Handles state management, network, and native module access.

Currently miso-lynx runs everything on the MTS (single-threaded). PR #70 (open since February 2026) is implementing the dual-thread split, which is required for native module access.

---

## Part 2: UI Layer

### 2.1 Widget Model

**Hatter** defines widgets as a Haskell ADT:

```haskell
data Widget
  = Text TextConfig
  | Button ButtonConfig
  | TextInput TextInputConfig
  | Column LayoutSettings
  | Row LayoutSettings
  | Stack [LayoutItem]
  | Image ImageConfig
  | WebView WebViewConfig
  | MapView MapViewConfig
  | Styled WidgetStyle Widget
  | Animated AnimatedConfig Widget
```

Each variant maps to a native view per platform:

| Widget | Android | iOS | watchOS |
|---|---|---|---|
| `Text` | `TextView` | `UILabel` | SwiftUI `Text` |
| `Button` | `Button` | `UIButton` | SwiftUI `Button` |
| `TextInput` | `EditText` | `UITextField` | SwiftUI `TextField` |
| `Column` | `LinearLayout(vertical)` | `UIStackView(.vertical)` | SwiftUI `VStack` |
| `Row` | `LinearLayout(horizontal)` | `UIStackView(.horizontal)` | SwiftUI `HStack` |
| `Stack` | `FrameLayout` | Overlaid `UIView`s | SwiftUI `ZStack` |
| `Image` | `ImageView` | `UIImageView` | SwiftUI `Image` |
| `MapView` | Google Maps `MapView` | `MKMapView` | N/A |

**miso-lynx** uses miso's Elm Architecture with Lynx-specific elements:

```haskell
view_ [ onTap HandleTap ] [
  text_ [ css_ "color" "red" ] [ "Hello" ],
  image_ [ src_ "icon.png" ]
]
```

Elements map to LynxJS primitives: `view`, `text`, `image`, `scroll-view`, `list`, `frame`. LynxJS's CSS engine handles layout (flexbox, grid, linear, relative).

### 2.2 Tree Diffing

Both frameworks use virtual-DOM-style incremental updates:

**Hatter**: Widget derives `Eq`. The render engine compares new and old trees:
1. Exact equality → skip (zero work).
2. Same node type → in-place property update (preserves native view state like cursor position).
3. Same container type → diff children by key.
4. Different type → destroy and recreate.

**miso-lynx**: Standard miso virtual DOM diffing. Produces patches that are applied through the `DrawingContext<Node>` interface to LynxJS's PAPI.

---

## Part 3: Device API Access — The Critical Difference

### 3.1 Hatter's Approach

Each device API follows the same pattern. Taking BLE as the example:

**Haskell API** (`src/Hatter/Ble.hs`):

```haskell
foreign import ccall "ble_check_adapter" c_bleCheckAdapter :: IO CInt
foreign import ccall "ble_start_scan"    c_bleStartScan :: Ptr () -> IO ()
foreign import ccall "ble_stop_scan"     c_bleStopScan :: IO ()

foreign export ccall haskellOnBleScanResult
  :: Ptr AppContext -> CString -> CString -> CInt -> IO ()

checkBleAdapter :: IO BleAdapterStatus
startBleScan    :: BleState -> (BleScanResult -> IO ()) -> IO ()
stopBleScan     :: BleState -> IO ()
```

**Platform-agnostic C dispatcher** (`cbits/ble_bridge.c`):

```c
static int32_t (*g_check_adapter_impl)(void) = NULL;
static void (*g_start_scan_impl)(void *) = NULL;
static void (*g_stop_scan_impl)(void) = NULL;

void ble_register_impl(
    int32_t (*check_adapter)(void),
    void (*start_scan)(void *),
    void (*stop_scan)(void)) {
    g_check_adapter_impl = check_adapter;
    g_start_scan_impl = start_scan;
    g_stop_scan_impl = stop_scan;
}

int32_t ble_check_adapter(void) {
    if (!g_check_adapter_impl) {
        fprintf(stderr, "ble_check_adapter: no platform impl\n");
        return BLE_ADAPTER_UNSUPPORTED;
    }
    return g_check_adapter_impl();
}
```

**Android** (`cbits/ble_bridge_android.c`): JNI calls to `BluetoothLeScanner`:

```c
static int32_t android_ble_check_adapter(void) {
    jint result = (*env)->CallIntMethod(env, g_activity, g_method_checkBleAdapter);
    return (int32_t)result;
}
```

**iOS** (`ios/Hatter/BleBridgeIOS.m`): CoreBluetooth via Objective-C:

```objc
static int32_t ios_ble_check_adapter(void) {
    switch (g_delegate.centralManager.state) {
    case CBManagerStatePoweredOn:  return BLE_ADAPTER_ON;
    case CBManagerStatePoweredOff: return BLE_ADAPTER_OFF;
    // ...
    }
}
```

**In a Hatter app:**

```haskell
startBleScan bleState $ \result ->
    platformLog (bsrDeviceName result <> " at " <> bsrDeviceAddress result)
```

The callback comes back through: native BLE callback → C bridge → `foreign export ccall haskellOnBleScanResult` → Haskell callback → re-render.

Desktop builds (where `g_check_adapter_impl` is NULL) log to stderr and return safe defaults, so `cabal test` works without a phone.

### 3.2 What It Would Take in miso-lynx

BLE access in miso-lynx is tracked in issue #42. It is not implemented. Here is every step that would be required:

#### Step 1: Write Native Modules (per platform)

You must implement LynxJS's `LynxModule` protocol in each platform's native language.

**Kotlin (Android):**

```kotlin
class BluetoothModule(context: LynxContext) : LynxModule(context) {
    private val scanner = BluetoothAdapter.getDefaultAdapter().bluetoothLeScanner

    @LynxMethod
    fun startScan(callback: LynxCallback) {
        scanner.startScan(object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) {
                val map = WritableMap()
                map.putString("name", result.device.name)
                map.putString("address", result.device.address)
                map.putInt("rssi", result.rssi)
                callback.invoke(map)
            }
        })
    }
}
```

**Swift (iOS):**

```swift
class BluetoothModule: LynxModule, CBCentralManagerDelegate {
    var centralManager: CBCentralManager!
    var scanCallback: LynxCallback?

    override func startScan(_ callback: LynxCallback) {
        scanCallback = callback
        centralManager = CBCentralManager(delegate: self, queue: nil)
        centralManager.scanForPeripherals(withServices: nil)
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi: NSNumber) {
        scanCallback?.invoke([
            "name": peripheral.name ?? "",
            "address": peripheral.identifier.uuidString,
            "rssi": rssi.intValue
        ])
    }
}
```

If you want HarmonyOS support, you need a third implementation in ArkTS.

#### Step 2: Register Modules with LynxJS Runtime (per platform)

**Kotlin:**

```kotlin
class MyApplication : Application() {
    override fun onCreate() {
        LynxEnv.inst().addModuleBundle(object : LynxModuleBundle {
            override fun getModules(): List<LynxModuleProvider> {
                return listOf(
                    LynxModuleProvider("BluetoothModule", BluetoothModule::class.java)
                )
            }
        })
    }
}
```

**Swift:**

```swift
lynxView.addModule(BluetoothModule.self, param: "BluetoothModule")
```

#### Step 3: TypeScript Declarations

```typescript
declare const NativeModules: {
    BluetoothModule: {
        startScan(callback: (result: {
            name: string,
            address: string,
            rssi: number
        }) => void): void;
        stopScan(): void;
    }
}
```

#### Step 4: Wait for Dual-Thread Architecture (PR #70)

LynxJS native modules are **only callable from the Background Thread Script (BTS)**. The miso virtual DOM runs on the **Main Thread Script (MTS)**. These are separate JS interpreters in separate OS threads.

PR #70 (open since February 2026) implements the dual-thread split using a serialized message protocol called PATCH. Without this PR, native modules are unreachable from Haskell.

Remaining work on PR #70 as of last update:
- Abstract `requestAnimationFrame` into `DrawingContext<T>`
- Make main thread events top-level
- Use `__CreateComponent` for the component map

#### Step 5: Cross-Thread Callback Routing (BTS → MTS)

When a Bluetooth device is discovered, the callback fires on the BTS. The result must be serialized into a PATCH message, sent across the thread boundary, deserialized on the MTS, and dispatched into miso's Elm Architecture update loop.

The data flow for a single scan result:

```
Native BLE callback (platform thread)
    → LynxJS native module bridge
    → BTS JavaScript interpreter
    → serialize scan result to PATCH message
    → cross-thread channel (BTS → MTS)
    → MTS JavaScript interpreter
    → GHC JS runtime
    → miso's update function
    → virtual DOM diff
    → PAPI calls back to native views
```

Every hop in this chain adds latency and requires correct serialization/deserialization. For BLE scanning, which can produce many results per second, this is non-trivial.

#### Step 6: Haskell JS FFI Bindings

You need GHC JS backend FFI bindings to call the native module from Haskell and to wrap Haskell callbacks as JS functions:

```haskell
foreign import javascript unsafe
    "NativeModules.BluetoothModule.startScan($1)"
    js_startBleScan :: JSVal -> IO ()

startBleScan :: (BleScanResult -> action) -> Effect parent model action
startBleScan toAction = withSink $ \sink -> do
    callback <- syncCallback1 ThrowWouldBlock $ \jsVal -> do
        name    <- fromJSVal =<< getProp "name" jsVal
        address <- fromJSVal =<< getProp "address" jsVal
        rssi    <- fromJSVal =<< getProp "rssi" jsVal
        sink $ toAction $ BleScanResult name address rssi
    js_startBleScan (jsval callback)
```

This code is hypothetical. The `syncCallback1`, `fromJSVal`, and `getProp` functions would need to work correctly across the BTS/MTS boundary, which is uncharted territory.

#### Step 7: Permissions

BLE scanning requires runtime permissions (`ACCESS_FINE_LOCATION` on Android, `CBManagerAuthorization` on iOS). Each permission request needs its own native module, its own cross-thread callback routing, and its own Haskell FFI wrapper — the same six-step pipeline again.

#### Step 8: Testing

Desktop testing is unclear. LynxJS's native module system is tied to the LynxJS runtime. There is no obvious equivalent to Hatter's "return safe defaults when no platform is registered" pattern that would allow `cabal test` on a developer machine.

### 3.3 Comparison Summary

| Step | Hatter | miso-lynx |
|---|---|---|
| Native BLE code | C bridge + JNI/ObjC | LynxModule in Kotlin/Swift/ArkTS |
| Registration | Function pointer registration at startup | LynxJS module bundle registration |
| Thread model | Direct FFI call, same process | BTS→MTS cross-thread serialization |
| Haskell binding | `foreign import ccall` | `foreign import javascript` (hypothetical) |
| Callback routing | `foreign export ccall` → direct Haskell call | JS callback → PATCH message → deserialize → miso action |
| Desktop testing | Null dispatcher returns safe defaults | No known mechanism |
| Permissions | Same bridge pattern, already implemented | Same pipeline, not implemented |
| Status | **Working** | **Blocked on PR #70 + unsolved research** |
| Languages touched | Haskell, C, Java/Kotlin, ObjC/Swift | Haskell, TypeScript, Kotlin, Swift, ArkTS |
| Hops per callback | 3 (native → C → Haskell) | 6+ (native → LynxJS → BTS JS → PATCH → MTS JS → GHC JS → miso) |

---

## Part 4: Full Tradeoff Analysis

### 4.1 Where Hatter Wins

**Device API access**: 10+ subsystems working today (BLE, Camera, Location, HTTP, Permissions, SecureStorage, NetworkStatus, AuthSession, PlatformSignIn, Dialog). miso-lynx has zero, blocked on infrastructure.

**Execution performance**: Native ARM binary vs. JS interpreter. GHC's RTS gives green threads, STM, unboxed types, and direct memory access. The JS runtime constrains concurrency to an event loop and requires a BigInt polyfill.

**Callback simplicity**: Hatter's FFI callbacks are direct C function calls — the shortest possible path between native code and Haskell. miso-lynx callbacks must traverse JS interpreter boundaries, thread boundaries, and a serialization protocol.

**Desktop development**: Hatter's platform-agnostic C dispatchers return safe defaults when no platform is registered, making `cabal test` work on any machine. miso-lynx has no equivalent mechanism for testing without the LynxJS runtime.

**Fewer moving parts**: Hatter's dependency chain is GHC + Nix cross-compilation. miso-lynx requires a forked GHC JS backend, a BigInt polyfill, LynxJS, and the PATCH protocol — more things that can break.

### 4.2 Where miso-lynx Wins

**CSS layout**: LynxJS provides a real CSS engine (flexbox, grid, linear, relative positioning). Hatter delegates layout to platform-native systems, which vary between platforms and offer less control.

**Battle-tested rendering engine**: LynxJS is used in production by TikTok. The rendering pipeline has been optimized at ByteDance scale. Hatter's rendering is correct but has not been subjected to the same level of stress testing.

**HarmonyOS and Web**: LynxJS supports HarmonyOS and can target web browsers. Hatter targets Android, iOS, watchOS, and Wear OS.

**Elm Architecture**: miso provides the well-established Elm Architecture (Model/View/Update) with a mature virtual DOM. Hatter's widget model is purpose-built and less familiar to developers coming from web frameworks.

**Ecosystem backing**: miso is maintained by dmjio, an established Haskell community member. LynxJS is backed by ByteDance. Hatter is a solo project.

### 4.3 Shared Weaknesses

Both projects are young and not widely adopted. Neither has a large contributor base. Both require Nix for their build systems, which narrows the potential contributor pool.

### 4.4 Architectural Risk

**Hatter's risk**: The C FFI bridge is manual and per-subsystem. Each new device API requires writing C bridge code, JNI bindings, Objective-C bindings, and optionally Swift bindings. This is labor-intensive but well-understood.

**miso-lynx's risk**: The dual-thread architecture (PR #70) is a prerequisite for all device API access. If this design proves difficult to stabilize, or if the PATCH protocol introduces unacceptable latency for high-frequency callbacks (BLE scanning, sensor data, audio), the entire device API story is compromised. This is a deeper architectural risk because the problem sits in infrastructure that the project does not fully control (LynxJS's threading model).

---

## Part 5: Available Device APIs

Hatter ships working bindings for the following subsystems. miso-lynx has none.

| Module | Haskell API | Android Implementation | iOS Implementation |
|---|---|---|---|
| `Hatter.Ble` | `startBleScan` / `stopBleScan` / `checkBleAdapter` | `BluetoothLeScanner` via JNI | `CBCentralManager` via ObjC |
| `Hatter.Permission` | `requestPermission` / `checkPermission` | `ActivityCompat.requestPermissions` via JNI | OS-level prompts |
| `Hatter.Location` | `startLocationUpdates` | `LocationManager` via JNI | `CLLocationManager` via ObjC |
| `Hatter.Camera` | `capturePhoto` / `startVideoCapture` | Camera2 API via JNI | AVFoundation via ObjC |
| `Hatter.SecureStorage` | `secureStorageRead` / `secureStorageWrite` | SharedPreferences via JNI | Keychain via ObjC |
| `Hatter.Http` | `performRequest` | OkHttp/URLConnection via JNI | `URLSession` via ObjC |
| `Hatter.Dialog` | `showDialog` | `AlertDialog` via JNI | `UIAlertController` via ObjC |
| `Hatter.NetworkStatus` | `startNetworkMonitoring` | `ConnectivityManager` via JNI | `NWPathMonitor` via ObjC |
| `Hatter.AuthSession` | `startAuthSession` | Custom Tab via JNI | `ASWebAuthenticationSession` |
| `Hatter.PlatformSignIn` | `startPlatformSignIn` | Google Sign-In via JNI | Sign in with Apple |

---

## References

- [Hatter repository](https://github.com/jappeace/hatter)
- [miso repository](https://github.com/dmjio/miso)
- [miso-lynx repository](https://github.com/haskell-miso/miso-lynx)
- [LynxJS](https://lynxjs.org)
- [LynxJS Native Modules](https://lynxjs.org/guide/use-native-modules)
- [miso-lynx issue #42: Device API access](https://github.com/haskell-miso/miso-lynx/issues/42)
- [miso-lynx PR #70: Dual-thread architecture](https://github.com/haskell-miso/miso-lynx/pull/70)
- [Haskell Discourse: Hatter announcement](https://discourse.haskell.org/t/hatter-native-haskell-mobile-apps/13952)
