import RexKit
import XCTest
@testable import Pteron

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
        host.leaveTiming = TerminalHost.LeaveTiming(settle: 0.02, claimGrace: 0.4, backgroundGrace: 0)
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
        // And both answered, so the claim is the host's: a call that started has not returned
        // yet on a busy machine, and a host taken away before its answer holds no claim.
        XCTAssertTrue(eventually { transport.log.filter { $0.hasSuffix(" done") }.count == 2 }, "both answered")
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
        XCTAssertEqual(host.statusChipText, "Resized on another screen · tap to fit this one")
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

    // MARK: What holds a pane that left

    func testAPaneEvictedWhileParkedIsGoneAtOnce() {
        let pool = parkingPool()
        let transport = FakeFitTransport()
        weak var pane: TerminalHost?
        weak var terminal: GhosttyTerminalView?
        autoreleasepool {
            let host = claimedHost(pool, transport)
            // Far longer than the test waits: only letting go of the pane can free it.
            host.leaveTiming.claimGrace = 60
            pane = host
            terminal = host.term
            host.removeFromSuperview()
            XCTAssertTrue(eventually { host.isParked })
            pool.evictParked()
            XCTAssertNil(pool.host(for: key(1)))
        }
        XCTAssertTrue(eventually(2) { pane == nil }, "nothing holds an evicted pane, its grace least of all")
        XCTAssertTrue(eventually(2) { terminal == nil }, "and its terminal left the render thread with it")
        XCTAssertTrue(eventually(1) { transport.calls.contains("disown") }, "the Mac got its size back")
    }

    func testAPaneEvictedRightAfterItLeftIsGoneAtOnce() {
        let pool = parkingPool()
        let transport = FakeFitTransport()
        weak var pane: TerminalHost?
        weak var terminal: GhosttyTerminalView?
        autoreleasepool {
            let host = claimedHost(pool, transport)
            // Neither delay runs out in this test: the pane is let go before it has settled.
            host.leaveTiming = TerminalHost.LeaveTiming(settle: 60, claimGrace: 60)
            pane = host
            terminal = host.term
            host.removeFromSuperview()
            host.evict()
            XCTAssertNil(pool.host(for: key(1)))
        }
        XCTAssertTrue(eventually(2) { pane == nil }, "neither the settle time nor the grace holds it")
        XCTAssertTrue(eventually(2) { terminal == nil })
        XCTAssertTrue(eventually(1) { transport.calls.contains("disown") })
    }

    func testAPaneNobodyStopsIsHeldUntilItsGraceGaveItsClaimBack() {
        let transport = FakeFitTransport()
        weak var pane: TerminalHost?
        autoreleasepool {
            // The pool goes with the pane still parked in it, and nobody stops the pane.
            let pool = parkingPool()
            let host = claimedHost(pool, transport)
            host.leaveTiming.claimGrace = 2
            pane = host
            host.removeFromSuperview()
            XCTAssertTrue(eventually { host.isParked })
        }
        XCTAssertNotNil(pane, "its grace holds it")
        XCTAssertFalse(transport.calls.contains("disown"), "inside the grace the claim stays")
        XCTAssertTrue(eventually(5) { transport.calls.contains("disown") }, "the Mac gets its size back all the same")
        XCTAssertTrue(eventually(2) { pane == nil }, "and then the pane goes")
        XCTAssertEqual(transport.calls.filter { $0 == "disown" }.count, 1)
    }

    func testLeavingAgainInsideTheGraceGivesTheClaimBackOnceAndCountsFromTheSecondLeave() {
        let pool = parkingPool()
        let transport = FakeFitTransport()
        let host = claimedHost(pool, transport)
        host.leaveTiming.claimGrace = 1.2
        // The stream echoes the size the claim asked for, so a return asks for nothing.
        let size = try? XCTUnwrap(host.claimWanted)
        host.streamResized(cols: size?.cols ?? 0, rows: size?.rows ?? 0, owner: nil)
        host.removeFromSuperview()
        XCTAssertTrue(eventually { host.isParked })
        pause(0.5)
        // Back on screen inside the grace: that grace is over, with the claim kept.
        window.addSubview(host)
        host.layoutIfNeeded()
        pause(0.3)
        let leftAgain = Date()
        host.removeFromSuperview()
        // Past the end of the first leave's grace, well inside the second's.
        pause(0.7)
        XCTAssertFalse(transport.calls.contains("disown"), "the first leave's grace ended with the return")
        XCTAssertTrue(eventually(5) { transport.calls.contains("disown") })
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(leftAgain), 1.1, "a whole grace after the second leave")
        pause(0.3)
        XCTAssertEqual(transport.calls.filter { $0 == "disown" }.count, 1, "given back once")
    }

    // MARK: A warm fitted pane's return

    func testOnlyAClaimThatWillFollowFencesAWarmReturn() {
        let fits = (60, 40)
        XCTAssertFalse(WarmReturn.fences(fit: false, claimed: nil, server: (80, 24), fits: fits), "mirror")
        XCTAssertFalse(WarmReturn.fences(fit: true, claimed: fits, server: fits, fits: fits), "the claim is held at this size")
        XCTAssertTrue(WarmReturn.fences(fit: true, claimed: nil, server: fits, fits: fits), "the grace ran out")
        XCTAssertTrue(WarmReturn.fences(fit: true, claimed: (50, 40), server: (50, 40), fits: fits), "another grid fits now")
        XCTAssertTrue(WarmReturn.fences(fit: true, claimed: fits, server: (120, 50), fits: fits), "the server has another size")
    }

    func testAWarmFittedPaneInsideItsGraceComesBackWithNoFenceAndNoClaim() throws {
        let pool = warmPool()
        let transport = FakeFitTransport()
        let host = claimedHost(pool, transport)
        host.leaveTiming.claimGrace = 30
        let size = try XCTUnwrap(host.claimWanted)
        host.streamResized(cols: size.cols, rows: size.rows, owner: nil)
        let calls = transport.calls
        host.removeFromSuperview()
        XCTAssertTrue(eventually { host.isWarm })
        XCTAssertFalse(host.warmReturnFences, "streamed at the claimed size the whole time")
        window.addSubview(host)
        host.layoutIfNeeded()
        pause(0.3)
        XCTAssertEqual(transport.calls, calls, "nothing is claimed again")
        XCTAssertFalse(host.stream.isClaimPending)
        host.removeFromSuperview()
    }

    func testAWarmFittedPaneWhoseClaimLapsedIsFencedOnReturn() throws {
        let pool = warmPool()
        let transport = FakeFitTransport()
        let host = claimedHost(pool, transport)
        let size = try XCTUnwrap(host.claimWanted)
        host.streamResized(cols: size.cols, rows: size.rows, owner: nil)
        host.removeFromSuperview()
        XCTAssertTrue(eventually { host.isWarm })
        XCTAssertTrue(eventually { transport.calls.contains("disown") }, "the grace ran out")
        XCTAssertTrue(host.warmReturnFences)
        window.addSubview(host)
        host.layoutIfNeeded()
        XCTAssertTrue(host.stream.isClaimPending, "claimed again, and the fence waits for it")
        host.removeFromSuperview()
    }

    func testThePoolCountsTheMemoryReadWhenThePaneLeft() {
        let pool = warmPool()
        let host = pooledHost(pool, key(1))
        XCTAssertEqual(host.keptBytes, 0)
        showAndLeaveWarm(host)
        let kept = host.keptBytes
        XCTAssertGreaterThan(kept, 0)
        XCTAssertEqual(kept, host.term.core.memoryBytes)
        // What a warm pane takes in afterwards is counted when it parks, not on every leave.
        let chunk = [UInt8](repeating: 0x61, count: 400_000)
        for _ in 0..<8 { chunk.withUnsafeBufferPointer { host.term.feed(buffer: $0) } }
        host.term.core.sync()
        XCTAssertEqual(host.keptBytes, kept)
        host.park()
        XCTAssertEqual(host.keptBytes, host.term.core.memoryBytes)
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

    func testAMirrorPaneThatComesBackSendsNothingWhateverTheServersSize() {
        let pool = warmPool()
        let transport = FakeFitTransport()
        let host = pooledHost(pool, key(1), transport: transport, sizing: .mirror)
        showAndLeaveWarm(host)
        host.streamResized(cols: 60, rows: 30, owner: "client:mac")
        window.addSubview(host)
        host.layoutIfNeeded()
        host.streamResized(cols: 211, rows: 57, owner: "client:mac")
        pause(0.3)
        XCTAssertEqual(transport.calls, [], "mirror never takes or resizes, on a return either")
        XCTAssertFalse(host.stream.isClaimPending)
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

    // MARK: A new width: a fold, a rotation, Split View

    /// The resizes sent, as grids.
    private func resizes(_ transport: FakeFitTransport) -> [(cols: Int, rows: Int)] {
        transport.calls.compactMap { call in
            guard call.hasPrefix("resize ") else { return nil }
            let n = call.dropFirst(7).split(separator: "x").compactMap { Int($0) }
            return n.count == 2 ? (n[0], n[1]) : nil
        }
    }

    /// The terminal as drawn fits inside the pane: no column runs past its right edge.
    private func drawnFits(_ host: TerminalHost) -> Bool {
        host.term.frame.width <= host.bounds.width + 1
    }

    /// A claimed host whose resize the stream has echoed, at the window's size.
    private func echoedHost(_ pool: TerminalHostPool, _ transport: FakeFitTransport) throws -> TerminalHost {
        let host = claimedHost(pool, transport)
        let size = try XCTUnwrap(host.claimWanted)
        host.streamResized(cols: size.cols, rows: size.rows, owner: nil)
        XCTAssertTrue(eventually { !host.stream.isClaimPending })
        return host
    }

    func testAnotherClientsSizeBetweenOurEchoAndTheClaimsAnswerIsNotTakenForOurs() throws {
        // Our resize's echo comes before the claim's answer. A wider size another client set
        // right after it was taken in silently, then the answer marked the claim as ours: the
        // pane stayed at the wider grid, its lines and its input line cut at the right edge, and
        // every later layout found the claim "in place" and sent nothing.
        let pool = parkingPool()
        let transport = FakeFitTransport()
        transport.held = ["resize"]
        let host = pooledHost(pool, key(1), transport: transport, sizing: .fit)
        host.frame = window.bounds
        window.addSubview(host)
        host.layoutIfNeeded()
        XCTAssertTrue(eventually { transport.waitingKinds == ["resize"] })
        let mine = try XCTUnwrap(host.claimWanted)
        host.streamResized(cols: mine.cols, rows: mine.rows, owner: nil)
        host.streamResized(cols: mine.cols + 40, rows: mine.rows, owner: "client:mac")
        transport.held = []
        transport.finishAll()
        pause(0.1)
        XCTAssertEqual(host.statusChipText, "Resized on another screen · tap to fit this one")
        XCTAssertTrue(drawnFits(host), "drawn as the server's grid scaled to the pane, as when resized elsewhere")
        host.removeFromSuperview()
    }

    func testANewWidthWithTheKeyboardUpClaimsTheNewColumnsAndTheRestRows() throws {
        // Unfolded, then folded with the keyboard up: the pane is narrower and shorter. The rest
        // size is the folded pane's with the keyboard's room given back (`PaneLayout.restCanvas`),
        // so the grid has the new columns and the rows of the pane with the keyboard down, in one
        // resize.
        let pool = parkingPool()
        let transport = FakeFitTransport()
        let wide = CGSize(width: 320, height: 480)
        let host = try echoedHost(pool, transport)
        host.setRestSize(wide)
        host.layoutIfNeeded()
        let before = try XCTUnwrap(resizes(transport).last)
        let folded = PaneLayout.restCanvas(now: CGSize(width: 200, height: 180), room: 300)
        host.setRestSize(folded)
        host.frame = CGRect(x: 0, y: 0, width: 200, height: 180)
        host.layoutIfNeeded()
        XCTAssertTrue(eventually { resizes(transport).count == 2 })
        let after = try XCTUnwrap(resizes(transport).last)
        XCTAssertEqual(after.cols, TerminalLayout.fitGrid(in: CGSize(width: 200, height: 480), cell: host.term.cellSize).cols)
        XCTAssertLessThan(after.cols, before.cols)
        XCTAssertEqual(after.rows, before.rows, "the keyboard covers the pane: the rows are the rest size's")
        host.streamResized(cols: after.cols, rows: after.rows, owner: nil)
        XCTAssertTrue(drawnFits(host))
        // The keyboard goes down in the folded pane: nothing more to send.
        host.setRestSize(PaneLayout.restCanvas(now: CGSize(width: 200, height: 480), room: 0))
        host.frame = CGRect(x: 0, y: 0, width: 200, height: 480)
        host.layoutIfNeeded()
        pause(0.2)
        XCTAssertEqual(resizes(transport).count, 2)
        host.removeFromSuperview()
    }

    func testTheKeyboardAloneResizesNothing() throws {
        let pool = parkingPool()
        let transport = FakeFitTransport()
        let rest = CGSize(width: 320, height: 480)
        let host = try echoedHost(pool, transport)
        host.setRestSize(rest)
        host.layoutIfNeeded()
        let calls = transport.calls
        for height: CGFloat in [180, 240, 480, 200, 480] {
            // The keyboard comes and goes, and changes height (emoji, the key bar alone).
            host.setRestSize(PaneLayout.restCanvas(now: CGSize(width: 320, height: height), room: 480 - height))
            host.frame = CGRect(x: 0, y: 0, width: 320, height: height)
            host.layoutIfNeeded()
        }
        pause(0.2)
        XCTAssertEqual(transport.calls, calls, "no resize: the keyboard covers the pane")
        host.removeFromSuperview()
    }

    func testAParkedPaneBackAtANewWidthInsideItsGraceClaimsTheNewWidth() throws {
        let pool = parkingPool()
        let transport = FakeFitTransport()
        let host = try echoedHost(pool, transport)
        host.leaveTiming.claimGrace = 30
        let before = try XCTUnwrap(resizes(transport).last)
        host.removeFromSuperview()
        XCTAssertTrue(eventually { host.isParked })
        // Folded while it was parked: it comes back narrower, its claim still held.
        host.frame = CGRect(x: 0, y: 0, width: 200, height: 480)
        window.addSubview(host)
        host.layoutIfNeeded()
        XCTAssertTrue(eventually { resizes(transport).count == 2 }, "the claim grace keeps the pane, not its width")
        let after = try XCTUnwrap(resizes(transport).last)
        XCTAssertLessThan(after.cols, before.cols)
        host.streamResized(cols: after.cols, rows: after.rows, owner: nil)
        XCTAssertTrue(drawnFits(host))
        XCTAssertFalse(transport.calls.contains("disown"))
        host.removeFromSuperview()
    }

    func testAWarmPaneBackAtANewWidthInsideItsGraceIsFencedAndClaimsTheNewWidth() throws {
        let pool = warmPool()
        let transport = FakeFitTransport()
        let host = try echoedHost(pool, transport)
        host.leaveTiming.claimGrace = 30
        let before = try XCTUnwrap(resizes(transport).last)
        host.removeFromSuperview()
        XCTAssertTrue(eventually { host.isWarm })
        host.frame = CGRect(x: 0, y: 0, width: 200, height: 480)
        XCTAssertTrue(host.warmReturnFences, "another grid fits now")
        window.addSubview(host)
        host.layoutIfNeeded()
        XCTAssertTrue(host.stream.isClaimPending, "fenced until the new size has landed")
        XCTAssertTrue(eventually { resizes(transport).count == 2 })
        let after = try XCTUnwrap(resizes(transport).last)
        XCTAssertLessThan(after.cols, before.cols)
        host.streamResized(cols: after.cols, rows: after.rows, owner: nil)
        XCTAssertTrue(drawnFits(host))
        host.removeFromSuperview()
    }

    // MARK: Block ownership: another client has the pane

    private static let lostText = "Resized on another screen · tap to fit this one"

    /// The pane has a screen and its stream has caught up: nothing is on its way.
    private func current(_ host: TerminalHost) {
        host.streamSnapshot("$ ")
        pause(0.1)
        // Ends the stream's fence as a stream that caught up does; the host stays started.
        host.stream.stop()
        XCTAssertFalse(host.isCatchingUp)
    }

    private func tapChip(_ host: TerminalHost) {
        host.perform(NSSelectorFromString("statusTapped"))
    }

    private func takes(_ transport: FakeFitTransport) -> Int { transport.calls.filter { $0 == "own" }.count }

    func testAClaimTheServerAnsweredButKeptForLaterShowsTheChipAndNeverOverflows() throws {
        // The owner's report: the Mac app owns the pane, so the phone's resize is answered and
        // kept for later, and the stream keeps the Mac's size. The phone drew the Mac's grid
        // 1:1, lines cut at the right edge, with no chip.
        let pool = parkingPool()
        let transport = FakeFitTransport()
        let host = claimedHost(pool, transport)
        host.fitCheckDelay = 0.1
        XCTAssertTrue(eventually { !host.stream.isClaimPending })
        // The snapshot's size, the Mac's, while the stream catches up: not news yet.
        host.streamResized(cols: 211, rows: 57, owner: "client:mac")
        XCTAssertNil(host.statusChipText)
        current(host)
        XCTAssertTrue(eventually(1) { host.statusChipText == Self.lostText }, "the chip, never a silent overflow")
        XCTAssertTrue(drawnFits(host), "the server's grid scaled to the pane")
        XCTAssertTrue(eventually { transport.calls.last == "disown" }, "out of the line, nothing else")
        let calls = transport.calls
        pause(0.3)
        XCTAssertEqual(transport.calls, calls, "not fought over")
        host.removeFromSuperview()
    }

    func testTheChipTakesThePaneThenResizesIt() throws {
        let pool = parkingPool()
        let transport = FakeFitTransport()
        let host = try echoedHost(pool, transport)
        current(host)
        host.streamResized(cols: 211, rows: 57, owner: "client:mac")
        XCTAssertEqual(host.statusChipText, Self.lostText)
        XCTAssertTrue(eventually { transport.calls.last == "disown" })
        let before = transport.calls.count
        tapChip(host)
        host.layoutIfNeeded()
        XCTAssertTrue(eventually { transport.calls.count == before + 2 })
        XCTAssertEqual(Array(transport.calls.suffix(2)).first, "own", "a take first: a resize from a non-owner only waits")
        XCTAssertTrue(transport.calls.last?.hasPrefix("resize") ?? false)
        XCTAssertNil(host.statusChipText)
        host.removeFromSuperview()
    }

    func testAPaneBackOnScreenTakesItBeforeItResizes() throws {
        // A claim moment. The phone took the pane once and then sent only resizes, which the
        // server kept for later once the Mac app owned it: 34 resizes, never applied.
        let pool = parkingPool()
        let transport = FakeFitTransport()
        let host = try echoedHost(pool, transport)
        host.leaveTiming.claimGrace = 30
        host.removeFromSuperview()
        XCTAssertTrue(eventually { host.isParked })
        host.frame = CGRect(x: 0, y: 0, width: 200, height: 480)
        window.addSubview(host)
        host.layoutIfNeeded()
        XCTAssertTrue(eventually { resizes(transport).count == 2 })
        XCTAssertEqual(takes(transport), 2, "taken again before the new size")
        let n = transport.calls.count
        XCTAssertEqual(transport.calls[n - 2], "own")
        host.removeFromSuperview()
    }

    func testBackFromTheBackgroundAfterAnotherClientWidenedThePaneClaimsAgainAndFits() throws {
        let pool = parkingPool()
        let transport = FakeFitTransport()
        let host = try echoedHost(pool, transport)
        let mine = try XCTUnwrap(host.claimWanted)
        host.fitCheckDelay = 0.1
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        XCTAssertTrue(eventually { transport.calls.contains("disown") })
        // The Mac gets the pane back, wider, while the phone is away.
        host.streamResized(cols: 211, rows: 57, owner: "client:mac")
        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        host.layoutIfNeeded()
        XCTAssertTrue(eventually { resizes(transport).count == 2 }, "the claim is sent again")
        XCTAssertEqual(takes(transport), 2)
        XCTAssertEqual(resizes(transport).last?.cols, mine.cols)
        host.streamResized(cols: mine.cols, rows: mine.rows, owner: nil)
        XCTAssertTrue(drawnFits(host))
        XCTAssertNil(host.statusChipText)
        host.removeFromSuperview()
    }

    func testATakeTheConnectionLostOnTheWayBackIsSentWhenItIsBack() throws {
        let pool = parkingPool()
        let transport = FakeFitTransport()
        let host = try echoedHost(pool, transport)
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        XCTAssertTrue(eventually { transport.calls.contains("disown") })
        transport.answers = ["own": [.offline]]
        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        host.layoutIfNeeded()
        XCTAssertTrue(eventually { transport.waitsForConnection })
        XCTAssertEqual(resizes(transport).count, 1, "nothing resized on a dead connection")
        XCTAssertTrue(host.stream.isClaimPending, "not taken for claimed")
        transport.connect()
        XCTAssertTrue(eventually { resizes(transport).count == 2 })
        XCTAssertTrue(eventually { !host.stream.isClaimPending })
        host.removeFromSuperview()
    }

    func testARefusedClaimShowsTheChip() {
        let pool = parkingPool()
        let transport = FakeFitTransport()
        transport.answers = ["own": [.refused]]
        let host = pooledHost(pool, key(1), transport: transport, sizing: .fit)
        host.frame = window.bounds
        window.addSubview(host)
        host.layoutIfNeeded()
        XCTAssertTrue(eventually { host.statusChipText == Self.lostText })
        XCTAssertFalse(host.stream.isClaimPending)
        XCTAssertFalse(transport.calls.contains { $0.hasPrefix("resize") })
        host.removeFromSuperview()
    }

    func testAnotherOwnerInTheSessionsViewShowsTheChip() throws {
        let pool = parkingPool()
        let transport = FakeFitTransport()
        let host = try echoedHost(pool, transport)
        host.fitCheckDelay = 0.1
        var owner = "client:phone"
        host.ownClientID = { "client:phone" }
        host.blockOwner = { owner }
        current(host)
        pause(0.3)
        XCTAssertNil(host.statusChipText, "ours")
        // The Mac app took the pane at the size the phone had: the size didn't change.
        let mine = try XCTUnwrap(host.claimWanted)
        owner = "client:mac"
        host.streamResized(cols: mine.cols, rows: mine.rows, owner: "client:mac")
        XCTAssertNil(host.statusChipText, "the same size is no news by itself")
        XCTAssertTrue(eventually(1) { host.statusChipText == Self.lostText }, "the view names another owner")
        XCTAssertTrue(drawnFits(host))
        host.removeFromSuperview()
    }

    func testTwoClientsTakingTurnsMakeNoLoop() throws {
        let pool = parkingPool()
        let transport = FakeFitTransport()
        let host = try echoedHost(pool, transport)
        host.fitCheckDelay = 0.1
        current(host)
        for round in 0..<3 {
            host.streamResized(cols: 211, rows: 57, owner: "client:mac")
            XCTAssertEqual(host.statusChipText, Self.lostText, "round \(round)")
            XCTAssertTrue(eventually { transport.calls.last == "disown" })
            let calls = transport.calls.count
            pause(0.3)
            XCTAssertEqual(transport.calls.count, calls, "the phone doesn't take it back by itself")
            tapChip(host)
            host.layoutIfNeeded()
            XCTAssertTrue(eventually { transport.calls.count == calls + 2 }, "one take and one resize per tap")
            let mine = try XCTUnwrap(resizes(transport).last)
            host.streamResized(cols: mine.cols, rows: mine.rows, owner: nil)
        }
        pause(0.3)
        XCTAssertEqual(takes(transport), 4, "the first claim and one per tap")
        host.removeFromSuperview()
    }

    func testAPaneTheServerGivesBackAtTheSizeThatFitsIsOursAgain() throws {
        // A dropped connection: the pane passes to the Mac and comes back when the phone
        // reconnects, at the phone's size.
        let pool = parkingPool()
        let transport = FakeFitTransport()
        let host = try echoedHost(pool, transport)
        host.ownClientID = { "client:phone" }
        let mine = try XCTUnwrap(host.claimWanted)
        current(host)
        host.streamResized(cols: 211, rows: 57, owner: "client:mac")
        XCTAssertEqual(host.statusChipText, Self.lostText)
        XCTAssertTrue(eventually { transport.calls.last == "disown" })
        let calls = transport.calls
        host.streamResized(cols: mine.cols, rows: mine.rows, owner: "client:phone")
        XCTAssertNil(host.statusChipText)
        XCTAssertTrue(drawnFits(host))
        pause(0.2)
        XCTAssertEqual(transport.calls, calls, "nothing to send: it is in place")
        // And given back as the app leaves, as any claim.
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        XCTAssertTrue(eventually { transport.calls.count == calls.count + 1 && transport.calls.last == "disown" })
        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        host.removeFromSuperview()
    }

    func testAMirrorPaneScalesAnotherClientsSizeAndNeverOwns() {
        let pool = parkingPool()
        let transport = FakeFitTransport()
        let host = pooledHost(pool, key(1), transport: transport, sizing: .mirror)
        host.frame = window.bounds
        window.addSubview(host)
        host.layoutIfNeeded()
        host.streamResized(cols: 211, rows: 57, owner: "client:mac")
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        host.layoutIfNeeded()
        pause(0.2)
        XCTAssertTrue(drawnFits(host), "scaled to the pane's width")
        XCTAssertEqual(transport.calls, [], "mirror never takes, resizes or gives back")
        host.removeFromSuperview()
    }
}

/// What a fitted pane on screen does when it looks at its grid.
final class FitCheckTests: XCTestCase {
    func testTheServersSizeIsTheOneClaimed() {
        XCTAssertEqual(FitCheck.verdict(claimed: (40, 20), server: (40, 20), fits: (40, 20), foreignOwner: false, claimedOnce: false), .fine)
    }

    func testAClaimTheServerKeptForLaterOrAnotherOwnerIsElsewhere() {
        XCTAssertEqual(FitCheck.verdict(claimed: (40, 20), server: (211, 57), fits: (40, 20), foreignOwner: false, claimedOnce: false), .elsewhere)
        XCTAssertEqual(FitCheck.verdict(claimed: (40, 20), server: (40, 20), fits: (40, 20), foreignOwner: true, claimedOnce: false), .elsewhere)
    }

    func testNothingClaimedAtAnotherSizeClaimsOnceThenGivesUp() {
        XCTAssertEqual(FitCheck.verdict(claimed: nil, server: (211, 57), fits: (40, 20), foreignOwner: false, claimedOnce: false), .claim)
        XCTAssertEqual(FitCheck.verdict(claimed: nil, server: (211, 57), fits: (40, 20), foreignOwner: false, claimedOnce: true), .elsewhere)
        XCTAssertEqual(FitCheck.verdict(claimed: nil, server: (40, 20), fits: (40, 20), foreignOwner: true, claimedOnce: false), .claim)
        XCTAssertEqual(FitCheck.verdict(claimed: nil, server: (40, 20), fits: (40, 20), foreignOwner: false, claimedOnce: false), .fine)
    }
}
