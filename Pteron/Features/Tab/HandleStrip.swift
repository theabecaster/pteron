import SwiftUI
import UIKit

/// Where a resize handle's touch area reaches over a pane: a split's divider (`SplitHandle`) and
/// the sidebar's edge (`SidebarSplit`).
///
/// A handle is a SwiftUI gesture, and a SwiftUI gesture's shape over a pane doesn't keep the touch
/// from the pane's UIKit view: the pane's recognizers see it too. So a short drag on a divider
/// was also the pane's tap (the pane became active and raised the keyboard), and a drag on a
/// stacked split's divider also scrolled the pane. Nothing here takes a touch from anyone. Each handle marks its touch area
/// with a view that hit-tests nothing (`HandleStripView`), and each pane has one more recognizer,
/// its grip (`TerminalHost.gripPan`), which takes only touches that start in a strip. The pane's
/// taps and drags wait for the grip to fail on those touches alone: a drag across the strip, the
/// handle's own, starts the grip, so the pane's tap and scroll fail and only the handle's
/// gesture goes on. A tap, a double tap, a long press or a drag along the strip never starts the
/// grip, and the pane has them as anywhere else.
@MainActor
final class HandleStrips {
    private final class Weak {
        weak var view: HandleStripView?
        init(_ view: HandleStripView) { self.view = view }
    }

    private var strips: [Weak] = []

    func add(_ v: HandleStripView) {
        strips.removeAll { $0.view == nil || $0.view === v }
        strips.append(Weak(v))
    }

    func remove(_ v: HandleStripView) {
        strips.removeAll { $0.view == nil || $0.view === v }
    }

    /// The strip that holds `point` (window coordinates) and lies over `pane`, if any. A strip
    /// under the pane (a split's handle under a floating window) is not the pane's business.
    func strip(at point: CGPoint, over pane: UIView) -> HandleStripView? {
        guard let window = pane.window else { return nil }
        for s in strips.reversed() {
            guard let v = s.view, v.window === window, !v.isHidden, v.alpha > 0 else { continue }
            if v.holds(v.convert(point, from: window)), Self.isAbove(v, pane) { return v }
        }
        return nil
    }

    /// Whether `a` is drawn over `b`: under their nearest common ancestor, `a`'s branch comes later.
    static func isAbove(_ a: UIView, _ b: UIView) -> Bool {
        func chain(_ v: UIView) -> [UIView] {
            var out: [UIView] = []
            var cur: UIView? = v
            while let c = cur { out.append(c); cur = c.superview }
            return out.reversed()
        }
        let ca = chain(a), cb = chain(b)
        var i = 0
        while i < ca.count, i < cb.count, ca[i] === cb[i] { i += 1 }
        // No common root, or one inside the other: neither is drawn over the other.
        guard i > 0, i < ca.count, i < cb.count else { return false }
        let siblings = ca[i - 1].subviews
        guard let ia = siblings.firstIndex(where: { $0 === ca[i] }),
              let ib = siblings.firstIndex(where: { $0 === cb[i] }) else { return false }
        return ia > ib
    }

    /// Whether a drag that moved by `dx`, `dy` is the handle's: across the strip. Rex's
    /// side-by-side split (and the sidebar's edge) drags sideways.
    nonisolated static func claims(dx: CGFloat, dy: CGFloat, sideways: Bool) -> Bool {
        guard abs(dx) + abs(dy) > 0 else { return false }
        return sideways ? abs(dx) >= abs(dy) : abs(dy) >= abs(dx)
    }
}

extension EnvironmentValues {
    /// The handles' strips of the window (`HandleStrips`). Owned by `RootView`.
    @Entry var handleStrips: HandleStrips? = nil
}

/// Marks a handle's touch area for the panes under it. Takes no touch.
struct HandleStrip: UIViewRepresentable {
    /// The handle drags sideways (a side-by-side split, the sidebar's edge).
    let sideways: Bool
    /// The touch area within the frame; nil for all of it.
    var shape: AnyShape? = nil

    @Environment(\.handleStrips) private var strips

    func makeUIView(context: Context) -> HandleStripView {
        let v = HandleStripView()
        updateUIView(v, context: context)
        return v
    }

    func updateUIView(_ v: HandleStripView, context: Context) {
        v.sideways = sideways
        v.shape = shape
        v.strips = strips
    }

    static func dismantleUIView(_ v: HandleStripView, coordinator: ()) {
        v.strips = nil
    }
}

final class HandleStripView: UIView {
    var sideways = true
    var shape: AnyShape?
    /// Where the strip is listed while it is in a window.
    var strips: HandleStrips? {
        didSet {
            guard strips !== oldValue else { return }
            oldValue?.remove(self)
            if window != nil { strips?.add(self) }
        }
    }

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError() }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { strips?.add(self) } else { strips?.remove(self) }
    }

    /// Whether `point` (this view's coordinates) is in the touch area.
    func holds(_ point: CGPoint) -> Bool {
        guard bounds.contains(point) else { return false }
        guard let shape else { return true }
        return shape.path(in: bounds).contains(point)
    }
}
