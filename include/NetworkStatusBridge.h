#ifndef NETWORK_STATUS_BRIDGE_H
#define NETWORK_STATUS_BRIDGE_H

/*
 * Platform-agnostic network connectivity status bridge.
 *
 * Haskell calls network_status_start_monitoring /
 * network_status_stop_monitoring through these wrappers.  When no
 * platform callbacks are registered (desktop), start_monitoring
 * dispatches a fixed status (connected=1, transport=WIFI) so that
 * cabal test can verify the callback path.
 *
 * On Android/iOS the platform-specific setup function fills in real
 * implementations via network_status_register_impl().
 */

/* Transport type constants (must match NetworkTransport enum in Haskell) */
#define NETWORK_TRANSPORT_NONE      0
#define NETWORK_TRANSPORT_WIFI      1
#define NETWORK_TRANSPORT_CELLULAR  2
#define NETWORK_TRANSPORT_ETHERNET  3
#define NETWORK_TRANSPORT_OTHER     4

/* Start monitoring network connectivity changes.  Status changes are
 * delivered via haskellOnNetworkStatusChange().  ctx is the opaque
 * Haskell context. */
void network_status_start_monitoring(void *ctx);

/* Stop monitoring network connectivity changes. */
void network_status_stop_monitoring(void);

/* Register platform-specific implementations.
 * Called by platform setup functions (setup_android_network_status_bridge,
 * etc). */
void network_status_register_impl(
    void (*start_monitoring)(void *),
    void (*stop_monitoring)(void));

#endif /* NETWORK_STATUS_BRIDGE_H */
