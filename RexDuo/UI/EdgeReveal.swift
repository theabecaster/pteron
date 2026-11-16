import SwiftUI
import UIKit

/// Wide layouts: a swipe in from the screen's left edge brings the sidebar back.
/// The recognizer sits on the window, so it works over the terminal too; the terminal's own pane
/// swipe ignores touches that start at the edge.
struct EdgeReveal: UIViewRepresentable {
    var enabled: Bool
    var onReveal: () -> Void

    func makeUIView(context: Context) -> Host { Host() }

    func updateUIView(_ v: Host, context: Context) {
        v.enabled = enabled
        v.onReveal = onReveal
    }

    static func dismantleUIView(_ v: Host, coordinator: ()) { v.detach() }

    final class Host: UIView {
        var enabled = false { didSet { edge.isEnabled = enabled } }
        var onReveal: () -> Void = {}
        private var fired = false
        private lazy var edge: UIScreenEdgePanGestureRecognizer = {
            let g = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(panned(_:)))
            g.edges = .left
            g.isEnabled = false
            return g
        }()

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) { fatalError() }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            edge.view?.removeGestureRecognizer(edge)
            window?.addGestureRecognizer(edge)
        }

        func detach() { edge.view?.removeGestureRecognizer(edge) }

        @objc private func panned(_ g: UIScreenEdgePanGestureRecognizer) {
            let t = g.translation(in: g.view)
            switch g.state {
            case .began:
                fired = false
            case .changed:
                if !fired, t.x > 56 { fired = true; onReveal() }
            case .ended:
                if !fired, t.x > 20, g.velocity(in: g.view).x > 300 { fired = true; onReveal() }
            default:
                break
            }
        }
    }
}
