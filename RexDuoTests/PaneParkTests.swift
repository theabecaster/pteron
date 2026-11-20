import RexKit
import XCTest
@testable import RexDuo

/// Parking: which panes are kept ready to come back, what a parked pane holds on to, and when
/// its fit claim is given back.
@MainActor
final class PaneParkTests: XCTestCase {
    private var window: UIWindow!

    override func setUp() async throws {
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first { window.windowScene = scene }
        window.isHidden = false
    }

    override func tearDown() async throws {
        window.isHidden = true
        window = nil
    }

    private func pause(_ seconds: TimeInterval) {
        let done = expectation(description: "pause")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { done.fulfill() }
        wait(for: [done], timeout: seconds + 5)
    }

    private func eventually(_ seconds: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while !condition(), Date() < end { pause(0.01) }
        return condition()
    }

    // MARK: The policy

    private func evicted(_ sizes: [Int], count: Int = 4, bytes: Int = 96 << 20) -> [Int] {
        ParkPolicy.evictions(sizes.enumerated().map { (key: $0.offset, bytes: $0.element) },
                             limits: ParkLimits(count: count, bytes: bytes))
    }

    func testFourPanesAreKept() {
        XCTAssertEqual(evicted([1, 1, 1, 1]), [])
        XCTAssertEqual(evicted([]), [])
    }

    func testTheOldestGoesFirst() {
        XCTAssertEqual(evicted([1, 1, 1, 1, 1]), [0])
        XCTAssertEqual(evicted([1, 1, 1, 1, 1, 1, 1]), [0, 1, 2])
    }

    func testTheMemoryBoundLetsTheOldestGoUntilTheRestFit() {
        let mb = 1 << 20
        XCTAssertEqual(evicted([40 * mb, 40 * mb, 16 * mb]), [], "exactly 96 MB fits")
        XCTAssertEqual(evicted([40 * mb, 40 * mb, 17 * mb]), [0])
        XCTAssertEqual(evicted([60 * mb, 60 * mb, 60 * mb]), [0, 1])
        XCTAssertEqual(evicted([10 * mb, 100 * mb]), [0, 1], "one pane over the bound is not kept either")
        XCTAssertEqual(evicted([100 * mb, 10 * mb]), [0])
    }

    func testBothBoundsHold() {
        let mb = 1 << 20
        XCTAssertEqual(evicted([1, 1, 50 * mb, 50 * mb, 1]), [0, 1, 2])
    }

    func testAPaneIsStaleWhenItsServerWasLeftOrItsSessionClosed() {
        let a = UUID(), b = UUID()
        func stale(_ server: UUID, _ session: String, selected: UUID?, servers: Set<UUID>, sessions: [UUID: Set<String>]) -> Bool {
            ParkPolicy.isStale(server: server, session: session, selected: selected, servers: servers, sessions: sessions)
        }
        XCTAssertFalse(stale(a, "s1", selected: a, servers: [a, b], sessions: [a: ["s1", "s2"]]))
        XCTAssertTrue(stale(a, "s1", selected: b, servers: [a, b], sessions: [a: ["s1"]]), "the user left its server")
        XCTAssertTrue(stale(a, "s1", selected: a, servers: [b], sessions: [:]), "its server is gone")
        XCTAssertTrue(stale(a, "s1", selected: a, servers: [a], sessions: [a: ["s2"]]), "its session closed")
        XCTAssertFalse(stale(a, "s1", selected: a, servers: [a], sessions: [:]), "an offline server says nothing about its sessions")
        XCTAssertFalse(stale(a, "s1", selected: nil, servers: [a], sessions: [a: ["s1"]]), "no tab on screen is not another server")
    }

    func testTenMinutesAwayEndThePark() {
        let limits = ParkLimits()
        XCTAssertFalse(ParkPolicy.expired(awayFor: 599, limits: limits))
        XCTAssertTrue(ParkPolicy.expired(awayFor: 600, limits: limits))
    }

    // MARK: The pool

    /// A pool that keeps no pane warm (as in Low Power Mode): every pane that leaves parks.
    private func parkingPool() -> TerminalHostPool {
        let pool = TerminalHostPool()
        pool.power = { (lowPower: true, hot: false) }
        return pool
    }

    /// A pool with its warm panes, and the phone's state as the test says.
    private func warmPool(lowPower: Bool = false, hot: Bool = false, expensive: Bool = false) -> TerminalHostPool {
        let pool = TerminalHostPool()
        pool.power = { (lowPower: lowPower, hot: hot) }
        pool.expensiveNetwork = { expensive }
        return pool
    }

    /// Shows the host, takes it off screen and waits until the pool has decided about it.
    private func showAndLeaveWarm(_ host: TerminalHost) {
        host.frame = window.bounds
        window.addSubview(host)
        host.layoutIfNeeded()
        host.removeFromSuperview()
        XCTAssertTrue(eventually { host.isWarm || host.isParked })
    }

    private func key(_ n: Int, server: UUID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!, session: String = "s") -> TerminalHostPool.Key {
        TerminalHostPool.Key(server: server, session: session, block: "b\(n)")
    }

    private func pooledHost(_ pool: TerminalHostPool, _ key: TerminalHostPool.Key, transport: FakeFitTransport? = nil,
                            sizing: SizingMode = .mirror) -> TerminalHost {
        let control = RexControl(address: "", client: ClientInfo(name: "test", version: "0", label: "test"))
        let stream = TerminalStream(control: control, sessionID: key.session, blockID: key.block)
        let claim = transport.map { FitClaim(transport: $0, settle: {}) }
        let host = TerminalHost(stream: stream, sizing: sizing, fontSize: 12, theme: ThemeStore.fallback, claim: claim)
        host.leaveTiming = TerminalHost.LeaveTiming(settle: 0.02, claimGrace: 0.4)
        host.hardwareKeyboard = { false }
        pool.add(host, for: key)
        return host
    }

    /// Shows the host in the window until it has started, then takes it off screen and waits
    /// for it to park.
    private func showAndLeave(_ host: TerminalHost) {
        host.frame = window.bounds
        window.addSubview(host)
        host.layoutIfNeeded()
        host.removeFromSuperview()
        XCTAssertTrue(eventually { host.isParked }, "the pane parks when it has been off screen")
    }

    func testAPaneThatLeavesTheScreenParksAndStaysInThePool() {
        let pool = parkingPool()
        let host = pooledHost(pool, key(1))
        showAndLeave(host)
        XCTAssertTrue(pool.host(for: key(1)) === host)
        XCTAssertEqual(pool.parked, [key(1)])
        XCTAssertTrue(host.stream.isParked)
    }

    func testAPaneWithoutAPoolStopsAsBefore() {
        let control = RexControl(address: "", client: ClientInfo(name: "test", version: "0", label: "test"))
        let stream = TerminalStream(control: control, sessionID: "s", blockID: "b")
        let host = TerminalHost(stream: stream, sizing: .mirror, fontSize: 12, theme: ThemeStore.fallback)
        host.leaveTiming.settle = 0.02
        var stopped = false
        host.onStopped = { stopped = true }
        host.frame = window.bounds
        window.addSubview(host)
        host.layoutIfNeeded()
        host.removeFromSuperview()
        XCTAssertTrue(eventually { stopped })
        XCTAssertFalse(host.isParked)
    }

    func testThePoolKeepsTheFourParkedLast() {
        let pool = parkingPool()
        let hosts = (1...6).map { pooledHost(pool, key($0)) }
        for host in hosts { showAndLeave(host) }
        XCTAssertEqual(pool.parked, [key(3), key(4), key(5), key(6)])
        XCTAssertNil(pool.host(for: key(1)), "the oldest was let go")
        XCTAssertNil(pool.host(for: key(2)))
        XCTAssertFalse(hosts[0].isParked)
        XCTAssertFalse(hosts[0].stream.isParked, "and its stream is stopped for good")
    }

    func testAPaneOnScreenDoesNotCount() {
        let pool = parkingPool()
        let visible = pooledHost(pool, key(0))
        visible.frame = window.bounds
        window.addSubview(visible)
        visible.layoutIfNeeded()
        for n in 1...4 { showAndLeave(pooledHost(pool, key(n))) }
        XCTAssertEqual(pool.parked.count, 4)
        XCTAssertNotNil(pool.host(for: key(0)))
        visible.removeFromSuperview()
    }

    func testAReturningPaneLeavesTheParkAndAnotherReturnMakesItTheNewest() {
        let pool = parkingPool()
        let a = pooledHost(pool, key(1)), b = pooledHost(pool, key(2))
        showAndLeave(a)
        showAndLeave(b)
        XCTAssertEqual(pool.parked, [key(1), key(2)])
        a.frame = window.bounds
        window.addSubview(a)
        XCTAssertFalse(a.isParked)
        XCTAssertFalse(a.stream.isParked)
        XCTAssertEqual(pool.parked, [key(2)])
        a.removeFromSuperview()
        XCTAssertTrue(eventually { a.isParked })
        XCTAssertEqual(pool.parked, [key(2), key(1)])
    }

    func testTheMemoryBoundEvicts() {
        let pool = parkingPool()
        pool.limits.bytes = 1
        let host = pooledHost(pool, key(1))
        host.frame = window.bounds
        window.addSubview(host)
        host.layoutIfNeeded()
        host.removeFromSuperview()
        XCTAssertGreaterThan(host.term.core.memoryBytes, 1, "a terminal holds at least its screen")
        XCTAssertTrue(eventually { pool.host(for: self.key(1)) == nil })
        XCTAssertEqual(pool.parked, [])
    }

    // Hazard 8.
    func testAMemoryWarningLetsEveryParkedPaneGoAndKeepsTheOneOnScreen() {
        let pool = parkingPool()
        let visible = pooledHost(pool, key(0))
        visible.frame = window.bounds
        window.addSubview(visible)
        for n in 1...3 { showAndLeave(pooledHost(pool, key(n))) }
        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        XCTAssertEqual(pool.parked, [])
        for n in 1...3 { XCTAssertNil(pool.host(for: key(n))) }
        XCTAssertNotNil(pool.host(for: key(0)))
        visible.removeFromSuperview()
    }

    // Hazard 8.
    func testTenMinutesInTheBackgroundLetThemGoAndLessDoesNot() {
        let pool = parkingPool()
        var clock: CFTimeInterval = 1000
        pool.now = { clock }
        showAndLeave(pooledHost(pool, key(1)))
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        clock += 599
        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        XCTAssertEqual(pool.parked, [key(1)])
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        clock += 600
        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        XCTAssertEqual(pool.parked, [])
        XCTAssertNil(pool.host(for: key(1)))
    }

    func testLeavingTheServerAndAClosedSessionLetTheirPanesGo() {
        let pool = parkingPool()
        let here = UUID(), there = UUID()
        showAndLeave(pooledHost(pool, key(1, server: here, session: "open")))
        showAndLeave(pooledHost(pool, key(2, server: here, session: "closed")))
        showAndLeave(pooledHost(pool, key(3, server: there, session: "open")))
        pool.keep(selected: here, servers: [here, there], sessions: [here: ["open"], there: ["open"]])
        XCTAssertEqual(pool.parked, [key(1, server: here, session: "open")])
    }

    // MARK: What a parked pane keeps

    func testAParkedPaneKeepsItsScreenAndFreesItsDrawables() {
        let pool = parkingPool()
        let host = pooledHost(pool, key(1))
        host.frame = window.bounds
        window.addSubview(host)
        host.layoutIfNeeded()
        host.term.feed(text: "kept\r\n")
        host.term.core.sync()
        host.removeFromSuperview()
        XCTAssertTrue(eventually { host.isParked })
        XCTAssertEqual(host.term.core.rowText(0), "kept")
        XCTAssertEqual(host.term.metalLayerDrawableSize, CGSize(width: 1, height: 1))
        window.addSubview(host)
        host.layoutIfNeeded()
        XCTAssertGreaterThan(host.term.metalLayerDrawableSize.width, 1)
        XCTAssertEqual(host.term.core.rowText(0), "kept", "the same terminal, not a new one")
        XCTAssertTrue(host.isCatchingUp, "and its stream is behind the fence from the first moment")
        host.removeFromSuperview()
    }

    // MARK: Hazard 7: the claim grace

    /// A fitted host that has claimed its size.
    private func claimedHost(_ pool: TerminalHostPool, _ transport: FakeFitTransport) -> TerminalHost {
        let host = pooledHost(pool, key(1), transport: transport, sizing: .fit)
        host.frame = window.bounds
        window.addSubview(host)
        host.layoutIfNeeded()
        XCTAssertTrue(eventually { transport.calls.count == 2 }, "own and resize")
        return host
    }

    // MARK: The parallel start

    func testTheStreamStartsWhileTheClaimIsStillOnItsWay() {
        let pool = parkingPool()
        let transport = FakeFitTransport()
        transport.held = ["own"]
        let host = pooledHost(pool, key(1), transport: transport, sizing: .fit)
        host.frame = window.bounds
        window.addSubview(host)
        host.layoutIfNeeded()
        XCTAssertTrue(host.isCatchingUp, "started at the first layout, behind its fence")
        XCTAssertTrue(eventually { transport.waitingKinds == ["own"] })
        XCTAssertTrue(host.stream.isClaimPending, "the fence waits for the resize")
        XCTAssertFalse(transport.calls.contains { $0.hasPrefix("resize") })
        transport.held = []
        transport.finishAll()
        XCTAssertTrue(eventually { !host.stream.isClaimPending })
        XCTAssertEqual(transport.calls.count, 2, "own, then one resize")
        host.removeFromSuperview()
    }

    func testASizeFromBeforeOurResizeIsNotAnotherClientTakingThePane() {
        let pool = parkingPool()
        let transport = FakeFitTransport()
        let host = claimedHost(pool, transport)
        let mine = host.claimWanted ?? (cols: 0, rows: 0)
        XCTAssertTrue(host.isCatchingUp)
        // The snapshot's size, sent before the server ran our resize, arrives after the claim's answer.
        host.streamResized(cols: 211, rows: 57, owner: "client:mac")
        XCTAssertNil(host.statusChipText, "not resized elsewhere: ours is still to come")
        // Our own resize comes by; from here on another client's is news.
        host.streamResized(cols: mine.cols, rows: mine.rows, owner: nil)
        XCTAssertNil(host.statusChipText)
        host.streamResized(cols: 120, rows: 40, owner: "client:mac")
        XCTAssertEqual(host.statusChipText, "Resized elsewhere · tap to fit here")
        host.removeFromSuperview()
    }

    func testAPaneInTheBackgroundOrUnderTheBoardStartsNothing() {
        let pool = parkingPool()
        let transport = FakeFitTransport()
        let host = pooledHost(pool, key(1), transport: transport, sizing: .fit)
        host.setCovered(true)
        host.frame = window.bounds
        window.addSubview(host)
        host.layoutIfNeeded()
        pause(0.1)
        XCTAssertFalse(host.isCatchingUp)
        XCTAssertEqual(transport.calls, [])
        host.removeFromSuperview()
    }

    func testAParkedPaneKeepsItsClaimForTheGraceThenGivesItBack() {
        let pool = parkingPool()
        let transport = FakeFitTransport()
        let host = claimedHost(pool, transport)
        host.removeFromSuperview()
        XCTAssertTrue(eventually { host.isParked })
        pause(0.15)
        XCTAssertFalse(transport.calls.contains("disown"), "still the phone's size on the Mac")
        XCTAssertTrue(eventually { transport.calls.contains("disown") }, "the Mac gets its size back")
        XCTAssertTrue(host.isParked, "the pane itself stays parked")
    }

    func testAQuickReturnResizesNothing() {
        let pool = parkingPool()
        let transport = FakeFitTransport()
        let host = claimedHost(pool, transport)
        let resized = transport.calls.first { $0.hasPrefix("resize") }
        // The stream echoes the size the claim asked for.
        let size = try? XCTUnwrap(host.claimWanted)
        host.streamResized(cols: size?.cols ?? 0, rows: size?.rows ?? 0, owner: nil)
        host.removeFromSuperview()
        XCTAssertTrue(eventually { host.isParked })
        window.addSubview(host)
        host.layoutIfNeeded()
        pause(0.6)
        XCTAssertEqual(transport.calls, ["own", resized ?? ""], "no second resize and no disown: the screen can be exact")
        XCTAssertFalse(host.stream.isClaimPending)
        host.removeFromSuperview()
    }

    func testAReturnAfterTheGraceClaimsAgain() {
        let pool = parkingPool()
        let transport = FakeFitTransport()
        let host = claimedHost(pool, transport)
        host.removeFromSuperview()
        XCTAssertTrue(eventually { transport.calls.contains("disown") })
        window.addSubview(host)
        host.layoutIfNeeded()
        XCTAssertTrue(eventually { transport.calls.filter { $0 == "own" }.count == 2 })
        XCTAssertTrue(eventually { transport.calls.filter { $0.hasPrefix("resize") }.count == 2 })
        host.removeFromSuperview()
    }

    func testTheBackgroundGivesAParkedPanesClaimBackAtOnce() {
        let pool = parkingPool()
        let transport = FakeFitTransport()
        let host = claimedHost(pool, transport)
        host.leaveTiming.claimGrace = 30
        host.removeFromSuperview()
        XCTAssertTrue(eventually { host.isParked })
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        XCTAssertTrue(eventually(1) { transport.calls.contains("disown") })
        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    func testAnEvictedPaneGivesItsClaimBack() {
        let pool = parkingPool()
        let transport = FakeFitTransport()
        let host = claimedHost(pool, transport)
        host.leaveTiming.claimGrace = 30
        host.removeFromSuperview()
        XCTAssertTrue(eventually { host.isParked })
        pool.evictParked()
        XCTAssertTrue(eventually(1) { transport.calls.contains("disown") })
        XCTAssertNil(pool.host(for: key(1)))
    }

    // MARK: Warm panes

    func testTheLimitIsTwoOneOnAnExpensiveNetworkAndNoneWhenThePhoneSaves() {
        typealias F = WarmPolicy.Facts
        XCTAssertEqual(WarmPolicy.limit(F()), 2)
        XCTAssertEqual(WarmPolicy.limit(F(expensive: true)), 1)
        XCTAssertEqual(WarmPolicy.limit(F(foreground: false)), 0)
        XCTAssertEqual(WarmPolicy.limit(F(lowPower: true)), 0)
        XCTAssertEqual(WarmPolicy.limit(F(hot: true)), 0)
        XCTAssertEqual(WarmPolicy.limit(F(lowPower: true, expensive: true)), 0)
    }

    func testAWindowOver64KBPerSecondIsTooBusy() {
        var rate = WarmRate()
        rate.reset(at: 100)
        // 2 s at 60 KB/s: under the limit.
        for i in 0..<20 { XCTAssertFalse(rate.add(6 * 1024, at: 100 + Double(i) * 0.1)) }
        XCTAssertFalse(rate.add(6 * 1024, at: 102), "the window that ended held 120 KB in 2 s")
        // The next 2 s at 70 KB/s.
        for i in 1..<20 { XCTAssertFalse(rate.add(7 * 1024, at: 102 + Double(i) * 0.1)) }
        XCTAssertTrue(rate.add(7 * 1024, at: 104), "130 KB in 2 s is over")
    }

    func testABurstInsideAWindowIsJudgedByItsAverage() {
        var rate = WarmRate()
        rate.reset(at: 0)
        XCTAssertFalse(rate.add(100 * 1024, at: 0.1), "not before the window has ended")
        XCTAssertFalse(rate.add(1, at: 2.0), "100 KB in 2 s is 50 KB/s")
        XCTAssertFalse(rate.add(200 * 1024, at: 2.1))
        XCTAssertTrue(rate.add(1, at: 4.2), "200 KB in 2.2 s is over")
        // A pane that was silent for a long time and writes again is not judged by one chunk.
        XCTAssertFalse(rate.add(100 * 1024, at: 60))
        XCTAssertFalse(rate.add(1, at: 62.5))
    }

    func testTheTwoPanesLeftLastStayWarmAndTheOlderOnesPark() {
        let pool = warmPool()
        let hosts = (1...4).map { pooledHost(pool, key($0)) }
        for host in hosts { showAndLeaveWarm(host) }
        XCTAssertEqual(pool.warm, [key(3), key(4)])
        XCTAssertEqual(pool.parked, [key(1), key(2)])
        XCTAssertTrue(hosts[3].isWarm)
        XCTAssertFalse(hosts[3].stream.isParked, "its stream goes on")
        XCTAssertTrue(hosts[0].isParked)
        XCTAssertTrue(hosts[0].stream.isParked)
    }

    func testWarmAndParkedTogetherStayWithinFour() {
        let pool = warmPool()
        let hosts = (1...6).map { pooledHost(pool, key($0)) }
        for host in hosts { showAndLeaveWarm(host) }
        XCTAssertEqual(pool.warm, [key(5), key(6)])
        XCTAssertEqual(pool.parked, [key(3), key(4)])
        XCTAssertNil(pool.host(for: key(1)))
    }

    func testOnAnExpensiveNetworkOnePaneStaysWarm() {
        let pool = warmPool(expensive: true)
        let hosts = (1...3).map { pooledHost(pool, key($0)) }
        for host in hosts { showAndLeaveWarm(host) }
        XCTAssertEqual(pool.warm, [key(3)])
        XCTAssertEqual(pool.parked, [key(1), key(2)])
    }

    func testLowPowerModeAndAHotPhoneKeepNone() {
        for pool in [warmPool(lowPower: true), warmPool(hot: true)] {
            let host = pooledHost(pool, key(1))
            showAndLeaveWarm(host)
            XCTAssertTrue(host.isParked)
            XCTAssertEqual(pool.warm, [])
        }
    }

    func testTheBackgroundParksEveryWarmPane() {
        let pool = warmPool()
        let hosts = (1...2).map { pooledHost(pool, key($0)) }
        for host in hosts { showAndLeaveWarm(host) }
        XCTAssertEqual(pool.warm.count, 2)
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        XCTAssertEqual(pool.warm, [])
        XCTAssertEqual(pool.parked, [key(1), key(2)])
        XCTAssertTrue(hosts.allSatisfy { $0.isParked && $0.stream.isParked })
        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    func testLowPowerModeComingOnParksTheWarmPanes() {
        var low = false
        let pool = TerminalHostPool()
        pool.power = { (lowPower: low, hot: false) }
        let host = pooledHost(pool, key(1))
        showAndLeaveWarm(host)
        XCTAssertTrue(host.isWarm)
        low = true
        NotificationCenter.default.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        XCTAssertTrue(eventually { host.isParked })
        XCTAssertEqual(pool.warm, [])
    }

    func testAWarmPaneThatWritesTooMuchParks() {
        let pool = warmPool()
        let host = pooledHost(pool, key(1))
        showAndLeaveWarm(host)
        XCTAssertTrue(host.isWarm)
        let chunk = [UInt8](repeating: 0x61, count: 90 * 1024)
        // 90 KB every second for a little over one window: 90 KB/s.
        for _ in 0..<3 {
            chunk.withUnsafeBufferPointer { host.streamFeed($0) }
            pause(1.05)
        }
        chunk.withUnsafeBufferPointer { host.streamFeed($0) }
        XCTAssertTrue(eventually { host.isParked }, "too busy to follow unseen")
        XCTAssertEqual(pool.parked, [key(1)])
        host.term.core.sync()
        XCTAssertEqual(host.term.core.bytesParsed, 4 * chunk.count, "every byte it was given is in the terminal")
    }

    func testAQuietWarmPaneStaysWarmAndParsesWhatComes() {
        let pool = warmPool()
        let host = pooledHost(pool, key(1))
        showAndLeaveWarm(host)
        host.term.feed(text: "")
        Array("unseen\r\n".utf8).withUnsafeBufferPointer { host.streamFeed($0) }
        host.term.core.sync()
        XCTAssertTrue(host.isWarm)
        XCTAssertEqual(host.term.core.rowText(0), "unseen", "parsed while nobody looks")
        XCTAssertEqual(host.term.metalLayerDrawableSize, CGSize(width: 1, height: 1), "and never drawn")
    }

    func testAResizeOffScreenReachesTheTerminalAndMakesNoDrawables() {
        let pool = warmPool()
        let host = pooledHost(pool, key(1))
        showAndLeaveWarm(host)
        let frame = host.term.frame
        host.streamResized(cols: 100, rows: 30, owner: "client:other")
        host.layoutIfNeeded()
        host.term.core.sync()
        XCTAssertEqual(host.term.core.cols, 100, "the bytes that follow are for this size")
        XCTAssertEqual(host.term.core.rows, 30)
        XCTAssertEqual(host.term.frame, frame, "no layout for a pane nobody sees")
        XCTAssertEqual(host.term.metalLayerDrawableSize, CGSize(width: 1, height: 1))
        window.addSubview(host)
        host.layoutIfNeeded()
        XCTAssertGreaterThan(host.term.metalLayerDrawableSize.width, 1, "laid out and drawn when it is back")
        host.removeFromSuperview()
    }

    func testAWarmMirrorPaneComesBackWithNoFence() {
        let pool = warmPool()
        let host = pooledHost(pool, key(1))
        showAndLeaveWarm(host)
        // The stream of this test never went live, so its start's fence is still up; a live one
        // would be down. What matters here: coming back raises nothing and parks nothing.
        let fenced = host.isCatchingUp
        window.addSubview(host)
        host.layoutIfNeeded()
        XCTAssertFalse(host.isWarm)
        XCTAssertEqual(host.isCatchingUp, fenced)
        XCTAssertFalse(host.stream.isParked)
        XCTAssertEqual(pool.warm, [])
        XCTAssertGreaterThan(host.term.metalLayerDrawableSize.width, 1)
        host.removeFromSuperview()
    }

    func testAMemoryWarningLetsTheWarmPanesGoToo() {
        let pool = warmPool()
        for n in 1...2 { showAndLeaveWarm(pooledHost(pool, key(n))) }
        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        XCTAssertEqual(pool.warm, [])
        XCTAssertNil(pool.host(for: key(1)))
        XCTAssertNil(pool.host(for: key(2)))
    }
}
