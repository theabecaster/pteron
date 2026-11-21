import XCTest
@testable import RexKit

/// The control connection's one liveness watchdog, with a clock and sockets the test moves by
/// hand: while a call waits, nothing coming in for 5 s (10 s on cellular) sends a ping at once.
/// It is keyed on the oldest waiting call and on the last frame in, it is not a deadline on any
/// call, and it neither waits nor fires in the background or across a drop.
@MainActor
final class ControlWatchdogTests: XCTestCase {
    private let policy = ReconnectPolicy.standard
    private var clock: FakeControlClock!
    private var sockets: FakeControlSockets!
    private var control: RexControl!

    override func setUp() async throws {
        clock = FakeControlClock()
        sockets = FakeControlSockets()
        control = RexControl(address: "https://desk.example.ts.net",
                             client: ClientInfo(name: "test", version: "0", label: "test"),
                             clock: clock, sockets: sockets.factory,
                             governor: ReconnectGovernor(policy: policy), random: { 0.5 })
    }

    override func tearDown() async throws {
        control.disconnect()
        await pump()
        control = nil
    }

    private func connect() async {
        let control = control!
        let t = Task { @MainActor in try? await control.connect() }
        await pump()
        sockets.last.welcome()
        _ = await t.value
        await pump()
        XCTAssertEqual(control.state, .connected)
    }

    /// Sends a request that nobody answers until the test does. Typed input is such a request.
    @discardableResult
    private func call(_ method: String = "com.superlogical.terminal.write") async -> Task<Bool, Never> {
        let control = control!
        let t = Task { @MainActor in (try? await control.call(method, ["args": ["data": "x"] as JSONObject])) != nil }
        await pump()
        return t
    }

    /// The server's answer to request number `id`.
    private func answer(_ id: Int) async {
        sockets.last.deliver(#"{"type":"response","id":"\#(id)","payload":{}}"#)
        await pump()
    }

    private func event() async {
        sockets.last.deliver(#"{"type":"event","seq":1,"payload":{"type":"x"}}"#)
        await pump()
    }

    private var pings: Int { sockets.last.pings }

    func testTypedInputWithNothingBackPingsAfterFiveSecondsAndNoPongDropsTheHost() async {
        XCTAssertEqual(policy.activityTimeout, 5)
        XCTAssertEqual(policy.activityTimeoutExpensive, 10)
        XCTAssertEqual(policy.pongDeadline, 10)
        XCTAssertEqual(policy.pongDeadlineExpensive, 20)
        XCTAssertEqual(policy.idlePing, 30)
        await connect()
        await clock.advance(by: 12)
        let write = await call()
        await clock.advance(by: 4.9)
        XCTAssertEqual(pings, 0)
        await clock.advance(by: 0.2)
        XCTAssertEqual(pings, 1, "5 s after the input, not at the keepalive's turn")
        await clock.advance(by: 9.8)
        XCTAssertEqual(control.state, .connected)
        await clock.advance(by: 0.3)
        XCTAssertNotEqual(control.state, .connected, "no pong in 10 s: the host is gone, found 15 s after the key")
        let sent = await write.value
        XCTAssertFalse(sent)
    }

    func testOnCellularTheWaitIsTenSecondsAndThePongTwenty() async {
        control.pathChanged(satisfied: true, expensive: true, interfaceChanged: false)
        await connect()
        await call()
        await clock.advance(by: 9.9)
        XCTAssertEqual(pings, 0)
        await clock.advance(by: 0.2)
        XCTAssertEqual(pings, 1)
        await clock.advance(by: 19.7)
        XCTAssertEqual(control.state, .connected)
        await clock.advance(by: 0.3)
        XCTAssertNotEqual(control.state, .connected)
    }

    func testTheSilenceIsCountedFromTheLastFrameAndTheWaitIsSetForExactlyWhatIsLeft() async {
        await connect()
        await call()
        await clock.advance(by: 3)
        await event()
        await clock.advance(by: 4.9)
        XCTAssertEqual(pings, 0, "7.9 s after the request, 4.9 s after the last frame")
        await clock.advance(by: 0.2)
        XCTAssertEqual(pings, 1, "5 s after the last frame, not 10 s after the request")
    }

    func testACallSentLaterIsNotPingedForTheSilenceBeforeIt() async {
        await connect()
        await call()
        await clock.advance(by: 1)
        await answer(1)
        // A second request goes out while the first one's wait is still set.
        await clock.advance(by: 3.5)
        await call()
        await clock.advance(by: 4.9)
        XCTAssertEqual(pings, 0, "9.4 s in: the waiting call is 4.9 s old")
        await clock.advance(by: 0.2)
        XCTAssertEqual(pings, 1, "5 s after the oldest call that still waits")
    }

    func testItIsNoDeadlineOnACall() async {
        await connect()
        let slow = await call("com.superlogical.terminal.format")
        // The server is busy with the call and goes on sending other things.
        for _ in 0..<60 {
            await clock.advance(by: 2)
            await event()
        }
        XCTAssertEqual(pings, 0, "two minutes, frames arriving: nothing is pinged and nothing dropped")
        XCTAssertEqual(control.state, .connected)
        await answer(1)
        let ok = await slow.value
        XCTAssertTrue(ok)
    }

    func testAPingThatIsAnsweredEndsItUntilTheNextRequest() async {
        await connect()
        await call()
        await clock.advance(by: 5.1)
        XCTAssertEqual(pings, 1)
        sockets.last.answerPing()
        await pump()
        await clock.advance(by: 20)
        XCTAssertEqual(pings, 1, "the host answered: a call that takes long is only long")
        XCTAssertEqual(control.state, .connected)
        // The next request finds a call that has waited through 20 s of silence: asked at once.
        await call()
        await clock.advance(by: 0.1)
        XCTAssertEqual(pings, 2)
    }

    func testOneWaitHoweverManyRequests() async {
        await connect()
        let before = clock.waiting
        for _ in 0..<50 { await call() }
        XCTAssertEqual(clock.waiting - before, 1)
        XCTAssertEqual(clock.liveTimers, 1, "and the keepalive's one timer")
    }

    // MARK: The background

    func testNothingWaitsOrFiresInTheBackgroundAndThePongOfTheReturnStartsAFreshWait() async {
        await connect()
        await call()
        await clock.advance(by: 2)
        control.enteredBackground()
        await clock.advance(by: 600)
        XCTAssertEqual(pings, 0, "ten minutes away: no ping, and the wait that was set did nothing")
        XCTAssertEqual(control.state, .connected)
        control.wake()
        await pump()
        XCTAssertEqual(pings, 1, "the ping of the return")
        sockets.last.answerPing()
        await pump()
        // The call from before the background still waits: watched again, from the pong.
        await clock.advance(by: 4.9)
        XCTAssertEqual(pings, 1)
        await clock.advance(by: 0.2)
        XCTAssertEqual(pings, 2)
    }

    // MARK: A drop

    /// A wait that was set on a connection that dropped must neither ping the next connection
    /// nor leave its calls unwatched.
    func testAWaitFromBeforeADropLeavesTheNextConnectionsCallsWatched() async {
        await connect()
        await call()
        await clock.advance(by: 1)
        sockets.last.failReceive()
        await pump()
        await clock.advance(by: 0.5)
        XCTAssertEqual(sockets.count, 2)
        sockets.last.welcome()
        await pump()
        XCTAssertEqual(control.state, .connected)
        // 1.5 s in. A request on the new connection, at 2 s.
        await clock.advance(by: 0.5)
        await call()
        await clock.advance(by: 3.5)
        XCTAssertEqual(pings, 0, "5.5 s in: the old wait ended and did nothing")
        await clock.advance(by: 1.4)
        XCTAssertEqual(pings, 0)
        await clock.advance(by: 0.2)
        XCTAssertEqual(pings, 1, "5 s after the new request")
    }

    // MARK: A slow call on a live host

    /// Moves the clock `seconds` on in half seconds, with a host that answers every ping, and
    /// `each` run at the start of every whole second. Returns when each ping went out.
    private func run(_ seconds: Int, each: (() async -> Void)? = nil) async -> [Double] {
        var sent: [Double] = []
        var seen = pings
        for step in 0..<(seconds * 2) {
            if step % 2 == 0 { await each?() }
            await clock.advance(by: 0.5)
            if pings > seen {
                seen = pings
                sent.append(Double(step + 1) / 2)
                sockets.last.answerPing()
                await pump()
            }
        }
        return sent
    }

    func testACallUnansweredForThirtySecondsOnAHostThatAnswersPingsCostsOnePingAndIsNeverDropped() async {
        await connect()
        let slow = await call("com.superlogical.terminal.format")
        let sent = await run(30)
        XCTAssertEqual(sent, [5], "one ping, 5 s in; its pong ends the watchdog until the next request")
        XCTAssertEqual(control.state, .connected)
        XCTAssertEqual(sockets.count, 1, "never dropped, never connected again")
        // From here the keepalive alone asks: its timer looks every 30 s and pings when nothing
        // came in for 30 s. The pong came at 5 s, so the look at 30 s passed; the looks at 60 s
        // and 90 s ping.
        let later = await run(60)
        XCTAssertEqual(later, [30, 60], "60 s and 90 s after the welcome: one ping each 30 s")
        XCTAssertEqual(control.state, .connected)
        await answer(1)
        let ok = await slow.value
        XCTAssertTrue(ok, "and the answer is taken whenever it comes")
    }

    /// The worst case for the number of pings: requests keep going out, none is answered, and
    /// only pongs come in. One ping for each 5 s of silence, and no more.
    func testWithRequestsGoingOutEverySecondAndOnlyPongsBackThereIsOnePingPerFiveSeconds() async {
        await connect()
        let sent = await run(30) { [self] in await call() }
        XCTAssertEqual(sent, [5, 10, 15, 20, 25, 30])
        XCTAssertEqual(control.state, .connected)
        XCTAssertEqual(sockets.count, 1)
    }

    func testOnCellularASlowCallCostsOnePingAtTenSeconds() async {
        control.pathChanged(satisfied: true, expensive: true, interfaceChanged: false)
        await connect()
        await call("com.superlogical.terminal.format")
        let sent = await run(30)
        XCTAssertEqual(sent, [10])
        XCTAssertEqual(control.state, .connected)
    }

    // MARK: A ping asked for from outside (`ping()`)

    /// `ping()`, as a stream calls it after `checkLiveness`. Returns whether the pong came.
    private func pacerPing() async -> Task<Bool, Never> {
        let control = control!
        let t = Task { @MainActor in (try? await control.ping()) != nil }
        await pump()
        return t
    }

    func testAPingAskedForWithNoPongEndsAtThePongDeadlineAndTheHostIsDropped() async {
        await connect()
        let asked = await pacerPing()
        XCTAssertEqual(pings, 1)
        await clock.advance(by: 9.9)
        XCTAssertEqual(control.state, .connected)
        await clock.advance(by: 0.2)
        XCTAssertNotEqual(control.state, .connected, "no pong in 10 s: dropped, as for any missed pong")
        let answered = await asked.value
        XCTAssertFalse(answered, "and the wait is over")
    }

    func testOnCellularAPingAskedForHasTwentySeconds() async {
        control.pathChanged(satisfied: true, expensive: true, interfaceChanged: false)
        await connect()
        let asked = await pacerPing()
        await clock.advance(by: 19.9)
        XCTAssertEqual(control.state, .connected)
        await clock.advance(by: 0.2)
        XCTAssertNotEqual(control.state, .connected)
        let answered = await asked.value
        XCTAssertFalse(answered)
    }

    func testAPingAskedForThatIsAnsweredReturnsAndDropsNothing() async {
        await connect()
        let first = await pacerPing()
        // A second caller while the ping is out waits for the same pong.
        let second = await pacerPing()
        XCTAssertEqual(pings, 1)
        sockets.last.answerPing()
        await pump()
        let a = await first.value, b = await second.value
        XCTAssertTrue(a)
        XCTAssertTrue(b)
        await clock.advance(by: 25)
        XCTAssertEqual(control.state, .connected)
        XCTAssertEqual(sockets.count, 1)
    }

    func testInTheBackgroundAPingAskedForEndsAndNothingIsDropped() async {
        await connect()
        let asked = await pacerPing()
        control.enteredBackground()
        let answered = await asked.value
        XCTAssertFalse(answered, "the wait ends: nothing waits in the background")
        await clock.advance(by: 600)
        XCTAssertEqual(control.state, .connected, "and its deadline drops nothing there")
        // Asked in the background: no ping goes out.
        let before = pings
        let again = await pacerPing()
        let second = await again.value
        XCTAssertFalse(second)
        XCTAssertEqual(pings, before)
    }

    func testAPingAskedForFromBeforeADropDoesNothingToTheNextConnection() async {
        await connect()
        let asked = await pacerPing()
        await clock.advance(by: 1)
        sockets.last.failReceive()
        await pump()
        let answered = await asked.value
        XCTAssertFalse(answered, "the drop ends the wait")
        await clock.advance(by: 0.5)
        sockets.last.welcome()
        await pump()
        XCTAssertEqual(control.state, .connected)
        await clock.advance(by: 12)
        XCTAssertEqual(control.state, .connected, "the old ping's deadline passed and dropped nothing")
        XCTAssertEqual(sockets.count, 2)
    }

    // MARK: The ping an upload paces itself with (`paceProbe`)

    private func probe() async -> Task<PaceSample, Never> {
        let control = control!
        let t = Task { @MainActor in await control.paceProbe() }
        await pump()
        return t
    }

    /// The pacer's ping only measures: with no pong the wait ends at the pong deadline as a
    /// slow sample, and the host is not dropped for it.
    func testAPacingPingWithNoPongIsASlowSampleAtTheDeadlineAndNeverDropsTheHost() async {
        await connect()
        let asked = await probe()
        XCTAssertEqual(pings, 1)
        await clock.advance(by: 9.9)
        XCTAssertEqual(control.state, .connected)
        await clock.advance(by: 0.2)
        let sample = await asked.value
        XCTAssertEqual(sample, .slow, "the wait ended, as a slow sample")
        XCTAssertEqual(control.state, .connected, "and nothing was dropped for it")
        XCTAssertEqual(sockets.count, 1)
        // Whether the host is gone is the connection's own to find: its keepalive asks at 30 s,
        // and its ping with no pong is what drops.
        await clock.advance(by: 20)
        XCTAssertEqual(control.state, .connected)
        XCTAssertEqual(pings, 2, "the keepalive's own ping")
        await clock.advance(by: 10.1)
        XCTAssertNotEqual(control.state, .connected)
    }

    func testOnCellularAPacingPingWaitsTwentySeconds() async {
        control.pathChanged(satisfied: true, expensive: true, interfaceChanged: false)
        await connect()
        let asked = await probe()
        await clock.advance(by: 19.9)
        await pump()
        await clock.advance(by: 0.2)
        let sample = await asked.value
        XCTAssertEqual(sample, .slow)
        XCTAssertEqual(control.state, .connected)
    }

    /// A pacing ping is a ping of its own: with the connection's ping out already it does not
    /// share that one, so its time can't come out short.
    func testAPacingPingNeverSharesAPingThatIsOutAlready() async {
        await connect()
        control.checkLiveness()
        await pump()
        XCTAssertEqual(pings, 1)
        await clock.advance(by: 3)
        let asked = await probe()
        XCTAssertEqual(pings, 2, "its own ping, sent when it was asked for")
        // The earlier ping's pong is not the pacer's answer.
        sockets.last.answerPing()
        await pump()
        await clock.advance(by: 1)
        XCTAssertEqual(pings, 2)
        sockets.last.answerPing()
        await pump()
        let sample = await asked.value
        XCTAssertEqual(sample, .answered)
        XCTAssertEqual(control.state, .connected)
    }

    func testInTheBackgroundAPacingPingEndsWithNoSampleAndNoneIsSentThere() async {
        await connect()
        let asked = await probe()
        control.enteredBackground()
        let sample = await asked.value
        XCTAssertEqual(sample, PaceSample.none, "no sample, and the wait is over")
        await clock.advance(by: 600)
        XCTAssertEqual(control.state, .connected)
        let before = pings
        let again = await probe()
        let second = await again.value
        XCTAssertEqual(second, PaceSample.none)
        XCTAssertEqual(pings, before)
    }

    func testAPacingPingEndsWithTheConnectionAndItsDeadlineDoesNothingLater() async {
        await connect()
        let asked = await probe()
        await clock.advance(by: 1)
        sockets.last.failReceive()
        await pump()
        let sample = await asked.value
        XCTAssertEqual(sample, PaceSample.none)
        await clock.advance(by: 0.5)
        sockets.last.welcome()
        await pump()
        await clock.advance(by: 12)
        XCTAssertEqual(control.state, .connected)
        XCTAssertEqual(sockets.count, 2)
    }

    // MARK: Asked from outside

    func testCheckLivenessPingsNowAndNoPongDropsTheHost() async {
        await connect()
        control.checkLiveness()
        control.checkLiveness()
        await pump()
        XCTAssertEqual(pings, 1, "one ping waits at a time")
        await clock.advance(by: 10.1)
        XCTAssertNotEqual(control.state, .connected)
        // Not connected: nothing to ask.
        let before = sockets.last.pings
        control.checkLiveness()
        await pump()
        XCTAssertEqual(sockets.last.pings, before)
    }

    func testCheckLivenessLeavesAHostThatAnswersAlone() async {
        await connect()
        control.checkLiveness()
        await pump()
        sockets.last.answerPing()
        await clock.advance(by: 25)
        XCTAssertEqual(control.state, .connected)
        XCTAssertEqual(sockets.count, 1)
    }
}
