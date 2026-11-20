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
