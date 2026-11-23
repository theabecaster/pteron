import Foundation
import Testing
@testable import Pteron

/// "The app is in front", said again while it is: the timing alone, then through
/// `PushRegistrar` with stand-ins and a wait the test holds.
@MainActor
struct PresenceRenewalTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    // MARK: The timing

    @Test func aClaimIsRepeatedWellInsideItsLife() {
        // Two repeats in a row can be lost before a helper lets the claim go.
        #expect(PresenceRenewal.every == 60)
        #expect(PresenceRenewal.claimLife == 180)
        #expect(PresenceRenewal.every * 3 <= PresenceRenewal.claimLife)
    }

    @Test func nothingIsRepeatedBeforeTheAppIsInFront() {
        var r = PresenceRenewal()
        #expect(r.wait(at: t0) == nil)
        do { let due = r.renew(at: t0); #expect(!due) }
        do { let due = r.renew(at: at(3600)); #expect(!due) }
    }

    @Test func aRepeatIsDueOneIntervalAfterTheLastClaim() {
        var r = PresenceRenewal()
        r.start(at: t0)
        #expect(r.wait(at: t0) == 60)
        #expect(r.wait(at: at(45)) == 15)
        // A wait that ended early repeats nothing and moves nothing.
        do { let due = r.renew(at: at(59)); #expect(!due) }
        #expect(r.wait(at: at(59)) == 1)
        do { let due = r.renew(at: at(60)); #expect(due) }
        #expect(r.wait(at: at(60)) == 60)
        // The next one counts from the repeat, not from the start.
        do { let due = r.renew(at: at(119)); #expect(!due) }
        do { let due = r.renew(at: at(121)); #expect(due) }
        #expect(r.wait(at: at(121)) == 60)
    }

    @Test func aLateWaitRepeatsOnceAndStartsOver() {
        var r = PresenceRenewal()
        r.start(at: t0)
        #expect(r.wait(at: at(600)) == 0)
        do { let due = r.renew(at: at(600)); #expect(due) }
        do { let due = r.renew(at: at(600)); #expect(!due) }
        #expect(r.wait(at: at(600)) == 60)
    }

    @Test func leavingTheFrontEndsTheRepeats() {
        var r = PresenceRenewal()
        r.start(at: t0)
        r.stop()
        #expect(r.wait(at: at(60)) == nil)
        do { let due = r.renew(at: at(60)); #expect(!due) }
        // Back in front: counted from the return.
        r.start(at: at(500))
        #expect(r.wait(at: at(530)) == 30)
    }

    @Test func aClockSetBackRepeatsNowAndNeverWaitsLonger() {
        var r = PresenceRenewal()
        r.start(at: t0)
        #expect(r.wait(at: at(-3600)) == 0)
        do { let due = r.renew(at: at(-3600)); #expect(due) }
        #expect(r.wait(at: at(-3600)) == 60)
    }

    // MARK: Through the registrar

    private let server = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let other = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    @MainActor
    private struct Setup {
        var world: PushWorld
        /// Holds the wait between two repeats until the test moves it.
        var ticks: TestClock
        var push: PushRegistrar

        var helpers: HelperStandIn { world.helpers }

        /// A minute passes, for the registrar's clock and for the held wait.
        func minute() async {
            world.clock.now = world.clock.now.addingTimeInterval(PresenceRenewal.every)
            ticks.advance(by: PresenceRenewal.every)
            await world.quiet()
        }
    }

    private func make(_ servers: [UUID]) -> Setup {
        let world = PushWorld()
        for (index, id) in servers.enumerated() { world.helpers.add(id, name: index == 0 ? "Studio" : "Laptop") }
        world.defaults.set(PushWorld.token, forKey: "pushToken.last")
        world.prefs.pushEnabled = true
        let ticks = TestClock()
        ticks.passes = false
        var parts = world.parts
        parts.renewalSleep = { [ticks] in await ticks.sleep($0) }
        let system = PushRegistrar.System(permission: { .allowed }, ask: {}, registerForNotifications: {},
                                          unregisterForNotifications: {}, openSettings: {}, deviceName: { "Test iPhone" })
        let push = PushRegistrar(prefs: world.prefs, deviceID: "abcd1234", environment: "sandbox", defaults: world.defaults,
                                 parts: parts, system: system)
        return Setup(world: world, ticks: ticks, push: push)
    }

    /// Signed up and in front, with the claims of the sign-up and the return over.
    private func inFront(_ servers: [UUID]) async -> Setup {
        let s = make(servers)
        s.push.start()
        s.push.becameActive()
        await s.world.eventually { servers.allSatisfy { !s.helpers[$0].presence.isEmpty } }
        await s.world.quiet()
        return s
    }

    @Test func whileInFrontEveryHelperHearsItAgainEachMinute() async {
        let s = await inFront([server, other])
        let before = [server, other].map { s.helpers[$0].presence.count }
        #expect(s.ticks.sleeps == [60])
        for minute in 1...5 {
            await s.minute()
            for (i, id) in [server, other].enumerated() {
                #expect(s.helpers[id].presence.count == before[i] + minute, "minute \(minute)")
                #expect(s.helpers[id].presence.allSatisfy { $0 })
            }
        }
        // One wait of a minute per repeat, and nothing in between.
        #expect(s.ticks.sleeps == Array(repeating: 60, count: 6))
        s.ticks.release()
    }

    @Test func nothingIsRepeatedBeforeAMinuteIsOver() async {
        let s = await inFront([server])
        let before = s.helpers[server].presence.count
        s.world.clock.now = s.world.clock.now.addingTimeInterval(59)
        s.ticks.advance(by: 59)
        await s.world.quiet()
        #expect(s.helpers[server].presence.count == before)
        s.ticks.release()
    }

    @Test func goingToTheBackgroundSaysSoOnceAndEndsTheRepeats() async {
        let s = await inFront([server])
        await s.minute()
        let before = s.helpers[server].presence.count
        s.push.enteredBackground()
        await s.world.eventually { s.helpers[server].presence.count == before + 1 }
        #expect(s.helpers[server].presence.last == false)
        // Minutes pass in the background, and a wait that was held ends: nothing more is said.
        for _ in 0..<4 { await s.minute() }
        s.ticks.release()
        await s.world.quiet()
        #expect(s.helpers[server].presence.count == before + 1)
        #expect(s.helpers[server].presence.last == false)
    }

    @Test func comingBackStartsTheRepeatsAgainFromTheReturn() async {
        let s = await inFront([server])
        s.push.enteredBackground()
        await s.world.eventually { s.helpers[server].presence.last == false }
        s.world.clock.now = s.world.clock.now.addingTimeInterval(1000)
        s.push.becameActive()
        await s.world.eventually { s.helpers[server].presence.last == true }
        await s.world.quiet()
        let before = s.helpers[server].presence.count
        await s.minute()
        #expect(s.helpers[server].presence.count == before + 1)
        await s.minute()
        #expect(s.helpers[server].presence.count == before + 2)
        #expect(s.helpers[server].presence.suffix(2) == [true, true])
        s.ticks.release()
    }

    /// Each return to the front replaces the wait before it: two returns do not make two
    /// repeats a minute.
    @Test func becomingActiveTwiceKeepsOneRepeatAMinute() async {
        let s = await inFront([server])
        s.push.becameActive()
        s.push.becameActive()
        await s.world.quiet()
        let before = s.helpers[server].presence.count
        await s.minute()
        #expect(s.helpers[server].presence.count == before + 1)
        s.ticks.release()
    }

    @Test func noClaimGoesOutBeforeTheAppIsActive() async {
        let s = make([server])
        s.push.start()
        await s.world.eventually { s.helpers[server].secret != nil }
        for _ in 0..<3 { await s.minute() }
        #expect(s.helpers[server].presence.isEmpty)
        #expect(s.ticks.sleeps.isEmpty)
    }

    /// The app is active before the registrar has started: the repeats run all the same, so
    /// the claim the registration sends does not run out three minutes later.
    @Test func activeBeforeTheRegistrarStartsStillRepeats() async {
        let s = make([server])
        s.push.becameActive()
        s.push.start()
        await s.world.eventually { !s.helpers[server].presence.isEmpty }
        await s.world.quiet()
        let before = s.helpers[server].presence.count
        await s.minute()
        #expect(s.helpers[server].presence.count == before + 1)
        s.ticks.release()
    }

    @Test func aComputerThatDoesNotHoldThePhoneIsNotTold() async {
        let s = make([server, other])
        s.helpers[other].installed = false
        s.push.start()
        s.push.becameActive()
        await s.world.eventually { !s.helpers[server].presence.isEmpty }
        await s.world.quiet()
        await s.minute()
        #expect(s.helpers[server].presence.count >= 2)
        #expect(s.helpers[other].presence.isEmpty && s.helpers[other].count("push_presence") == 0)
        s.ticks.release()
    }
}
