import XCTest
@testable import RexKit

/// One host's `RexControl` with a clock and sockets the test moves by hand: the schedule, the
/// floor, dormancy, the deadlines, the keepalive, and what a tap, a network change, the
/// background and the return do. No real time passes and no server runs. The count of sockets
/// opened is the point of most of them: each one is a packet to a computer that may be off.
///
/// The policy is the app's (`ReconnectPolicy.standard`), with the jitter held at its middle, so
/// the waits are 0.5 s, 10 s, 120 s, then 300 s.
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
        for step in 1...4 {
            await clock.advance(by: policy.delay(step: step))
            await fail()
        }
        XCTAssertTrue(control.dormant)
        XCTAssertEqual(sockets.count, 5)
    }

    private let refused = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost,
                                  userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNREFUSED))])

    // MARK: The schedule (spec test 1)

    func testTheScheduleIsHalfASecondTenSecondsTwoMinutesThenFiveMinutes() async {
        let first = await beginConnect()
        XCTAssertTrue(sockets.last.resumed)
        XCTAssertTrue(sockets.last.sentHello)
        sockets.last.failReceive(refused)
        let connected = await first.value
        XCTAssertFalse(connected, "the first attempt's failure is thrown to the caller")
        let waits: [Double] = [0.5, 10, 120, 300, 300, 300]
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

    /// Whatever the jitter draws, attempts from the third on are 2 minutes or more after the one
    /// before, and the waits stay within a fifth of their length.
    func testTheFloorHoldsUnderEveryJitter() async {
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
            sockets.last.failReceive(refused)
            await pump()
            for _ in 0..<6 {
                await clock.advance(by: retries.last!)
                XCTAssertEqual(control.state, .connecting)
                began.append(clock.now)
                sockets.last.failReceive(refused)
                await pump()
            }
            XCTAssertEqual(sockets.count - from, 7)
            let gaps = zip(began, began.dropFirst()).map { $1.timeIntervalSince($0) }
            XCTAssertLessThanOrEqual(gaps[0], 1)
            XCTAssertTrue((8...12).contains(gaps[1]), "10 s within a fifth: \(gaps[1])")
            for gap in gaps.dropFirst(2) { XCTAssertGreaterThanOrEqual(gap, 120, "draw \(draw)") }
            XCTAssertTrue((120...144).contains(gaps[2]))
            XCTAssertTrue((240...360).contains(gaps[3]))
        }
    }

    func testAWelcomeStartsTheScheduleOver() async {
        await beginConnect()
        await fail()
        await clock.advance(by: 0.5)
        await fail()
        XCTAssertEqual(retries, [0.5, 10])
        await clock.advance(by: 10)
        sockets.last.welcome()
        await pump()
        XCTAssertEqual(control.state, .connected)
        XCTAssertEqual(reconnects, 1)
        await fail()
        XCTAssertEqual(retries, [0.5, 10, 0.5])
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
        for step in 1...3 {
            XCTAssertFalse(control.dormant)
            await clock.advance(by: policy.delay(step: step))
            await fail()
        }
        XCTAssertFalse(control.dormant, "four")
        await clock.advance(by: policy.delay(step: 4))
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
    func testAHostThatNeverAnswersGetsTenAttemptsInAnHourAndUnderOneHundredFiftyInADay() async {
        await beginConnect()
        await clock.advance(by: 3600)
        XCTAssertEqual(sockets.count, 10)
        XCTAssertTrue(control.dormant)
        await clock.advance(by: 23 * 3600)
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
        await clock.advance(by: 0.5)
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
        await clock.advance(by: 0.5)
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
        await clock.advance(by: 0.5)
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
        XCTAssertEqual(retries, [0, 0.5], "at once only once")
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
        await clock.advance(by: 0.5)
        await fail()
        await clock.advance(by: 10)
        await fail()
        XCTAssertEqual(retries, [0.5, 10, 120])
        control.kick()
        await pump()
        XCTAssertEqual(sockets.count, 4, "the attempt starts now, inside the floor: the user asked")
        await fail()
        XCTAssertEqual(retries, [0.5, 10, 120, 300], "the next wait is the next step, not the first")
        await clock.advance(by: 299)
        XCTAssertEqual(sockets.count, 4, "and the wait that was running is gone")
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
        XCTAssertLessThanOrEqual(sockets.count - from, 5, "ten minutes of changes")
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
        XCTAssertEqual(retries, [0.5])
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
        XCTAssertEqual(retries.last, 10, "and the schedule goes on from where it was")
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
        await clock.advance(by: 0.5)
        await fail()
        await clock.advance(by: 10)
        await fail()
        XCTAssertEqual(sockets.count, 3)
        control.enteredBackground()
        await clock.advance(by: 20)
        control.wake()
        await pump()
        XCTAssertEqual(sockets.count, 3, "20 s after its third attempt: not yet")
        await clock.advance(by: 99.9)
        XCTAssertEqual(sockets.count, 3)
        await clock.advance(by: 0.2)
        XCTAssertEqual(sockets.count, 4, "two minutes after it")
    }

    func testTheReturnLeavesADormantHostAloneUnlessItIsSelected() async {
        await goDormant()
        control.enteredBackground()
        await clock.advance(by: 3600)
        control.wake()
        await pump()
        XCTAssertEqual(sockets.count, 5, "not selected: no attempt at the return")
        // Its ten-minute turn is long due: it comes two minutes after the return, no sooner.
        await clock.advance(by: 119)
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

    // MARK: Disconnect

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
