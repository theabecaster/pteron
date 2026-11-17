import UIKit

/// Reads what is on screen from UIKit, so the toast knows which panes the user is looking at
/// without the tab and sidebar views having to report it.
@MainActor
enum ScreenInspector {
    private static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
    }

    /// Blocks whose terminal is on screen: at least half of it inside the window, not hidden.
    static func visibleBlocks() -> Set<String> {
        guard let window = keyWindow else { return [] }
        var out = Set<String>()
        func walk(_ v: UIView) {
            guard !v.isHidden, v.alpha > 0.01 else { return }
            if let host = v as? TerminalHost {
                let area = host.bounds.width * host.bounds.height
                let shown = host.convert(host.bounds, to: window).intersection(window.bounds)
                if area > 0, !shown.isNull, shown.width * shown.height >= area / 2 { out.insert(host.stream.blockID) }
                return
            }
            for s in v.subviews { walk(s) }
        }
        walk(window)
        return out
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
