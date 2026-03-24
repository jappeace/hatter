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
