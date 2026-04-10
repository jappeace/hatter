/*
 * Platform-agnostic bottom sheet bridge dispatcher.
 *
 * Stores a function pointer filled by the platform (Android/iOS/watchOS).
 * bottom_sheet_show() delegates to the pointer. When no callback is registered
 * (desktop), a stub logs to stderr and auto-selects the first item via
 * haskellOnBottomSheetResult so that cabal test exercises the round-trip
 * without native code.
 *
 * The opaque Haskell context pointer is threaded through each call
 * rather than stored as a global, allowing multiple contexts to coexist.
 */

#include "BottomSheetBridge.h"
#include <stdio.h>

/* Haskell FFI export (called from desktop stub to dispatch result back) */
extern void haskellOnBottomSheetResult(void *ctx, int32_t requestId, int32_t actionCode);

static void (*g_show_impl)(void *, int32_t, const char *, const char *) = NULL;

void bottom_sheet_register_impl(
    void (*show_impl)(void *, int32_t, const char *, const char *))
{
    g_show_impl = show_impl;
}

/* ---- Desktop stub ---- */

static void stub_show(void *ctx, int32_t requestId,
                      const char *title, const char *items)
{
    fprintf(stderr, "[BottomSheetBridge stub] show(title=\"%s\", items=\"%s\")\n",
            title, items);
    /* Auto-select first item synchronously for desktop testing */
    haskellOnBottomSheetResult(ctx, requestId, 0);
}

/* ---- Public API ---- */

void bottom_sheet_show(void *ctx, int32_t requestId,
                       const char *title, const char *items)
{
    if (g_show_impl) {
        g_show_impl(ctx, requestId, title, items);
        return;
    }
    stub_show(ctx, requestId, title, items);
}
