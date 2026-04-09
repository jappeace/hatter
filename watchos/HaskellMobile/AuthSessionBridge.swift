import Foundation
import os.log

/// watchOS auth session bridge — auth sessions are not supported on watchOS.
/// Returns an error immediately via the Haskell callback.

private let bridgeLog = OSLog(subsystem: "me.jappie.haskellmobile", category: "AuthSessionBridge")

@_cdecl("watchos_auth_session_start")
func watchosAuthSessionStart(_ ctx: UnsafeMutableRawPointer?,
                              _ requestId: Int32,
                              _ authUrl: UnsafePointer<CChar>?,
                              _ callbackScheme: UnsafePointer<CChar>?) {
    os_log("auth_session_start: not supported on watchOS (id=%d)", log: bridgeLog, type: .info, requestId)

    "auth sessions not supported on watchOS".withCString { errorMsg in
        haskellOnAuthSessionResult(ctx, requestId, 2 /* ERROR */, nil, errorMsg)
    }
}
