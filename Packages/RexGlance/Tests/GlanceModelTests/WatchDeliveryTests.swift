import Foundation
import Testing
@testable import GlanceModel

/// When the phone sends to the watch: at once for a change in who waits, seldom for anything
/// else, never for nothing, and never to a session that can't deliver.
@Suite struct WatchDeliveryTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private let ready = WatchDelivery.Link(ready: true)
    private let face = WatchDelivery.Link(ready: true, complicationEnabled: true, transfersLeft: 50)

    private func snap(_ name: String, at: TimeInterval = 0, seq: Int = 1) -> GlanceSnapshot {
        // The waits' starts hang on a fixed time, so two snapshots of one scenario hold the same waits.
        var s = GlanceDemo.snapshot(name, now: t0)!
        s.asOf = t0.addingTimeInterval(at)
        s.seq = seq
        return s
    }

    @Test func theFirstSnapshotGoesAtOnce() {
        var d = WatchDelivery()
        #expect(d.offer(snap("one"), reason: .wrote, link: ready, now: t0) == .init(context: true, complication: false))
    }

    @Test func aChangeInWhoWaitsGoesAtOnceAfterAQuietSpell() {
        var d = WatchDelivery()
        _ = d.offer(snap("quiet"), reason: .wrote, link: ready, now: t0)
        let later = t0.addingTimeInterval(WatchDelivery.urgentGap)
        #expect(d.offer(snap("one", at: 30), reason: .wrote, link: ready, now: later).context)
    }

    @Test func aSecondChangeInWhoWaitsIsHeldForTheUrgentGap() {
        var d = WatchDelivery()
        _ = d.offer(snap("quiet"), reason: .wrote, link: ready, now: t0)
        let soon = t0.addingTimeInterval(5)
        let one = snap("one", at: 5)
        #expect(d.offer(one, reason: .wrote, link: ready, now: soon) == .none)
        #expect(d.wake(one, now: soon) == t0.addingTimeInterval(WatchDelivery.urgentGap))
        #expect(d.offer(one, reason: .wrote, link: ready, now: t0.addingTimeInterval(WatchDelivery.urgentGap)).context)
        #expect(d.wake(one, now: t0.addingTimeInterval(31)) == nil)
    }

    @Test func anotherChangeWaitsForTheQuietGap() {
        var d = WatchDelivery()
        _ = d.offer(snap("quiet"), reason: .wrote, link: ready, now: t0)
        // Agents work now; nobody waits, as before.
        let working = snap("working", at: 40)
        #expect(d.offer(working, reason: .wrote, link: ready, now: t0.addingTimeInterval(40)) == .none)
        #expect(d.wake(working, now: t0.addingTimeInterval(40)) == t0.addingTimeInterval(WatchDelivery.quietGap))
        #expect(d.offer(working, reason: .wrote, link: ready, now: t0.addingTimeInterval(60)).context)
    }

    @Test func nothingNewSendsNothing() {
        var d = WatchDelivery()
        _ = d.offer(snap("one"), reason: .wrote, link: ready, now: t0)
        let same = snap("one", at: 600, seq: 9)
        #expect(d.offer(same, reason: .wrote, link: ready, now: t0.addingTimeInterval(600)) == .none)
        #expect(d.offer(same, reason: .leaving, link: ready, now: t0.addingTimeInterval(600)) == .none)
        #expect(d.wake(same, now: t0.addingTimeInterval(600)) == nil)
    }

    @Test func aRestampGoesAfterFifteenMinutes() {
        var d = WatchDelivery()
        _ = d.offer(snap("one"), reason: .wrote, link: ready, now: t0)
        #expect(d.offer(snap("one", at: 899), reason: .wrote, link: ready, now: t0.addingTimeInterval(899)) == .none)
        #expect(d.offer(snap("one", at: 900), reason: .wrote, link: ready, now: t0.addingTimeInterval(900)).context)
    }

    @Test func aHeldChangeGoesWhenTheAppLeaves() {
        var d = WatchDelivery()
        _ = d.offer(snap("quiet"), reason: .wrote, link: ready, now: t0)
        let working = snap("working", at: 3)
        #expect(d.offer(working, reason: .wrote, link: ready, now: t0.addingTimeInterval(3)) == .none)
        #expect(d.offer(working, reason: .leaving, link: ready, now: t0.addingTimeInterval(4)).context)
        // It went: nothing is held any more.
        #expect(d.wake(working, now: t0.addingTimeInterval(5)) == nil)
    }

    @Test func anOpenedSessionGetsTheNewestWhateverWasSent() {
        var d = WatchDelivery()
        let one = snap("one")
        _ = d.offer(one, reason: .wrote, link: ready, now: t0)
        #expect(d.offer(one, reason: .opened, link: ready, now: t0.addingTimeInterval(1)).context)
    }

    @Test func nothingGoesToASessionThatCannotDeliver() {
        var d = WatchDelivery()
        let off = WatchDelivery.Link(ready: false, complicationEnabled: true, transfersLeft: 50)
        for reason in [WatchDelivery.Reason.wrote, .leaving, .opened] {
            #expect(d.offer(snap("one"), reason: reason, link: off, now: t0) == .none)
        }
        // And nothing counts as sent: once it can deliver, the snapshot goes.
        #expect(d.offer(snap("one"), reason: .wrote, link: ready, now: t0).context)
    }

    @Test func aComplicationTransferOnlyForANewCountAnEnabledFaceAndBudgetLeft() {
        var d = WatchDelivery()
        #expect(d.offer(snap("one"), reason: .wrote, link: face, now: t0).complication)
        // The same count again (the session reopened): no transfer.
        #expect(d.offer(snap("one"), reason: .opened, link: face, now: t0.addingTimeInterval(1)) == .init(context: true, complication: false))
        // Two wait now.
        let two = t0.addingTimeInterval(100)
        #expect(d.offer(snap("several", at: 100), reason: .wrote, link: face, now: two).complication)

        var none = WatchDelivery()
        #expect(none.offer(snap("one"), reason: .wrote, link: ready, now: t0) == .init(context: true, complication: false))
        var spent = WatchDelivery()
        let empty = WatchDelivery.Link(ready: true, complicationEnabled: true, transfersLeft: 0)
        #expect(spent.offer(snap("one"), reason: .wrote, link: empty, now: t0) == .init(context: true, complication: false))
        // The budget is back: the count was never transferred, so it goes with the next send.
        #expect(spent.offer(snap("one"), reason: .opened, link: face, now: t0.addingTimeInterval(1)).complication)
    }

    @Test func theComplicationCountsOnlyConnectedMachines() {
        #expect(WatchDelivery.waitingCount(snap("several")) == 2)
        #expect(WatchDelivery.waitingCount(snap("offline")) == 0)
        #expect(WatchDelivery.waitingCount(snap("machines")) == 2)
    }

    @Test func aRefusedSendIsTriedAgainWithTheNextSnapshot() {
        var d = WatchDelivery()
        _ = d.offer(snap("one"), reason: .wrote, link: face, now: t0)
        d.failed()
        let again = t0.addingTimeInterval(WatchDelivery.urgentGap)
        #expect(d.offer(snap("one", at: 30), reason: .wrote, link: face, now: again) == .init(context: true, complication: true))
    }

    @Test func anotherWatchStartsFromNothing() {
        var d = WatchDelivery()
        _ = d.offer(snap("one"), reason: .wrote, link: face, now: t0)
        d.reset()
        #expect(d == WatchDelivery())
    }

    @Test func anAgentThatAsksAgainInTheSamePaneIsAnotherWait() {
        var a = snap("one"), b = snap("one")
        b.machines[0].waiting[0].since = a.machines[0].waiting[0].since.addingTimeInterval(60)
        #expect(WatchDelivery.waits(a) != WatchDelivery.waits(b))
        a.machines[0].waiting[0].msg = "another question"
        #expect(WatchDelivery.waits(a) == WatchDelivery.waits(snap("one")))
    }

    /// The worst case: the picture changes on every write, for an hour with the app in front.
    @Test func theWorstCaseIsOneDeliveryPerUrgentGap() {
        var d = WatchDelivery()
        var sends = 0, transfers = 0, now = t0, flip = false
        var left = 50
        while now < t0.addingTimeInterval(3600) {
            flip.toggle()
            let s = snap(flip ? "one" : "several", at: now.timeIntervalSince(t0))
            let step = d.offer(s, reason: .wrote, link: .init(ready: true, complicationEnabled: true, transfersLeft: left), now: now)
            if step.context { sends += 1 }
            if step.complication { transfers += 1; left -= 1 }
            now.addTimeInterval(0.5)
        }
        #expect(sends <= 120)
        #expect(transfers <= 50)
        #expect(WatchDelivery.urgentGap == 30 && WatchDelivery.quietGap == 60 && WatchDelivery.restampEvery == 900)
    }

    /// Counts that change on every write while nobody new waits: one delivery a minute.
    @Test func otherChangesAreOneDeliveryAMinuteAtMost() {
        var d = WatchDelivery()
        var sends = 0, now = t0, n = 0
        while now < t0.addingTimeInterval(3600) {
            n += 1
            var s = snap("one", at: now.timeIntervalSince(t0))
            s.machines[0].counts.working = n
            if d.offer(s, reason: .wrote, link: ready, now: now).context { sends += 1 }
            now.addTimeInterval(2)
        }
        #expect(sends <= 60)
    }
}
