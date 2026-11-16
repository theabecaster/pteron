import SwiftUI
import TipKit

/// One-time hints that point out a gesture after the user has done the same thing the long way.
/// Each shows at most once, and TipKit shows at most one tip a day.
@MainActor
enum GestureTips {
    private static var configured = false

    /// `-tips off` hides every tip (UI tests); `-tips show` shows them all (screenshots).
    static func configure() {
        guard !configured else { return }
        configured = true
        switch UserDefaults.standard.string(forKey: "tips") {
        case "off": Tips.hideAllTipsForTesting()
        case "show": Tips.showAllTipsForTesting()
        default: break
        }
        try? Tips.configure([.displayFrequency(.daily)])
    }

    static func donate(_ e: Tips.Event<Tips.EmptyDonation>) {
        Task { await e.donate() }
    }
}

/// After Zoom was picked from the ⋯ menu twice.
struct ZoomGestureTip: Tip {
    static let zoomedFromMenu = Tips.Event(id: "zoomedFromMenu")
    var title: Text { Text("Tap with two fingers to zoom") }
    var message: Text? { Text("Tap a pane with two fingers to show it alone. Do it again to go back.") }
    var image: Image? { Image(systemName: "hand.tap") }
    var rules: [Rule] { #Rule(Self.zoomedFromMenu) { $0.donations.count >= 2 } }
    var options: [any TipOption] { MaxDisplayCount(1) }
}

/// After three tab switches from the title menu.
struct OverviewGestureTip: Tip {
    static let switchedFromTitleMenu = Tips.Event(id: "switchedFromTitleMenu")
    var title: Text { Text("Swipe up here to see all tabs") }
    var image: Image? { Image(systemName: "square.on.square") }
    var rules: [Rule] { #Rule(Self.switchedFromTitleMenu) { $0.donations.count >= 3 } }
    var options: [any TipOption] { MaxDisplayCount(1) }
}

/// After three tab switches from the title menu or the sidebar.
struct TabSwipeTip: Tip {
    static let switchedTabs = Tips.Event(id: "switchedTabs")
    var title: Text { Text("Swipe the title to change tabs") }
    var image: Image? { Image(systemName: "arrow.left.and.right") }
    var rules: [Rule] { #Rule(Self.switchedTabs) { $0.donations.count >= 3 } }
    var options: [any TipOption] { MaxDisplayCount(1) }
}

/// After the first split made from the ⋯ menu.
struct PlusMenuTip: Tip {
    static let splitFromMenu = Tips.Event(id: "splitFromMenu")
    var title: Text { Text("Touch and hold + for more") }
    var message: Text? { Text("Tap + to split this pane. Hold it to pick a direction or open a tab.") }
    var image: Image? { Image(systemName: "plus") }
    var rules: [Rule] { #Rule(Self.splitFromMenu) { $0.donations.count >= 1 } }
    var options: [any TipOption] { MaxDisplayCount(1) }
}
