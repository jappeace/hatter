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

/* BLE GATT operation codes (must match Hatter.Ble).
 * Passed back through haskellOnBleGattResult so Haskell can sanity
 * check that a completion belongs to the operation it has pending. */
#define BLE_GATT_OP_DISCOVER    0
#define BLE_GATT_OP_READ        1
#define BLE_GATT_OP_WRITE       2
#define BLE_GATT_OP_SUBSCRIBE   3
#define BLE_GATT_OP_UNSUBSCRIBE 4
#define BLE_GATT_OP_MTU         5

/* GATT completion status: 0 = success; BLE_GATT_STATUS_NO_IMPL when no
 * platform implementation is registered; anything else is the
 * platform's own error code passed through verbatim. */
#define BLE_GATT_STATUS_SUCCESS 0
#define BLE_GATT_STATUS_NO_IMPL (-1)

/* Characteristic property bits (must match Hatter.Ble) */
#define BLE_CHAR_PROP_READ              1
#define BLE_CHAR_PROP_WRITE             2
#define BLE_CHAR_PROP_WRITE_NO_RESPONSE 4
#define BLE_CHAR_PROP_NOTIFY            8

/* Write modes for ble_write_characteristic */
#define BLE_WRITE_WITHOUT_RESPONSE 0
#define BLE_WRITE_WITH_RESPONSE    1

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
 * haskellOnBleScanResult(). ctx is the opaque Haskell context.
 * service_uuid_filter: 128-bit service UUID string to filter
 * advertisements by, or NULL for an unfiltered scan. */
void ble_start_scan(void *ctx, const char *service_uuid_filter);

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

/*
 * GATT operations on the active connection.  All are asynchronous;
 * exactly one may be outstanding at a time (enforced on the Haskell
 * side).  Completions arrive via haskellOnBleGattResult(); discovered
 * characteristics are streamed via
 * haskellOnBleCharacteristicDiscovered() before the discover
 * completion; notification data arrives via haskellOnBleNotification()
 * for characteristics enabled with ble_set_characteristic_notification.
 */

/* Discover all services and characteristics on the connected device. */
void ble_discover_services(void *ctx);

/* Read a characteristic's value. */
void ble_read_characteristic(void *ctx, const char *service_uuid,
                             const char *characteristic_uuid);

/* Write a characteristic's value. write_mode is BLE_WRITE_*. */
void ble_write_characteristic(void *ctx, const char *service_uuid,
                              const char *characteristic_uuid,
                              const uint8_t *data, int32_t length,
                              int32_t write_mode);

/* Enable (1) or disable (0) notifications for a characteristic. */
void ble_set_characteristic_notification(void *ctx, const char *service_uuid,
                                         const char *characteristic_uuid,
                                         int32_t enable);

/* Request a larger ATT MTU (Android negotiates; iOS reports the
 * already-negotiated maximum). Granted value is delivered in the
 * completion's length field. */
void ble_request_mtu(void *ctx, int32_t mtu);

/* Register platform-specific scan implementations.
 * Called by platform setup functions (setup_android_ble_bridge, etc). */
void ble_register_impl(
    int32_t (*check_adapter)(void),
    void (*start_scan)(void *, const char *),
    void (*stop_scan)(void));

/* Register platform-specific GATT operation implementations. */
void ble_register_gatt_impl(
    void (*discover_services)(void *),
    void (*read_characteristic)(void *, const char *, const char *),
    void (*write_characteristic)(void *, const char *, const char *,
                                 const uint8_t *, int32_t, int32_t),
    void (*set_characteristic_notification)(void *, const char *,
                                            const char *, int32_t),
    void (*request_mtu)(void *, int32_t));

/* Register platform-specific connection implementations.
 * Registered separately from ble_register_impl so that consumer apps
 * whose Activity predates the connect API keep working scans: the
 * Android bridge only registers these when the connect JNI methods
 * resolve. */
void ble_register_connect_impl(
    void (*connect)(void *, const char *),
    void (*disconnect)(void));

#endif /* BLE_BRIDGE_H */
