import Testing
@testable import RexDuo

/// The tab's actions in the vertical bar and its menus (`TabActions`): Hide Keyboard takes All
/// Tabs' place while the key bar is up, nothing else moves, and All Tabs stays within reach.
struct TabActionsTests {
    @Test func hideKeyboardTakesAllTabsPlaceAndNothingElseMoves() {
        for zoomed in [false, true] {
            let typing = TabActions.verticalBar(zoomed: zoomed, hidesKeyboard: true)
            let resting = TabActions.verticalBar(zoomed: zoomed, hidesKeyboard: false)
            // As many items either way, so the bar never overflows for it, and every other item
            // keeps its slot.
            #expect(typing.count == resting.count)
            for (t, r) in zip(typing, resting) where r != .allTabs {
                #expect(t == r)
            }
            #expect(typing.firstIndex(of: .hideKeyboard) == resting.firstIndex(of: .allTabs))
            #expect(typing.last == .paneActions && resting.last == .paneActions)
        }
        #expect(TabActions.verticalBar(zoomed: false, hidesKeyboard: false) == [.allTabs, .paneActions])
        #expect(TabActions.verticalBar(zoomed: true, hidesKeyboard: true) == [.unzoom, .hideKeyboard, .paneActions])
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
