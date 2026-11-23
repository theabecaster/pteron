import ObjectiveC
import StoreKit
import UIKit

/// The Tailscale app, which this iPhone uses to reach a computer's Rex privately: what its
/// addresses look like, and its App Store page, shown in the app. There is no documented way to
/// open Tailscale itself, or to tell an installed but disconnected Tailscale from none.
enum TailscaleApp {
    static let appStoreID = 1_470_499_037

    /// A server address on a tailnet (`*.ts.net`).
    static func isTailnetAddress(_ address: String) -> Bool {
        guard let host = ServerConfig.url(from: address)?.host()?.lowercased() else { return false }
        return host.hasSuffix(".ts.net")
    }

    /// The App Store page in a sheet over whatever is on screen, so the person stays in the app.
    /// Where the page can't load (a simulator, no App Store), Safari opens it instead.
    /// `onClose` runs once the sheet is gone, or at once when there was none.
    @MainActor
    static func showInAppStore(onClose: @escaping @MainActor () -> Void = {}) {
        let web = URL(string: "https://apps.apple.com/app/id\(appStoreID)")
        guard let top = topViewController() else {
            if let web { UIApplication.shared.open(web) }
            onClose()
            return
        }
        let store = SKStoreProductViewController()
        let closer = StoreCloser(onClose: onClose)
        store.delegate = closer
        // The delegate lives as long as the sheet does.
        objc_setAssociatedObject(store, &StoreCloser.key, closer, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        top.present(store, animated: true)
        // A swipe down closes the sheet without its Done button.
        store.presentationController?.delegate = closer
        store.loadProduct(withParameters: [SKStoreProductParameterITunesItemIdentifier: NSNumber(value: appStoreID)]) { loaded, _ in
            guard !loaded else { return }
            Task { @MainActor in
                store.dismiss(animated: true) { closer.closed() }
                if let web { await UIApplication.shared.open(web) }
            }
        }
    }

    @MainActor
    private static func topViewController() -> UIViewController? {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?
            .keyWindow
        var top = window?.rootViewController
        while let next = top?.presentedViewController, !next.isBeingDismissed { top = next }
        return top
    }

    /// Closes the App Store sheet on its Done button, and says once that it is gone, however it went.
    @MainActor
    private final class StoreCloser: NSObject, SKStoreProductViewControllerDelegate, UIAdaptivePresentationControllerDelegate {
        /// The association's key. `nonisolated(unsafe)`: only its address is used, its value is
        /// never read or written.
        nonisolated(unsafe) static var key: UInt8 = 0
        private let onClose: @MainActor () -> Void
        private var done = false

        init(onClose: @escaping @MainActor () -> Void) { self.onClose = onClose }

        func closed() {
            guard !done else { return }
            done = true
            onClose()
        }

        nonisolated func productViewControllerDidFinish(_ viewController: SKStoreProductViewController) {
            // StoreKit calls its delegate on the main thread.
            MainActor.assumeIsolated {
                viewController.dismiss(animated: true) { self.closed() }
            }
        }

        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            closed()
        }
    }
}
