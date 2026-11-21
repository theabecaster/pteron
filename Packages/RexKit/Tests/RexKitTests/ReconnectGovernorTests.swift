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

    func testWhenTheTunnelDiesOneHostIsTriedAtATimeAndAWelcomeBringsTheOthersBackInOrder() async {
        makeHosts(4)
        await connectAll()
        governor.select(hosts[1].control)
        var opened: [Bool] = []
        governor.onBreaker = { opened.append($0) }
        let before = hosts.map { $0.sockets.count }

        // Every connection is lost in the same moment, with no answer.
        for h in hosts { h.sockets.last.failReceive() }
        await pump()
        XCTAssertTrue(governor.breakerOpen)
        XCTAssertEqual(opened, [true])
        XCTAssertEqual(hosts.map { $0.control.isHeld }, [true, false, true, true], "the selected host is the one tried")

        // Ten minutes with no answer from anyone: one host under way at a time.
        for _ in 0..<600 {
            XCTAssertLessThanOrEqual(hosts.filter(\.isConnecting).count, 1, "one test host at a time")
            XCTAssertEqual(hosts.filter { !$0.control.isHeld }.count, 1)
            await clock.advance(by: 1)
        }
        let during = zip(hosts, before).map { $0.sockets.count - $1 }.reduce(0, +)
        XCTAssertLessThanOrEqual(during, 4 + 2 * 6, "each host's first attempt, then two per 100 s")
        XCTAssertGreaterThanOrEqual(during, 4)

        // The host under test answers: the tunnel is back.
        var test = hosts.first { $0.isConnecting }
        var waited = 0
        while test == nil, waited < 400 {
            await clock.advance(by: 1)
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
        // 500 ms apart, the selected host first, then the one that was good last.
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

    /// A computer that is really off must not keep the others held: when it is the test host and
    /// stays silent, the next host takes the turn, and its welcome closes the breaker.
    func testAHostThatIsOffDoesNotKeepTheOthersHeld() async {
        makeHosts(3)
        await connectAll()
        governor.select(hosts[0].control)
        for h in hosts { h.sockets.last.failReceive() }
        await pump()
        XCTAssertTrue(governor.breakerOpen)
        XCTAssertFalse(hosts[0].control.isHeld)
        // Host 0 is off; the others answer when they are tried.
        var seconds = 0
        while governor.breakerOpen, seconds < 120 {
            for h in hosts where h.isConnecting && h.sockets.last.isWaitingToReceive && h !== hosts[0] {
                h.sockets.last.welcome()
            }
            await pump()
            await clock.advance(by: 1)
            seconds += 1
        }
        XCTAssertFalse(governor.breakerOpen)
        XCTAssertLessThan(seconds, 30, "within the off host's first two attempts")
        await clock.advance(by: 3)
        for h in hosts.dropFirst() where h.isConnecting { h.sockets.last.welcome() }
        await pump()
        XCTAssertEqual(hosts[1].control.state, .connected)
        XCTAssertEqual(hosts[2].control.state, .connected)
    }

    func testATapGoesThroughAnOpenBreakerAndItsWelcomeClosesIt() async {
        makeHosts(3)
        await connectAll()
        governor.select(hosts[0].control)
        for h in hosts { h.sockets.last.failReceive() }
        await pump()
        XCTAssertTrue(hosts[2].control.isHeld)
        let before = hosts[2].sockets.count
        hosts[2].control.kick()
        await pump()
        XCTAssertEqual(hosts[2].sockets.count, before + 1, "the user asked")
        hosts[2].sockets.last.welcome()
        await pump()
        XCTAssertFalse(governor.breakerOpen, "a welcome from any host: the tunnel works")
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
