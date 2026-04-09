#ifndef LOCATION_BRIDGE_H
#define LOCATION_BRIDGE_H

/*
 * Platform-agnostic location (GPS) bridge.
 *
 * Haskell calls location_start_updates / location_stop_updates through
 * these wrappers.  When no platform callbacks are registered (desktop),
 * start_updates dispatches a fixed location (Amsterdam) so that
 * cabal test can verify the callback path.
 *
 * On Android/iOS the platform-specific setup function fills in real
 * implementations via location_register_impl().
 */

/* Start receiving location updates.  Discovered positions are delivered
 * via haskellOnLocationUpdate(). ctx is the opaque Haskell context. */
void location_start_updates(void *ctx);

/* Stop receiving location updates. */
void location_stop_updates(void);

/* Register platform-specific implementations.
 * Called by platform setup functions (setup_android_location_bridge, etc). */
void location_register_impl(
    void (*start_updates)(void *),
    void (*stop_updates)(void));

#endif /* LOCATION_BRIDGE_H */
