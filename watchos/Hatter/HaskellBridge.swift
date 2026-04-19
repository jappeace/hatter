import Foundation
import WatchKit
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
    /// Passes -M256m to limit the heap — watchOS rejects the default ~1TB virtual memory reservation.
    static func initialize() {
        os_log("HaskellBridge: starting hs_init", log: bridgeLog, type: .info)
        let rtsArgs = ["hatter", "+RTS", "-M256m", "-RTS"]
        var args: [UnsafeMutablePointer<CChar>?] = rtsArgs.map { strdup($0) }
        args.append(nil)  // null terminator, like C argv
        var argc = Int32(rtsArgs.count)
        os_log("HaskellBridge: argc=%d, args allocated", log: bridgeLog, type: .info, argc)
        os_log("HaskellBridge: calling hs_init", log: bridgeLog, type: .info)
        args.withUnsafeMutableBufferPointer { buf in
            var ptr = buf.baseAddress
            withUnsafeMutablePointer(to: &ptr) { argv in
                os_log("HaskellBridge: about to call hs_init(&argc, argv)", log: bridgeLog, type: .info)
                hs_init(&argc, argv)
            }
        }
        os_log("HaskellBridge: hs_init returned, argc now=%d", log: bridgeLog, type: .info, argc)
        for arg in args { if let arg = arg { free(arg) } }
        setSystemLocale("en")  // watchOS default locale, before Haskell main

        // Device info — WKInterfaceDevice for watchOS
        let device = WKInterfaceDevice.current()
        setDeviceModel(strdup(device.model))
        setDeviceOsVersion(strdup(device.systemVersion))
        let scale = device.screenScale
        setDeviceScreenDensity(strdup(String(format: "%.1f", scale)))
        let bounds = device.screenBounds
        setDeviceScreenWidth(strdup(String(Int(bounds.width * scale))))
        setDeviceScreenHeight(strdup(String(Int(bounds.height * scale))))

        context = haskellRunMain()
        haskellLogLocale()
        haskellLogDeviceInfo()
        setup_watchos_redraw_bridge(context)
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

    /// Dispatch a text change event to Haskell.
    static func onUITextChange(_ callbackId: Int32, _ text: String) {
        os_log("Text changed: callbackId=%d", log: bridgeLog, type: .info, callbackId)
        haskellOnUITextChange(context, callbackId, text)
    }

    /// Return the opaque Haskell context pointer (for passing to C bridge setup).
    static func getContext() -> UnsafeMutableRawPointer? {
        return context
    }

}
