#ifndef REDRAW_BRIDGE_H
#define REDRAW_BRIDGE_H

/*
 * Platform-agnostic redraw bridge.
 *
 * Allows background Haskell threads to request a UI re-render.
 * On mobile platforms, this posts work to the main/UI thread
 * (required for JNI on Android, main queue on iOS/watchOS).
 * On desktop (no platform registered), calls haskellRenderUI directly.
 *
 * Platform-specific setup functions fill in the real implementation
 * via redraw_register_impl().
 */

/* Request a UI re-render from any thread.
 * ctx is the opaque Haskell context pointer. */
void request_redraw(void *ctx);

/* Register a platform-specific implementation.
 * Called by platform setup functions (setup_android_redraw_bridge, etc). */
void redraw_register_impl(void (*impl)(void *));

#endif /* REDRAW_BRIDGE_H */
