/*
 * Platform-agnostic redraw bridge dispatcher.
 *
 * Stores a function pointer filled by the platform (Android/iOS/watchOS).
 * request_redraw() delegates to the platform implementation.
 * When no callback is registered (desktop), calls haskellRenderUI()
 * directly so that cabal test can verify the redraw path.
 */

#include "RedrawBridge.h"
#include <stdio.h>

/* Haskell FFI export (renders the UI tree) */
extern void haskellRenderUI(void *ctx);

static void (*g_request_redraw_impl)(void *) = NULL;

void redraw_register_impl(void (*impl)(void *))
{
    g_request_redraw_impl = impl;
}

void request_redraw(void *ctx)
{
    if (g_request_redraw_impl) {
        g_request_redraw_impl(ctx);
        return;
    }
    /* Desktop stub: call haskellRenderUI directly */
    fprintf(stderr, "[RedrawBridge stub] request_redraw() -> calling haskellRenderUI\n");
    haskellRenderUI(ctx);
}
