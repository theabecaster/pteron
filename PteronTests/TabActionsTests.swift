import CoreGraphics
import Testing
@testable import Pteron

/// The tab's actions in the vertical bar and its menus (`TabActions`): Hide Keyboard is the bar's
/// top item while the key bar is up and absent while it is down, All Tabs leaves the bar while it
/// shows where the bar has no room for it, tab mode has no leading item, and every action stays
/// within reach.
struct TabActionsTests {
    @Test func hideKeyboardIsFirstWhileTheKeyboardIsUpAndAbsentWhenDown() {
        for navigation in [NavigationStyle.sidebar, .tabs] {
            for zoomed in [false, true] {
                for room in [2, 3] {
                    let up = TabActions.verticalBar(navigation, zoomed: zoomed, hidesKeyboard: true, room: room)
                    let down = TabActions.verticalBar(navigation, zoomed: zoomed, hidesKeyboard: false, room: room)
                    #expect(up.first == .hideKeyboard, "\(navigation), zoomed \(zoomed), room \(room)")
                    #expect(up.filter { $0 == .hideKeyboard }.count == 1)
                    #expect(!down.contains(.hideKeyboard))
                    // Keyboard down, the bar is as it was before Hide Keyboard came to it.
                    let lead: [TabAction] = navigation == .sidebar ? [.sidebar] : []
                    #expect(down == lead + (zoomed ? [.unzoom] : []) + [.allTabs, .paneActions])
                }
            }
        }
    }

    @Test func theBarsOrderTopToBottom() {
        // Keyboard up: Hide Keyboard, the sidebar toggle, Pane Actions.
        #expect(TabActions.verticalBar(.sidebar, zoomed: false, hidesKeyboard: true, room: 3) == [.hideKeyboard, .sidebar, .paneActions])
        // Zoomed, Unzoom leaves first where room is short.
        #expect(TabActions.verticalBar(.sidebar, zoomed: true, hidesKeyboard: true, room: 3) == [.hideKeyboard, .sidebar, .paneActions])
        // Keyboard down: the bar as before.
        #expect(TabActions.verticalBar(.sidebar, zoomed: false, hidesKeyboard: false, room: 3) == [.sidebar, .allTabs, .paneActions])
        #expect(TabActions.verticalBar(.sidebar, zoomed: true, hidesKeyboard: false, room: 3) == [.sidebar, .unzoom, .allTabs, .paneActions])
        // The tab's own items, after the root's.
        #expect(TabActions.tabItems(.sidebar, zoomed: false, hidesKeyboard: false) == [.allTabs, .paneActions])
        #expect(TabActions.tabItems(.sidebar, zoomed: false, hidesKeyboard: true) == [.paneActions])
        #expect(TabActions.tabItems(.sidebar, zoomed: true, hidesKeyboard: false) == [.unzoom, .allTabs, .paneActions])
        #expect(TabActions.tabItems(.sidebar, zoomed: true, hidesKeyboard: true) == [.paneActions])
    }

    @Test func tabModesBarHasNoLeadingItem() {
        #expect(TabActions.barLeading(.tabs) == nil && TabActions.barLeading(.sidebar) == .sidebar)
        // Keyboard down: the tab's items alone.
        for room in [2, 3] {
            #expect(TabActions.verticalBar(.tabs, zoomed: false, hidesKeyboard: false, room: room) == [.allTabs, .paneActions])
            #expect(TabActions.verticalBar(.tabs, zoomed: true, hidesKeyboard: false, room: room) == [.unzoom, .allTabs, .paneActions])
            #expect(TabActions.leadingItems(.tabs, hidesKeyboard: false, room: room).isEmpty)
        }
        // Keyboard up where three fit: the toggle's room keeps All Tabs below Hide Keyboard.
        // Zoomed, Unzoom leaves first, as in sidebar mode.
        #expect(TabActions.verticalBar(.tabs, zoomed: false, hidesKeyboard: true, room: 3) == [.hideKeyboard, .allTabs, .paneActions])
        #expect(TabActions.verticalBar(.tabs, zoomed: true, hidesKeyboard: true, room: 3) == [.hideKeyboard, .allTabs, .paneActions])
        // Where two fit: Hide Keyboard and Pane Actions, as in sidebar mode.
        #expect(TabActions.verticalBar(.tabs, zoomed: false, hidesKeyboard: true, room: 2) == [.hideKeyboard, .paneActions])
        #expect(TabActions.verticalBar(.tabs, zoomed: true, hidesKeyboard: true, room: 2) == [.hideKeyboard, .paneActions])
        #expect(TabActions.leadingItems(.tabs, hidesKeyboard: true, room: 3) == [.hideKeyboard])
        // Sidebar mode's floats never reach tab mode's bar (the tab passes none there); the rule
        // itself is the same.
        #expect(TabActions.tabItems(.tabs, zoomed: false, hidesKeyboard: false, floats: true) == [.allTabs, .paneActions, .floats])
        #expect(!TabActions.tabItems(.tabs, zoomed: false, hidesKeyboard: true, floats: true).contains(.floats))
    }

    @Test func theBarsRoomAboveTheKeyboard() {
        // The outer screen's columns, in screen coordinates (84 pt wide).
        let left = CGRect(x: 0, y: 0, width: 84, height: 466)
        let right = CGRect(x: 594, y: 0, width: 84, height: 466)
        let upright = CGRect(x: 382, y: 0, width: 84, height: 678)
        let halfLeft = CGRect(x: 0, y: 0, width: 84, height: 669)
        #expect(TabActions.keyBarRoom(column: left, compactHeight: true) == 2, "on its side, bar on the left")
        #expect(TabActions.keyBarRoom(column: right, compactHeight: true) == 3, "on its side, bar on the right")
        #expect(TabActions.keyBarRoom(column: upright, compactHeight: false) == 3, "upright")
        #expect(TabActions.keyBarRoom(column: halfLeft, compactHeight: false) == 3, "half the inner screen, bar on the left")
        #expect(TabActions.keyBarRoom(column: nil, compactHeight: true) == 3)
    }

    @Test func aShortBarGivesItsLeadingItemUpWhileTheKeyBarIsUp() {
        // Bar on the left of the outer screen on its side: Hide Keyboard, then Pane Actions.
        #expect(!TabActions.showsBarLeading(hidesKeyboard: true, room: 2))
        #expect(TabActions.leadingItems(.sidebar, hidesKeyboard: true, room: 2) == [.hideKeyboard])
        #expect(TabActions.verticalBar(.sidebar, zoomed: false, hidesKeyboard: true, room: 2) == [.hideKeyboard, .paneActions])
        #expect(TabActions.verticalBar(.tabs, zoomed: true, hidesKeyboard: true, room: 2) == [.hideKeyboard, .paneActions])
        // The keyboard goes: the toggle and the items as before come back.
        #expect(TabActions.showsBarLeading(hidesKeyboard: false, room: 2))
        #expect(TabActions.leadingItems(.sidebar, hidesKeyboard: false, room: 2) == [.sidebar])
        #expect(TabActions.tabItems(.sidebar, zoomed: false, hidesKeyboard: false, room: 2) == [.allTabs, .paneActions])
        // Where three fit, the toggle stays, below Hide Keyboard.
        #expect(TabActions.showsBarLeading(hidesKeyboard: true, room: 3))
        #expect(TabActions.leadingItems(.sidebar, hidesKeyboard: true, room: 3) == [.hideKeyboard, .sidebar])
    }

    @Test func nothingFallsIntoTheOverflowMenuWhileTyping() {
        // In every room and state, what the bar shows fits it, Hide Keyboard on top.
        for navigation in [NavigationStyle.sidebar, .tabs] {
            for room in [2, 3] {
                for zoomed in [false, true] {
                    let items = TabActions.verticalBar(navigation, zoomed: zoomed, hidesKeyboard: true, room: room)
                    #expect(items.count <= room, "room \(room), zoomed \(zoomed)")
                    #expect(items.first == .hideKeyboard)
                    #expect(items.last == .paneActions, "All Tabs and Unzoom stay reachable from its menu")
                }
            }
        }
    }

    @Test func voiceOverFindsExactlyOneOfTheTwo() {
        for zoomed in [false, true] {
            for hides in [false, true] {
                let items = TabActions.verticalBar(.sidebar, zoomed: zoomed, hidesKeyboard: hides)
                #expect(items.filter { $0 == .allTabs || $0 == .hideKeyboard }.count == 1)
                #expect(items.contains(.hideKeyboard) == hides)
            }
        }
    }

    @Test func allTabsIsWithinReachWhileTyping() {
        // Out of the bar while the key bar is up, so in both menus: the Pane Actions menu, which
        // stays in the bar, and the title menu.
        #expect(!TabActions.verticalBar(.sidebar, zoomed: false, hidesKeyboard: true).contains(.allTabs))
        #expect(TabActions.tabItems(.sidebar, zoomed: false, hidesKeyboard: true).contains(.paneActions))
        #expect(TabActions.paneMenuFirstSection.contains(.allTabs))
        #expect(TabActions.titleMenu.contains(.allTabs))
    }

    @Test func theMenusAreAsTheyWere() {
        #expect(TabActions.paneMenuFirstSection == [.splitRight, .splitDown, .newTab, .allTabs])
        #expect(TabActions.titleMenu == [.allTabs, .goTo, .newTab, .rename])
        #expect(TabAction.allTabs.symbol == "square.on.square")
        #expect(TabAction.paneActions.symbol == "square.split.2x2")
        #expect(TabAction.hideKeyboard.symbol == "keyboard.chevron.compact.down")
    }
}
