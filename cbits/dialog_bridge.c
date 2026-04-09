/*
 * Platform-agnostic dialog bridge dispatcher.
 *
 * Stores a function pointer filled by the platform (Android/iOS/watchOS).
 * dialog_show() delegates to the pointer. When no callback is registered
 * (desktop), a stub logs to stderr and auto-presses button 1 via
 * haskellOnDialogResult so that cabal test exercises the round-trip
 * without native code.
 *
 * The opaque Haskell context pointer is threaded through each call
 * rather than stored as a global, allowing multiple contexts to coexist.
 */

#include "DialogBridge.h"
#include <stdio.h>

/* Haskell FFI export (called from desktop stub to dispatch result back) */
extern void haskellOnDialogResult(void *ctx, int32_t requestId, int32_t actionCode);

static void (*g_show_impl)(void *, int32_t, const char *, const char *,
                           const char *, const char *, const char *) = NULL;

void dialog_register_impl(
    void (*show_impl)(void *, int32_t, const char *, const char *,
                      const char *, const char *, const char *))
{
    g_show_impl = show_impl;
}

/* ---- Desktop stub ---- */

static void stub_show(void *ctx, int32_t requestId, const char *title,
                      const char *message, const char *button1,
                      const char *button2, const char *button3)
{
    fprintf(stderr, "[DialogBridge stub] show(title=\"%s\", message=\"%s\", "
            "btn1=\"%s\", btn2=%s, btn3=%s)\n",
            title, message, button1,
            button2 ? button2 : "NULL",
            button3 ? button3 : "NULL");
    /* Auto-press button 1 synchronously for desktop testing */
    haskellOnDialogResult(ctx, requestId, DIALOG_BUTTON_1);
}

/* ---- Public API ---- */

void dialog_show(void *ctx, int32_t requestId, const char *title,
                 const char *message, const char *button1,
                 const char *button2, const char *button3)
{
    if (g_show_impl) {
        g_show_impl(ctx, requestId, title, message, button1, button2, button3);
        return;
    }
    stub_show(ctx, requestId, title, message, button1, button2, button3);
}
