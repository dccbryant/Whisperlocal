import SwiftUI
import UIKit

/// Detects an iPhone shake gesture from anywhere inside SwiftUI. Wire it onto any view that
/// stays mounted while the app is in use (e.g. RootView) and the action fires whenever the
/// user shakes the device.
struct ShakeDetector: UIViewControllerRepresentable {
    let onShake: () -> Void

    func makeUIViewController(context: Context) -> ShakeViewController {
        let vc = ShakeViewController()
        vc.onShake = onShake
        return vc
    }

    func updateUIViewController(_ vc: ShakeViewController, context: Context) {
        vc.onShake = onShake
    }
}

final class ShakeViewController: UIViewController {
    var onShake: (() -> Void)?

    override var canBecomeFirstResponder: Bool { true }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake { onShake?() }
    }
}

/// Open the iOS Mail composer with a pre-filled feedback email to the app author.
/// Falls back silently if no Mail account is configured — the alert layer above this
/// can present a graceful message if needed.
enum FeedbackComposer {
    static let recipient = "dccbryant@gmail.com"

    static func open() {
        let subject = "Parley feedback"
        let body = """


        ---
        \(deviceFooter())
        """

        var components = URLComponents()
        components.scheme = "mailto"
        components.path = recipient
        components.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: body),
        ]
        guard let url = components.url else { return }
        UIApplication.shared.open(url)
    }

    private static func deviceFooter() -> String {
        let dict = Bundle.main.infoDictionary
        let version = (dict?["CFBundleShortVersionString"] as? String) ?? "?"
        let build = (dict?["CFBundleVersion"] as? String) ?? "?"
        let iOS = UIDevice.current.systemVersion
        let model = UIDevice.current.model
        return "Parley \(version) (\(build)) · iOS \(iOS) · \(model)"
    }
}
