/*
 * Platform-agnostic location (GPS) bridge dispatcher.
 *
 * Stores function pointers filled by the platform (Android/iOS).
 * Each location_* function delegates to the corresponding pointer.
 * When no callbacks are registered (desktop), start_updates dispatches
 * a fixed location (lat=52.37, lon=4.90, alt=0.0, acc=10.0) so that
 * cabal test can verify the callback path, and stop_updates is a no-op.
 */

#include "LocationBridge.h"
#include <stdio.h>

/* Haskell FFI export (dispatches location update back to Haskell callback) */
extern void haskellOnLocationUpdate(void *ctx, double lat, double lon,
                                     double alt, double acc);

static void (*g_start_updates_impl)(void *) = NULL;
static void (*g_stop_updates_impl)(void) = NULL;

void location_register_impl(
    void (*start_updates)(void *),
    void (*stop_updates)(void))
{
    g_start_updates_impl = start_updates;
    g_stop_updates_impl = stop_updates;
}

void location_start_updates(void *ctx)
{
    if (g_start_updates_impl) {
        g_start_updates_impl(ctx);
        return;
    }
    /* Desktop stub: dispatch a fixed location (Amsterdam) */
    fprintf(stderr, "[LocationBridge stub] location_start_updates() -> fixed location\n");
    haskellOnLocationUpdate(ctx, 52.37, 4.90, 0.0, 10.0);
}

void location_stop_updates(void)
{
    if (g_stop_updates_impl) {
        g_stop_updates_impl();
        return;
    }
    /* Desktop stub: no-op */
    fprintf(stderr, "[LocationBridge stub] location_stop_updates() -> no-op\n");
}
