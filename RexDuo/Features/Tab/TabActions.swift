import Foundation

/// A tab action, with the title and symbol it shows everywhere it appears.
enum TabAction: Hashable, CaseIterable {
    case splitRight, splitDown, newTab, allTabs, unzoom, hideKeyboard, paneActions, goTo, rename, floats
    /// The vertical bar's first item in sidebar mode: the sidebar toggle.
    case sidebar

    var title: String {
        switch self {
        case .splitRight: "Split Pane Right"
        case .splitDown: "Split Pane Down"
        case .newTab: "New Tab"
        case .allTabs: "Show All Tabs"
        case .unzoom: "Unzoom"
        case .hideKeyboard: "Hide Keyboard"
        case .paneActions: "Pane Actions"
        case .goTo: "Go to Anything…"
        case .rename: "Rename Tab…"
        case .floats: "Floating Windows"
        case .sidebar: "Sidebar"
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
        // Not All Tabs' square.on.square: a window over a window.
        case .floats: "macwindow.on.rectangle"
        case .sidebar: "sidebar.left"
        }
    }
}

/// Whether closing a tab asks first, and what the question says: it asks when an agent would stop,
/// and when the tab holds two panes or more, as Close Other Panes always asks. The same rule for
/// every Close Tab: the title bar's, a chip's, a sidebar row's and the keyboard's.
struct CloseTabAsk: Equatable {
    /// Every pane in the tab, floating ones too: they all close.
    var panes: Int
    /// An agent runs in one of them.
    var agent: Bool

    /// nil: the tab closes at once.
    static func decide(panes: Int, agent: Bool) -> CloseTabAsk? {
        agent || panes >= 2 ? CloseTabAsk(panes: panes, agent: agent) : nil
    }

    static let title = "Close this tab?"

    func message(computer: String) -> String {
        switch (agent, panes >= 2) {
        case (true, true): "Its \(panes) panes close, and the agent running there stops on \(computer) too."
        case (true, false): "The agent running there stops on \(computer) too."
        default: "Its \(panes) panes close, and their programs stop on \(computer) too."
        }
    }
}

/// Where the tab's actions show. Pure, so the tests check that none is out of reach: All Tabs leaves
/// the vertical bar while the key bar is up where the bar has no room for it, and stays in the Pane
/// Actions menu and the title menu.
///
/// The vertical bar, top to bottom: the root's items (`leadingItems`: Hide Keyboard while the
/// pane's key bar is up, then the sidebar toggle in sidebar mode), then the tab's (`tabItems`).
/// Tab mode has no leading item: the strip's session chip, always placed beside the bar, opens
/// the sessions.
enum TabActions {
    /// The items the bar fits above the keyboard and key bar where nothing cuts it short
    /// (`keyBarRoom`).
    static let fullRoom = 3

    /// The vertical bar's leading item, first but for Hide Keyboard, which the root draws with no
    /// tab on screen too: the sidebar toggle. None in tab mode, where the session chip beside the
    /// tabs opens the sessions, so the bar would only repeat it.
    static func barLeading(_ navigation: NavigationStyle) -> TabAction? {
        navigation == .sidebar ? .sidebar : nil
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
        guard let column else { return fullRoom }
        return column.minX < 1 && compactHeight ? 2 : fullRoom
    }

    /// Whether the bar's leading item (`barLeading`), where the mode has one, keeps its place,
    /// below Hide Keyboard while that shows. While the key bar is up it gives its place up first
    /// where the bar has no room for it beside Hide Keyboard and Pane Actions, and comes back when
    /// the key bar goes, so nothing falls into the system's "…" menu.
    static func showsBarLeading(hidesKeyboard: Bool, room: Int) -> Bool {
        // Hide Keyboard and Pane Actions, which always stay, and the leading item.
        !hidesKeyboard || room > 2
    }

    /// The root's items in the vertical bar, top to bottom: Hide Keyboard while the key bar is up,
    /// and only then, then the leading item, where the mode has one, as `showsBarLeading` leaves it.
    static func leadingItems(_ navigation: NavigationStyle, hidesKeyboard: Bool, room: Int) -> [TabAction] {
        let leading = barLeading(navigation).map { [$0] } ?? []
        return (hidesKeyboard ? [.hideKeyboard] : [])
            + (showsBarLeading(hidesKeyboard: hidesKeyboard, room: room) ? leading : [])
    }

    /// The tab's items in the vertical bar, top to bottom, below the root's (`leadingItems`):
    /// Unzoom while zoomed, All Tabs, Pane Actions, then Floating Windows (a narrow tab with a
    /// float) with the keyboard down only: it goes while typing without moving another item, and
    /// the sheet's grabber and the Pane Actions menu keep the floats in reach. With the keyboard
    /// down nothing is trimmed. While the key bar is up, with Hide Keyboard at the top of the bar,
    /// items leave from the top (Unzoom, which stays in the Pane Actions menu and the two-finger
    /// tap, then All Tabs, which stays in that menu and the title menu) until the root's and the
    /// tab's fit in `room` (`keyBarRoom`), and Pane Actions, last, always stays. So in sidebar mode
    /// the toggle keeps All Tabs out while typing, and in tab mode, with no leading item, All Tabs
    /// stays where three fit. Nothing moves into the bar's overflow menu.
    static func tabItems(_ navigation: NavigationStyle, zoomed: Bool, hidesKeyboard: Bool, room: Int = fullRoom,
                         floats: Bool = false) -> [TabAction] {
        var items: [TabAction] = (zoomed ? [.unzoom] : []) + [.allTabs, .paneActions]
        guard hidesKeyboard else { return items + (floats ? [.floats] : []) }
        let leading = leadingItems(navigation, hidesKeyboard: true, room: room).count
        while leading + items.count > room, items.count > 1 { items.removeFirst() }
        return items
    }

    /// Everything the vertical bar shows in `room`, top to bottom: the root's items, then the tab's.
    static func verticalBar(_ navigation: NavigationStyle, zoomed: Bool, hidesKeyboard: Bool,
                            room: Int = fullRoom) -> [TabAction] {
        leadingItems(navigation, hidesKeyboard: hidesKeyboard, room: room)
            + tabItems(navigation, zoomed: zoomed, hidesKeyboard: hidesKeyboard, room: room)
    }

    /// The Pane Actions menu's first section.
    static let paneMenuFirstSection: [TabAction] = [.splitRight, .splitDown, .newTab, .allTabs]

    /// The title menu's rows after the session's tabs.
    static let titleMenu: [TabAction] = [.allTabs, .goTo, .newTab, .rename]
}
