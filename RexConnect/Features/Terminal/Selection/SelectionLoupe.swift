import UIKit

/// The magnifier shown over the finger while it selects. Tests put a recorder here.
@MainActor
protocol SelectionLoupe: AnyObject {
    /// Shows the loupe, magnifying `point` of `view`.
    func begin(at point: CGPoint, in view: UIView)
    /// Moves it. `caret` is the edge of the selection being moved (the loupe keeps to its row),
    /// or nil to follow the point freely.
    func move(to point: CGPoint, caret: CGRect?)
    func end()
}

/// The system's text loupe (`UITextLoupeSession`, iOS 17). It needs no `UITextInput` and
/// magnifies what is on screen, so the Metal-drawn grid and its selection highlight appear in
/// it as they are (checked in the simulator; docs/selection.md says what a device still has to
/// confirm). `-selectionLoupe off` turns it off.
@MainActor
final class SystemSelectionLoupe: SelectionLoupe {
    private var session: UITextLoupeSession?
    private let enabled: Bool

    init(enabled: Bool = UserDefaults.standard.string(forKey: "selectionLoupe") != "off") {
        self.enabled = enabled
    }

    func begin(at point: CGPoint, in view: UIView) {
        end()
        guard enabled, view.window != nil else { return }
        session = UITextLoupeSession.begin(at: point, fromSelectionWidgetView: nil, in: view)
    }

    func move(to point: CGPoint, caret: CGRect?) {
        session?.move(to: point, withCaretRect: caret ?? .null, trackingCaret: caret != nil)
    }

    func end() {
        session?.invalidate()
        session = nil
    }
}
