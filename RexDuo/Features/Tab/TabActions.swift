import Foundation

/// A tab action, with the title and symbol it shows everywhere it appears.
enum TabAction: Hashable, CaseIterable {
    case splitRight, splitDown, newTab, allTabs, unzoom, hideKeyboard, paneActions, goTo, rename
    /// The vertical bar's first item: the sidebar toggle, or in tab mode the sessions.
    case sidebar, sessions

    var title: String {
        switch self {
        case .splitRight: "Split Right"
        case .splitDown: "Split Down"
        case .newTab: "New Tab"
        case .allTabs: "All Tabs"
        case .unzoom: "Unzoom"
        case .hideKeyboard: "Hide Keyboard"
        case .paneActions: "Pane Actions"
        case .goTo: "Go to Anything…"
        case .rename: "Rename Tab…"
        case .sidebar: "Sidebar"
        case .sessions: "Sessions"
        }
    }

    var symbol: String {
        switch self {
        case .splitRight: "rectangle.split.2x1"
        case .splitDown: "rectangle.split.1x2"
        case .newTab: "plus.square"
        case .allTabs: "square.on.square"
        case .unzoom: "arrow.down.right.and.arrow.up.left"
        case .hideKeyboard: "keyboard.chevron.compact.down"
        // Not an ellipsis: Apple keeps that symbol for the system's overflow menu.
        case .paneActions: "square.split.2x2"
        case .goTo: "magnifyingglass"
        case .rename: "pencil"
        case .sidebar: "sidebar.left"
        case .sessions: "rectangle.stack"
        }
    }
}

/// Where the tab's actions show. Pure, so the tests check that none is out of reach: All Tabs leaves
/// the vertical bar while the key bar is up and stays in the Pane Actions menu and the title menu.
///
/// The vertical bar, top to bottom: the root's items (`leadingItems`: Hide Keyboard while the
/// pane's key bar is up, then the sidebar toggle or Sessions), then the tab's (`verticalBar`).
enum TabActions {
    /// The tab's items in the system's vertical bar, top to bottom, after the root's. With the
    /// keyboard up the bar has room for three items in all. So while the pane's key bar is up with
    /// its hide key in the bar (`HideKeyboardItem`), Hide Keyboard goes first, at the top of the
    /// bar, the item used most then, and All Tabs leaves the tab's items. With the key bar gone,
    /// Hide Keyboard leaves and the order is All Tabs, Pane Actions again. Nothing moves into the
    /// bar's overflow menu where three items fit.
    static func verticalBar(zoomed: Bool, hidesKeyboard: Bool) -> [TabAction] {
        (zoomed ? [.unzoom] : []) + (hidesKeyboard ? [.paneActions] : [.allTabs, .paneActions])
    }

    /// The vertical bar's leading item, first but for Hide Keyboard, which the root draws with no
    /// tab on screen too: the sidebar toggle, and in tab mode Sessions, which opens the session
    /// chip's popover.
    static func barLeading(_ navigation: NavigationStyle) -> TabAction {
        navigation == .tabs ? .sessions : .sidebar
    }

    /// Everything in the vertical bar, top to bottom, room aside: Hide Keyboard first while the
    /// key bar is up, and only then. Tab mode changes the leading item and nothing else, so the bar
    /// holds as many items either way.
    static func verticalBar(_ navigation: NavigationStyle, zoomed: Bool, hidesKeyboard: Bool) -> [TabAction] {
        (hidesKeyboard ? [.hideKeyboard] : []) + [barLeading(navigation)] + verticalBar(zoomed: zoomed, hidesKeyboard: hidesKeyboard)
    }

    /// The items, the root's among them, that the vertical bar fits above the keyboard and
    /// key bar. Three, except on the outer screen on its side with the bar on the left, where the
    /// bar's items start lower, past the camera, and two fit. The system reports neither the items'
    /// frames nor that offset, so this reads the facts the key bar already uses: the bar's column
    /// on the screen's left (`KeyBarPlacement.column`, in screen coordinates) and a compact height.
    /// - Parameters:
    ///   - column: the bar's column in screen coordinates, nil without a vertical bar.
    ///   - compactHeight: the window's vertical size class is compact.
    static func keyBarRoom(column: CGRect?, compactHeight: Bool) -> Int {
        guard let column else { return 3 }
        return column.minX < 1 && compactHeight ? 2 : 3
    }

    /// Whether the bar's leading item (`barLeading`: the sidebar toggle, or Sessions in tab mode)
    /// keeps its place, below Hide Keyboard while that shows. While the key bar is up it gives its
    /// place up first where the bar has no room for it beside Hide Keyboard and Pane Actions, and
    /// comes back when the key bar goes, so nothing falls into the system's "…" menu.
    static func showsBarLeading(hidesKeyboard: Bool, room: Int) -> Bool {
        !hidesKeyboard || room > 1 + verticalBar(zoomed: false, hidesKeyboard: true).count
    }

    /// The root's items in the vertical bar, top to bottom: Hide Keyboard while the key bar is up,
    /// and only then, then the leading item as `showsBarLeading` leaves it.
    static func leadingItems(_ navigation: NavigationStyle, hidesKeyboard: Bool, room: Int) -> [TabAction] {
        (hidesKeyboard ? [.hideKeyboard] : [])
            + (showsBarLeading(hidesKeyboard: hidesKeyboard, room: room) ? [barLeading(navigation)] : [])
    }

    /// The tab's items that fit in `room` (`keyBarRoom`) below the root's (`leadingItems`): while
    /// the key bar is up, items leave from the top (Unzoom, which stays in the Pane Actions menu
    /// and the two-finger tap) until the rest fit, and Pane Actions, last, always stays.
    static func verticalBar(zoomed: Bool, hidesKeyboard: Bool, room: Int) -> [TabAction] {
        var items = verticalBar(zoomed: zoomed, hidesKeyboard: hidesKeyboard)
        guard hidesKeyboard else { return items }
        let leading = leadingItems(.sidebar, hidesKeyboard: true, room: room).count
        while leading + items.count > room, items.count > 1 { items.removeFirst() }
        return items
    }

    /// Everything the vertical bar shows in `room`, top to bottom: the root's items, then the tab's.
    static func verticalBar(_ navigation: NavigationStyle, zoomed: Bool, hidesKeyboard: Bool, room: Int) -> [TabAction] {
        leadingItems(navigation, hidesKeyboard: hidesKeyboard, room: room)
            + verticalBar(zoomed: zoomed, hidesKeyboard: hidesKeyboard, room: room)
    }

    /// The Pane Actions menu's first section.
    static let paneMenuFirstSection: [TabAction] = [.splitRight, .splitDown, .newTab, .allTabs]

    /// The title menu's rows after the session's tabs.
    static let titleMenu: [TabAction] = [.allTabs, .goTo, .newTab, .rename]
}
