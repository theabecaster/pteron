import XCTest
@testable import RexKit

/// Parking: a stream set aside for a pane that left the screen, and what its return costs.
@MainActor
final class StreamParkTests: XCTestCase {
    typealias Sink = StreamFenceTests.Sink
    private static let write = "com.superlogical.terminal.write"

    private var notices: [TerminalStream.Notice] = []
    private var streams: [TerminalStream] = []
    private var logs: [SleepLog] = []

    override func tearDown() async throws {
        for log in logs { log.release(.seconds(1)) }
        logs = []
    }

    private func current(_ link: FakeLink) async -> (TerminalStream, Sink, SleepLog) {
        let sink = Sink()
        let (s, log) = makeStream(link: link, sink: sink)
        // Held keys live a second in the app. Here that second does not pass by itself, so no
        // test's outcome depends on how fast the machine runs it; a test about the keys' life
        // sets a life of its own.
        log.held = [s.fence.timing.heldLife]
        logs.append(log)
        s.onActionFailed = { [weak self] in self?.notices.append($0) }
        streams.append(s)
        s.start()
        await catchUp(s, link)
        return (s, sink, log)
    }

    func testParkingDropsTheSocketWithoutEndingTheStream() async {
        let link = FakeLink()
        let (s, sink, _) = await current(link)
        s.park()
        XCTAssertTrue(s.isParked)
        XCTAssertTrue(link.sockets[0].aborted, "no status 1000: the server keeps the stream")
        XCTAssertFalse(link.sockets[0].closed)
        await settle()
        // Nothing follows: no RESUME, no ticket, no status.
        XCTAssertEqual(link.sockets.count, 1)
        XCTAssertEqual(link.count("data.connect"), 1)
        XCTAssertEqual(sink.statuses, [.connecting, .live])
        XCTAssertFalse(s.isFenced)
    }

    func testAParkedStreamDoesNothingOnAWakeOrAReconnect() async {
        let link = FakeLink()
        let (s, _, log) = await current(link)
        s.park()
        let asked = log.asked.count
        s.wake()
        link.disconnect()
        link.connect()
        await settle()
        XCTAssertEqual(link.sockets.count, 1)
        XCTAssertEqual(link.sockets[0].pings, 0)
        XCTAssertEqual(log.asked.count, asked, "no wait was started")
    }

    func testParkingDropsQueuedInputAndTakesNoMore() async {
        let link = FakeLink()
        let (s, _, _) = await current(link)
        link.held = [Self.write]
        s.send(text: "a")
        _ = await eventually { link.waitingCount == 1 }
        s.send(text: "b")
        s.park()
        XCTAssertFalse(s.hasPendingInput)
        XCTAssertFalse(s.send(text: "typed at a pane that is not on screen"))
        link.held = []
        link.release()
        await settle()
        s.unpark()
        _ = await eventually { !s.isFenced }
        await settle()
        XCTAssertEqual(link.written, ["a"], "what had left is not sent again, what had not is gone")
        XCTAssertEqual(notices, [])
    }

    /// `park()` with a request out that left in the key's turn (`StreamLink.start`). However
    /// it ends afterwards, nothing is in flight, nothing is sent again, nobody is told, and
    /// the pane that comes back takes the next key in that key's turn.
    func testParkingWithAKeyOutThatLeftInItsOwnTurnKeepsNothingOfIt() async {
        let ends: [(String, Error?)] = [
            ("answered", nil),
            ("never sent", RexError.unsent("socket is not connected")),
            ("lost", RexError.local("connection lost")),
        ]
        for (name, failure) in ends {
            let link = FakeLink()
            let (s, _, log) = await current(link)
            if let failure { link.failures[Self.write] = [failure] }
            let left = (failure as? RexError)?.neverSent == true ? [String]() : ["a"]
            s.send(text: "a")
            XCTAssertEqual(link.startedNow, 1, name)
            s.send(text: "b")
            s.park()
            XCTAssertFalse(s.hasPendingInput, name)
            await settle()
            XCTAssertFalse(s.hasPendingInput, name)
            XCTAssertEqual(link.written, left, name)
            s.unpark()
            let back = await eventually { !s.isFenced }
            XCTAssertTrue(back, name)
            await settle()
            XCTAssertEqual(link.written, left, "\(name): what had left is not sent again, what had not is gone")
            XCTAssertFalse(log.asked.contains(.milliseconds(250)), "\(name): no retry was asked for")
            s.send(text: "c")
            XCTAssertEqual(link.written, left + ["c"], name)
            XCTAssertEqual(link.startedNow, 2, name)
            let idle = await eventually { !s.hasPendingInput }
            XCTAssertTrue(idle, name)
            XCTAssertEqual(notices, [], name)
        }
    }

    func testTheReturnResumesAtOnceWithTheBytesTaken() async {
        let link = FakeLink()
        let (s, sink, log) = await current(link)
        link.sockets[0].push(Array("hello".utf8))
        _ = await eventually { sink.fed == 5 }
        s.park()
        let waits = log.asked.count
        link.plans = [.silent]
        s.unpark()
        XCTAssertTrue(s.isFenced, "up from the first moment")
        XCTAssertFalse(s.isParked)
        let resumed = await eventually { link.sockets.count == 2 && link.sockets[1].sent.count == 1 }
        XCTAssertTrue(resumed)
        XCTAssertTrue(link.sockets[1].isResume)
        XCTAssertEqual(link.sockets[1].resumeCount, UInt64(Wire.opening.count + 5))
        XCTAssertEqual(link.count("data.connect"), 1, "a resume needs no ticket")
        XCTAssertFalse(log.asked[waits...].contains(.milliseconds(400)), "and no pause before it")
        link.sockets[1].push(FakeLink.welcome())
        let down = await eventually { !s.isFenced }
        XCTAssertTrue(down)
        XCTAssertEqual(sink.statuses.last, .live)
    }

    /// A pane that returns while its host's control connection is down opens nothing: the
    /// control connection alone asks a host that may be away. It comes back with the welcome.
    func testTheReturnWaitsForTheControlConnection() async {
        let link = FakeLink()
        let (s, _, _) = await current(link)
        s.park()
        link.disconnect()
        s.unpark()
        await settle()
        XCTAssertEqual(link.sockets.count, 1, "no socket to a host whose control connection is down")
        XCTAssertTrue(s.waitingForControl)
        link.connect()
        let back = await eventually { link.sockets.count == 2 && !s.waitingForControl }
        XCTAssertTrue(back, "the welcome brings the pane back")
        let down = await eventually { !s.isFenced }
        XCTAssertTrue(down)
    }

    func testKeysTypedOnAnIdleReturnArriveInOrderOnce() async {
        let link = FakeLink()
        let (s, _, _) = await current(link)
        s.park()
        link.plans = [.silent]
        s.unpark()
        s.send(text: "l")
        s.send(text: "s\r")
        _ = await eventually { link.sockets.count == 2 && link.sockets[1].sent.count == 1 }
        XCTAssertEqual(link.written, [])
        link.sockets[1].push(FakeLink.welcome())
        let sent = await eventually { link.written == ["ls\r"] }
        XCTAssertTrue(sent)
        await settle()
        XCTAssertEqual(link.written, ["ls\r"])
        XCTAssertEqual(notices, [])
    }

    func testKeysTypedOnABusyReturnAreDroppedWithTheNotice() async {
        let link = FakeLink()
        let (s, sink, _) = await current(link)
        s.park()
        link.plans = [.silent]
        s.unpark()
        s.send(text: "y\r")
        _ = await eventually { link.sockets.count == 2 && link.sockets[1].sent.count == 1 }
        link.sockets[1].push(FakeLink.welcome())
        link.sockets[1].push(Array("output the user never saw".utf8))
        let down = await eventually { !s.isFenced && sink.fed > 0 }
        XCTAssertTrue(down)
        await settle()
        XCTAssertEqual(link.written, [])
        XCTAssertEqual(notices, [.paneChanged])
    }

    // Hazard 9.
    func testAReturnAfterTheResumeWindowStartsFreshAndStaysFenced() async {
        let link = FakeLink()
        link.defaultPlan = .welcome(keepMs: 0)
        let (s, sink, _) = await current(link)
        s.park()
        s.unpark()
        s.send(text: "typed at the old screen")
        let fresh = await eventually { link.sockets.count == 2 && sink.statuses.last == .live }
        XCTAssertTrue(fresh)
        XCTAssertTrue(link.sockets[1].isHello)
        XCTAssertEqual(link.count("data.connect"), 2)
        await settle()
        XCTAssertTrue(s.isFenced, "until the new snapshot is in")
        await catchUp(s, link)
        await settle()
        XCTAssertEqual(link.written, [])
        XCTAssertEqual(notices, [.paneChanged])
    }

    // Hazard 9.
    func testARefusedResumeOnReturnStartsFresh() async {
        let link = FakeLink()
        let (s, sink, _) = await current(link)
        s.park()
        link.plans = [.reject(0x01)]
        s.unpark()
        let fresh = await eventually { link.sockets.count == 3 && link.sockets[2].isHello && sink.statuses.last == .live }
        XCTAssertTrue(fresh)
        XCTAssertTrue(link.sockets[1].isResume)
        XCTAssertTrue(s.isFenced)
        XCTAssertEqual(sink.fence, [true, false, true], "one fence from the return to the new snapshot")
        await catchUp(s, link)
    }

    func testStopAfterParkingEndsTheStreamForGood() async {
        let link = FakeLink()
        let (s, _, _) = await current(link)
        s.park()
        s.stop()
        XCTAssertFalse(s.isParked)
        s.unpark()
        await settle()
        XCTAssertEqual(link.sockets.count, 1, "a stopped stream does not come back by itself")
        XCTAssertFalse(s.isFenced)
    }

    func testParkingTwiceAndUnparkingALiveStreamChangeNothing() async {
        let link = FakeLink()
        let (s, _, _) = await current(link)
        s.unpark()
        await settle()
        XCTAssertEqual(link.sockets.count, 1)
        s.park()
        s.park()
        s.unpark()
        s.unpark()
        let down = await eventually { !s.isFenced && link.sockets.count == 2 }
        XCTAssertTrue(down)
        await settle()
        XCTAssertEqual(link.sockets.count, 2)
    }

    func testAStreamParkedInTheMiddleOfItsSnapshotGoesOnWithIt() async {
        let link = FakeLink()
        let sink = Sink()
        let (s, _) = makeStream(link: link, sink: sink)
        streams.append(s)
        s.start()
        _ = await eventually { sink.statuses.last == .live }
        let half = Wire.opening.count / 2
        link.sockets[0].push(Array(Wire.opening[..<half]))
        await settle()
        s.park()
        link.plans = [.silent]
        s.unpark()
        _ = await eventually { link.sockets.count == 2 && link.sockets[1].sent.count == 1 }
        XCTAssertEqual(link.sockets[1].resumeCount, UInt64(half))
        link.sockets[1].push(FakeLink.welcome())
        link.sockets[1].push(Array(Wire.opening[half...]))
        let down = await eventually { !s.isFenced }
        XCTAssertTrue(down, "the snapshot's end arrives over the resumed stream")
    }

    // MARK: A stream that went on unseen

    func testAReturnToARunningStreamIsFencedOnlyUntilItIsQuiet() async {
        let link = FakeLink()
        let (s, sink, _) = await current(link)
        s.returned()
        XCTAssertTrue(s.isFenced)
        s.send(text: "ls\r")
        let sent = await eventually { link.written == ["ls\r"] }
        XCTAssertTrue(sent, "the screen was the stream's own: the keys go")
        XCTAssertFalse(s.isFenced)
        XCTAssertEqual(link.sockets.count, 1, "no resume, no ticket: the stream never stopped")
        XCTAssertEqual(sink.statuses, [.connecting, .live])
        XCTAssertEqual(notices, [])
    }

    func testAReturnWithAClaimOnItsWayWaitsForItAndDropsKeysWhenTheSizeChanges() async {
        let link = FakeLink()
        let (s, _, log) = await current(link)
        // The held keys' life does not run out here, however slow the machine.
        log.held = [s.fence.timing.heldLife]
        defer { log.release(s.fence.timing.heldLife) }
        s.setClaimPending(true)
        s.returned()
        s.send(text: "k")
        await settle()
        XCTAssertTrue(s.isFenced, "the lapsed claim is being made again")
        link.sockets[0].push(Wire.resize(cols: 60, rows: 40, owner: "client:test"))
        s.setClaimPending(false)
        let down = await eventually { !s.isFenced }
        XCTAssertTrue(down)
        await settle()
        XCTAssertEqual(link.written, [])
        XCTAssertEqual(notices, [.paneChanged])
    }

    func testAReturnToAStreamThatIsNotLiveChangesNothing() async {
        let link = FakeLink()
        let (s, sink, _) = await current(link)
        link.plans = [.silent]
        link.sockets[0].drop()
        _ = await eventually { s.isFenced }
        let before = sink.fence
        s.returned()
        XCTAssertEqual(sink.fence, before, "it is fenced already, until its resume")
        XCTAssertTrue(s.isFenced)
    }
}
