import Foundation
import os.log

/// Swift wrapper around the Haskell FFI functions exposed via C.
class HaskellBridge {
    private static let bridgeLog = OSLog(subsystem: "me.jappie.hatter", category: "UIBridge")
    // Lifecycle event codes (must match Hatter.h)
    static let lifecycleCreate: Int32     = 0
    static let lifecycleStart: Int32      = 1
    static let lifecycleResume: Int32     = 2
    static let lifecyclePause: Int32      = 3
    static let lifecycleStop: Int32       = 4
    static let lifecycleDestroy: Int32    = 5
    static let lifecycleLowMemory: Int32  = 6

    /// Opaque Haskell context pointer, created during initialization.
    private static var context: UnsafeMutableRawPointer?

    /// Initialize the Haskell RTS. Must be called before any other Haskell function.
    /// Uses hatter_hs_init with RtsConfig to set -M512m — passing argv to hs_init
    /// hangs on iOS cross-compiled builds (the argv parsing codepath is broken).
    static func initialize() {
        os_log("HaskellBridge: calling hatter_hs_init with -M512m", log: bridgeLog, type: .fault)
        hatter_hs_init("-M512m")
        os_log("HaskellBridge: hatter_hs_init returned", log: bridgeLog, type: .fault)

        setup_ios_platform_globals()
        os_log("HaskellBridge: platform globals set", log: bridgeLog, type: .info)

        context = haskellRunMain()
        os_log("HaskellBridge: haskellRunMain done, context=%{public}s", log: bridgeLog, type: .info, String(describing: context))

        haskellLogLocale()
        setup_ios_permission_bridge(context)
        setup_ios_secure_storage_bridge(context)
        setup_ios_ble_bridge(context)
        setup_ios_dialog_bridge(context)
        setup_ios_location_bridge(context)
        setup_ios_auth_session_bridge(context)
        setup_ios_camera_bridge(context)
        setup_ios_bottom_sheet_bridge(context)
        setup_ios_http_bridge(context)
        setup_ios_network_status_bridge(context)
        setup_ios_animation_bridge(context)
        setup_ios_redraw_bridge(context)
        setup_ios_platform_sign_in_bridge(context)
        os_log("HaskellBridge: all bridges initialized", log: bridgeLog, type: .info)
    }

    /// Notify Haskell of a lifecycle event.
    static func onLifecycle(_ event: Int32) {
        haskellOnLifecycle(context, event)
    }

    /// Render the Haskell UI tree via the registered bridge callbacks.
    static func renderUI() {
        haskellRenderUI(context)
    }

    /// Dispatch a UI event (e.g. button tap) to Haskell, which re-renders.
    static func onUIEvent(_ callbackId: Int32) {
        os_log("Click dispatched: callbackId=%d", log: bridgeLog, type: .info, callbackId)
        haskellOnUIEvent(context, callbackId)
    }

    /// Dispatch a text change event to Haskell (does not re-render).
    static func onUITextChange(_ callbackId: Int32, text: String) {
        haskellOnUITextChange(context, callbackId, text)
    }

    /// Return the opaque Haskell context pointer (for passing to C bridge setup).
    static func getContext() -> UnsafeMutableRawPointer? {
        return context
    }

}
