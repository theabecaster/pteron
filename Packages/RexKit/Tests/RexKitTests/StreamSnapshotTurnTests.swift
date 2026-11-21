import XCTest
@testable import RexKit

/// One fresh snapshot at a time for a host's unseen panes on cellular (`SnapshotTurns`): a pane on
/// screen never waits, nothing changed on Wi-Fi, and a turn that is always given back, whatever becomes of
/// the stream that holds it.
@MainActor
final class StreamSnapshotTurnTests: XCTestCase {
    typealias Sink = StreamSnapshotHandoffTests.Sink

    private var control: RexControl!
    private var link: FakeLink!
    private var streams: [String: TerminalStream] = [:]
    private var sinks: [String: Sink] = [:]
    /// The turn's own limit: it passes only when a test says so.
    private var limit: DeadlineGate!

    override func setUp() async throws {
        control = RexControl(address: "http://127.0.0.1:9", client: ClientInfo(name: "test", version: "0", label: "test"))
        link = FakeLink()
        limit = DeadlineGate()
        let gate = limit!
        control.snapshotTurns.sleep = { await gate.sleep(.milliseconds(Int64($0 * 1000))) }
        streams = [:]
        sinks = [:]
    }

    override func tearDown() async throws {
        for s in streams.values { s.stop() }
        limit.pass()
        await settle()
    }

    private func cellular(_ on: Bool = true) {
        control.pathChanged(satisfied: true, expensive: on, interfaceChanged: false)
    }

    /// A pane's stream on the one host, started.
    @discardableResult
    private func start(_ block: String, onScreen: Bool = true) -> TerminalStream {
        let s = TerminalStream(control: control, link: link, sessionID: "session:test", blockID: block)
        let sink = Sink()
        s.sink = sink
        SleepLog().attach(to: s)
        s.isOnScreen = onScreen
        streams[block] = s
        sinks[block] = sink
        s.start()
        return s
    }

    /// The panes whose fresh start has asked for its ticket, in order.
    private var started: [String] {
        link.calls.filter { $0.method == "data.connect" }.compactMap { $0.payload.str("block_id") }
    }

    private func wait(_ blocks: [String], _ message: String = "", line: UInt = #line) async {
        let ok = await eventually { self.started == blocks }
        XCTAssertTrue(ok, "\(message) started \(started), expected \(blocks)", line: line)
        await settle()
        XCTAssertEqual(started, blocks, message, line: line)
    }

    /// The snapshot of the pane whose socket was opened as number `n` arrives whole.
    private func finishSnapshot(_ n: Int) {
        link.sockets[n].push(Wire.opening)
    }

    private var turns: SnapshotTurns { control.snapshotTurns }

    // MARK: Cellular: unseen panes one at a time, the pane on screen never waits

    func testOnCellularUnseenPanesGoOneAtATimeAndAPaneOnScreenStartsAtOnce() async {
        cellular()
        start("h1", onScreen: false)
        start("h2", onScreen: false)
        // An unseen pane holds the turn and another waits: the pane on screen does not.
        start("seen")
        let both = await eventually { Set(self.started) == ["h1", "seen"] }
        XCTAssertTrue(both, "the pane on screen started at once, beside the holder: \(started)")
        await settle()
        XCTAssertEqual(Set(started), ["h1", "seen"])
        XCTAssertEqual(turns.waitingCount, 1, "only the second unseen pane waits")
        // A second pane on screen starts at once too.
        start("seen2")
        let three = await eventually { self.started.contains("seen2") }
        XCTAssertTrue(three)
        XCTAssertFalse(started.contains("h2"))
        // The holder's snapshot ends: the unseen pane that waited starts.
        finishSnapshot(started.firstIndex(of: "h1")!)
        let next = await eventually { self.started.contains("h2") }
        XCTAssertTrue(next)
        finishSnapshot(started.firstIndex(of: "h2")!)
        let free = await eventually { !self.turns.isHeld }
        XCTAssertTrue(free, "the last one gave its turn back")
        XCTAssertEqual(turns.waitingCount, 0)
    }

    func testAPaneThatComesOnScreenWhileItWaitsStartsThen() async {
        cellular()
        start("h1", onScreen: false)
        let h2 = start("h2", onScreen: false)
        start("h3", onScreen: false)
        await wait(["h1"])
        XCTAssertEqual(turns.waitingCount, 2)
        h2.isOnScreen = true
        await wait(["h1", "h2"], "it gave its place up and started")
        XCTAssertTrue(turns.isHeld, "the holder still holds")
        XCTAssertEqual(turns.waitingCount, 1, "and the other unseen pane still waits")
        finishSnapshot(0)
        await wait(["h1", "h2", "h3"])
    }

    func testAHolderThatComesOnScreenKeepsItsTurnUntilItsSnapshotEnds() async {
        cellular()
        let h1 = start("h1", onScreen: false)
        start("h2", onScreen: false)
        await wait(["h1"])
        h1.isOnScreen = true
        await settle()
        XCTAssertEqual(started, ["h1"], "one fresh snapshot of the two is still under way")
        finishSnapshot(0)
        await wait(["h1", "h2"])
    }

    func testOnCellularPanesOnScreenTakeNoTurn() async {
        cellular()
        start("a")
        start("b")
        let both = await eventually { self.link.sockets.count == 2 }
        XCTAssertTrue(both)
        XCTAssertFalse(turns.isHeld)
        XCTAssertTrue(limit.asked.isEmpty)
    }

    // MARK: Wi-Fi: nothing changes

    func testOnWiFiPanesStartTogetherAndNobodyTakesATurn() async {
        start("a")
        start("b")
        start("c", onScreen: false)
        let all = await eventually { self.link.sockets.count == 3 }
        XCTAssertTrue(all, "three sockets with no snapshot in yet")
        XCTAssertEqual(Set(started), ["a", "b", "c"])
        XCTAssertFalse(turns.isHeld)
        XCTAssertEqual(turns.waitingCount, 0)
        XCTAssertTrue(limit.asked.isEmpty, "no turn, so no limit either")
    }

    func testLeavingCellularStartsEveryoneWhoWaited() async {
        cellular()
        start("a", onScreen: false)
        start("b", onScreen: false)
        start("c", onScreen: false)
        await wait(["a"])
        cellular(false)
        let all = await eventually { Set(self.started) == ["a", "b", "c"] }
        XCTAssertTrue(all)
        XCTAssertFalse(turns.isHeld)
        XCTAssertEqual(turns.waitingCount, 0)
    }

    // MARK: A turn is always given back

    /// With `a` holding the turn and `b` waiting, `body` happens to `a`. Then `b` must start.
    private func holderThen(_ name: String, _ body: (TerminalStream) -> Void, line: UInt = #line) async {
        cellular()
        let a = start("a", onScreen: false)
        start("b", onScreen: false)
        await wait(["a"], name, line: line)
        XCTAssertEqual(turns.waitingCount, 1, name, line: line)
        body(a)
        let next = await eventually { self.started.contains("b") }
        XCTAssertTrue(next, "\(name): the turn was not given back", line: line)
    }

    func testAStoppedHolderGivesTheTurnBack() async {
        await holderThen("stop") { $0.stop() }
        XCTAssertEqual(started, ["a", "b"])
    }

    func testAParkedHolderGivesTheTurnBack() async {
        await holderThen("park") { $0.park() }
        XCTAssertEqual(started, ["a", "b"])
    }

    func testARestartedHolderGivesTheTurnBackAndTakesANewOneBehind() async {
        await holderThen("restart") { $0.restart() }
        XCTAssertEqual(started, ["a", "b"], "b first; a waits its new turn")
        XCTAssertEqual(turns.waitingCount, 1)
        finishSnapshot(1)
        await wait(["a", "b", "a"])
    }

    func testAHolderWhoseSocketDropsGivesTheTurnBack() async {
        await holderThen("drop") { _ in self.link.sockets[0].drop() }
    }

    func testAHolderWhoseHostDiedGivesTheTurnBack() async {
        await holderThen("host died") { $0.hostDied() }
    }

    func testAHolderWhoseSnapshotCantBeRestoredGivesTheTurnBack() async {
        await holderThen("snapshot refused") { _ in
            self.sinks["a"]?.answer = { _ in false }
            self.finishSnapshot(0)
        }
    }

    func testAHolderThatSaysItsSnapshotFailedGivesTheTurnBack() async {
        await holderThen("restore failed") { $0.snapshotRestoreFailed() }
    }

    func testAHolderWhoseStartIsRefusedGivesTheTurnBack() async {
        cellular()
        link.plans = [.reject(0x01)]
        start("a", onScreen: false)
        start("b", onScreen: false)
        let next = await eventually { self.started.contains("b") }
        XCTAssertTrue(next, "a refused HELLO is a failed start: the turn goes on")
    }

    func testInTheBackgroundNobodyHoldsOrWaits() async {
        cellular()
        start("a", onScreen: false)
        start("b", onScreen: false)
        await wait(["a"])
        control.enteredBackground()
        let free = await eventually { !self.turns.isHeld && self.turns.waitingCount == 0 }
        XCTAssertTrue(free, "the holder and the waiter both gave their places back")
        await settle()
        XCTAssertEqual(started, ["a"], "and nothing started there")
    }

    func testAWaiterThatStopsLeavesTheQueue() async {
        cellular()
        start("a", onScreen: false)
        let b = start("b", onScreen: false)
        start("c", onScreen: false)
        await wait(["a"])
        b.stop()
        await settle()
        XCTAssertEqual(turns.waitingCount, 1)
        finishSnapshot(0)
        await wait(["a", "c"], "c, not the pane that stopped")
    }

    /// The backstop: whatever a holder does or fails to do, its turn ends by itself after the
    /// limit, and the next pane starts beside it. The holder's own snapshot is not cut off.
    func testATurnEndsByItselfAfterItsLimit() async {
        cellular()
        start("a", onScreen: false)
        start("b", onScreen: false)
        await wait(["a"])
        XCTAssertEqual(limit.asked, [.seconds(15)], "one wait, the cellular connect deadline")
        limit.pass()
        await wait(["a", "b"], "the next one starts with the first still open")
        XCTAssertFalse(link.sockets[0].closed)
        XCTAssertFalse(link.sockets[0].aborted)
        // The first one's snapshot still lands, and its late end takes nobody's turn away.
        finishSnapshot(0)
        let shown = await eventually { self.streams["a"]?.isFenced == false }
        XCTAssertTrue(shown)
        XCTAssertTrue(turns.isHeld, "b still holds its own")
        finishSnapshot(1)
        let free = await eventually { !self.turns.isHeld }
        XCTAssertTrue(free)
    }

    // MARK: The turns themselves

    func testATurnGivenBackTwiceOrNeverTakenChangesNothing() async {
        let t = SnapshotTurns()
        let a = SnapshotTurns.Turn(), b = SnapshotTurns.Turn()
        t.give(a)
        await t.take(a)
        XCTAssertTrue(t.holds(a))
        t.give(b)
        XCTAssertTrue(t.holds(a), "another's turn is not this one's to give")
        t.give(a)
        t.give(a)
        XCTAssertFalse(t.isHeld)
        await t.take(b)
        XCTAssertTrue(t.holds(b))
    }
}
