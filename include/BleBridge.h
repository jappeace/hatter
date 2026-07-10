#ifndef BLE_BRIDGE_H
#define BLE_BRIDGE_H

#include <stdint.h>

/* BLE adapter status codes (must match Hatter.Ble) */
#define BLE_ADAPTER_OFF          0
#define BLE_ADAPTER_ON           1
#define BLE_ADAPTER_UNAUTHORIZED 2
#define BLE_ADAPTER_UNSUPPORTED  3

/* BLE connection event codes (must match Hatter.Ble) */
#define BLE_CONNECTION_ESTABLISHED 0
#define BLE_CONNECTION_CLOSED      1
#define BLE_CONNECTION_FAILED      2

/*
 * Platform-agnostic BLE bridge.
 *
 * Haskell calls ble_check_adapter / ble_start_scan / ble_stop_scan /
 * ble_connect / ble_disconnect through these wrappers.  When no
 * platform callbacks are registered (desktop), stubs return
 * BLE_ADAPTER_ON, log no-ops, and fail connection attempts loudly so
 * that cabal build/test works without native code.
 *
 * On Android/iOS the platform-specific setup function fills in real
 * implementations via ble_register_impl() and, when the platform
 * supports GATT connections, ble_register_connect_impl().
 */

/* Check the BLE adapter status (synchronous).
 * Returns one of BLE_ADAPTER_* constants. */
int32_t ble_check_adapter(void);

/* Start a BLE scan. Discovered devices are delivered via
 * haskellOnBleScanResult(). ctx is the opaque Haskell context. */
void ble_start_scan(void *ctx);

/* Stop a running BLE scan. */
void ble_stop_scan(void);

/* Connect to a BLE device by address (MAC on Android, peripheral UUID
 * on iOS). Connection state changes are delivered asynchronously via
 * haskellOnBleConnectionEvent() with a BLE_CONNECTION_* code.
 * When no connect implementation is registered, dispatches
 * BLE_CONNECTION_FAILED immediately so callers always receive an event. */
void ble_connect(void *ctx, const char *address);

/* Disconnect the active BLE connection. Completion is delivered via
 * haskellOnBleConnectionEvent() with BLE_CONNECTION_CLOSED. */
void ble_disconnect(void);

/* Register platform-specific scan implementations.
 * Called by platform setup functions (setup_android_ble_bridge, etc). */
void ble_register_impl(
    int32_t (*check_adapter)(void),
    void (*start_scan)(void *),
    void (*stop_scan)(void));

/* Register platform-specific connection implementations.
 * Registered separately from ble_register_impl so that consumer apps
 * whose Activity predates the connect API keep working scans: the
 * Android bridge only registers these when the connect JNI methods
 * resolve. */
void ble_register_connect_impl(
    void (*connect)(void *, const char *),
    void (*disconnect)(void));

#endif /* BLE_BRIDGE_H */
