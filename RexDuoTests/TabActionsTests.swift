import CoreGraphics
import Testing
@testable import RexDuo

/// The tab's actions in the vertical bar and its menus (`TabActions`): Hide Keyboard replaces All
/// Tabs while the key bar is up and goes last, nearest the keyboard, and All Tabs stays within reach.
struct TabActionsTests {
    @Test func hideKeyboardReplacesAllTabsAndGoesLast() {
        for zoomed in [false, true] {
            let typing = TabActions.verticalBar(zoomed: zoomed, hidesKeyboard: true)
            let resting = TabActions.verticalBar(zoomed: zoomed, hidesKeyboard: false)
            // As many items either way, so the bar never overflows for it.
            #expect(typing.count == resting.count)
            #expect(Set(typing) == Set(resting).subtracting([.allTabs]).union([.hideKeyboard]))
            #expect(resting.last == .paneActions)
            #expect(Array(typing.dropLast()) == resting.filter { $0 != .allTabs })
        }
        #expect(TabActions.verticalBar(zoomed: false, hidesKeyboard: false) == [.allTabs, .paneActions])
        #expect(TabActions.verticalBar(zoomed: false, hidesKeyboard: true) == [.paneActions, .hideKeyboard])
        #expect(TabActions.verticalBar(zoomed: true, hidesKeyboard: false) == [.unzoom, .allTabs, .paneActions])
        #expect(TabActions.verticalBar(zoomed: true, hidesKeyboard: true) == [.unzoom, .paneActions, .hideKeyboard])
    }

    @Test func hideKeyboardIsTheLowestItemWhileTheKeyBarIsUp() {
        // The bar lists its items top to bottom and the keyboard sits below its end in every
        // posture, so the last item is the one nearest the keyboard.
        for zoomed in [false, true] {
            #expect(TabActions.verticalBar(zoomed: zoomed, hidesKeyboard: true).last == .hideKeyboard)
        }
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

    @Test func aShortBarGivesItsFirstItemUpWhileTheKeyBarIsUp() {
        // Bar on the left of the outer screen on its side: Pane Actions, then Hide Keyboard.
        #expect(!TabActions.showsBarLeading(hidesKeyboard: true, room: 2))
        #expect(TabActions.verticalBar(zoomed: false, hidesKeyboard: true, room: 2) == [.paneActions, .hideKeyboard])
        #expect(TabActions.verticalBar(zoomed: true, hidesKeyboard: true, room: 2) == [.paneActions, .hideKeyboard])
        // The keyboard goes: the toggle and today's items come back.
        #expect(TabActions.showsBarLeading(hidesKeyboard: false, room: 2))
        #expect(TabActions.verticalBar(zoomed: false, hidesKeyboard: false, room: 2) == [.allTabs, .paneActions])
        // Where three fit, the toggle stays.
        #expect(TabActions.showsBarLeading(hidesKeyboard: true, room: 3))
        #expect(TabActions.verticalBar(zoomed: false, hidesKeyboard: true, room: 3) == [.paneActions, .hideKeyboard])
    }

    @Test func hideKeyboardNeverFallsIntoTheOverflowMenu() {
        // In every room and state, what the bar shows fits it, and Hide Keyboard is shown, last.
        for room in [2, 3] {
            for zoomed in [false, true] {
                let items = TabActions.verticalBar(zoomed: zoomed, hidesKeyboard: true, room: room)
                let toggle = TabActions.showsBarLeading(hidesKeyboard: true, room: room) ? 1 : 0
                #expect(toggle + items.count <= room, "room \(room), zoomed \(zoomed)")
                #expect(items.last == .hideKeyboard)
                #expect(items.contains(.paneActions), "All Tabs and Unzoom stay reachable from its menu")
            }
        }
    }

    @Test func voiceOverFindsExactlyOneOfTheTwo() {
        for zoomed in [false, true] {
            for hides in [false, true] {
                let items = TabActions.verticalBar(zoomed: zoomed, hidesKeyboard: hides)
                #expect(items.filter { $0 == .allTabs || $0 == .hideKeyboard }.count == 1)
                #expect(items.contains(.hideKeyboard) == hides)
            }
        }
    }

    @Test func allTabsIsWithinReachWhileTyping() {
        // Out of the bar while the key bar is up, so in both menus: the Pane Actions menu, which
        // stays in the bar, and the title menu.
        #expect(!TabActions.verticalBar(zoomed: false, hidesKeyboard: true).contains(.allTabs))
        #expect(TabActions.verticalBar(zoomed: false, hidesKeyboard: true).contains(.paneActions))
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
