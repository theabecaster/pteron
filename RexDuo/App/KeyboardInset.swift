import SwiftUI
import UIKit

/// How much room the docked keyboard takes from the bottom of the root, from frames alone.
///
/// The root keeps out of SwiftUI's keyboard safe area and pads itself by this instead. SwiftUI's
/// can stay at a frame the keyboard only had for a moment: when the keyboard moves from one pane's
/// terminal to the next, the system reports it for an instant with both key bars, and the keyboard
/// area stayed one key bar too tall, a band of chrome between the terminal and the key bar that no
/// later layout cleared. This is a pure function of the frames as they are now, so every keyboard
/// change and every root layout computes it afresh and nothing stale can stay.
enum KeyboardInset {
    /// The bottom padding the root adds to its safe area for the keyboard. All rects in window
    /// coordinates.
    /// - Parameters:
    ///   - keyboard: the keyboard's last reported end frame. Below the window when hidden, empty
    ///     when floating.
    ///   - view: the root's frame.
    ///   - window: the window's bounds.
    ///   - windowSafeBottom: the window's own bottom safe-area inset (home indicator), which the
    ///     keyboard covers and the root already keeps clear of.
    static func padding(keyboard: CGRect, view: CGRect, window: CGRect, windowSafeBottom: CGFloat) -> CGFloat {
        guard !keyboard.isNull, !keyboard.isEmpty, !view.isEmpty else { return 0 }
        // Only a keyboard docked at the window's bottom takes room, as in SwiftUI: a floating or
        // undocked one sits over the content.
        guard keyboard.maxY >= window.maxY - 1 else { return 0 }
        guard keyboard.minX < view.maxX, keyboard.maxX > view.minX else { return 0 }
        let covered = min(max(view.maxY - keyboard.minY, 0), view.height)
        // The part of the window's bottom inset that reaches the root, which its safe area has already.
        let container = max(windowSafeBottom - max(window.maxY - view.maxY, 0), 0)
        return max(covered - container, 0).rounded(.up)
    }
}

/// Reports `KeyboardInset.padding` for the view it backs: on every keyboard frame change and every
/// layout of that view, from the keyboard's last reported frame and the frames as they are then.
/// Place it behind the root, ignoring the safe area, so it has the root's frame.
struct KeyboardInsetReader: UIViewRepresentable {
    let onChange: (CGFloat) -> Void

    func makeUIView(context: Context) -> Probe {
        let p = Probe()
        p.onChange = onChange
        return p
    }

    func updateUIView(_ p: Probe, context: Context) {
        p.onChange = onChange
    }

    final class Probe: UIView {
        var onChange: ((CGFloat) -> Void)?
        /// The keyboard's last reported end frame, in screen coordinates.
        private var keyboard: CGRect = .null
        private var reported: CGFloat?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            let names: [Notification.Name] = [UIResponder.keyboardWillChangeFrameNotification,
                                              UIResponder.keyboardDidChangeFrameNotification,
                                              UIResponder.keyboardWillHideNotification,
                                              UIResponder.keyboardDidHideNotification]
            for name in names {
                NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged), name: name, object: nil)
            }
        }

        required init?(coder: NSCoder) { fatalError() }

        @objc private func keyboardChanged(_ n: Notification) {
            guard let end = n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            // The last report wins, a did after its will: during a hand-over between panes the
            // reports interleave, and the last one is where the keyboard settled.
            keyboard = end
            update()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            update()
        }

        override func safeAreaInsetsDidChange() {
            super.safeAreaInsetsDidChange()
            update()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            update()
        }

        private func update() {
            guard let window else { return }
            let kb = keyboard.isNull ? CGRect.null : window.convert(keyboard, from: window.screen.coordinateSpace)
            let pad = KeyboardInset.padding(keyboard: kb, view: convert(bounds, to: window), window: window.bounds,
                                            windowSafeBottom: window.safeAreaInsets.bottom)
            guard pad != reported else { return }
            reported = pad
            onChange?(pad)
        }
    }
}
