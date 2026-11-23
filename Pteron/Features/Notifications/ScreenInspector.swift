import UIKit

/// Reads what covers the app's screen from UIKit. Which panes are on screen is `VisiblePanes`.
@MainActor
enum ScreenInspector {
    static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
    }

    /// A sheet, full-screen cover or alert is over the app's main screen.
    static func modalPresented() -> Bool {
        guard let presented = keyWindow?.rootViewController?.presentedViewController else { return false }
        return !presented.isBeingDismissed
    }

    /// Closes whatever is presented over the main screen, so a pane opened from a push shows.
    static func dismissModals() {
        guard modalPresented() else { return }
        keyWindow?.rootViewController?.dismiss(animated: true)
    }
}
