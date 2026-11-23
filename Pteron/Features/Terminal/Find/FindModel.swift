import UIKit

/// The state the pane's two find bars show: one model, two views (`FindAccessoryBar` in the
/// keyboard's accessory slot, `FindOverlayBar` in the pane). Neither view ever moves between the
/// keyboard's window and the pane; each shows the same text and count.
@MainActor
final class FindModel {
    /// The last needle used in any pane: a new find starts with it, selected.
    static var lastText = ""

    /// The field's text, committed and marked.
    private(set) var text = ""
    /// The newest search result.
    private(set) var result = FindResult()
    private var views: [WeakBar] = []

    private struct WeakBar {
        weak var bar: FindBarContent?
    }

    func attach(_ bar: FindBarContent) {
        views.removeAll { $0.bar == nil || $0.bar === bar }
        views.append(WeakBar(bar: bar))
        bar.show(text: text)
        bar.show(result: result)
    }

    /// `from`: the bar whose field typed it (it already shows it).
    func setText(_ t: String, from: FindBarContent?) {
        guard t != text else { return }
        text = t
        for v in views where v.bar !== from { v.bar?.show(text: t) }
    }

    func setResult(_ r: FindResult) {
        guard r != result else { return }
        result = r
        for v in views { v.bar?.show(result: r) }
    }
}
