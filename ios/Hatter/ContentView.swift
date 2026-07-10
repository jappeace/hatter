import SwiftUI
import UIKit

/// Wraps a UIViewController whose view hierarchy is built by Haskell
/// via the iOS UI bridge (UIBridgeIOS.m).
struct HaskellUIView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        let vc = UIViewController()
        vc.view.backgroundColor = .systemBackground
        let ptr = Unmanaged.passUnretained(vc).toOpaque()
        setup_ios_ui_bridge(ptr, HaskellBridge.getContext())

        HaskellBridge.renderUI()

        // CI auto-test: simulate button tap 3s after the initial render.
        // Scheduled here (not in App.init) so the tap always fires AFTER
        // the first render — on slow CI simulators, init() can run 60s+
        // before SwiftUI creates the view.
        if CommandLine.arguments.contains("--autotest") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                HaskellBridge.onUIEvent(0)
            }
        }

        // CI auto-test: simulate typing in a TextInput.
        // Fires onUITextChange with callbackId 0 (the first onChange handle)
        // to verify the re-render pipeline updates the dependent Text widget.
        if CommandLine.arguments.contains("--autotest-textinput") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                HaskellBridge.onUITextChange(0, text: "hello")
            }
        }

        // CI auto-test: exercise the BLE connect path.  Event ids follow
        // the action creation order in test/BleDemoMain.hs: 0 = Check
        // Adapter, 1 = Start Scan, 2 = Stop Scan, 3 = Connect,
        // 4 = Disconnect.  The simulator has no CoreBluetooth support,
        // so Connect must round-trip through the bridge and log
        // BleConnectionFailed without crashing.
        if CommandLine.arguments.contains("--autotest-ble") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                HaskellBridge.onUIEvent(3)  // Connect
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
                HaskellBridge.onUIEvent(4)  // Disconnect
            }
        }

        // CI auto-test: exercise both "+" and "-" buttons.
        // Sequence: +, +, -, -, - → Counter: 1, 2, 1, 0, -1
        if CommandLine.arguments.contains("--autotest-buttons") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                HaskellBridge.onUIEvent(0)  // + → Counter: 1
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                HaskellBridge.onUIEvent(0)  // + → Counter: 2
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 7) {
                HaskellBridge.onUIEvent(1)  // - → Counter: 1
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 9) {
                HaskellBridge.onUIEvent(1)  // - → Counter: 0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 11) {
                HaskellBridge.onUIEvent(1)  // - → Counter: -1
            }
        }

        return vc
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}

struct ContentView: View {
    var body: some View {
        HaskellUIView()
            .edgesIgnoringSafeArea(.all)
    }
}
