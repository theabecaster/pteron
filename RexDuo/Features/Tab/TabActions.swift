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
enum TabActions {
    /// The tab's items in the system's vertical bar, top to bottom, after the sidebar toggle. With
    /// the keyboard up the bar has room for three items in all. So while the pane's key bar is up
    /// with its hide key in the bar (`HideKeyboardItem`), Hide Keyboard takes All Tabs' place:
    /// nothing moves into the bar's overflow menu and Pane Actions keeps its place.
    static func verticalBar(zoomed: Bool, hidesKeyboard: Bool) -> [TabAction] {
        (zoomed ? [.unzoom] : []) + [hidesKeyboard ? .hideKeyboard : .allTabs, .paneActions]
    }

    /// The vertical bar's first item, which the root draws with no tab on screen too: the
    /// sidebar toggle, and in tab mode Sessions, which opens the session chip's popover.
    static func barLeading(_ navigation: NavigationStyle) -> TabAction {
        navigation == .tabs ? .sessions : .sidebar
    }

    /// Everything in the vertical bar, top to bottom. Tab mode changes the first item and
    /// nothing else, so the bar holds as many items either way.
    static func verticalBar(_ navigation: NavigationStyle, zoomed: Bool, hidesKeyboard: Bool) -> [TabAction] {
        [barLeading(navigation)] + verticalBar(zoomed: zoomed, hidesKeyboard: hidesKeyboard)
    }

    /// The Pane Actions menu's first section.
    static let paneMenuFirstSection: [TabAction] = [.splitRight, .splitDown, .newTab, .allTabs]

    /// The title menu's rows after the session's tabs.
    static let titleMenu: [TabAction] = [.allTabs, .goTo, .newTab, .rename]
}
