import UIKit

extension UIResponder {
    private static weak var rexFound: UIResponder?

    /// The app's current first responder, if any.
    @MainActor
    static func rexCurrentFirstResponder() -> UIResponder? {
        rexFound = nil
        UIApplication.shared.sendAction(#selector(rexReportFirstResponder(_:)), to: nil, from: nil, for: nil)
        return rexFound
    }

    @objc private func rexReportFirstResponder(_ sender: Any?) {
        UIResponder.rexFound = self
    }
}
