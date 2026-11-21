import SwiftUI
import UIKit

/// The vertical bar's Hide Keyboard item. Where the system's vertical bar sits beside the keyboard
/// (iPhone Duo), the key bar has no hide key of its own (`KeyBarPlacement.HideKey.verticalBar`):
/// the root's toolbar shows this item at the top of the bar, above the sidebar toggle, while a
/// pane's key bar is up, over the software keyboard or alone for a hardware one, and nothing in its
/// place when the key bar goes. All Tabs leaves the tab's items while it shows and comes back with
/// it gone (`TabActions.verticalBar`).
///
/// Each pane's host says when its key bar is up with its hide key in the vertical bar
/// (`TerminalHost.barHidesKeyboard`); this keeps the one pane that has it. The change shows one
/// turn of the main queue later, with the animation of the keyboard notification that came with
/// it, so the item comes and goes with the keyboard. The notifications only time it: they never
/// show or hide it. Owned by `TerminalHostPool`.
@MainActor
@Observable
final class HideKeyboardItem: NSObject {
    /// The pane whose keyboard the item hides. Nil while no key bar is up with its hide key in
    /// the vertical bar: no item.
    private(set) var pane: TerminalHostPool.Key?

    /// What `pane` becomes at the next publish.
    @ObservationIgnored private var target: TerminalHostPool.Key?
    @ObservationIgnored private var scheduled = false
    /// The last keyboard notification's animation (nil: none), and when it came.
    @ObservationIgnored private var keyboard: (animation: Animation?, at: CFTimeInterval)?
    /// How recent a keyboard notification must be to time the item.
    static let fresh: CFTimeInterval = 0.3

    override init() {
        super.init()
        let names = [UIResponder.keyboardWillShowNotification, UIResponder.keyboardWillHideNotification,
                     UIResponder.keyboardWillChangeFrameNotification]
        for name in names {
            NotificationCenter.default.addObserver(self, selector: #selector(keyboardMoves(_:)), name: name, object: nil)
        }
    }

    /// A pane's key bar came up with its hide key in the vertical bar (`shown`), or went. A pane
    /// that goes takes the item only if it has it: during a pane switch the new pane may say so first.
    func set(_ key: TerminalHostPool.Key, shown: Bool) {
        if shown {
            target = key
        } else if target == key {
            target = nil
        } else {
            return
        }
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in self?.publish() }
    }

    private func publish() {
        scheduled = false
        guard pane != target else { return }
        let now = CACurrentMediaTime()
        let animation: Animation? = if let k = keyboard, now - k.at < Self.fresh { k.animation } else { Self.keyboardSpring }
        withAnimation(animation) { pane = target }
    }

    @objc private func keyboardMoves(_ n: Notification) {
        let duration = (n.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0
        let curve = (n.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int) ?? UIView.AnimationCurve.easeInOut.rawValue
        keyboard = (Self.animation(duration: duration, curve: curve), CACurrentMediaTime())
    }

    /// The keyboard's own curve (7, not one of `UIView.AnimationCurve`'s cases): a spring, as
    /// UIKit runs it.
    static let keyboardSpring = Animation.interpolatingSpring(mass: 3, stiffness: 1000, damping: 500, initialVelocity: 0)

    /// SwiftUI's form of a keyboard notification's animation. Nil without a duration: no animation
    /// (a rotation, a keyboard that moves at once).
    static func animation(duration: Double, curve: Int) -> Animation? {
        guard duration > 0 else { return nil }
        switch curve {
        case UIView.AnimationCurve.easeInOut.rawValue: return .easeInOut(duration: duration)
        case UIView.AnimationCurve.easeIn.rawValue: return .easeIn(duration: duration)
        case UIView.AnimationCurve.easeOut.rawValue: return .easeOut(duration: duration)
        case UIView.AnimationCurve.linear.rawValue: return .linear(duration: duration)
        default: return keyboardSpring
        }
    }
}
