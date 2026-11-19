import UIKit
import RexKit

/// Which panes the user is looking at: one answer for everything that holds back a signal about a
/// pane in view (toasts, the Waiting pill). Floating panes later change what counts here, and the
/// callers follow without edits.
@MainActor
enum VisiblePanes {
    /// Blocks whose terminal is on screen now, read from UIKit: at least half of it inside the key
    /// window, not hidden. The tab and sidebar views don't have to report it.
    static func onScreen() -> Set<String> {
        guard let window = ScreenInspector.keyWindow else { return [] }
        return onScreen(in: window)
    }

    /// The same, under one window.
    static func onScreen(in window: UIWindow) -> Set<String> {
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

    /// The panes a tab shows: only the active one when it shows one pane at a time (`single`),
    /// else every pane of its splits.
    nonisolated static func inTab(_ w: WindowInfo, active: String, single: Bool) -> Set<String> {
        single ? [active] : Set(w.orderedBlockIDs)
    }
}
