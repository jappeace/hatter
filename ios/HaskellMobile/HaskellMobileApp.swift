import SwiftUI

@main
struct HaskellMobileApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        HaskellBridge.initialize()
        HaskellBridge.onLifecycle(HaskellBridge.lifecycleCreate)

        // CI auto-test: simulate a "+" button tap after 3 seconds
        if CommandLine.arguments.contains("--autotest") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                HaskellBridge.onUIEvent(0)
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .onChange(of: scenePhase) { newPhase in
            switch newPhase {
            case .active:
                HaskellBridge.onLifecycle(HaskellBridge.lifecycleResume)
            case .inactive:
                HaskellBridge.onLifecycle(HaskellBridge.lifecyclePause)
            case .background:
                HaskellBridge.onLifecycle(HaskellBridge.lifecycleStop)
            @unknown default:
                break
            }
        }
    }
}
