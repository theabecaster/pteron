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
        return max(covered - home(view: view, window: window, windowSafeBottom: windowSafeBottom), 0).rounded(.up)
    }

    /// The part of the window's bottom inset (the home indicator) that reaches the root, which its
    /// safe area has already. UIKit's inset stays the same while the keyboard is up, where
    /// SwiftUI's turns into the keyboard's region.
    static func home(view: CGRect, window: CGRect, windowSafeBottom: CGFloat) -> CGFloat {
        guard !view.isEmpty else { return 0 }
        return max(windowSafeBottom - max(window.maxY - view.maxY, 0), 0)
    }

    /// The padding with the key bar's own frame as a floor. The keyboard reports its frame with
    /// the key bar (its input accessory) in it, but not always: an input-mode switch (ES/EN, emoji)
    /// or a sheet or menu handing the keyboard back can be reported last without it, and the pane
    /// then ran one key bar too tall, its last rows behind the bar. While the keyboard is up the
    /// root keeps clear of the bar's top whatever the keyboard said.
    /// - Parameters:
    ///   - keyBar: the key bar's frame while it is in a window and visible; nil otherwise (the
    ///     palette's field, find, a quiet pane).
    ///   - hiding: the last report was a hide. The keyboard's frame rules then, so a bar frame
    ///     left from before can't hold the pane short on the way down.
    /// With a floating keyboard (an iPad's), the bar alone takes room, where it is docked at the
    /// window's bottom.
    static func padding(keyboard: CGRect, keyBar: CGRect?, hiding: Bool, view: CGRect, window: CGRect,
                        windowSafeBottom: CGFloat) -> CGFloat {
        let pad = padding(keyboard: keyboard, view: view, window: window, windowSafeBottom: windowSafeBottom)
        guard let bar = keyBar, !hiding, !bar.isEmpty else { return pad }
        if floats(keyboard, window: window) {
            // An iPad's floating keyboard leaves its key bar docked at the window's bottom, on its
            // own: the keys take no room, the bar does.
            guard bar.maxY >= window.maxY - 1, bar.maxY <= window.maxY + 1, bar.minY < view.maxY,
                  bar.minX < view.maxX, bar.maxX > view.minX else { return pad }
            return max(pad, padding(keyboard: bar, view: view, window: window, windowSafeBottom: windowSafeBottom))
        }
        guard isUp(keyboard, window: window) else { return pad }
        // A bar the keyboard's top doesn't reach (one laid out before the keyboard placed it,
        // or beside the root), or below the root, isn't the one above these keys.
        guard bar.maxY >= keyboard.minY - 1, bar.minY < view.maxY, bar.maxY <= window.maxY + 1,
              bar.minX < view.maxX, bar.maxX > view.minX else { return pad }
        // The bar's top to the window's bottom, as if the keyboard reached that high.
        let floor = CGRect(x: bar.minX, y: bar.minY, width: bar.width, height: window.maxY - bar.minY)
        return max(pad, padding(keyboard: floor, view: view, window: window, windowSafeBottom: windowSafeBottom))
    }

    /// Floating or undocked: a frame of its own that ends above the window's bottom and shows in
    /// the window. Not an empty frame, which says nothing about where the keys are.
    static func floats(_ keyboard: CGRect, window: CGRect) -> Bool {
        !keyboard.isNull && !keyboard.isEmpty && keyboard.maxY < window.maxY - 1 && keyboard.minY < window.maxY
            && keyboard.maxY > window.minY
    }

    /// Docked at the window's bottom with some of it on screen: shown or showing.
    static func isUp(_ keyboard: CGRect, window: CGRect) -> Bool {
        !keyboard.isNull && !keyboard.isEmpty && keyboard.maxY >= window.maxY - 1 && keyboard.minY < window.maxY - 1
    }
}

/// Reports `KeyboardInset.padding` for the view it backs: on every keyboard frame change and every
/// layout of that view, from the keyboard's last reported frame, the key bar's frame and the
/// frames as they are then. Place it behind the root, ignoring the safe area, so it has the root's
/// frame.
struct KeyboardInsetReader: UIViewRepresentable {
    /// The palette's hold, which ends with a fresh measure instead of the value it kept.
    var padHold: PadHold?
    /// The window's bottom inset under the view (`KeyboardInset.home`), its side insets and its
    /// bottom corners (`WindowBottom`), when they change.
    var onBottom: (WindowBottom) -> Void = { _ in }
    let onChange: (CGFloat) -> Void

    func makeUIView(context: Context) -> Probe {
        let p = Probe()
        p.onChange = onChange
        p.onBottom = onBottom
        connect(p)
        return p
    }

    func updateUIView(_ p: Probe, context: Context) {
        p.onChange = onChange
        p.onBottom = onBottom
        connect(p)
    }

    private func connect(_ p: Probe) {
        padHold?.remeasure[.pad] = { [weak p] in p?.remeasure() }
    }

    final class Probe: UIView {
        var onChange: ((CGFloat) -> Void)?
        var onBottom: ((WindowBottom) -> Void)?
        private var reportedBottom: WindowBottom?
        /// The keyboard's last reported end frame, in screen coordinates.
        private var keyboard: CGRect = .null
        /// The last report was a hide.
        private var hiding = false
        /// The key bar in a window now, which reported itself (`KeyBar.frameChanged`). Its frame is
        /// read whenever the padding is, so it is never one from before.
        private weak var keyBar: UIView?
        private var reported: CGFloat?
        private var settle: DispatchWorkItem?
        /// How long after the keyboard's last frame change the padding is measured again, once
        /// everything has settled.
        static let settleDelay: TimeInterval = 0.3
        /// How many times the padding was reported. Internal for tests.
        private(set) var reports = 0

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            // The window's corners, read as this view's own: it has the root's frame, flush with
            // the window, so its concentric corners are the window's. It draws nothing, so its
            // corners change nothing on screen.
            if #available(iOS 26.0, *) { cornerConfiguration = .corners(radius: .containerConcentric()) }
            let names: [Notification.Name] = [UIResponder.keyboardWillChangeFrameNotification,
                                              UIResponder.keyboardDidChangeFrameNotification,
                                              UIResponder.keyboardWillHideNotification,
                                              UIResponder.keyboardDidHideNotification]
            let nc = NotificationCenter.default
            for name in names {
                nc.addObserver(self, selector: #selector(keyboardChanged), name: name, object: nil)
            }
            nc.addObserver(self, selector: #selector(inputModeChanged),
                           name: UITextInputMode.currentInputModeDidChangeNotification, object: nil)
            nc.addObserver(self, selector: #selector(keyBarChanged), name: KeyBar.frameChanged, object: nil)
        }

        required init?(coder: NSCoder) { fatalError() }

        @objc private func keyboardChanged(_ n: Notification) {
            guard let end = n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            keyboard(end, name: n.name)
        }

        /// A keyboard report. Internal for tests.
        func keyboard(_ end: CGRect, name: Notification.Name) {
            // The last report wins, a did after its will: during a hand-over between panes the
            // reports interleave, and the last one is where the keyboard settled.
            keyboard = end
            hiding = name == UIResponder.keyboardWillHideNotification || name == UIResponder.keyboardDidHideNotification
            update()
            if name == UIResponder.keyboardDidChangeFrameNotification { scheduleSettle() }
        }

        /// A new language or the emoji keyboard: the keyboard's height changes, and the bar may
        /// not lay out again.
        @objc private func inputModeChanged() {
            update()
            scheduleSettle()
        }

        @objc private func keyBarChanged(_ n: Notification) {
            guard let bar = n.object as? UIView else { return }
            keyBarMoved(bar)
        }

        /// A key bar came into a window, left one, moved, or was hidden. Internal for tests.
        func keyBarMoved(_ bar: UIView) {
            if bar.window != nil, !bar.isHidden {
                keyBar = bar
            } else if bar === keyBar {
                keyBar = nil
            }
            update()
        }

        /// Measures again once everything has settled, without animation. It reports only a
        /// padding that differs, in whole points, so by 1 pt or more.
        private func scheduleSettle() {
            settle?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.settled() }
            settle = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay, execute: work)
        }

        /// Internal for tests.
        func settled() {
            settle = nil
            UIView.performWithoutAnimation {
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) { update() }
            }
        }

        /// Reports the padding as it is now, even if unchanged: the palette's hold ended, and the
        /// root takes this instead of the value the hold kept.
        func remeasure() {
            reported = nil
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

        /// The padding as it is now; nil out of a window. Internal for tests.
        func padding() -> CGFloat? {
            guard let window else { return nil }
            let screen = window.screen.coordinateSpace
            let kb = keyboard.isNull ? CGRect.null : window.convert(keyboard, from: screen)
            return KeyboardInset.padding(keyboard: kb, keyBar: keyBarFrame(in: window), hiding: hiding,
                                         view: convert(bounds, to: window), window: window.bounds,
                                         windowSafeBottom: window.safeAreaInsets.bottom)
        }

        /// The key bar's frame in this window, while it shows in this window's scene.
        private func keyBarFrame(in window: UIWindow) -> CGRect? {
            guard let bar = keyBar, let barWindow = bar.window, !bar.isHidden, !barWindow.isHidden,
                  barWindow.windowScene === window.windowScene else { return nil }
            let screen = window.screen.coordinateSpace
            return window.convert(bar.convert(bar.bounds, to: screen), from: screen)
        }

        /// The window's bottom inset under this view, its side insets and, from iOS 26, its bottom
        /// corners' radii. Read in `layoutSubviews` too, where UIKit lays the view out again when
        /// a corner's radius changes.
        private func windowBottom(in window: UIWindow) -> WindowBottom {
            let insets = window.safeAreaInsets
            var b = WindowBottom(home: KeyboardInset.home(view: convert(bounds, to: window), window: window.bounds,
                                                          windowSafeBottom: insets.bottom),
                                 left: insets.left, right: insets.right)
            if #available(iOS 26.0, *) {
                b.corners = .init(left: effectiveRadius(corner: .bottomLeft), right: effectiveRadius(corner: .bottomRight))
            }
            return b
        }

        private func update() {
            if let window {
                // In the same pass as the padding: a turn, a fold or Split View changes them
                // together, and the panes' bottom takes them in one layout.
                let bottom = windowBottom(in: window)
                if bottom != reportedBottom {
                    reportedBottom = bottom
                    #if DEBUG
                    NSLog("WINDOW_BOTTOM home=%.1f sides=%.1f/%.1f corners=%@", bottom.home, bottom.left, bottom.right,
                          bottom.corners.map { String(format: "%.1f/%.1f", $0.left, $0.right) } ?? "unknown")
                    #endif
                    onBottom?(bottom)
                }
            }
            guard let pad = padding(), pad != reported else { return }
            reported = pad
            reports += 1
            onChange?(pad)
        }
    }
}

