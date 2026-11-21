import XCTest
@testable import RexKit

/// One host's `RexControl` with a clock and sockets the test moves by hand: the schedule, the
/// floor, dormancy, the deadlines, the keepalive, and what a tap, a network change, the
/// background and the return do. No real time passes and no server runs. The count of sockets
/// opened is the point of most of them: each one is a packet to a computer that may be off.
///
/// The policy is the app's (`ReconnectPolicy.standard`), with the jitter held at its middle, so
/// the waits before an episode's attempts are 0.5 s, 10 s, 120 s, then 300 s. An episode that
/// begins with an attempt (`connect()`, the return) has no first wait: its second attempt follows
/// by the 10 s.
@MainActor
final class ControlTimingTests: XCTestCase {
    private let policy = ReconnectPolicy.standard
    private var clock: FakeControlClock!
    private var sockets: FakeControlSockets!
    private var governor: ReconnectGovernor!
    private var control: RexControl!
    /// What `onRetryScheduled` reported, in order.
    private var retries: [Double] = []
    private var states: [RexControl.State] = []
    private var reconnects = 0
    /// What asked for each attempt, in order.
    private var triggers: [AttemptTrigger] = []
    private var unit = 0.5

    override func setUp() async throws {
        clock = FakeControlClock()
        sockets = FakeControlSockets()
        governor = ReconnectGovernor(policy: policy)
        unit = 0.5
        control = RexControl(address: "https://desk.example.ts.net",
                             client: ClientInfo(name: "test", version: "0", label: "test"),
                             clock: clock, sockets: sockets.factory, governor: governor, random: { [unowned self] in unit })
        retries = []
        states = []
        reconnects = 0
        triggers = []
        control.onRetryScheduled = { [unowned self] in retries.append($0) }
        control.onStateChange = { [unowned self] in states.append($0) }
        control.onReconnected = { [unowned self] _ in reconnects += 1 }
        control.onAttempt = { [unowned self] in triggers.append($0) }
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

    /// The attempt under way fails with no answer.
    private func fail() async {
        sockets.last.failReceive()
        await pump()
    }

    /// Five attempts with no answer: dormant.
    private func goDormant() async {
        await beginConnect()
        await fail()
        for step in 2...5 {
            await clock.advance(by: policy.delay(step: step))
            await fail()
        }
        XCTAssertTrue(control.dormant)
        XCTAssertEqual(sockets.count, 5)
    }

    private let refused = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost,
                                  userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNREFUSED))])

    // MARK: The schedule (spec test 1)

    func testAfterConnectTheScheduleIsTenSecondsTwoMinutesThenFiveMinutes() async {
        let first = await beginConnect()
        XCTAssertTrue(sockets.last.resumed)
        XCTAssertTrue(sockets.last.sentHello)
        sockets.last.failReceive(refused)
        let connected = await first.value
        XCTAssertFalse(connected, "the first attempt's failure is thrown to the caller")
        // `connect()` was the first attempt: the second follows by the 10 s, not by the 0.5 s.
        let waits: [Double] = [10, 120, 300, 300, 300, 300]
        for (i, wait) in waits.enumerated() {
            XCTAssertEqual(retries.count, i + 1)
            XCTAssertEqual(retries.last, wait)
            let before = sockets.count
            await clock.advance(by: wait - 0.01)
            XCTAssertEqual(sockets.count, before, "no attempt before the wait is over")
            await clock.advance(by: 0.01)
            XCTAssertEqual(sockets.count, before + 1, "one attempt when it is over")
            XCTAssertEqual(control.state, .connecting)
            sockets.last.failReceive(refused)
            await pump()
        }
        XCTAssertEqual(triggers, [.first] + Array(repeating: .backoff, count: 6))
    }

    func testAfterADropTheScheduleIsHalfASecondTenSecondsTwoMinutesThenFiveMinutes() async {
        await connect()
        sockets.last.failReceive(refused)
        await pump()
        let waits: [Double] = [0.5, 10, 120, 300, 300, 300]
        for (i, wait) in waits.enumerated() {
            XCTAssertEqual(retries.count, i + 1)
            XCTAssertEqual(retries.last, wait)
            let before = sockets.count
            await clock.advance(by: wait - 0.01)
            XCTAssertEqual(sockets.count, before)
            await clock.advance(by: 0.01)
            XCTAssertEqual(sockets.count, before + 1)
            sockets.last.failReceive(refused)
            await pump()
        }
    }

    /// Whatever the jitter draws, and however an attempt ends (at once, or at its deadline),
    /// every attempt from the third on starts 2 minutes or more after the one before STARTED.
    /// The second follows the first by its 10 s, within a fifth.
    func testTheFloorHoldsUnderEveryJitter() async {
        for timesOut in [false, true] {
            for draw in [0.0, 0.25, 0.5, 0.75, 1.0] {
                unit = draw
                control.disconnect()
                await pump()
                // Long enough for the shared budget to forget the round before.
                await clock.advance(by: 200)
                retries = []
                let from = sockets.count
                await beginConnect()
                var began = [clock.now]
                for _ in 0..<6 {
                    if timesOut { await clock.advance(by: 10) } else { sockets.last.failReceive(refused); await pump() }
                    await clock.advance(by: retries.last!)
                    XCTAssertEqual(control.state, .connecting)
                    began.append(clock.now)
                }
                XCTAssertEqual(sockets.count - from, 7)
                let gaps = zip(began, began.dropFirst()).map { $1.timeIntervalSince($0) }
                let slack = timesOut ? 10.0 : 0
                XCTAssertTrue((8 + slack...12 + slack).contains(gaps[0]), "10 s within a fifth: \(gaps[0])")
                for gap in gaps.dropFirst() { XCTAssertGreaterThanOrEqual(gap, 120, "draw \(draw)") }
                XCTAssertTrue((120 + slack...144 + slack).contains(gaps[1]))
                XCTAssertTrue((240 + slack...360 + slack).contains(gaps[2]))
            }
        }
    }

    /// The same after a drop: 0.5 s, 10 s, and from the third attempt on the floor.
    func testTheFloorHoldsAfterADropToo() async {
        await connect()
        await fail()
        var began: [Date] = []
        for _ in 0..<5 {
            await clock.advance(by: retries.last!)
            XCTAssertEqual(control.state, .connecting)
            began.append(clock.now)
            sockets.last.failReceive(refused)
            await pump()
        }
        let gaps = zip(began, began.dropFirst()).map { $1.timeIntervalSince($0) }
        XCTAssertEqual(gaps, [10, 120, 300, 300])
    }

    /// Nothing that asks brings the third attempt nearer than the floor to the second: not the
    /// return, not the network, not a host the breaker let go.
    func testNoTriggerBringsTheThirdAttemptInsideTheFloor() async {
        await beginConnect()
        await fail()
        await clock.advance(by: 10)
        await fail()
        XCTAssertEqual(sockets.count, 2)
        for _ in 0..<118 {
            control.wake()
            control.pathChanged(satisfied: true, expensive: false, interfaceChanged: true)
            control.kick(.peer)
            control.kick(.foreground)
            await clock.advance(by: 1)
        }
        XCTAssertEqual(sockets.count, 2, "118 s after the second attempt began: none")
        await clock.advance(by: 2.1)
        XCTAssertEqual(sockets.count, 3, "at 120 s: one")
    }

    func testAWelcomeStartsTheScheduleOver() async {
        await beginConnect()
        await fail()
        await clock.advance(by: 10)
        await fail()
        XCTAssertEqual(retries, [10, 120])
        await clock.advance(by: 120)
        sockets.last.welcome()
        await pump()
        XCTAssertEqual(control.state, .connected)
        XCTAssertEqual(reconnects, 1)
        await fail()
        XCTAssertEqual(retries, [10, 120, 0.5])
    }

    func testOneSocketThatFailsSeveralWaysCountsOnce() async {
        await connect()
        let s = sockets.last
        control.wake()
        s.failReceive()
        s.answerPing(URLError(.networkConnectionLost))
        s.callEverythingAgain()
        await pump()
        XCTAssertEqual(retries.count, 1, "one drop, one retry")
        XCTAssertEqual(states.filter { if case .failed = $0 { true } else { false } }.count, 1)
    }

    // MARK: Dormant (spec tests 2 and 3)

    func testFiveFailuresWithNoAnswerMakeAHostDormant() async {
        var wentDormant = 0
        control.onDormant = { wentDormant += 1 }
        await beginConnect()
        await fail()
        for step in 2...4 {
            XCTAssertFalse(control.dormant)
            await clock.advance(by: policy.delay(step: step))
            await fail()
        }
        XCTAssertFalse(control.dormant, "four")
        await clock.advance(by: policy.delay(step: 5))
        await fail()
        XCTAssertTrue(control.dormant, "five")
        XCTAssertEqual(wentDormant, 1)
        XCTAssertEqual(sockets.count, 5)
        XCTAssertEqual(retries.last, policy.dormantInterval)
    }

    func testADormantHostTakesOneSocketPerTenMinutesAndNoneInTheBackground() async {
        await goDormant()
        let before = sockets.count
        for window in 1...6 {
            await clock.advance(by: 599.9)
            XCTAssertEqual(sockets.count, before + window - 1, "nothing inside the ten minutes")
            await clock.advance(by: 0.1)
            XCTAssertEqual(sockets.count, before + window, "one attempt when they are over")
            await fail()
        }
        XCTAssertTrue(control.dormant)

        control.enteredBackground()
        await clock.advance(by: 12 * 3600)
        XCTAssertEqual(sockets.count, before + 6, "twelve hours in the background: none")
        XCTAssertEqual(clock.waiting, 0, "and nothing waits to try")
    }

    /// A computer that is off, with every attempt left to run into its deadline: the count of
    /// sockets over one hour and over a day with the app open.
    func testAHostThatNeverAnswersGetsNineAttemptsInAnHourFiftyInEightAndUnderOneHundredFiftyInADay() async {
        await beginConnect()
        await clock.advance(by: 3600)
        // At 0, 20, 150, 460 and 770 s, each running 10 s into its deadline; dormant at 780 s,
        // then one per 610 s: 1390, 2000, 2610, 3220.
        XCTAssertEqual(sockets.count, 9)
        XCTAssertTrue(control.dormant)
        await clock.advance(by: 7 * 3600)
        XCTAssertEqual(sockets.count, 50)
        await clock.advance(by: 16 * 3600)
        XCTAssertEqual(sockets.count, 145)
    }

    func testAnAnswerIsNotASilenceAndRefusalsNeverMakeAHostDormant() async {
        await beginConnect()
        sockets.last.failReceive(refused)
        await pump()
        for _ in 0..<12 {
            await clock.advance(by: retries.last!)
            sockets.last.failReceive(refused)
            await pump()
        }
        XCTAssertFalse(control.dormant)
        XCTAssertEqual(retries.last, 300, "the normal schedule, at its cap")
    }

    // MARK: Stopped (spec test 9)

    func testAServerThatTurnsTheClientAwayIsNotRetriedUntilTheUserAsks() async {
        await beginConnect()
        let s = sockets.last
        s.response = HTTPURLResponse(url: URL(string: "https://desk.example.ts.net")!, statusCode: 403, httpVersion: nil, headerFields: nil)
        s.failReceive(URLError(.badServerResponse))
        await pump()
        XCTAssertTrue(control.retryStopped)
        XCTAssertEqual(retries, [])
        await clock.advance(by: 3600)
        XCTAssertEqual(sockets.count, 1)
        control.wake()
        control.pathChanged(satisfied: true, expensive: false, interfaceChanged: true)
        await pump()
        XCTAssertEqual(sockets.count, 1, "the return and the network don't ask again")
        control.kick()
        await pump()
        XCTAssertEqual(sockets.count, 2, "the user does")
    }

    // MARK: Generations

    func testLateCallbacksFromAnOldSocketAreIgnored() async {
        await connect()
        let old = sockets.last
        control.wake()
        old.failReceive()
        await pump()
        XCTAssertTrue(old.cancelled)
        XCTAssertEqual(retries, [0], "the drop came right after a wake: at once")
        XCTAssertEqual(sockets.count, 2)
        let new = sockets.last
        new.welcome(token: "t2")
        await pump()
        XCTAssertEqual(control.state, .connected)
        let seen = states.count, asked = retries.count

        var events = 0
        control.onEvent = { _, _ in events += 1 }
        old.callEverythingAgain()
        old.deliverLate(#"{"type":"event","seq":9,"payload":{}}"#)
        await pump()
        await clock.advance(by: 20)
        XCTAssertEqual(control.state, .connected)
        XCTAssertEqual(states.count, seen, "no state change")
        XCTAssertEqual(retries.count, asked, "no retry")
        XCTAssertEqual(sockets.count, 2, "no new socket")
        XCTAssertEqual(events, 0, "an old socket's message is dropped")
        XCTAssertFalse(new.cancelled)
    }

    func testAWelcomeOnAnOldSocketDoesNotConnect() async {
        let first = await beginConnect()
        let old = sockets.last
        old.failReceive()
        _ = await first.value
        await clock.advance(by: 10)
        XCTAssertEqual(sockets.count, 2)
        old.deliverLate(#"{"type":"welcome","client":{"id":"client:old","reconnect_token":"old"}}"#)
        await pump()
        XCTAssertEqual(control.state, .connecting, "only the current socket's welcome counts")
        XCTAssertNil(control.clientID)
    }

    // MARK: Deadlines

    func testNoWelcomeByTheDeadlineFailsTheAttemptTenSecondsOnWiFiFifteenOnCellular() async {
        let first = await beginConnect()
        await clock.advance(by: 9.99)
        XCTAssertEqual(control.state, .connecting)
        await clock.advance(by: 0.01)
        XCTAssertEqual(control.state, .failed(.timedOut()))
        let connected = await first.value
        XCTAssertFalse(connected)
        XCTAssertTrue(sockets.last.cancelled)

        control.pathChanged(satisfied: true, expensive: true, interfaceChanged: false)
        await clock.advance(by: 10)
        XCTAssertEqual(sockets.count, 2)
        await clock.advance(by: 14.99)
        XCTAssertEqual(control.state, .connecting)
        await clock.advance(by: 0.01)
        XCTAssertEqual(control.state, .failed(.timedOut()))
    }

    func testAnEarlierAttemptsDeadlineDoesNotFailALaterOne() async {
        await beginConnect()
        await clock.advance(by: 9)
        await fail()
        control.kick()
        await pump()
        XCTAssertEqual(sockets.count, 2)
        await clock.advance(by: 2)
        XCTAssertEqual(control.state, .connecting, "the first attempt's 10 s are over; the second is 2 s old")
        XCTAssertFalse(sockets.last.cancelled)
    }

    // MARK: Liveness

    func testAPingGoesWhenNothingCameInForThirtySecondsAndAMissedPongDropsTheConnection() async {
        await connect()
        let s = sockets.last
        await clock.advance(by: 29.9)
        XCTAssertEqual(s.pings, 0)
        await clock.advance(by: 0.1)
        XCTAssertEqual(s.pings, 1)
        s.answerPing()
        await pump()
        // Something comes in: the next turn sends no ping.
        await clock.advance(by: 20)
        s.deliver(#"{"type":"event","seq":1,"payload":{}}"#)
        await pump()
        await clock.advance(by: 10)
        XCTAssertEqual(s.pings, 1, "an event arrived 10 s ago")
        await clock.advance(by: 30)
        XCTAssertEqual(s.pings, 2)
        // No pong: dead after 10 s.
        await clock.advance(by: 9.9)
        XCTAssertEqual(control.state, .connected)
        await clock.advance(by: 0.1)
        XCTAssertEqual(control.state, .failed(.timedOut()))
        XCTAssertTrue(s.cancelled)
        XCTAssertEqual(clock.liveTimers, 0, "a dropped connection sends no more pings")
    }

    func testThePongDeadlineIsTwentySecondsOnCellular() async {
        await connect()
        control.pathChanged(satisfied: true, expensive: true, interfaceChanged: false)
        await clock.advance(by: 30)
        XCTAssertEqual(sockets.last.pings, 1)
        await clock.advance(by: 19.9)
        XCTAssertEqual(control.state, .connected)
        await clock.advance(by: 0.1)
        XCTAssertEqual(control.state, .failed(.timedOut()))
    }

    func testAFailedPingDropsAtOnce() async {
        await connect()
        await clock.advance(by: 30)
        sockets.last.answerPing(URLError(.networkConnectionLost))
        await pump()
        XCTAssertTrue(isFailed)
        XCTAssertEqual(retries, [0.5])
    }

    /// The watchdog: a request with nothing at all coming back sends a ping after 5 s, not at
    /// the keepalive's turn, and the missed pong drops the connection 10 s later.
    func testARequestWithNothingComingBackPingsAfterFiveSeconds() async {
        await connect()
        let s = sockets.last
        var socketDied = 0
        control.onSocketDead = { socketDied += 1 }
        let call = Task { @MainActor [control] in _ = try? await control!.call("session.list") }
        await pump()
        await clock.advance(by: 4.9)
        XCTAssertEqual(s.pings, 0)
        await clock.advance(by: 0.1)
        XCTAssertEqual(s.pings, 1, "5 s with no frame: a ping")
        await clock.advance(by: 10)
        XCTAssertEqual(control.state, .failed(.timedOut()), "no pong in 10 s: dead")
        XCTAssertEqual(socketDied, 1, "what else holds sockets to the host is told once")
        _ = await call.value
    }

    func testARequestThatIsAnsweredSendsNoPing() async {
        await connect()
        let s = sockets.last
        let call = Task { @MainActor [control] in _ = try? await control!.call("session.list") }
        await pump()
        await clock.advance(by: 2)
        s.deliver(#"{"type":"response","id":"1","payload":{}}"#)
        await pump()
        _ = await call.value
        await clock.advance(by: 10)
        XCTAssertEqual(s.pings, 0)
        XCTAssertEqual(control.state, .connected)
    }

    // MARK: Wake

    func testWakeKeepsAConnectionThatAnswersThePing() async {
        await connect()
        control.wake()
        XCTAssertEqual(sockets.last.pings, 1)
        sockets.last.answerPing()
        await clock.advance(by: 4)
        XCTAssertEqual(control.state, .connected)
        XCTAssertEqual(sockets.count, 1)
        XCTAssertEqual(retries, [])
        await fail()
        XCTAssertEqual(retries, [0.5], "the pong ended the wake: a later drop takes the schedule")
    }

    func testWakeDropsAConnectionWithNoPongAndRetriesAtOnce() async {
        await connect()
        control.wake()
        await clock.advance(by: 2.49)
        XCTAssertEqual(control.state, .connected)
        await clock.advance(by: 0.01)
        XCTAssertEqual(retries, [0], "at once, not after a wait")
        XCTAssertEqual(sockets.count, 2)
        XCTAssertEqual(triggers.last, .foreground)
        await fail()
        XCTAssertEqual(retries, [0, 10], "at once only once: that was the episode's first attempt")
    }

    func testTheWakePongWaitIsFiveSecondsOnCellular() async {
        await connect()
        control.pathChanged(satisfied: true, expensive: true, interfaceChanged: false)
        control.wake()
        await clock.advance(by: 4.9)
        XCTAssertEqual(control.state, .connected)
        await clock.advance(by: 0.1)
        XCTAssertEqual(sockets.count, 2)
    }

    // MARK: A tap (spec test 7)

    func testTenTapsGiveOneAttempt() async {
        await beginConnect()
        await fail()
        for _ in 0..<10 { control.kick() }
        await pump()
        XCTAssertEqual(sockets.count, 2, "ten taps in a moment: one attempt")
        for _ in 0..<10 {
            control.kick()
            await pump()
            await clock.advance(by: 0.3)
        }
        XCTAssertEqual(sockets.count, 2, "and none while it is under way")
        XCTAssertFalse(sockets.last.cancelled, "the attempt is not started over")
        XCTAssertEqual(triggers.last, .user)
    }

    func testATapDuringTheFirstConnectIsANoOp() async {
        let first = await beginConnect()
        control.kick()
        control.wake()
        await pump()
        XCTAssertEqual(sockets.count, 1)
        XCTAssertFalse(sockets.last.cancelled)
        sockets.last.welcome()
        let ok = await first.value
        XCTAssertTrue(ok, "the first connect() ends with its own welcome")
    }

    func testATapTriesNowAndDoesNotStartTheScheduleOver() async {
        await beginConnect()
        await fail()
        await clock.advance(by: 10)
        await fail()
        XCTAssertEqual(retries, [10, 120])
        control.kick()
        await pump()
        XCTAssertEqual(sockets.count, 3, "the attempt starts now, inside the floor: the user asked")
        await fail()
        XCTAssertEqual(retries, [10, 120, 300], "the next wait is the next step, not the first")
        await clock.advance(by: 299)
        XCTAssertEqual(sockets.count, 3, "and the wait that was running is gone")
    }

    /// Taps on one host are 10 s apart: a host that turns each attempt away at once is not
    /// asked once per tap. The tap is not lost: its attempt comes when the 10 s are over.
    func testTapsOnOneHostAreTenSecondsApart() async {
        await beginConnect()
        sockets.last.failReceive(refused)
        await pump()
        control.kick()
        await pump()
        XCTAssertEqual(sockets.count, 2)
        sockets.last.failReceive(refused)
        await pump()
        for _ in 0..<9 {
            control.kick()
            await pump()
            await clock.advance(by: 1)
        }
        XCTAssertEqual(sockets.count, 2, "nine taps in the 9 s after: none yet")
        await clock.advance(by: 1)
        XCTAssertEqual(sockets.count, 3, "at 10 s: the one they asked for")
        XCTAssertEqual(triggers.last, .user)
    }

    func testATapGivesADormantHostOneAttemptAndItStaysDormant() async {
        await goDormant()
        await clock.advance(by: 30)
        control.kick()
        await pump()
        XCTAssertEqual(sockets.count, 6)
        await fail()
        XCTAssertTrue(control.dormant)
        await clock.advance(by: 599)
        XCTAssertEqual(sockets.count, 6, "the next one is ten minutes after it")
        await clock.advance(by: 1)
        XCTAssertEqual(sockets.count, 7)
    }

    func testKickWhileConnectedOrBeforeConnectDoesNothing() async {
        control.kick()
        control.wake()
        await pump()
        XCTAssertEqual(sockets.count, 0)
        XCTAssertEqual(control.state, .idle)
        await connect()
        control.kick()
        await pump()
        XCTAssertEqual(sockets.count, 1)
        XCTAssertFalse(sockets.last.cancelled)
    }

    // MARK: The network path (spec test 6)

    func testAPathChangePingsALiveSocketAndNeverTearsItDown() async {
        await connect()
        let s = sockets.last
        control.pathChanged(satisfied: true, expensive: true, interfaceChanged: true)
        await pump()
        XCTAssertEqual(s.pings, 1)
        XCTAssertFalse(s.cancelled)
        XCTAssertEqual(sockets.count, 1)
        s.answerPing()
        await clock.advance(by: 25)
        XCTAssertEqual(control.state, .connected)
        // No path at all: still not torn down.
        control.pathChanged(satisfied: false, expensive: false, interfaceChanged: true)
        await pump()
        XCTAssertEqual(control.state, .connected)
        XCTAssertFalse(s.cancelled)
    }

    func testAPathChangeGivesADormantHostOneAttemptOnlyPastTheFloor() async {
        await goDormant()
        let before = sockets.count
        // 30 s after its last attempt: a minute of a path that changes every second.
        await clock.advance(by: 30)
        for _ in 0..<60 {
            control.pathChanged(satisfied: true, expensive: false, interfaceChanged: true)
            await clock.advance(by: 1)
        }
        XCTAssertEqual(sockets.count, before, "inside the two minutes: none")
        await clock.advance(by: 30)
        // Past the floor: the next change, reported several times over, gives one.
        for _ in 0..<20 { control.pathChanged(satisfied: true, expensive: false, interfaceChanged: true) }
        await pump()
        XCTAssertEqual(sockets.count, before + 1)
        XCTAssertEqual(triggers.last, .network)
        await fail()
        XCTAssertTrue(control.dormant)
        // And a path that goes on changing: one attempt per two minutes at most.
        let from = sockets.count
        for _ in 0..<600 {
            control.pathChanged(satisfied: true, expensive: false, interfaceChanged: true)
            await pump()
            if sockets.last.isWaitingToReceive { sockets.last.failReceive() }
            await clock.advance(by: 1)
        }
        XCTAssertLessThanOrEqual(sockets.count - from, 1, "ten minutes of changes: its own turn, no more")
    }

    /// A path that changes route every 5 s for an hour (`RouteWatch` settles each one), and a
    /// host that is dormant: it is asked no more often than its ten minutes.
    func testUnderAFlappingPathForAnHourADormantHostGetsAtMostSixAttempts() async {
        await goDormant()
        let watch = RouteWatch(policy: policy, clock: clock)
        var changes = 0
        watch.onChange = { [unowned self] in
            changes += 1
            control.pathChanged(satisfied: true, expensive: false, interfaceChanged: true)
        }
        let wifi = PathFacts(satisfied: true, interface: .wifi, tunnel: ["a"])
        let cell = PathFacts(satisfied: true, expensive: true, interface: .cellular, tunnel: ["a"])
        watch.report(wifi)
        let from = sockets.count
        for second in 0..<3600 {
            if second % 5 == 0 { watch.report((second / 5) % 2 == 0 ? cell : wifi) }
            if sockets.last.isWaitingToReceive { sockets.last.failReceive() }
            await clock.advance(by: 1)
        }
        XCTAssertGreaterThan(changes, 600, "the route did change, hundreds of times")
        XCTAssertLessThanOrEqual(sockets.count - from, 6)
        XCTAssertGreaterThanOrEqual(sockets.count - from, 5)
    }

    /// `RouteWatch`: a burst of reports is one change, 2 s after the last; reports that change
    /// no route are none; the first report is the start.
    func testARouteChangeIsReportedOnceItHasSettled() async {
        let watch = RouteWatch(policy: policy, clock: clock)
        var changes = 0
        watch.onChange = { changes += 1 }
        let wifi = PathFacts(satisfied: true, interface: .wifi, tunnel: ["a"])
        let cell = PathFacts(satisfied: true, expensive: true, interface: .cellular, tunnel: ["a"])
        watch.report(wifi)
        await clock.advance(by: 10)
        XCTAssertEqual(changes, 0, "the first report is where the app started")
        // A burst: ten reports in a second.
        for i in 0..<10 {
            watch.report(i % 2 == 0 ? cell : PathFacts(satisfied: false, interface: .none))
            await clock.advance(by: 0.1)
        }
        watch.report(cell)
        await clock.advance(by: 1.9)
        XCTAssertEqual(changes, 0, "not settled yet")
        await clock.advance(by: 0.2)
        XCTAssertEqual(changes, 1)
        // Cost and constraints alone: no change of route.
        var same = cell
        same.expensive = false
        watch.report(same)
        await clock.advance(by: 5)
        XCTAssertEqual(changes, 1)
        // Away and back to the same route inside the 2 s: none.
        watch.report(wifi)
        await clock.advance(by: 1)
        watch.report(same)
        await clock.advance(by: 5)
        XCTAssertEqual(changes, 1)
        // No path, then a path: one, when the path is back.
        watch.report(PathFacts(satisfied: false, interface: .none))
        await clock.advance(by: 5)
        XCTAssertEqual(changes, 1, "no path is nothing to try on")
        watch.report(same)
        await clock.advance(by: 2)
        XCTAssertEqual(changes, 2)
        // Another tunnel address on the same interface.
        watch.report(PathFacts(satisfied: true, interface: .cellular, tunnel: ["b"]))
        await clock.advance(by: 2)
        XCTAssertEqual(changes, 3)
    }

    /// A path report that is no change of route, after no path at all: the wait that had
    /// stopped goes on, and nothing is asked on top of it.
    func testAPathAgainWithNoChangeOfRouteLetsTheScheduleGoOn() async {
        await beginConnect()
        await fail()
        await clock.advance(by: 10)
        await fail()
        XCTAssertEqual(retries, [10, 120])
        await clock.advance(by: 30)
        control.pathChanged(satisfied: false, expensive: false, interfaceChanged: false)
        await clock.advance(by: 30)
        control.pathChanged(satisfied: true, expensive: false, interfaceChanged: false)
        await pump()
        XCTAssertEqual(sockets.count, 2)
        await clock.advance(by: 59)
        XCTAssertEqual(sockets.count, 2)
        await clock.advance(by: 1)
        XCTAssertEqual(sockets.count, 3, "at the end of the 120 s it was waiting")
    }

    func testAPathReportThatChangesNoInterfaceAsksForNothing() async {
        await goDormant()
        await clock.advance(by: 300)
        control.pathChanged(satisfied: true, expensive: false, interfaceChanged: false)
        await pump()
        XCTAssertEqual(sockets.count, 5)
    }

    func testWithNoPathNothingIsTriedAndNothingCounts() async {
        await beginConnect()
        control.pathChanged(satisfied: false, expensive: false, interfaceChanged: true)
        for _ in 0..<8 {
            if sockets.last.isWaitingToReceive { sockets.last.failReceive(URLError(.notConnectedToInternet)) }
            await pump()
            await clock.advance(by: 600)
        }
        XCTAssertEqual(sockets.count, 1, "no attempt while the phone has no network")
        XCTAssertFalse(control.dormant, "and the failure counted toward nothing")
        // A tap is still let through.
        control.kick()
        await pump()
        XCTAssertEqual(sockets.count, 2)
        sockets.last.failReceive(URLError(.notConnectedToInternet))
        await pump()
        // The path is back: one attempt, the last one being long ago.
        await clock.advance(by: 200)
        control.pathChanged(satisfied: true, expensive: false, interfaceChanged: true)
        await pump()
        XCTAssertEqual(sockets.count, 3)
        XCTAssertEqual(triggers.last, .network)
    }

    func testAPathThatComesBackRightAfterADropReconnectsWithinASecond() async {
        await connect()
        await clock.advance(by: 30)
        control.pathChanged(satisfied: false, expensive: false, interfaceChanged: true)
        await fail()
        XCTAssertEqual(retries, [], "no path: no wait is set")
        await clock.advance(by: 3)
        control.pathChanged(satisfied: true, expensive: false, interfaceChanged: true)
        await pump()
        await clock.advance(by: 0.5)
        XCTAssertEqual(sockets.count, 2)
    }

    // MARK: Background

    func testNothingIsTriedPingedOrWaitingInTheBackground() async {
        await beginConnect()
        await fail()
        XCTAssertEqual(retries, [10])
        control.enteredBackground()
        XCTAssertTrue(control.suspended)
        await clock.advance(by: 15)
        XCTAssertEqual(clock.waiting, 0, "no wait is armed once the first attempt's deadline has passed")
        await clock.advance(by: 8 * 3600)
        XCTAssertEqual(sockets.count, 1, "eight hours in the background: no attempt")
        control.kick(.network)
        control.kick()
        control.pathChanged(satisfied: true, expensive: false, interfaceChanged: true)
        await pump()
        await clock.advance(by: 600)
        XCTAssertEqual(sockets.count, 1, "asking changes nothing there")

        control.wake()
        await pump()
        XCTAssertFalse(control.suspended)
        XCTAssertEqual(sockets.count, 2, "back in front: one attempt")
        XCTAssertEqual(triggers.last, .foreground)
        await fail()
        XCTAssertEqual(retries.last, 120, "and the schedule goes on from where it was")
    }

    /// An attempt that is under way when the app goes to the background is given up: its
    /// socket is dropped at once, and it is not taken for the host's failure.
    func testAnAttemptUnderWayIsCancelledAtTheBackground() async {
        let first = await beginConnect()
        let s = sockets.last
        control.enteredBackground()
        XCTAssertTrue(s.cancelled)
        XCTAssertTrue(isFailed)
        let connected = await first.value
        XCTAssertFalse(connected)
        await clock.advance(by: 3600)
        XCTAssertEqual(sockets.count, 1)
        XCTAssertEqual(clock.waiting, 0)
        XCTAssertFalse(control.dormant)
        // A welcome that comes late on the socket that was dropped changes nothing.
        s.deliverLate(#"{"type":"welcome","client":{"id":"client:old","reconnect_token":"old"}}"#)
        await pump()
        XCTAssertTrue(isFailed)
        control.wake()
        await pump()
        XCTAssertEqual(sockets.count, 2, "back in front: one attempt")
    }

    // MARK: The verdict after the background (data paths wait for it)

    func testDataIsHeldFromTheBackgroundUntilThePongOfTheReturn() async {
        await connect()
        var verdicts = 0
        control.observeVerdict { verdicts += 1; return true }
        XCTAssertFalse(control.holdsData)
        control.enteredBackground()
        XCTAssertTrue(control.holdsData, "in the background")
        XCTAssertThrowsError(try control.openDataSocket(subprotocol: "rex.data.terminal.v1")) { _ in }
        control.wake()
        XCTAssertTrue(control.holdsData, "back, but the connection has not answered yet")
        XCTAssertEqual(verdicts, 0)
        await clock.advance(by: 1)
        XCTAssertTrue(control.holdsData)
        sockets.last.answerPing()
        await pump()
        XCTAssertFalse(control.holdsData, "the pong is the verdict")
        XCTAssertEqual(verdicts, 1)
        // The keepalive's pongs later are no verdicts.
        await clock.advance(by: 30)
        sockets.last.answerPing()
        await pump()
        XCTAssertEqual(verdicts, 1)
    }

    func testWithNoPongTheVerdictIsTheFreshWelcome() async {
        await connect()
        var verdicts = 0, connects = 0
        control.observeVerdict { verdicts += 1; return true }
        control.observeConnected { connects += 1; return true }
        control.enteredBackground()
        control.wake()
        await clock.advance(by: 2.5)
        XCTAssertEqual(sockets.count, 2, "no pong: the connection is made again")
        XCTAssertTrue(control.holdsData)
        sockets.last.welcome()
        await pump()
        XCTAssertFalse(control.holdsData)
        XCTAssertEqual(connects, 1, "the welcome is told as every reconnect is")
        XCTAssertEqual(verdicts, 0)
    }

    func testAConnectionInTheBackgroundIsNotPingedAndADropIsNotRetriedUntilTheReturn() async {
        await connect()
        control.enteredBackground()
        await clock.advance(by: 600)
        XCTAssertEqual(sockets.last.pings, 0, "no ping in the background")
        await fail()
        XCTAssertEqual(retries, [])
        await clock.advance(by: 3600)
        XCTAssertEqual(sockets.count, 1)
        XCTAssertEqual(clock.waiting, 0)
        control.wake()
        await pump()
        await clock.advance(by: 0.5)
        XCTAssertEqual(sockets.count, 2, "one attempt at the return")
        sockets.last.welcome()
        await pump()
        XCTAssertEqual(control.state, .connected)
    }

    func testTheReturnHoldsABackingOffHostToTheFloor() async {
        await beginConnect()
        await fail()
        await clock.advance(by: 10)
        await fail()
        XCTAssertEqual(sockets.count, 2)
        control.enteredBackground()
        await clock.advance(by: 20)
        control.wake()
        await pump()
        XCTAssertEqual(sockets.count, 2, "20 s after its second attempt began: not yet")
        await clock.advance(by: 99.9)
        XCTAssertEqual(sockets.count, 2)
        await clock.advance(by: 0.2)
        XCTAssertEqual(sockets.count, 3, "two minutes after it")
    }

    func testTheReturnLeavesADormantHostAloneUnlessItIsSelected() async {
        await goDormant()
        control.enteredBackground()
        await clock.advance(by: 3600)
        control.wake()
        await pump()
        XCTAssertEqual(sockets.count, 5, "not selected: no attempt at the return")
        // Its wait goes on from where the background stopped it: the whole ten minutes here.
        await clock.advance(by: 599)
        XCTAssertEqual(sockets.count, 5)
        await clock.advance(by: 1)
        XCTAssertEqual(sockets.count, 6)
        await fail()

        governor.select(control)
        control.enteredBackground()
        await clock.advance(by: 60)
        control.wake()
        await pump()
        XCTAssertEqual(sockets.count, 6, "selected, but inside the floor")
        control.enteredBackground()
        await clock.advance(by: 120)
        control.wake()
        await pump()
        XCTAssertEqual(sockets.count, 7, "selected and past the floor: one attempt")
    }

    /// A dormant host that is not selected, and visits to the app of 90 s each: its wait counts
    /// the time in the foreground, so the visits add up to a turn. Never in the background, and
    /// never two turns within ten minutes.
    func testADormantHostIsNotStarvedByShortVisits() async {
        await goDormant()
        var began: [Date] = []
        control.onAttempt = { [unowned self] _ in began.append(clock.now) }
        var inBackground = false, triedInBackground = 0
        for _ in 0..<80 {
            // 90 s in front.
            for _ in 0..<90 {
                if sockets.last.isWaitingToReceive { sockets.last.failReceive() }
                await clock.advance(by: 1)
            }
            control.enteredBackground()
            inBackground = true
            let n = began.count
            await clock.advance(by: 300)
            triedInBackground += began.count - n
            inBackground = false
            control.wake()
            await pump()
        }
        _ = inBackground
        XCTAssertEqual(triedInBackground, 0)
        // Two hours in front, in 80 visits: about one turn per ten minutes of them.
        XCTAssertGreaterThanOrEqual(began.count, 9, "the visits add up")
        XCTAssertLessThanOrEqual(began.count, 12)
        for gap in zip(began, began.dropFirst()).map({ $1.timeIntervalSince($0) }) {
            XCTAssertGreaterThanOrEqual(gap, 600)
        }
    }

    // MARK: What an observer of the state reads

    /// Whoever hears of a failure reads the facts as they are after it: `dormant` at the fifth
    /// silence, `retryStopped` at a 401.
    func testAnObserverOfAFailureReadsTheFactsAfterIt() async {
        var seen: [(dormant: Bool, stopped: Bool)] = []
        control.onStateChange = { [unowned self] st in
            if case .failed = st { seen.append((control.dormant, control.retryStopped)) }
        }
        await goDormant()
        XCTAssertEqual(seen.map(\.dormant), [false, false, false, false, true], "dormant is set when the fifth failure is told")
        control.kick()
        await pump()
        sockets.last.response = HTTPURLResponse(url: URL(string: "https://desk.example.ts.net")!, statusCode: 401,
                                                httpVersion: nil, headerFields: nil)
        sockets.last.failReceive(URLError(.badServerResponse))
        await pump()
        XCTAssertEqual(seen.last?.stopped, true, "and stopped when the 401 is told")
    }

    /// The deadline of an attempt ends with the attempt: after the welcome nothing sleeps on.
    func testTheWelcomeDeadlineIsCancelledWhenTheAttemptEnds() async {
        await connect()
        XCTAssertEqual(clock.waiting, 0, "after the welcome")
        await fail()
        await clock.advance(by: 0.5)
        XCTAssertEqual(control.state, .connecting)
        XCTAssertEqual(clock.waiting, 1, "the attempt's deadline")
        await fail()
        XCTAssertEqual(clock.waiting, 1, "the failed attempt's deadline is gone: only the wait for the next is left")
        control.disconnect()
        await pump()
        XCTAssertEqual(clock.waiting, 0, "after the disconnect")
    }

    // MARK: Disconnect

    /// A tap, then `disconnect()` before its attempt began: nothing is opened.
    func testAnAttemptLetThroughBeforeDisconnectOpensNothing() async {
        await beginConnect()
        await fail()
        control.kick()
        control.disconnect()
        await pump()
        await clock.advance(by: 60)
        XCTAssertEqual(sockets.count, 1)
        XCTAssertEqual(control.state, .idle)
        // The same for a wait that ends in the turn of the disconnect.
        await beginConnect()
        await fail()
        control.kick(.foreground)
        control.disconnect()
        await clock.advance(by: 60)
        XCTAssertEqual(sockets.count, 2)
    }

    // MARK: TLS

    private let untrusted = URLError(.serverCertificateUntrusted)

    /// A TLS failure is tried again on the normal schedule. It stops the retries only at the
    /// third in a row while another host is connected: then the tunnel works and this host's
    /// certificate is the trouble.
    func testATLSFailureIsRetriedAndStopsOnlyAtTheThirdWhileAnotherHostIsUp() async {
        await beginConnect()
        for _ in 0..<6 {
            sockets.last.failReceive(untrusted)
            await pump()
            XCTAssertFalse(control.retryStopped, "no other host is up: a tunnel half up fails TLS too")
            await clock.advance(by: retries.last!)
        }
        XCTAssertFalse(control.dormant, "and it is not a silence")
        sockets.last.welcome()
        await pump()

        // Another host of the same governor is connected.
        let others = FakeControlSockets()
        let other = RexControl(address: "https://other.example.ts.net",
                               client: ClientInfo(name: "test", version: "0", label: "test"),
                               clock: clock, sockets: others.factory, governor: governor)
        Task { @MainActor in try? await other.connect() }
        await pump()
        others.last.welcome()
        await pump()
        sockets.last.failReceive(untrusted)
        await pump()
        for n in 1...2 {
            XCTAssertFalse(control.retryStopped, "TLS failure \(n)")
            await clock.advance(by: retries.last!)
            sockets.last.failReceive(untrusted)
            await pump()
        }
        XCTAssertTrue(control.retryStopped, "the third in a row")
        let n = sockets.count
        await clock.advance(by: 3600)
        XCTAssertEqual(sockets.count, n, "only the user asks again")
        control.kick()
        await pump()
        XCTAssertEqual(sockets.count, n + 1)
        other.disconnect()
    }

    func testDisconnectClosesTheSocketAndStopsEverything() async {
        await connect()
        let s = sockets.last
        control.disconnect()
        XCTAssertEqual(s.closedWith, .normalClosure)
        XCTAssertEqual(control.state, .idle)
        s.callEverythingAgain()
        await pump()
        await clock.advance(by: 3600)
        XCTAssertEqual(sockets.count, 1)
        XCTAssertEqual(retries, [])
        XCTAssertEqual(clock.liveTimers, 0)
    }

    func testDisconnectDuringAWaitOpensNothing() async {
        await beginConnect()
        await fail()
        control.disconnect()
        await clock.advance(by: 3600)
        XCTAssertEqual(sockets.count, 1)
        XCTAssertEqual(control.state, .idle)
    }
}
