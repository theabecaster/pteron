import Testing
@testable import Pteron

/// A sideways swipe on the terminal (`TabNav.step`, `wrapped`, `landing`): it walks the tab's
/// panes, goes on to the tab beside past either end, round from the last tab to the first, and
/// shows the new tab's panes from the end it came in at.
struct TabSwipeTests {
    @Test func aSwipeWalksThePanesThenGoesOnToTheTab() {
        let pages = ["a", "b", "c"]
        #expect(TabNav.step(pages: pages, from: "a", by: 1) == .pane("b"))
        #expect(TabNav.step(pages: pages, from: "b", by: 1) == .pane("c"))
        #expect(TabNav.step(pages: pages, from: "b", by: -1) == .pane("a"))
        // Past either end: the tab beside.
        #expect(TabNav.step(pages: pages, from: "c", by: 1) == .tab)
        #expect(TabNav.step(pages: pages, from: "a", by: -1) == .tab)
    }

    @Test func aTabThatDoesntPageGoesStraightOnToTheTab() {
        // One pane.
        #expect(TabNav.step(pages: ["a"], from: "a", by: 1) == .tab)
        #expect(TabNav.step(pages: ["a"], from: "a", by: -1) == .tab)
        // Splits: the tab passes no pages.
        #expect(TabNav.step(pages: [], from: "a", by: 1) == .tab)
        #expect(TabNav.step(pages: [], from: "a", by: -1) == .tab)
    }

    @Test func theTabsWrapBothWays() {
        let order = ["1", "2", "3"]
        #expect(TabNav.wrapped(order, from: "1", by: 1) == "2")
        #expect(TabNav.wrapped(order, from: "2", by: -1) == "1")
        // Next from the last is the first; previous from the first is the last.
        #expect(TabNav.wrapped(order, from: "3", by: 1) == "1")
        #expect(TabNav.wrapped(order, from: "1", by: -1) == "3")
        // Two tabs: either way is the other one.
        #expect(TabNav.wrapped(["1", "2"], from: "1", by: 1) == "2")
        #expect(TabNav.wrapped(["1", "2"], from: "1", by: -1) == "2")
        #expect(TabNav.wrapped(["1", "2"], from: "2", by: 1) == "1")
    }

    @Test func noOtherTabOrAClosedOneGoesNowhere() {
        // One tab: the swipe bumps.
        #expect(TabNav.wrapped(["1"], from: "1", by: 1) == nil)
        #expect(TabNav.wrapped(["1"], from: "1", by: -1) == nil)
        #expect(TabNav.wrapped([], from: "1", by: 1) == nil)
        // The tab swiped from closed meanwhile.
        #expect(TabNav.wrapped(["2", "3"], from: "1", by: 1) == nil)
    }

    @Test func oneSwipeIsOneStep() {
        // However far the finger went, a swipe moves one tab.
        let order = ["1", "2", "3", "4"]
        for (i, id) in order.enumerated() {
            #expect(TabNav.wrapped(order, from: id, by: 1) == order[(i + 1) % order.count])
            #expect(TabNav.wrapped(order, from: id, by: -1) == order[(i + order.count - 1) % order.count])
        }
    }

    @Test func theNewTabShowsItsPanesFromTheEndItCameInAt() {
        #expect(TabNav.landing(pages: ["a", "b", "c"], forward: true) == "a")
        #expect(TabNav.landing(pages: ["a", "b", "c"], forward: false) == "c")
        #expect(TabNav.landing(pages: [], forward: true) == nil)
    }
}
