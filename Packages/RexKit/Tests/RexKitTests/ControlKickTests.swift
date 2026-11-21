import XCTest
@testable import RexKit

/// What a request for an attempt does to an attempt that is already under way, with a clock and
/// sockets the test moves by hand. No request cancels it or opens a second socket beside it; a
/// change of route alone gives it a new socket, once. And the state is checked where the socket
/// is opened, so a request that was let through a turn ago can't replace a socket that has since
/// got its welcome.
@MainActor
final class ControlKickTests: XCTestCase {
    private let policy = ReconnectPolicy.standard
    private var clock: FakeControlClock!
    private var sockets: FakeControlSockets!
    private var control: RexControl!
    private var retries: [Double] = []
    private var states: [RexControl.State] = []
    private var reconnects = 0
    private var triggers: [AttemptTrigger] = []

    override func setUp() async throws {
        clock = FakeControlClock()
        sockets = FakeControlSockets()
        control = RexControl(address: "https://desk.example.ts.net",
                             client: ClientInfo(name: "test", version: "0", label: "test"),
                             clock: clock, sockets: sockets.factory,
                             governor: ReconnectGovernor(policy: policy), random: { 0.5 })
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

    private func routeChanged() {
        control.pathChanged(satisfied: true, expensive: false, interfaceChanged: true)
    }

    // MARK: A request during an attempt

    func testNoRequestButARouteChangeTouchesAnAttemptUnderWay() async {
        let first = await beginConnect()
        for trigger in [AttemptTrigger.user, .foreground, .peer, .backoff] {
            for _ in 0..<5 { control.kick(trigger) }
            await pump()
        }
        control.wake()
        await pump()
        XCTAssertEqual(sockets.count, 1)
        XCTAssertFalse(sockets.last.cancelled)
        XCTAssertEqual(triggers, [.first])
        sockets.last.welcome()
        let ok = await first.value
        XCTAssertTrue(ok, "the attempt ends with its own welcome")
    }

    func testThePolicyMovesAnAttemptOnlyForANetworkChangeAndOnlyOnce() {
        func kick(_ t: AttemptTrigger, suspended: Bool = false, path: Bool = true, moved: Bool = false,
                  policy: ReconnectPolicy = .standard) -> ReconnectPolicy.Kick {
            policy.kick(t, connecting: true, dormant: false, stopped: false, held: false, selected: true,
                        suspended: suspended, pathSatisfied: path, attempts: 1, sinceLastAttempt: 3, moved: moved)
        }
        XCTAssertEqual(kick(.network), .move)
        XCTAssertEqual(kick(.network, moved: true), .ignore, "one new socket per attempt")
        XCTAssertEqual(kick(.network, suspended: true), .ignore, "nothing in the background")
        XCTAssertEqual(kick(.network, path: false), .ignore)
        for t in [AttemptTrigger.user, .foreground, .peer, .backoff, .first] { XCTAssertEqual(kick(t), .ignore) }
        var off = ReconnectPolicy.standard
        off.movesAttemptOnRouteChange = false
        XCTAssertEqual(kick(.network, policy: off), .ignore)
    }

    // MARK: A route change (the review's rule)

    func testARouteChangeMovesTheAttemptToANewSocketAndItsWelcomeEndsTheSameConnect() async {
        let first = await beginConnect()
        let old = sockets.last
        await clock.advance(by: 3)
        routeChanged()
        XCTAssertEqual(sockets.count, 2, "in the same turn: nothing can come between")
        XCTAssertTrue(old.cancelled)
        XCTAssertTrue(sockets.last.resumed && sockets.last.sentHello)
        XCTAssertEqual(triggers, [.first, .network])
        XCTAssertEqual(states, [.connecting, .connecting], "the log gets the new socket as its own line")
        // The old socket is gone for good.
        old.deliverLate(#"{"type":"welcome","client":{"id":"old","reconnect_token":"old"}}"#)
        old.callEverythingAgain()
        await pump()
        XCTAssertEqual(control.state, .connecting)
        XCTAssertEqual(retries, [], "a move is no failure: nothing is counted and no wait is set")

        sockets.last.welcome()
        let ok = await first.value
        await pump()
        XCTAssertTrue(ok, "what waited for the welcome went on waiting")
        XCTAssertEqual(control.state, .connected)
        XCTAssertEqual(control.clientID, "client:test")
        XCTAssertEqual(reconnects, 0)
        // The keepalive runs on the socket that connected.
        await clock.advance(by: policy.idlePing)
        XCTAssertEqual(sockets.last.pings, 1)
        XCTAssertEqual(old.pings, 0)
    }

    func testAnAttemptMovesOnceHoweverOftenTheRouteChanges() async {
        await beginConnect()
        for _ in 0..<20 {
            routeChanged()
            await clock.advance(by: 0.2)
        }
        XCTAssertEqual(sockets.count, 2)
        XCTAssertFalse(sockets.last.cancelled, "the second socket is left to end")
        XCTAssertEqual(control.state, .connecting)
    }

    func testAMovedAttemptHasItsOwnDeadlineAndFailsOnce() async {
        let first = await beginConnect()
        await clock.advance(by: 6)
        routeChanged()
        await clock.advance(by: 5)
        XCTAssertEqual(control.state, .connecting, "the first socket's deadline, at 10 s, is not this one's")
        await clock.advance(by: 4.9)
        XCTAssertEqual(control.state, .connecting)
        await clock.advance(by: 0.2)
        XCTAssertEqual(retries, [policy.delay(step: 2)], "its own, 10 s after the move: one failure, and the wait before the second attempt, for a move is not another attempt")
        let ok = await first.value
        XCTAssertFalse(ok)
    }

    func testARetryIsMovedAsTheFirstConnectIs() async {
        await beginConnect()
        sockets.last.failReceive()
        await pump()
        await clock.advance(by: policy.delay(step: 2))
        XCTAssertEqual(sockets.count, 2)
        routeChanged()
        XCTAssertEqual(sockets.count, 3)
        XCTAssertTrue(sockets.all[1].cancelled)
        sockets.last.welcome()
        await pump()
        XCTAssertEqual(control.state, .connected)
        XCTAssertEqual(reconnects, 1, "the retry that was moved reports the reconnect, once")
    }

    func testNothingMovesForAReportThatChangesNoRouteOrWhileThereIsNoPath() async {
        await beginConnect()
        control.pathChanged(satisfied: true, expensive: true, interfaceChanged: false)
        XCTAssertEqual(sockets.count, 1, "the same route")
        control.pathChanged(satisfied: false, expensive: false, interfaceChanged: true)
        XCTAssertEqual(sockets.count, 1, "no path: nothing to move to")
        XCTAssertFalse(sockets.last.cancelled)
        control.pathChanged(satisfied: true, expensive: false, interfaceChanged: false)
        XCTAssertEqual(sockets.count, 1, "a path again is a change of route only when `RouteWatch` says so")
        routeChanged()
        XCTAssertEqual(sockets.count, 2)
    }

    func testNothingMovesInTheBackground() async {
        await beginConnect()
        control.enteredBackground()
        routeChanged()
        await pump()
        XCTAssertEqual(sockets.count, 1, "the attempt is given up there, and nothing takes its place")
    }

    /// A host that never answers, with the route changing every second for an hour. Attempts stay
    /// at least two minutes apart from the third on, a move included in the count, and no
    /// attempt has more than two sockets.
    func testARouteThatNeverStopsChangingAddsAtMostOneSocketPerAttempt() async {
        clock.yields = 30
        var began: [Double] = []
        control.onAttempt = { [unowned self] in
            triggers.append($0)
            began.append(clock.now.timeIntervalSinceReferenceDate)
        }
        await beginConnect()
        for _ in 0..<3600 {
            routeChanged()
            await clock.advance(by: 1)
        }
        // A move is a `.network` attempt within a deadline of the attempt before it.
        var moves = 0, own = 0, lastOwn = -Double.infinity
        for (at, trigger) in zip(began, triggers) {
            if trigger == .network, at - lastOwn < policy.connectDeadline { moves += 1 } else { own += 1; lastOwn = at }
        }
        XCTAssertEqual(own + moves, sockets.count)
        XCTAssertLessThanOrEqual(moves, own)
        XCTAssertLessThanOrEqual(own, 2 + 3600 / Int(policy.floor))
        XCTAssertTrue(sockets.all.dropLast().allSatisfy(\.cancelled), "never two sockets at once")
    }

    // MARK: The state check where the socket is opened

    func testAnAttemptThatBeginsAfterTheWelcomeKeepsTheSocket() async {
        let first = await beginConnect()
        sockets.last.welcome()
        _ = await first.value
        // A request that was let through before the welcome, and runs after it.
        await control.attempt(.user)
        await control.attempt(.foreground)
        await pump()
        XCTAssertEqual(sockets.count, 1)
        XCTAssertFalse(sockets.last.cancelled)
        XCTAssertEqual(control.state, .connected)
        XCTAssertEqual(reconnects, 0)
        XCTAssertEqual(triggers, [.first])
    }

    func testAnAttemptThatBeginsWhileAnotherIsUnderWayOpensNothing() async {
        let first = await beginConnect()
        await control.attempt(.user)
        XCTAssertEqual(sockets.count, 1)
        XCTAssertFalse(sockets.last.cancelled)
        sockets.last.welcome()
        let ok = await first.value
        XCTAssertTrue(ok)
    }

    func testATapAndThenAStopOpensNothing() async {
        await beginConnect()
        sockets.last.failReceive()
        await pump()
        control.kick()
        control.disconnect()
        await pump()
        XCTAssertEqual(sockets.count, 1, "the tap's attempt found the connection stopped")
        XCTAssertEqual(control.state, .idle)
    }

    // MARK: The launch

    /// What the app does as it launches: the server is started, and the app coming to the front
    /// asks again, before the first attempt began and while it is under way.
    func testALaunchOpensOneSocket() async {
        control.pathChanged(satisfied: true, expensive: false, interfaceChanged: false)
        let control = control!
        let first = Task { @MainActor in
            do { try await control.connect(); return true } catch { return false }
        }
        control.kick(.foreground)
        control.wake()
        await pump()
        XCTAssertEqual(sockets.count, 1)
        control.kick(.foreground)
        control.wake()
        await pump()
        XCTAssertEqual(sockets.count, 1)
        XCTAssertFalse(sockets.last.cancelled)
        sockets.last.welcome()
        let ok = await first.value
        XCTAssertTrue(ok)
        control.kick(.foreground)
        await pump()
        XCTAssertEqual(sockets.count, 1)
        XCTAssertEqual(triggers, [.first])
    }
}
