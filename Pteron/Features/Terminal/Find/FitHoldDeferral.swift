import UIKit

/// Defers find's fit-hold release while another surface holds the layout (goto's palette pad).
///
/// One flag per window, set and cleared by its owner. While it is set, a find field that stops
/// editing marks its hold's release as pending instead of running it: ⌘P from the find field on
/// a rising keyboard must not refit the pane to the shrunk bounds and resize it on the Mac. When
/// the flag clears, a pane whose field holds the keyboard again keeps its hold; any other runs the
/// pending release. Close, font, width, sizing and ownership releases are never deferred.
@MainActor
enum FitHoldDeferral {
    static let cleared = Notification.Name("FitHoldDeferral.cleared")
    private static var windows: Set<ObjectIdentifier> = []

    static func set(_ on: Bool, in window: UIWindow?) {
        guard let window else { return }
        let id = ObjectIdentifier(window)
        if on {
            windows.insert(id)
        } else if windows.remove(id) != nil {
            NotificationCenter.default.post(name: cleared, object: window)
        }
    }

    static func isSet(in window: UIWindow?) -> Bool {
        guard let window else { return false }
        return windows.contains(ObjectIdentifier(window))
    }
}
