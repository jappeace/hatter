/*
 * Platform-agnostic BLE bridge dispatcher.
 *
 * Stores function pointers filled by the platform (Android/iOS).
 * Each ble_* function delegates to the corresponding pointer.
 * When no callbacks are registered (desktop), functions log to stderr
 * and return safe defaults so that cabal build/test works without
 * native code.
 *
 * Unlike the permission bridge, no fabricated devices are delivered
 * on desktop; start_scan is a no-op.  Connection attempts however
 * always produce an event: with no registered implementation,
 * ble_connect dispatches BLE_CONNECTION_FAILED so that callers are
 * never left waiting on a connection that can not happen.
 */

#include "BleBridge.h"
#include <stdio.h>

/* Haskell FFI exports (dispatch results back to Haskell) */
extern void haskellOnBleConnectionEvent(void *ctx, int32_t event);
extern void haskellOnBleGattResult(void *ctx, int32_t operation, int32_t status,
                                   const uint8_t *data, int32_t length);

static int32_t (*g_check_adapter_impl)(void) = NULL;
static void (*g_start_scan_impl)(void *, const char *) = NULL;
static void (*g_stop_scan_impl)(void) = NULL;
static void (*g_connect_impl)(void *, const char *) = NULL;
static void (*g_disconnect_impl)(void) = NULL;
static void (*g_discover_services_impl)(void *) = NULL;
static void (*g_read_characteristic_impl)(void *, const char *, const char *) = NULL;
static void (*g_write_characteristic_impl)(void *, const char *, const char *,
                                           const uint8_t *, int32_t, int32_t) = NULL;
static void (*g_set_notification_impl)(void *, const char *, const char *, int32_t) = NULL;
static void (*g_request_mtu_impl)(void *, int32_t) = NULL;

void ble_register_impl(
    int32_t (*check_adapter)(void),
    void (*start_scan)(void *, const char *),
    void (*stop_scan)(void))
{
    g_check_adapter_impl = check_adapter;
    g_start_scan_impl = start_scan;
    g_stop_scan_impl = stop_scan;
}

void ble_register_gatt_impl(
    void (*discover_services)(void *),
    void (*read_characteristic)(void *, const char *, const char *),
    void (*write_characteristic)(void *, const char *, const char *,
                                 const uint8_t *, int32_t, int32_t),
    void (*set_characteristic_notification)(void *, const char *,
                                            const char *, int32_t),
    void (*request_mtu)(void *, int32_t))
{
    g_discover_services_impl = discover_services;
    g_read_characteristic_impl = read_characteristic;
    g_write_characteristic_impl = write_characteristic;
    g_set_notification_impl = set_characteristic_notification;
    g_request_mtu_impl = request_mtu;
}

/* Fail a GATT operation that has no platform implementation.  Loud and
 * always delivers a completion so callers are never left waiting. */
static void ble_gatt_stub_fail(void *ctx, int32_t operation, const char *name)
{
    fprintf(stderr,
            "[BleBridge stub] %s -> BLE_GATT_STATUS_NO_IMPL"
            " (no platform GATT implementation registered)\n",
            name);
    if (ctx) {
        haskellOnBleGattResult(ctx, operation, BLE_GATT_STATUS_NO_IMPL, NULL, 0);
    } else {
        fprintf(stderr, "[BleBridge stub] %s: null context,"
                " cannot dispatch failure\n", name);
    }
}

void ble_register_connect_impl(
    void (*connect)(void *, const char *),
    void (*disconnect)(void))
{
    g_connect_impl = connect;
    g_disconnect_impl = disconnect;
}

int32_t ble_check_adapter(void)
{
    if (g_check_adapter_impl) {
        return g_check_adapter_impl();
    }
    /* Desktop stub: adapter is on */
    fprintf(stderr, "[BleBridge stub] ble_check_adapter() -> BLE_ADAPTER_ON\n");
    return BLE_ADAPTER_ON;
}

void ble_start_scan(void *ctx, const char *service_uuid_filter)
{
    if (g_start_scan_impl) {
        g_start_scan_impl(ctx, service_uuid_filter);
        return;
    }
    /* Desktop stub: no-op (no fabricated devices) */
    fprintf(stderr, "[BleBridge stub] ble_start_scan(filter=%s) -> no-op\n",
            service_uuid_filter ? service_uuid_filter : "(none)");
}

void ble_stop_scan(void)
{
    if (g_stop_scan_impl) {
        g_stop_scan_impl();
        return;
    }
    /* Desktop stub: no-op */
    fprintf(stderr, "[BleBridge stub] ble_stop_scan() -> no-op\n");
}

void ble_connect(void *ctx, const char *address)
{
    if (g_connect_impl) {
        g_connect_impl(ctx, address);
        return;
    }
    /* No implementation (desktop, or a consumer Activity without the
     * connect JNI methods): fail the connection immediately and loudly
     * instead of leaving the caller waiting forever. */
    fprintf(stderr,
            "[BleBridge stub] ble_connect(\"%s\") -> BLE_CONNECTION_FAILED"
            " (no platform connect implementation registered)\n",
            address ? address : "(null)");
    if (ctx) {
        haskellOnBleConnectionEvent(ctx, BLE_CONNECTION_FAILED);
    } else {
        fprintf(stderr,
                "[BleBridge stub] ble_connect: null context,"
                " cannot dispatch failure event\n");
    }
}

void ble_disconnect(void)
{
    if (g_disconnect_impl) {
        g_disconnect_impl();
        return;
    }
    /* Desktop stub: no-op (nothing can be connected without an impl) */
    fprintf(stderr, "[BleBridge stub] ble_disconnect() -> no-op\n");
}

void ble_discover_services(void *ctx)
{
    if (g_discover_services_impl) {
        g_discover_services_impl(ctx);
        return;
    }
    ble_gatt_stub_fail(ctx, BLE_GATT_OP_DISCOVER, "ble_discover_services()");
}

void ble_read_characteristic(void *ctx, const char *service_uuid,
                             const char *characteristic_uuid)
{
    if (g_read_characteristic_impl) {
        g_read_characteristic_impl(ctx, service_uuid, characteristic_uuid);
        return;
    }
    ble_gatt_stub_fail(ctx, BLE_GATT_OP_READ, "ble_read_characteristic()");
}

void ble_write_characteristic(void *ctx, const char *service_uuid,
                              const char *characteristic_uuid,
                              const uint8_t *data, int32_t length,
                              int32_t write_mode)
{
    if (g_write_characteristic_impl) {
        g_write_characteristic_impl(ctx, service_uuid, characteristic_uuid,
                                    data, length, write_mode);
        return;
    }
    ble_gatt_stub_fail(ctx, BLE_GATT_OP_WRITE, "ble_write_characteristic()");
}

void ble_set_characteristic_notification(void *ctx, const char *service_uuid,
                                         const char *characteristic_uuid,
                                         int32_t enable)
{
    if (g_set_notification_impl) {
        g_set_notification_impl(ctx, service_uuid, characteristic_uuid, enable);
        return;
    }
    ble_gatt_stub_fail(ctx,
                       enable ? BLE_GATT_OP_SUBSCRIBE : BLE_GATT_OP_UNSUBSCRIBE,
                       "ble_set_characteristic_notification()");
}

void ble_request_mtu(void *ctx, int32_t mtu)
{
    if (g_request_mtu_impl) {
        g_request_mtu_impl(ctx, mtu);
        return;
    }
    ble_gatt_stub_fail(ctx, BLE_GATT_OP_MTU, "ble_request_mtu()");
}
