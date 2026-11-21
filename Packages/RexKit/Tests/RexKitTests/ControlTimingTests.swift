import XCTest
@testable import RexKit

/// `RexControl`'s timing, with a clock and sockets the test moves by hand: the backoff, the
/// welcome and wake deadlines, the keepalive, and what a kick does. No real time passes and no
/// server runs.
///
/// These tests record how the connection behaves today. Two of them record a fact that is due to
/// change (`testAKickDuringAnAttemptOpensASecondSocket`, `testAWakeDuringAnAttemptOpensASecondSocket`).
@MainActor
final class ControlTimingTests: XCTestCase {
    private var clock: FakeControlClock!
    private var sockets: FakeControlSockets!
    private var control: RexControl!
    /// What `onRetryScheduled` reported, in order.
    private var retries: [Double] = []
    private var states: [RexControl.State] = []
    private var reconnects = 0

    override func setUp() async throws {
        clock = FakeControlClock()
        sockets = FakeControlSockets()
        control = RexControl(address: "https://desk.example.ts.net",
                             client: ClientInfo(name: "test", version: "0", label: "test"),
                             clock: clock, sockets: sockets.factory)
        retries = []
        states = []
        reconnects = 0
        control.onRetryScheduled = { [unowned self] in retries.append($0) }
        control.onStateChange = { [unowned self] in states.append($0) }
        control.onReconnected = { [unowned self] _ in reconnects += 1 }
    }

    override func tearDown() async throws {
        control.disconnect()
        await pump()
        control = nil
    }

    /// Starts `connect()` and returns once its socket waits for the welcome.
    @discardableResult
    private func beginConnect() async -> Task<Bool, Never> {
        let control = control!
        let t = Task { @MainActor in
            do { try await control.connect(); return true } catch { return false }
        }
        await pump()
        return t
    }

    /// Connects on the first socket.
    private func connect() async {
        let t = await beginConnect()
        sockets.last.welcome()
        let ok = await t.value
        await pump()
        XCTAssertTrue(ok)
        XCTAssertEqual(control.state, .connected)
    }

    private var isFailed: Bool {
        if case .failed = control.state { return true }
        return false
    }

    // MARK: Backoff

    func testBackoffDoublesFromOneSecondToTheCapOfFifteen() async {
        let first = await beginConnect()
        XCTAssertEqual(sockets.count, 1)
        XCTAssertTrue(sockets.last.resumed)
        XCTAssertTrue(sockets.last.sentHello)
        sockets.last.failReceive()
        let connected = await first.value
        XCTAssertFalse(connected, "the first attempt's failure is thrown to the caller")
        XCTAssertTrue(isFailed)

        let steps: [Double] = [1, 2, 4, 8, 15, 15, 15]
        for (i, step) in steps.enumerated() {
            XCTAssertEqual(retries.count, i + 1)
            XCTAssertEqual(retries.last, step, "failure \(i + 1) waits \(step) s")
            let before = sockets.count
            await clock.advance(by: step - 0.01)
            XCTAssertEqual(sockets.count, before, "no attempt before the step is over")
            await clock.advance(by: 0.01)
            XCTAssertEqual(sockets.count, before + 1, "one attempt when it is over")
            XCTAssertEqual(control.state, .connecting)
            sockets.last.failReceive()
            await pump()
            XCTAssertTrue(isFailed)
        }
        XCTAssertEqual(RexControl.firstRetryDelay, 1)
        XCTAssertEqual(RexControl.maxRetryDelay, 15)
    }

    func testAReconnectResetsTheBackoff() async {
        await beginConnect()
        sockets.last.failReceive()
        await pump()
        for step in [1.0, 2.0] {
            await clock.advance(by: step)
            sockets.last.failReceive()
            await pump()
        }
        XCTAssertEqual(retries, [1, 2, 4])

        // The next attempt gets its welcome.
        await clock.advance(by: 4)
        sockets.last.welcome()
        await pump()
        XCTAssertEqual(control.state, .connected)
        XCTAssertEqual(reconnects, 1)

        // The next drop starts from the first step again.
        sockets.last.failReceive()
        await pump()
        XCTAssertEqual(retries, [1, 2, 4, 1])
    }

    func testOneSocketThatFailsSeveralWaysCountsOnce() async {
        await connect()
        let s = sockets.last
        // The receive fails, a ping fails and the send fails, all for the same dead socket.
        control.wake()
        s.failReceive()
        s.answerPing(URLError(.networkConnectionLost))
        s.callEverythingAgain()
        await pump()
        XCTAssertEqual(retries.count, 1, "one drop, one retry")
        XCTAssertEqual(states.filter { if case .failed = $0 { true } else { false } }.count, 1)
    }

    // MARK: Generations

    func testLateCallbacksFromAnOldSocketAreIgnored() async {
        await connect()
        let old = sockets.last
        control.wake()
        old.failReceive()
        await pump()
        XCTAssertTrue(old.cancelled)
        // The drop came right after a wake, so the retry is at once.
        XCTAssertEqual(retries, [0])
        XCTAssertEqual(sockets.count, 2)
        let new = sockets.last
        new.welcome(token: "t2")
        await pump()
        XCTAssertEqual(control.state, .connected)
        let seen = states.count, asked = retries.count

        // The old socket's handlers are called again, and a message arrives on it.
        old.callEverythingAgain()
        var events = 0
        control.onEvent = { _, _ in events += 1 }
        old.deliverLate(#"{"type":"event","seq":9,"payload":{}}"#)
        await pump()
        await clock.advance(by: 60)
        XCTAssertEqual(control.state, .connected)
        XCTAssertEqual(states.count, seen, "no state change")
        XCTAssertEqual(retries.count, asked, "no retry")
        XCTAssertEqual(sockets.count, 2, "no new socket")
        XCTAssertEqual(events, 0, "an old socket's message is dropped")
        XCTAssertFalse(new.cancelled)
    }

    func testAWelcomeOnASupersededSocketDoesNotConnect() async {
        let first = await beginConnect()
        let old = sockets.last
        old.failReceive()
        _ = await first.value
        await clock.advance(by: 1)
        XCTAssertEqual(sockets.count, 2)
        XCTAssertEqual(control.state, .connecting)

        old.deliverLate(#"{"type":"welcome","client":{"id":"client:old","reconnect_token":"old"}}"#)
        await pump()
        XCTAssertEqual(control.state, .connecting, "only the current socket's welcome counts")
        XCTAssertNil(control.clientID)
    }

    // MARK: Deadlines

    func testNoWelcomeInEightSecondsFailsTheAttempt() async {
        let first = await beginConnect()
        await clock.advance(by: RexControl.welcomeTimeout - 0.01)
        XCTAssertEqual(control.state, .connecting)
        await clock.advance(by: 0.01)
        XCTAssertEqual(control.state, .failed(.timedOut()))
        let connected = await first.value
        XCTAssertFalse(connected)
        XCTAssertTrue(sockets.last.cancelled)
        XCTAssertEqual(retries, [1])
        XCTAssertEqual(RexControl.welcomeTimeout, 8)
    }

    func testTheWelcomeDeadlineOfAnEarlierAttemptDoesNotFailALaterOne() async {
        await beginConnect()
        // 5 s in, the socket fails; the retry opens the next one a second later.
        await clock.advance(by: 5)
        sockets.last.failReceive()
        await pump()
        await clock.advance(by: 1)
        XCTAssertEqual(sockets.count, 2)
        // 8 s after the first attempt began: its deadline passes and changes nothing.
        await clock.advance(by: 2.5)
        XCTAssertEqual(control.state, .connecting)
        XCTAssertFalse(sockets.last.cancelled)
        XCTAssertEqual(retries, [1])
    }

    func testAKeepalivePingGoesEveryThirtySecondsAndAFailedOneDrops() async {
        await connect()
        let s = sockets.last
        XCTAssertEqual(clock.liveTimers, 1)
        await clock.advance(by: RexControl.pingInterval - 0.01)
        XCTAssertEqual(s.pings, 0)
        await clock.advance(by: 0.01)
        XCTAssertEqual(s.pings, 1)
        s.answerPing()
        await clock.advance(by: RexControl.pingInterval)
        XCTAssertEqual(s.pings, 2)
        XCTAssertEqual(control.state, .connected)
        XCTAssertEqual(RexControl.pingInterval, 30)

        s.answerPing(URLError(.networkConnectionLost))
        await pump()
        XCTAssertTrue(isFailed)
        XCTAssertEqual(retries, [1])
        XCTAssertEqual(clock.liveTimers, 0, "a dropped connection sends no more pings")
    }

    /// Today a keepalive ping that gets no pong changes nothing: the connection stays up for as
    /// long as the socket reports no error.
    func testAKeepalivePingWithoutAPongKeepsTheConnection() async {
        await connect()
        await clock.advance(by: 10 * RexControl.pingInterval)
        XCTAssertEqual(sockets.last.pings, 10)
        XCTAssertEqual(control.state, .connected)
        XCTAssertEqual(retries, [])
    }

    // MARK: Wake

    func testWakeKeepsAConnectionThatAnswersThePing() async {
        await connect()
        control.wake()
        XCTAssertEqual(sockets.last.pings, 1)
        sockets.last.answerPing()
        await clock.advance(by: RexControl.wakeTimeout + 1)
        XCTAssertEqual(control.state, .connected)
        XCTAssertEqual(sockets.count, 1)
        XCTAssertEqual(retries, [])

        // The pong ended the wake: a later drop takes the backoff.
        sockets.last.failReceive()
        await pump()
        XCTAssertEqual(retries, [1])
    }

    func testWakeDropsAConnectionWithNoPongAfterTheTimeoutAndRetriesAtOnce() async {
        await connect()
        control.wake()
        await clock.advance(by: RexControl.wakeTimeout - 0.01)
        XCTAssertEqual(control.state, .connected)
        await clock.advance(by: 0.01)
        XCTAssertEqual(retries, [0], "at once, not after the backoff")
        XCTAssertEqual(sockets.count, 2)
        XCTAssertEqual(control.state, .connecting)
        XCTAssertEqual(RexControl.wakeTimeout, 2.5)

        // At once only once: the attempt after that waits the first step.
        sockets.last.failReceive()
        await pump()
        XCTAssertEqual(retries, [0, 1])
    }

    // MARK: Kick

    func testKickWhileConnectedDoesNothing() async {
        await connect()
        control.kick()
        await pump()
        XCTAssertEqual(sockets.count, 1)
        XCTAssertEqual(control.state, .connected)
        XCTAssertFalse(sockets.last.cancelled)
    }

    func testKickBeforeConnectDoesNothing() async {
        control.kick()
        control.wake()
        await pump()
        XCTAssertEqual(sockets.count, 0)
        XCTAssertEqual(control.state, .idle)
    }

    func testKickWhileWaitingOutTheBackoffTriesNowAndStartsTheBackoffOver() async {
        await beginConnect()
        sockets.last.failReceive()
        await pump()
        for step in [1.0, 2.0, 4.0] {
            await clock.advance(by: step)
            sockets.last.failReceive()
            await pump()
        }
        XCTAssertEqual(retries, [1, 2, 4, 8])
        XCTAssertEqual(sockets.count, 4)

        control.kick()
        await pump()
        XCTAssertEqual(sockets.count, 5, "the attempt starts now")
        XCTAssertEqual(control.state, .connecting)
        // The wait that was running is over: no second attempt when its 8 s end.
        sockets.last.failReceive()
        await pump()
        XCTAssertEqual(retries, [1, 2, 4, 8, 1], "the backoff starts over")
        await clock.advance(by: 0.99)
        XCTAssertEqual(sockets.count, 5)
        await clock.advance(by: 0.01)
        XCTAssertEqual(sockets.count, 6)
        await clock.advance(by: 7)
        XCTAssertEqual(sockets.count, 6, "the cancelled 8 s wait opened nothing")
    }

    /// TODAY'S BEHAVIOUR, recorded as a fact and due to change: a kick while an attempt waits for
    /// its welcome ends that attempt and opens another socket, so ten kicks make ten sockets and
    /// an attempt on a slow link may never finish. When a kick during an attempt becomes a no-op,
    /// this test turns around: one socket, not cancelled, and the first `connect()` still waiting.
    func testAKickDuringAnAttemptOpensASecondSocket() async {
        let first = await beginConnect()
        let a = sockets.last
        XCTAssertEqual(control.state, .connecting)

        control.kick()
        await pump()
        XCTAssertEqual(sockets.count, 2, "a second socket")
        XCTAssertTrue(a.cancelled, "the first attempt's socket is dropped")
        let connected = await first.value
        XCTAssertFalse(connected, "the first connect() is told it was superseded")
        XCTAssertEqual(control.state, .connecting)
        XCTAssertEqual(retries, [], "superseding is not a failure: nothing is scheduled")

        for _ in 0..<9 { control.kick() }
        await pump()
        XCTAssertEqual(sockets.count, 11, "one more socket for every kick")
        XCTAssertEqual(sockets.all.filter(\.cancelled).count, 10)

        // The last one still connects.
        sockets.last.welcome()
        await pump()
        XCTAssertEqual(control.state, .connected)
        XCTAssertEqual(reconnects, 1, "one of the kicks' attempts reports the reconnect")
    }

    /// TODAY'S BEHAVIOUR, as above: a wake while not connected is a kick, so it too restarts an
    /// attempt that is under way.
    func testAWakeDuringAnAttemptOpensASecondSocket() async {
        await beginConnect()
        let a = sockets.last
        control.wake()
        await pump()
        XCTAssertEqual(sockets.count, 2)
        XCTAssertTrue(a.cancelled)
        XCTAssertEqual(a.pings, 0, "an attempt is not pinged")
    }

    /// TODAY'S BEHAVIOUR: the superseded attempt's welcome deadline still runs, but belongs to an
    /// old generation and changes nothing.
    func testTheSupersededAttemptsDeadlineDoesNotFailTheNewAttempt() async {
        await beginConnect()
        await clock.advance(by: 6)
        control.kick()
        await pump()
        XCTAssertEqual(sockets.count, 2)
        await clock.advance(by: 2.5)
        XCTAssertEqual(control.state, .connecting, "8 s after the first attempt began, 2.5 s after the second")
        await clock.advance(by: 5.5)
        XCTAssertEqual(control.state, .failed(.timedOut()), "the second attempt's own 8 s")
    }

    // MARK: Disconnect

    func testDisconnectClosesTheSocketAndStopsRetrying() async {
        await connect()
        let s = sockets.last
        control.disconnect()
        XCTAssertEqual(s.closedWith, .normalClosure)
        XCTAssertEqual(control.state, .idle)
        s.callEverythingAgain()
        await pump()
        await clock.advance(by: 120)
        XCTAssertEqual(sockets.count, 1)
        XCTAssertEqual(retries, [])
        XCTAssertEqual(control.state, .idle)
        XCTAssertEqual(clock.liveTimers, 0)
    }

    func testDisconnectWhileWaitingOutTheBackoffOpensNothing() async {
        await beginConnect()
        sockets.last.failReceive()
        await pump()
        XCTAssertEqual(retries, [1])
        control.disconnect()
        await clock.advance(by: 30)
        XCTAssertEqual(sockets.count, 1)
        XCTAssertEqual(control.state, .idle)
    }
}
