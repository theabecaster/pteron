import Testing
@testable import RexDuo

// The focus a program is told about: which pane is the front pane, and which report is due.

struct PaneFrontTests {
    private let front = PaneFront(active: true, onScreen: true, appActive: true)

    @Test func theActivePaneOnScreenInTheAppInFrontIsTheFrontPane() {
        #expect(front.isFront)
        #expect(!PaneFront().isFront)
    }

    @Test func eachMissingPartTakesThePaneFromTheFront() {
        var f = front
        f.active = false
        #expect(!f.isFront, "another pane of the split is the active one")
        f = front
        f.onScreen = false
        #expect(!f.isFront, "off screen or parked")
        f = front
        f.appActive = false
        #expect(!f.isFront, "another app is in front")
    }

    @Test func aCoveredPaneIsNotTheFrontPane() {
        var f = front
        f.underBoard = true
        #expect(!f.isFront)
        f = front
        f.underSheet = true
        #expect(!f.isFront)
        f = front
        f.underPalette = true
        #expect(!f.isFront)
    }
}

struct ProgramFocusTests {
    @Test func aChangeIsSaidOnce() {
        var focus = ProgramFocus()
        #expect(focus.due(at: .changed) == nil, "not in front and never told otherwise")
        var changed = focus.set(front: true)
        #expect(changed)
        #expect(focus.due(at: .changed) == true)
        focus.told(true)
        #expect(focus.due(at: .changed) == nil)
        changed = focus.set(front: true)
        #expect(!changed, "no change")
        changed = focus.set(front: false)
        #expect(changed)
        #expect(focus.due(at: .changed) == false)
        focus.told(false)
        #expect(focus.due(at: .changed) == nil)
    }

    @Test func aReportThatCouldNotLeaveStaysDue() {
        var focus = ProgramFocus()
        _ = focus.set(front: true)
        // Dropped: nobody calls `told`.
        #expect(focus.due(at: .changed) == true)
        #expect(focus.due(at: .current) == true)
        // The pane left the front again before anything was said: no change is owed.
        _ = focus.set(front: false)
        #expect(focus.due(at: .changed) == nil)
    }

    @Test func aPaneSaysWhereItIsAgainWhenItsStreamIsCurrentAgain() {
        var focus = ProgramFocus()
        _ = focus.set(front: true)
        focus.told(true)
        #expect(focus.due(at: .current) == true, "the earlier report may never have arrived")
        _ = focus.set(front: false)
        #expect(focus.due(at: .current) == false)
        focus.told(false)
        #expect(focus.due(at: .current) == false, "nor the one that it left the front")
    }

    @Test func aClickWaitsOutTheWindowAfterAReportThatTheFocusWasGained() {
        var focus = ProgramFocus()
        #expect(focus.clickWait(at: 100) == 0, "no such report yet")
        focus.gainedLeft(at: 100)
        #expect(focus.clickWait(at: 100) == ProgramFocus.activationWindow)
        #expect(abs(focus.clickWait(at: 100.25) - (ProgramFocus.activationWindow - 0.25)) < 0.0001)
        #expect(focus.clickWait(at: 100 + ProgramFocus.activationWindow) == 0)
        #expect(focus.clickWait(at: 200) == 0)
        // A report that the focus was lost opens no window.
        focus.told(false)
        #expect(focus.clickWait(at: 300) == 0)
        // Longer than programs wait before they take a press for a click.
        #expect(ProgramFocus.activationWindow > 0.4)
    }

    /// The window runs from the moment the report's write leaves, not from when it was handed
    /// on: until then a click takes its turn behind it.
    @Test func aClickTakesItsTurnBehindAReportThatIsStillOnItsWay() {
        var focus = ProgramFocus()
        #expect(!focus.holdsClick(at: 10))
        focus.gainedHanded(at: 10)
        #expect(focus.gainedCount == 1)
        #expect(focus.holdsClick(at: 10))
        #expect(focus.holdsClick(at: 12), "still on its way, however long that takes")
        #expect(focus.clickWait(at: 12) == 0, "its window has not begun")
        focus.gainedLeft(at: 12)
        #expect(focus.holdsClick(at: 12.2))
        #expect(abs(focus.clickWait(at: 12.2) - (ProgramFocus.activationWindow - 0.2)) < 0.0001)
        #expect(!focus.holdsClick(at: 12.001 + ProgramFocus.activationWindow))
        // A report that was not taken, or that never left, holds nothing for long.
        focus.gainedHanded(at: 20)
        focus.gainedDropped()
        #expect(!focus.holdsClick(at: 20))
        focus.gainedHanded(at: 30)
        #expect(!focus.holdsClick(at: 30 + ProgramFocus.handedLife))
        #expect(focus.gainedCount == 3)
    }

    @Test func aProgramThatStartsToAskIsToldOnlyWhileItsPaneIsInFront() {
        var focus = ProgramFocus()
        #expect(focus.due(at: .asked) == nil)
        // Told that it lost the focus before it stopped asking: that still stands.
        focus.told(true)
        #expect(focus.due(at: .asked) == false)
        focus.told(false)
        _ = focus.set(front: true)
        // While it did not ask, the change counted as said.
        focus.told(true)
        #expect(focus.due(at: .asked) == true)
    }
}
