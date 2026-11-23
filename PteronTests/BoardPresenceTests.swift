import Foundation
import Testing
@testable import Pteron

/// When the board is on screen during tent: the 60 s return, what counts as use, sheets.
struct BoardPresenceTests {
    private let t0 = Date(timeIntervalSince1970: 1000)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    private func shownThenDismissed() -> BoardPresence {
        var p = BoardPresence()
        p.tent(true, modal: false, now: at(0))
        p.dismissed(now: at(10))
        return p
    }

    @Test func tentShowsTheBoardAndLeavingRemovesIt() {
        var p = BoardPresence()
        #expect(!p.shown)
        p.tent(true, modal: false, now: at(0))
        #expect(p.shown)
        #expect(p.deadline == nil)
        p.tent(false, modal: false, now: at(5))
        #expect(!p.shown)
        #expect(!p.inTent)
        #expect(p.deadline == nil)
    }

    @Test func returnsSixtySecondsAfterADismissal() {
        var p = shownThenDismissed()
        #expect(!p.shown)
        #expect(p.deadline == at(70))
        p.tick(now: at(69.9), busy: false, modal: false)
        #expect(!p.shown)
        p.tick(now: at(70), busy: false, modal: false)
        #expect(p.shown)
        #expect(p.deadline == nil)
    }

    @Test func aTouchStartsTheSixtySecondsAgain() {
        var p = shownThenDismissed()
        p.activity(now: at(50))
        #expect(p.deadline == at(110))
        p.tick(now: at(70), busy: false, modal: false)
        #expect(!p.shown)
        p.tick(now: at(110), busy: false, modal: false)
        #expect(p.shown)
    }

    @Test func aKeyboardOrASheetAtTheDeadlineCountsAsUse() {
        var p = shownThenDismissed()
        p.tick(now: at(70), busy: true, modal: false)
        #expect(!p.shown)
        #expect(p.deadline == at(130))
        p.tick(now: at(130), busy: false, modal: true)
        #expect(!p.shown)
        #expect(p.deadline == at(190))
        p.tick(now: at(190), busy: false, modal: false)
        #expect(p.shown)
    }

    @Test func noReturnOutsideTent() {
        var p = shownThenDismissed()
        p.tent(false, modal: false, now: at(20))
        #expect(p.deadline == nil)
        p.tick(now: at(500), busy: false, modal: false)
        #expect(!p.shown)
        // Nothing to dismiss, and a touch is nothing, outside tent.
        p.dismissed(now: at(501))
        p.activity(now: at(502))
        #expect(p.deadline == nil)
    }

    @Test func touchesOnTheBoardItselfDoNotCount() {
        var p = BoardPresence()
        p.tent(true, modal: false, now: at(0))
        p.activity(now: at(5))
        #expect(p.shown)
        #expect(p.deadline == nil)
    }

    @Test func tentUnderASheetWaitsForTheSheetToGo() {
        var p = BoardPresence()
        p.tent(true, modal: true, now: at(0))
        #expect(!p.shown)
        #expect(p.deadline == at(1))
        p.tick(now: at(1), busy: false, modal: true)
        #expect(!p.shown)
        #expect(p.deadline == at(2))
        p.tick(now: at(2), busy: false, modal: false)
        #expect(p.shown, "at once when the sheet is gone, not after a minute")
    }

    @Test func theReturnTimeCanBeShortened() {
        var p = BoardPresence()
        p.returnAfter = 5
        p.tent(true, modal: false, now: at(0))
        p.dismissed(now: at(1))
        #expect(p.deadline == at(6))
    }

    @Test func staysAwakeOnlyWhileShownActiveAndNotInLowPowerMode() {
        #expect(BoardAwake.keepsAwake(shown: true, lowPower: false, active: true))
        #expect(!BoardAwake.keepsAwake(shown: false, lowPower: false, active: true))
        #expect(!BoardAwake.keepsAwake(shown: true, lowPower: true, active: true))
        #expect(!BoardAwake.keepsAwake(shown: true, lowPower: false, active: false))
    }
}
