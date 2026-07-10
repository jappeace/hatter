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

/* Haskell FFI export (dispatches connection events back to Haskell) */
extern void haskellOnBleConnectionEvent(void *ctx, int32_t event);

static int32_t (*g_check_adapter_impl)(void) = NULL;
static void (*g_start_scan_impl)(void *) = NULL;
static void (*g_stop_scan_impl)(void) = NULL;
static void (*g_connect_impl)(void *, const char *) = NULL;
static void (*g_disconnect_impl)(void) = NULL;

void ble_register_impl(
    int32_t (*check_adapter)(void),
    void (*start_scan)(void *),
    void (*stop_scan)(void))
{
    g_check_adapter_impl = check_adapter;
    g_start_scan_impl = start_scan;
    g_stop_scan_impl = stop_scan;
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

void ble_start_scan(void *ctx)
{
    if (g_start_scan_impl) {
        g_start_scan_impl(ctx);
        return;
    }
    /* Desktop stub: no-op (no fabricated devices) */
    fprintf(stderr, "[BleBridge stub] ble_start_scan() -> no-op\n");
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
