import XCTest
@testable import RexKit

/// Several hosts on one `ReconnectGovernor`, with a clock and sockets the test moves by hand: the
/// budget they share and the tunnel breaker. The count of sockets opened is what is checked.
@MainActor
final class ReconnectGovernorTests: XCTestCase {
    private let policy = ReconnectPolicy.standard
    private var clock: FakeControlClock!
    private var governor: ReconnectGovernor!
    private var hosts: [Host] = []

    @MainActor
    final class Host {
        let control: RexControl
        let sockets = FakeControlSockets()
        var triggers: [AttemptTrigger] = []
        /// When each attempt began, in seconds on the test's clock.
        var began: [Double] = []

        init(_ n: Int, clock: FakeControlClock, governor: ReconnectGovernor) {
            control = RexControl(address: "https://host\(n).example.ts.net",
                                 client: ClientInfo(name: "test", version: "0", label: "test"),
                                 clock: clock, sockets: sockets.factory, governor: governor, random: { 0.5 })
            control.onAttempt = { [unowned self] in
                triggers.append($0)
                began.append(clock.now.timeIntervalSinceReferenceDate)
            }
        }

        var isConnecting: Bool { control.state == .connecting }
    }

    override func setUp() async throws {
        clock = FakeControlClock()
        clock.yields = 40
        governor = ReconnectGovernor(policy: policy)
        hosts = []
    }

    override func tearDown() async throws {
        for h in hosts { h.control.disconnect() }
        await pump()
        hosts = []
    }

    private func makeHosts(_ n: Int) {
        hosts = (0..<n).map { Host($0, clock: clock, governor: governor) }
    }

    /// Every host connected, one second apart, so host 0 was good longest ago.
    private func connectAll() async {
        for h in hosts {
            let c = h.control
            Task { @MainActor in try? await c.connect() }
            await pump()
            h.sockets.last.welcome()
            await pump()
            XCTAssertEqual(c.state, .connected)
            await clock.advance(by: 1)
        }
    }

    private var total: Int { hosts.reduce(0) { $0 + $1.sockets.count } }
    private let refused = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost,
                                  userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNREFUSED))])

    /// Moves the time on a second at a time; an attempt that is under way fails as `fail` says.
    private func run(seconds: Int, fail: (Host) -> (any Error)?) async {
        for _ in 0..<seconds {
            for h in hosts where h.isConnecting && h.sockets.last.isWaitingToReceive {
                if let error = fail(h) { h.sockets.last.failReceive(error) }
            }
            // A connection that is up answers its pings.
            for h in hosts where h.control.state == .connected { h.sockets.last.answerPing() }
            await pump(40)
            // Past each host's first attempt, never more than two under way.
            XCTAssertLessThanOrEqual(hosts.filter { $0.isConnecting && $0.began.count > 1 }.count, policy.maxInFlight)
            await clock.advance(by: 1)
        }
    }

    // MARK: The budget (spec test 4)

    /// Five hosts that are down, each refusing at once so the breaker stays out of it: after
    /// each one's first attempt, they get two attempts per 100 s between them.
    func testFiveHostsThatAreDownShareTwoAttemptsPerHundredSeconds() async {
        makeHosts(5)
        for h in hosts {
            let c = h.control
            Task { @MainActor in try? await c.connect() }
        }
        await pump()
        XCTAssertEqual(total, 5, "each host's first attempt")
        await run(seconds: 3600) { _ in self.refused }
        let later = hosts.flatMap { $0.began.dropFirst() }.sorted()
        XCTAssertGreaterThan(later.count, 20)
        for (i, t) in later.enumerated() {
            let inWindow = later[i...].prefix { $0 - t < 100 }.count
            XCTAssertLessThanOrEqual(inWindow, 2, "at \(t) s")
        }
        XCTAssertLessThanOrEqual(total, 5 + 2 * 36 + 2)
        XCTAssertFalse(governor.breakerOpen, "a refusal is an answer: the tunnel works")
    }

    /// Five computers that are off, with the app open and untouched for an hour.
    func testFiveDeadHostsGetFewAttemptsInAnHour() async {
        makeHosts(5)
        for h in hosts {
            let c = h.control
            Task { @MainActor in try? await c.connect() }
        }
        await pump()
        await run(seconds: 3600) { _ in nil }
        // Each attempt runs into its 10 s deadline; never more than two a 100 s after the first.
        XCTAssertLessThanOrEqual(total, 5 + 2 * 36)
        let later = hosts.flatMap { $0.began.dropFirst() }.sorted()
        for (i, t) in later.enumerated() {
            XCTAssertLessThanOrEqual(later[i...].prefix { $0 - t < 100 }.count, 2)
        }
        XCTAssertTrue(governor.breakerOpen)
    }

    // MARK: The breaker (spec test 5)

    func testWhenTheTunnelDiesOneHostIsTriedAtATime() async {
        makeHosts(4)
        await connectAll()
        governor.select(hosts[1].control)
        var opened: [Bool] = []
        governor.onBreaker = { opened.append($0) }
        let before = hosts.map { $0.sockets.count }
        let t0 = clock.now.timeIntervalSinceReferenceDate

        // Every connection is lost in the same moment, with no answer.
        for h in hosts { h.sockets.last.failReceive() }
        await pump()
        XCTAssertTrue(governor.breakerOpen)
        XCTAssertEqual(opened, [true])
        XCTAssertEqual(hosts.filter { !$0.control.isHeld }.count, 1, "one host is tried, the others are held")

        // Ten minutes with no answer from anyone: one host under way at a time, each in turn.
        for _ in 0..<600 {
            XCTAssertLessThanOrEqual(hosts.filter(\.isConnecting).count, 1, "one test host at a time")
            XCTAssertEqual(hosts.filter { !$0.control.isHeld }.count, 1)
            await clock.advance(by: 1)
        }
        let during = zip(hosts, before).map { $0.sockets.count - $1 }
        XCTAssertLessThanOrEqual(during.reduce(0, +), 4 + 2 * 6, "each host's first attempt, then two per 100 s")
        XCTAssertTrue(during.allSatisfy { $0 >= 1 }, "every host had a turn: \(during)")
        XCTAssertTrue(governor.breakerOpen)
        for h in hosts { assertFloor(h, from: t0) }
    }

    /// The welcome of the host that is tried closes the breaker, and the others start half a
    /// second apart: the selected one first, then the one that was good last.
    func testAWelcomeBringsTheOthersBackHalfASecondApartInOrder() async {
        makeHosts(4)
        await connectAll()
        governor.select(hosts[1].control)
        var opened: [Bool] = []
        governor.onBreaker = { opened.append($0) }
        for h in hosts { h.sockets.last.failReceive() }
        await pump()
        XCTAssertTrue(governor.breakerOpen)
        var test = hosts.first { $0.isConnecting }
        var waited = 0
        while test == nil, waited < 20 {
            await clock.advance(by: 0.1)
            waited += 1
            test = hosts.first { $0.isConnecting }
        }
        let answered = try! XCTUnwrap(test)
        let others = hosts.filter { $0 !== answered }
        let counts = others.map { $0.sockets.count }
        answered.sockets.last.welcome()
        await pump()
        XCTAssertFalse(governor.breakerOpen)
        XCTAssertEqual(opened, [true, false])
        XCTAssertEqual(zip(others, counts).map { $0.sockets.count - $1 }, [0, 0, 0], "not all at once")
        let t0 = clock.now.timeIntervalSinceReferenceDate
        await clock.advance(by: 2)
        XCTAssertEqual(zip(others, counts).map { $0.sockets.count - $1 }, [1, 1, 1], "each one once")
        let order = others.sorted { ($0.began.last ?? 0) < ($1.began.last ?? 0) }
        XCTAssertEqual(order.map { ($0.began.last ?? 0) - t0 }, [0.5, 1.0, 1.5])
        XCTAssertTrue(others.allSatisfy { $0.triggers.last == .peer })
        let expected = others.sorted { a, b in
            if (a === hosts[1]) != (b === hosts[1]) { return a === hosts[1] }
            return (a.control.lastGood ?? .distantPast) > (b.control.lastGood ?? .distantPast)
        }
        XCTAssertTrue(zip(order, expected).allSatisfy { $0 === $1 })
        for h in others { h.sockets.last.welcome() }
        await pump()
        XCTAssertTrue(hosts.allSatisfy { $0.control.state == .connected })
    }

    func testOneHostThatIsOffDoesNotOpenTheBreakerOrHoldTheOthers() async {
        makeHosts(3)
        await connectAll()
        hosts[0].sockets.last.failReceive()
        await pump()
        await run(seconds: 1800) { h in h === self.hosts[0] ? nil : self.refused }
        XCTAssertFalse(governor.breakerOpen)
        XCTAssertTrue(hosts[0].control.dormant)
        XCTAssertEqual(hosts[1].control.state, .connected)
        XCTAssertEqual(hosts[2].control.state, .connected)
    }

    // MARK: A dead host never holds healthy ones (the turn-taking)

    /// When each attempt of `h` began since `from`, and that from the third on each began 120 s
    /// or more after the one before began.
    @discardableResult
    private func assertFloor(_ h: Host, from: Double, file: StaticString = #filePath, line: UInt = #line) -> [Double] {
        let began = h.began.filter { $0 >= from }
        let gaps = zip(began, began.dropFirst()).map { $1 - $0 }
        for (i, gap) in gaps.enumerated() where i >= 1 {
            XCTAssertGreaterThanOrEqual(gap, 120 - 0.001, "attempt \(i + 2) began \(gap) s after the one before", file: file, line: line)
        }
        return began
    }

    /// The owner's case. One computer is off and selected; two are healthy. The phone comes
    /// back on a tunnel that is slow to wake: every host's first attempt runs into its deadline,
    /// so the breaker opens, and the host that is off is the first one it tries (it was the last
    /// one good: the worst order). The healthy hosts are back without a tap, about 44 s after
    /// the return on Wi-Fi: 2.5 s for the pings, then four attempts of 10 s in turn (the off
    /// host, each healthy host's first, the off host again), then a healthy host's second
    /// attempt answers and the other follows half a second later. The host that is off gets no
    /// attempt inside its floor in all of that.
    func testAnOffSelectedHostDoesNotStrandHealthyOnesOnASlowReturn() async {
        makeHosts(3)
        await connectAll()
        let off = hosts[2], healthy = [hosts[0], hosts[1]]
        governor.select(off.control)
        for h in hosts { h.control.enteredBackground() }
        await clock.advance(by: 900)
        for h in hosts { h.control.wake() }
        let t0 = clock.now.timeIntervalSinceReferenceDate
        var back: Double?
        var taps = 0
        for h in hosts { h.control.onAttempt = { [unowned h, clock] in
            if $0 == .user { taps += 1 }
            h.triggers.append($0)
            h.began.append(clock!.now.timeIntervalSinceReferenceDate)
        } }
        for _ in 0..<900 {
            for h in healthy {
                let tries = h.began.filter { $0 >= t0 }.count
                // The tunnel is up by a healthy host's second attempt; its first gets no answer.
                if h.isConnecting, h.sockets.last.isWaitingToReceive, tries >= 2 { h.sockets.last.welcome() }
                if h.control.state == .connected, tries >= 1 { h.sockets.last.answerPing() }
            }
            await pump(40)
            if back == nil, healthy.allSatisfy({ $0.control.state == .connected && $0.began.contains { $0 >= t0 } }) {
                back = clock.now.timeIntervalSinceReferenceDate - t0
            }
            await clock.advance(by: 1)
        }
        let took = try! XCTUnwrap(back, "the healthy hosts never came back")
        XCTAssertLessThanOrEqual(took, 50, "the healthy hosts were back \(took) s after the return")
        XCTAssertEqual(taps, 0, "without a tap")
        XCTAssertFalse(governor.breakerOpen)
        // The host that is off: no attempt inside its floor, and few in the 15 minutes.
        let began = assertFloor(off, from: t0)
        XCTAssertLessThanOrEqual(began.count, 6, "\(began.map { $0 - t0 })")
        XCTAssertTrue(off.control.dormant)
    }

    /// A long-dead host timing out again is no news about the tunnel. With a second host that
    /// drops and returns every 20 s for an hour, the breaker never opens, and the dead host
    /// keeps its ten minutes.
    func testADormantHostTimingOutAloneNeverOpensTheBreaker() async {
        makeHosts(2)
        await connectAll()
        let dead = hosts[0], flapping = hosts[1]
        var opened = 0
        governor.onBreaker = { if $0 { opened += 1 } }
        dead.sockets.last.failReceive()
        await pump()
        await run(seconds: 900) { _ in nil }
        XCTAssertTrue(dead.control.dormant)
        let t0 = clock.now.timeIntervalSinceReferenceDate
        var drops = 0
        for step in 0..<1800 {
            if flapping.isConnecting, flapping.sockets.last.isWaitingToReceive { flapping.sockets.last.welcome() }
            if flapping.control.state == .connected {
                if step % 10 == 0 { flapping.sockets.last.failReceive(); drops += 1 } else { flapping.sockets.last.answerPing() }
            }
            await pump(40)
            await clock.advance(by: 2)
        }
        XCTAssertGreaterThan(drops, 150)
        XCTAssertEqual(opened, 0, "one fresh failure and one old one are not two")
        let began = dead.began.filter { $0 >= t0 }
        XCTAssertLessThanOrEqual(began.count, 6)
        for gap in zip(began, began.dropFirst()).map({ $1 - $0 }) { XCTAssertGreaterThanOrEqual(gap, 600) }
    }

    /// The breaker's release keeps the floor and the budget. A host that is off and backing
    /// off, and two healthy hosts that drop together and return every 15 s: the breaker opens
    /// and closes each time, and each close lets the off host go, but it gets no attempt inside
    /// its floor however often that happens.
    func testAHostTheBreakerLetsGoGetsNoAttemptInsideItsFloor() async {
        makeHosts(3)
        await connectAll()
        let dead = hosts[0], flapping = [hosts[1], hosts[2]]
        var opened = 0
        governor.onBreaker = { if $0 { opened += 1 } }
        let t0 = clock.now.timeIntervalSinceReferenceDate
        dead.sockets.last.failReceive()
        await pump()
        for second in 0..<1800 {
            for h in flapping {
                if h.isConnecting, h.sockets.last.isWaitingToReceive { h.sockets.last.welcome() }
                if h.control.state == .connected {
                    if second % 15 == 14 { h.sockets.last.failReceive() } else { h.sockets.last.answerPing() }
                }
            }
            await pump(40)
            await clock.advance(by: 1)
        }
        XCTAssertGreaterThan(opened, 60, "the breaker opened and closed again and again")
        let began = assertFloor(dead, from: t0)
        XCTAssertGreaterThanOrEqual(began.count, 3, "it is still tried")
        XCTAssertLessThanOrEqual(began.count, 2 + 1800 / 120)
        XCTAssertTrue(dead.triggers.contains(.peer), "a close did let it go")
    }

    /// The tunnel really down for an hour, with three hosts that were connected: one attempt
    /// under way at a time, each host in turn on its own schedule and within the budget.
    func testWithTheTunnelDownForAnHourThreeHostsGetFewAttemptsBetweenThem() async {
        makeHosts(3)
        await connectAll()
        let t0 = clock.now.timeIntervalSinceReferenceDate
        let before = total
        for h in hosts { h.sockets.last.failReceive() }
        await pump()
        XCTAssertTrue(governor.breakerOpen)
        for _ in 0..<3600 {
            XCTAssertLessThanOrEqual(hosts.filter(\.isConnecting).count, 1)
            await clock.advance(by: 1)
        }
        XCTAssertTrue(governor.breakerOpen)
        XCTAssertEqual(total - before, Self.tunnelDownHourTotal, "\(hosts.map { $0.began.filter { $0 >= t0 }.map { Int($0 - t0) } })")
        for h in hosts { assertFloor(h, from: t0) }
        let all = hosts.flatMap { $0.began.filter { $0 >= t0 } }.sorted()
        for (i, t) in all.enumerated() where i >= 3 {
            XCTAssertLessThanOrEqual(all[i...].prefix { $0 - t < 100 }.count, 2, "past the first attempts, two per 100 s")
        }
    }

    /// Attempts across three hosts in an hour of no tunnel (see the test above).
    static let tunnelDownHourTotal = 16

    /// `connect()` asks the governor like every other attempt: while the breaker is open, a
    /// host that is new opens nothing, and goes with the others when a host answers.
    func testConnectWaitsForItsTurnWhileTheBreakerIsOpen() async {
        makeHosts(3)
        let a = hosts[0], b = hosts[1], new = hosts[2]
        for h in [a, b] {
            let c = h.control
            Task { @MainActor in try? await c.connect() }
            await pump()
            h.sockets.last.welcome()
            await pump()
        }
        for h in [a, b] { h.sockets.last.failReceive() }
        await pump()
        XCTAssertTrue(governor.breakerOpen)
        let c = new.control
        let first = Task { @MainActor in
            do { try await c.connect(); return true } catch { return false }
        }
        let connected = await first.value
        XCTAssertFalse(connected)
        XCTAssertEqual(new.sockets.count, 0, "no socket while the tunnel looks down")
        XCTAssertTrue(new.control.isHeld)
        await clock.advance(by: 0.5)
        let test = try! XCTUnwrap([a, b].first { $0.isConnecting })
        test.sockets.last.welcome()
        await clock.advance(by: 2)
        XCTAssertEqual(new.sockets.count, 1, "the welcome let it go")
    }

    func testATapGoesThroughAnOpenBreakerAndItsWelcomeClosesIt() async {
        makeHosts(3)
        await connectAll()
        governor.select(hosts[0].control)
        for h in hosts { h.sockets.last.failReceive() }
        await pump()
        let held = try! XCTUnwrap(hosts.first { $0.control.isHeld })
        let before = held.sockets.count
        held.control.kick()
        await pump()
        XCTAssertEqual(held.sockets.count, before + 1, "the user asked")
        held.sockets.last.welcome()
        await pump()
        XCTAssertFalse(governor.breakerOpen, "a welcome from any host: the tunnel works")
    }

    // MARK: The breaker's other transitions (the table in `ReconnectGovernor`)

    /// `n` hosts that were connected, all lost in the same moment with no answer: the breaker
    /// is open.
    private func openBreaker(_ n: Int) async {
        makeHosts(n)
        await connectAll()
        for h in hosts { h.sockets.last.failReceive() }
        await pump()
        XCTAssertTrue(governor.breakerOpen)
    }

    /// The one host the open breaker tries.
    private var testHost: Host? {
        let free = hosts.filter { $0.control.wantsAttempts && !$0.control.isHeld }
        return free.count == 1 ? free[0] : nil
    }

    /// Moves the time on until `h` has an attempt under way; false after `limit` seconds.
    private func untilConnecting(_ h: Host, limit: Double = 30) async -> Bool {
        var waited = 0.0
        while !(h.isConnecting && h.sockets.last.isWaitingToReceive), waited < limit {
            await clock.advance(by: 0.1)
            waited += 0.1
        }
        return h.isConnecting
    }

    /// closed -> closed: hosts fail while another host is connected. That one shows the tunnel
    /// works, so the breaker stays closed, and when it drops later it is tried at once, not held.
    func testTheBreakerNeverOpensWhileAHostIsConnected() async {
        makeHosts(3)
        await connectAll()
        var opened = 0
        governor.onBreaker = { if $0 { opened += 1 } }
        hosts[0].sockets.last.failReceive()
        hosts[1].sockets.last.failReceive()
        await pump()
        XCTAssertFalse(governor.breakerOpen, "host 2 is connected")
        await run(seconds: 300) { _ in nil }
        XCTAssertFalse(governor.breakerOpen)
        XCTAssertEqual(hosts[2].control.state, .connected)
        // The healthy host drops: nothing holds it, and it is back within a second.
        let n = hosts[2].sockets.count
        hosts[2].sockets.last.failReceive()
        await pump()
        XCTAssertFalse(hosts[2].control.isHeld)
        await clock.advance(by: 1)
        XCTAssertEqual(hosts[2].sockets.count, n + 1, "tried within a second of its drop")
        hosts[2].sockets.last.welcome()
        await pump()
        XCTAssertEqual(hosts[2].control.state, .connected)
        XCTAssertEqual(opened, 0)
    }

    /// The two that failed are remembered: when the host that was connected drops with no
    /// answer inside the 30 s too, no host is connected any more and the breaker opens.
    func testTheBreakerOpensWhenTheLastConnectedHostDropsToo() async {
        makeHosts(3)
        await connectAll()
        hosts[0].sockets.last.failReceive()
        hosts[1].sockets.last.failReceive()
        await pump()
        XCTAssertFalse(governor.breakerOpen)
        await clock.advance(by: 0.2)
        hosts[2].sockets.last.failReceive()
        await pump()
        XCTAssertTrue(governor.breakerOpen)
        XCTAssertNotNil(testHost)
    }

    /// open -> open: the test host is removed. The next host has the turn and is tried; the
    /// held hosts are not left waiting for a host that is gone.
    func testWhenTheTestHostIsRemovedTheNextHostHasTheTurn() async {
        await openBreaker(3)
        let first = try! XCTUnwrap(testHost)
        first.control.disconnect()
        await pump()
        XCTAssertTrue(governor.breakerOpen)
        let next = try! XCTUnwrap(testHost)
        XCTAssertFalse(next === first)
        let tried = await untilConnecting(next)
        XCTAssertTrue(tried, "the new test host is tried")
        next.sockets.last.welcome()
        await clock.advance(by: 2)
        XCTAssertFalse(governor.breakerOpen)
        XCTAssertTrue(hosts.filter { $0 !== first }.allSatisfy { $0.sockets.count >= 2 }, "and the last one followed")
    }

    /// open -> closed when the last host that could be tried is removed.
    func testRemovingEveryHostThatIsDownClosesTheBreaker() async {
        await openBreaker(2)
        for h in hosts { h.control.disconnect() }
        await pump()
        XCTAssertFalse(governor.breakerOpen)
    }

    /// open -> open: a held host is removed. The test host keeps the turn.
    func testRemovingAHeldHostChangesNothing() async {
        await openBreaker(3)
        let test = try! XCTUnwrap(testHost)
        let held = try! XCTUnwrap(hosts.first { $0.control.isHeld })
        held.control.disconnect()
        await pump()
        XCTAssertTrue(governor.breakerOpen)
        XCTAssertTrue(testHost === test)
    }

    /// open -> closed: the test host's side answers with a refusal. An answer of any kind
    /// proves the tunnel works, so the held hosts go on.
    func testARefusedTestHostClosesTheBreaker() async {
        await openBreaker(3)
        let test = try! XCTUnwrap(testHost)
        let others = hosts.filter { $0 !== test }
        let counts = others.map { $0.sockets.count }
        let tried = await untilConnecting(test)
        XCTAssertTrue(tried)
        test.sockets.last.failReceive(refused)
        await pump()
        XCTAssertFalse(governor.breakerOpen, "a refusal is an answer")
        await clock.advance(by: 2)
        XCTAssertEqual(zip(others, counts).map { $0.sockets.count - $1 }, [1, 1], "the held hosts were let go")
        XCTAssertFalse(test.control.retryStopped, "and the refused one keeps its schedule")
    }

    /// open -> closed: the test host answers 401. Its own retries stop, and the others go on.
    func testATestHostThatTurnsTheClientAwayClosesTheBreaker() async {
        await openBreaker(3)
        let test = try! XCTUnwrap(testHost)
        let others = hosts.filter { $0 !== test }
        let counts = others.map { $0.sockets.count }
        let tried = await untilConnecting(test)
        XCTAssertTrue(tried)
        test.sockets.last.response = HTTPURLResponse(url: URL(string: "https://host.example.ts.net")!, statusCode: 401,
                                                     httpVersion: nil, headerFields: nil)
        test.sockets.last.failReceive(URLError(.badServerResponse))
        await pump()
        XCTAssertTrue(test.control.retryStopped)
        XCTAssertFalse(governor.breakerOpen, "a 401 is an answer")
        await clock.advance(by: 2)
        XCTAssertEqual(zip(others, counts).map { $0.sockets.count - $1 }, [1, 1])
    }

    /// open -> closed: the test host fails TLS. Bytes came back from it, so that is an answer
    /// for the breaker, while the host itself is tried again on its schedule.
    func testATLSFailureOfTheTestHostClosesTheBreaker() async {
        await openBreaker(3)
        let test = try! XCTUnwrap(testHost)
        let tried = await untilConnecting(test)
        XCTAssertTrue(tried)
        test.sockets.last.failReceive(URLError(.secureConnectionFailed))
        await pump()
        XCTAssertFalse(governor.breakerOpen, "a TLS failure is an answer")
        XCTAssertFalse(test.control.retryStopped, "and it is tried again")
    }

    /// A TLS failure never opens the breaker either: it is no silence.
    func testTLSFailuresDoNotOpenTheBreaker() async {
        makeHosts(2)
        for h in hosts {
            let c = h.control
            Task { @MainActor in try? await c.connect() }
            await pump()
            h.sockets.last.failReceive(URLError(.secureConnectionFailed))
            await pump()
        }
        XCTAssertFalse(governor.breakerOpen)
    }

    /// A host that waits only for room among the attempts under way keeps no timer and writes
    /// nothing to the log meanwhile: it is told when an attempt ends, and goes then.
    func testAHostThatWaitsForRoomIsWokenAndLogsNothingMeanwhile() async {
        makeHosts(3)
        for h in hosts {
            let c = h.control
            Task { @MainActor in try? await c.connect() }
            await pump()
            h.sockets.last.failReceive(refused)
            await pump()
        }
        // Two taps are under way (until 15 s); the third host's own wait ends at 10 s.
        await clock.advance(by: 5)
        hosts[0].control.kick()
        hosts[1].control.kick()
        await pump()
        var logged = 0
        hosts[2].control.onRetryScheduled = { _ in logged += 1 }
        let n = hosts[2].sockets.count
        let waits = clock.waiting
        await clock.advance(by: 8)
        XCTAssertEqual(hosts[2].sockets.count, n, "two under way: it waits")
        XCTAssertEqual(logged, 0, "and no line is written for the wait")
        XCTAssertLessThan(clock.waiting, waits, "nor is a timer kept to ask again")
        hosts[0].sockets.last.failReceive(refused)
        await pump()
        XCTAssertEqual(hosts[2].sockets.count, n + 1, "room: it goes at once")
    }

    /// open -> open: the test host's retries stop with no answer to show for it (here the host
    /// is stopped by hand). The next has the turn.
    func testWhenTheTestHostStopsTheNextHostHasTheTurn() async {
        await openBreaker(3)
        let test = try! XCTUnwrap(testHost)
        governor.stopped(test.control.governorID)
        await pump()
        XCTAssertTrue(governor.breakerOpen)
        XCTAssertNotNil(hosts.first { $0 !== test && !$0.control.isHeld }, "another host has the turn")
    }

    /// open -> open: a tap on a held host. It is tried once, through the breaker, and held
    /// again when it fails; the test host keeps the turn.
    func testATapOnAHeldHostThatFailsLeavesItHeld() async {
        await openBreaker(3)
        let test = try! XCTUnwrap(testHost)
        let held = try! XCTUnwrap(hosts.first { $0.control.isHeld })
        let n = held.sockets.count
        held.control.kick()
        await pump()
        XCTAssertEqual(held.sockets.count, n + 1)
        held.sockets.last.failReceive()
        await pump()
        XCTAssertTrue(governor.breakerOpen)
        XCTAssertTrue(held.control.isHeld, "held again")
        XCTAssertFalse(test.control.isHeld)
        await clock.advance(by: 5)
        XCTAssertEqual(held.sockets.count, n + 1, "and not tried on its own")
    }

    /// open -> open: the app returns and the selected host is held. It takes the turn, so the
    /// host the user came back to is the one that is tried.
    func testAtTheReturnTheSelectedHostTakesTheTurn() async {
        await openBreaker(3)
        let test = try! XCTUnwrap(testHost)
        let chosen = try! XCTUnwrap(hosts.first { $0.control.isHeld })
        governor.select(chosen.control)
        for h in hosts { h.control.enteredBackground() }
        await clock.advance(by: 600)
        for h in hosts { h.control.wake() }
        await pump()
        XCTAssertTrue(governor.breakerOpen)
        XCTAssertFalse(chosen.control.isHeld)
        XCTAssertTrue(test.control.isHeld)
        let tried = await untilConnecting(chosen, limit: 2)
        XCTAssertTrue(tried, "and it is tried at the return")
        XCTAssertEqual(hosts.filter(\.isConnecting).count, 1)
    }

    /// open -> open: the route changes. The held hosts stay held and are not tried; the test
    /// host is asked no sooner than its floor allows.
    func testARouteChangeLeavesTheBreakerOpenAndTheHeldHostsHeld() async {
        await openBreaker(3)
        let t0 = clock.now.timeIntervalSinceReferenceDate
        let held = hosts.filter { $0.control.isHeld }
        let counts = held.map { $0.sockets.count }
        for _ in 0..<20 {
            for h in hosts { h.control.pathChanged(satisfied: true, expensive: false, interfaceChanged: true) }
            await clock.advance(by: 0.4)
        }
        XCTAssertTrue(governor.breakerOpen)
        XCTAssertEqual(hosts.filter(\.isConnecting).count, 1, "one host under way: the test host")
        XCTAssertEqual(zip(held, counts).map { $0.sockets.count - $1 }, [0, 0], "eight seconds of route changes: the held are not tried")
        for h in hosts { assertFloor(h, from: t0) }
    }

    /// Taps never put more than two attempts under way: a third host's tap waits for room, and
    /// its attempt comes when one of the two ends.
    func testTapsKeepTheInFlightCap() async {
        makeHosts(3)
        for h in hosts {
            let c = h.control
            Task { @MainActor in try? await c.connect() }
            await pump()
            h.sockets.last.failReceive(refused)
            await pump()
        }
        for h in hosts { h.control.kick() }
        await pump()
        XCTAssertEqual(hosts.filter(\.isConnecting).count, 2, "two under way; the third waits")
        await clock.advance(by: 3)
        XCTAssertEqual(hosts.filter(\.isConnecting).count, 2)
        let waiting = try! XCTUnwrap(hosts.first { !$0.isConnecting })
        let n = waiting.sockets.count
        hosts.first { $0.isConnecting }!.sockets.last.failReceive(refused)
        await clock.advance(by: 1)
        XCTAssertEqual(waiting.sockets.count, n + 1, "room: the tap's attempt goes")
        XCTAssertEqual(waiting.triggers.last, .user)
    }

    /// A pull to refresh tries one host that is down, not all of them: the selected one, else
    /// the one the breaker tries, else the likeliest to answer.
    func testAPullToRefreshNamesOneHost() async {
        makeHosts(3)
        await connectAll()
        XCTAssertNil(governor.refreshTarget(), "nothing is down")
        hosts[0].sockets.last.failReceive(refused)
        hosts[1].sockets.last.failReceive(refused)
        await pump()
        XCTAssertTrue(governor.refreshTarget() === hosts[1].control, "the one that was good last")
        governor.select(hosts[0].control)
        XCTAssertTrue(governor.refreshTarget() === hosts[0].control, "the selected one, if it is down")
        governor.select(hosts[2].control)
        XCTAssertTrue(governor.refreshTarget() === hosts[1].control, "the selected one is up")
    }

    func testAHostWithItsOwnGovernorIsAloneInIt() async {
        let a = RexControl(address: "https://a.example.ts.net", client: ClientInfo(name: "t", version: "0", label: "t"))
        let b = RexControl(address: "https://b.example.ts.net", client: ClientInfo(name: "t", version: "0", label: "t"))
        XCTAssertFalse(a.governor === b.governor)
        XCTAssertEqual(a.policy, .standard)
        a.invalidate()
        b.invalidate()
    }
}
