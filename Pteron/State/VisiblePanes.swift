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

    /// The panes a tab without a float on screen shows: only the active one when it shows one
    /// pane at a time (`single`), else every tiled pane of its splits. A minimized float's pane
    /// is never one.
    nonisolated static func inTab(_ w: WindowInfo, active: String, single: Bool) -> Set<String> {
        single ? [active] : Set(w.tiledPageIDs)
    }

    /// The panes a tab with a floating window on screen shows (`TabPresentation`): the page
    /// shown, or the tiled panes drawn and every float's panes. Minimized floats and pages a
    /// swipe away aren't on screen. The toasts' UIKit walk (`onScreen`) finds the same hosts.
    nonisolated static func inTab(_ w: WindowInfo, _ presentation: TabPresentation) -> Set<String> {
        presentation.visible(in: w)
    }
}
