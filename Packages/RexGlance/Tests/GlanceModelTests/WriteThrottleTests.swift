import Foundation
import Testing
@testable import GlanceModel

@Suite struct WriteThrottleTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
    private typealias Throttle = WriteThrottle<String>
    private typealias Step = Throttle.Step

    @Test func aNewWaitingAgentIsWrittenWithinHalfASecond() {
        var t = Throttle()
        #expect(t.wake(active: true, anyLive: true) == nil)
        t.changed(newWaiting: true, now: at(0))
        #expect(t.wake(active: true, anyLive: true) == at(0.5))
        #expect(t.fire(now: at(0.4), key: "a", active: true, anyLive: true) == Step(write: false, reload: false))
        #expect(t.fire(now: at(0.5), key: "a", active: true, anyLive: true) == Step(write: true, reload: true))
        // Written: nothing more is due until the restamp.
        #expect(t.wake(active: true, anyLive: true) == at(0.5 + 900))
        #expect(t.wake(active: true, anyLive: false) == nil)
    }

    @Test func anythingElseIsWrittenTwoSecondsAfterTheFirstChange() {
        var t = Throttle()
        t.changed(newWaiting: false, now: at(0))
        // More changes don't push the write back, so a stream of them can't hold it off.
        t.changed(newWaiting: false, now: at(1))
        t.changed(newWaiting: false, now: at(1.9))
        #expect(t.wake(active: true, anyLive: true) == at(2))
        #expect(!t.fire(now: at(1.95), key: "a", active: true, anyLive: true).write)
        #expect(t.fire(now: at(2), key: "a", active: true, anyLive: true).write)
        // A waiting agent that arrives while a later write is pending brings it forward.
        t.changed(newWaiting: false, now: at(10))
        t.changed(newWaiting: true, now: at(10.2))
        #expect(t.wake(active: true, anyLive: true) == at(10.7))
        // And never pushes an earlier one back.
        t.changed(newWaiting: false, now: at(10.3))
        #expect(t.wake(active: true, anyLive: true) == at(10.7))
    }

    @Test func whileActiveItReloadsAtMostOnceInTenSeconds() {
        var t = Throttle()
        t.changed(newWaiting: true, now: at(0))
        #expect(t.fire(now: at(0.5), key: "a", active: true, anyLive: true) == Step(write: true, reload: true))
        t.changed(newWaiting: true, now: at(1))
        // Written at once; its reload waits.
        #expect(t.fire(now: at(1.5), key: "b", active: true, anyLive: true) == Step(write: true, reload: false))
        #expect(t.wake(active: true, anyLive: true) == at(10.5))
        t.changed(newWaiting: true, now: at(3))
        #expect(t.fire(now: at(3.5), key: "c", active: true, anyLive: true) == Step(write: true, reload: false))
        #expect(t.fire(now: at(10.4), key: "c", active: true, anyLive: true) == Step(write: false, reload: false))
        // One reload for both, of the newest file.
        #expect(t.fire(now: at(10.5), key: "c", active: true, anyLive: true) == Step(write: false, reload: true))
        #expect(t.fire(now: at(30), key: "c", active: true, anyLive: true) == Step(write: false, reload: false))
    }

    @Test func aWriteThatShowsTheSamePictureReloadsNothing() {
        var t = Throttle()
        t.changed(newWaiting: false, now: at(0))
        #expect(t.fire(now: at(2), key: "a", active: true, anyLive: true) == Step(write: true, reload: true))
        // Say a message changed: the file is written, the picture is the same.
        t.changed(newWaiting: false, now: at(60))
        #expect(t.fire(now: at(62), key: "a", active: true, anyLive: true) == Step(write: true, reload: false))
        // Changed and back before the ten seconds were over: nothing to redraw.
        #expect(t.fire(now: at(100), key: "a", active: true, anyLive: true) == Step(write: false, reload: false))
        var u = Throttle()
        u.changed(newWaiting: false, now: at(0))
        #expect(u.fire(now: at(2), key: "a", active: true, anyLive: true) == Step(write: true, reload: true))
        u.changed(newWaiting: true, now: at(3))
        #expect(u.fire(now: at(3.5), key: "b", active: true, anyLive: true) == Step(write: true, reload: false))
        u.changed(newWaiting: false, now: at(4))
        #expect(u.fire(now: at(6), key: "a", active: true, anyLive: true) == Step(write: true, reload: false))
        #expect(u.wake(active: true, anyLive: false) == nil)
        #expect(u.fire(now: at(12), key: "a", active: true, anyLive: true) == Step(write: false, reload: false))
    }

    @Test func onTheWayToTheBackgroundItAlwaysWritesAndReloadsOnlyANewPicture() {
        var t = Throttle()
        t.changed(newWaiting: false, now: at(0))
        #expect(t.fire(now: at(2), key: "a", active: true, anyLive: true) == Step(write: true, reload: true))
        // Nothing changed: the widgets keep the older "as of".
        #expect(t.background(now: at(50), key: "a") == Step(write: true, reload: false))
        // Changed, and its reload was still waiting for the ten seconds: it goes now.
        var u = Throttle()
        u.changed(newWaiting: true, now: at(0))
        _ = u.fire(now: at(0.5), key: "a", active: true, anyLive: true)
        u.changed(newWaiting: true, now: at(1))
        #expect(u.fire(now: at(1.5), key: "b", active: true, anyLive: true) == Step(write: true, reload: false))
        #expect(u.background(now: at(2), key: "b") == Step(write: true, reload: true))
        #expect(u.background(now: at(3), key: "b") == Step(write: true, reload: false))
        // A change not yet written goes out with the flush.
        var v = Throttle()
        v.changed(newWaiting: false, now: at(0))
        #expect(v.background(now: at(1), key: "a") == Step(write: true, reload: true))
        #expect(v.wake(active: false, anyLive: true) == nil)
    }

    @Test func whileNotActiveItWritesAndDoesNotReload() {
        var t = Throttle()
        t.changed(newWaiting: true, now: at(0))
        #expect(t.fire(now: at(0.5), key: "a", active: false, anyLive: true) == Step(write: true, reload: false))
        #expect(t.wake(active: false, anyLive: true) == nil)
        // Active again: the reload it owes.
        #expect(t.fire(now: at(5), key: "a", active: true, anyLive: true) == Step(write: false, reload: true))
    }

    @Test func itRestampsEveryFifteenMinutesOnlyWhileActiveAndLive() {
        var t = Throttle()
        t.changed(newWaiting: false, now: at(0))
        _ = t.fire(now: at(2), key: "a", active: true, anyLive: true)
        #expect(t.fire(now: at(901), key: "a", active: true, anyLive: true) == Step(write: false, reload: false))
        // The same picture, a new "as of": written and reloaded.
        #expect(t.fire(now: at(902), key: "a", active: true, anyLive: true) == Step(write: true, reload: true))
        #expect(t.wake(active: true, anyLive: true) == at(1802))
        // Not while no machine is live, and not in the background.
        #expect(t.fire(now: at(1802), key: "a", active: true, anyLive: false) == Step(write: false, reload: false))
        #expect(t.fire(now: at(1802), key: "a", active: false, anyLive: true) == Step(write: false, reload: false))
        #expect(t.wake(active: false, anyLive: true) == nil && t.wake(active: true, anyLive: false) == nil)
        #expect(t.fire(now: at(5000), key: "a", active: true, anyLive: true) == Step(write: true, reload: true))
        // Nothing was ever written: there is nothing to restamp.
        var fresh = Throttle()
        #expect(fresh.fire(now: at(5000), key: "a", active: true, anyLive: true) == Step(write: false, reload: false))
    }
}
