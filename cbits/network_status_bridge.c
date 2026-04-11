/*
 * Platform-agnostic network connectivity status bridge dispatcher.
 *
 * Stores function pointers filled by the platform (Android/iOS).
 * Each network_status_* function delegates to the corresponding pointer.
 * When no callbacks are registered (desktop), start_monitoring dispatches
 * a fixed status (connected=1, transport=WIFI) so that cabal test can
 * verify the callback path, and stop_monitoring is a no-op.
 */

#include "NetworkStatusBridge.h"
#include <stdio.h>

/* Haskell FFI export (dispatches network status change back to Haskell callback) */
extern void haskellOnNetworkStatusChange(void *ctx, int connected, int transport);

static void (*g_start_monitoring_impl)(void *) = NULL;
static void (*g_stop_monitoring_impl)(void) = NULL;

void network_status_register_impl(
    void (*start_monitoring)(void *),
    void (*stop_monitoring)(void))
{
    g_start_monitoring_impl = start_monitoring;
    g_stop_monitoring_impl = stop_monitoring;
}

void network_status_start_monitoring(void *ctx)
{
    if (g_start_monitoring_impl) {
        g_start_monitoring_impl(ctx);
        return;
    }
    /* Desktop stub: dispatch a fixed status (connected, WiFi) */
    fprintf(stderr, "[NetworkStatusBridge stub] network_status_start_monitoring() -> connected WiFi\n");
    haskellOnNetworkStatusChange(ctx, 1, NETWORK_TRANSPORT_WIFI);
}

void network_status_stop_monitoring(void)
{
    if (g_stop_monitoring_impl) {
        g_stop_monitoring_impl();
        return;
    }
    /* Desktop stub: no-op */
    fprintf(stderr, "[NetworkStatusBridge stub] network_status_stop_monitoring() -> no-op\n");
}
