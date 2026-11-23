import XCTest
@testable import RexKit

/// What a fresh start does with the socket it opened beside its ticket request (`EarlySocket`).
final class EarlySocketRuleTests: XCTestCase {
    private let young = Duration.seconds(1), limit = EarlySocket.ageLimit

    func testTheHelloGoesOnASocketThatIsOpenAndYoung() {
        XCTAssertEqual(EarlySocket.step(ticket: .arrived, ended: false, age: .zero), .hello)
        XCTAssertEqual(EarlySocket.step(ticket: .arrived, ended: false, age: limit - .milliseconds(1)), .hello)
    }

    func testATicketForASocketThatEndedOrGrewOldGoesOnANewOne() {
        XCTAssertEqual(EarlySocket.step(ticket: .arrived, ended: true, age: young), .freshSocket)
        XCTAssertEqual(EarlySocket.step(ticket: .arrived, ended: false, age: limit), .freshSocket)
        XCTAssertEqual(EarlySocket.step(ticket: .arrived, ended: false, age: .seconds(9)), .freshSocket)
    }

    func testAConflictKeepsAYoungSocketForWhatIsLeftOfItsAge() {
        XCTAssertEqual(EarlySocket.step(ticket: .conflict, ended: false, age: .zero), .keep(limit))
        XCTAssertEqual(EarlySocket.step(ticket: .conflict, ended: false, age: young), .keep(limit - young))
        XCTAssertEqual(EarlySocket.step(ticket: .conflict, ended: false, age: limit), .close)
        XCTAssertEqual(EarlySocket.step(ticket: .conflict, ended: true, age: young), .close)
    }

    func testAnyOtherFailureClosesTheSocket() {
        XCTAssertEqual(EarlySocket.step(ticket: .failed, ended: false, age: .zero), .close)
        XCTAssertEqual(EarlySocket.step(ticket: .failed, ended: true, age: young), .close)
    }

    /// The server ends a socket that has said nothing 5 s after its upgrade.
    func testTheAgeLimitLeavesASecondUnderTheServers() {
        XCTAssertEqual(EarlySocket.ageLimit, .seconds(4))
    }
}

/// The early socket in a stream's fresh start.
@MainActor
final class EarlySocketStreamTests: XCTestCase {
    typealias Sink = StreamSnapshotHandoffTests.Sink

    private var streams: [TerminalStream] = []
    private var conflict: RexError { RexError(code: "conflict", message: "stream is not attached to session", status: 409) }

    /// A stream whose clock the test moves.
    private func make(_ link: FakeLink) -> (TerminalStream, Sink, SleepLog, (Duration) -> Void) {
        let sink = Sink()
        let (stream, log) = makeStream(link: link, sink: sink)
        streams.append(stream)
        var time = ContinuousClock.now
        stream.now = { time }
        return (stream, sink, log, { time += $0 })
    }

    private func hellos(_ link: FakeLink) -> Int { link.sockets.filter(\.isHello).count }
    private func open(_ link: FakeLink) -> Int { link.sockets.filter { !$0.closed && !$0.aborted }.count }

    // MARK: Both orders

    /// The socket is open before the ticket is there: the HELLO waits for the ticket.
    func testTheSocketOpensBesideTheTicketRequestAndTheHelloWaitsForTheTicket() async {
        let link = FakeLink()
        link.held = ["data.connect"]
        let (stream, sink, _, _) = make(link)
        stream.start()
        let asked = await eventually { link.waitingCount == 1 }
        XCTAssertTrue(asked)
        XCTAssertEqual(link.sockets.count, 1, "opened in the turn the ticket was asked for")
        XCTAssertEqual(link.sockets[0].sent.count, 0, "no HELLO without its ticket")
        link.release()
        let live = await eventually { sink.statuses.last == .live }
        XCTAssertTrue(live)
        XCTAssertEqual(link.sockets.count, 1, "one socket")
        XCTAssertEqual(link.sockets[0].sent.count, 1, "one HELLO")
        XCTAssertTrue(link.sockets[0].isHello)
        XCTAssertEqual(link.count("data.connect"), 1)
    }

    /// The ticket is there at once: the HELLO goes on the socket opened beside it.
    func testATicketThatComesAtOnceGoesOnTheSameSocket() async {
        let link = FakeLink()
        let (stream, sink, _, _) = make(link)
        stream.start()
        let live = await eventually { sink.statuses.last == .live }
        XCTAssertTrue(live)
        XCTAssertEqual(link.sockets.count, 1)
        XCTAssertEqual(hellos(link), 1)
        XCTAssertEqual(link.count("data.connect"), 1)
    }

    // MARK: A conflict

    /// Refused once for a session not attached yet: the stream waits with its socket open.
    private func waitingForAttach(_ link: FakeLink) async -> (TerminalStream, Sink, SleepLog, (Duration) -> Void) {
        let (stream, sink, log, pass) = make(link)
        log.held = [TerminalStream.attachWaitCap]
        link.failures["data.connect"] = [conflict]
        stream.start()
        let waits = await eventually { link.attachWaits.waiting == 1 }
        XCTAssertTrue(waits)
        return (stream, sink, log, pass)
    }

    func testAnAttachInsideTheAgeLimitUsesTheEarlySocket() async {
        let link = FakeLink()
        let (_, sink, log, pass) = await waitingForAttach(link)
        XCTAssertEqual(link.sockets.count, 1)
        XCTAssertFalse(link.sockets[0].closed, "kept through the wait")
        XCTAssertEqual(link.sockets[0].sent.count, 0)
        pass(.seconds(3))
        link.attachWaits.attach(["session:test"])
        let live = await eventually { sink.statuses.last == .live }
        XCTAssertTrue(live)
        XCTAssertEqual(link.sockets.count, 1, "no second socket")
        XCTAssertEqual(hellos(link), 1)
        XCTAssertEqual(link.count("data.connect"), 2, "the ticket asked after the attach")
        XCTAssertEqual(log.backoffs, [], "not a failed start")
        log.release(TerminalStream.attachWaitCap)
        XCTAssertEqual(log.earlyAsked, [EarlySocket.ageLimit], "kept for its whole age limit")
        log.releaseEarly()
        await settle()
        XCTAssertFalse(link.sockets[0].closed, "the age limit of a socket in use does nothing")
    }

    /// The attach is answered, and the ticket after it comes when the socket is too old.
    func testATicketThatComesAfterTheAgeLimitGoesOnAFreshSocket() async {
        let link = FakeLink()
        let (_, sink, log, pass) = await waitingForAttach(link)
        link.held = ["data.connect"]
        link.attachWaits.attach(["session:test"])
        let asked = await eventually { link.waitingCount == 1 }
        XCTAssertTrue(asked)
        XCTAssertFalse(link.sockets[0].closed)
        pass(EarlySocket.ageLimit)
        link.release()
        let live = await eventually { sink.statuses.last == .live }
        XCTAssertTrue(live)
        XCTAssertEqual(link.sockets.count, 2, "a fresh one")
        XCTAssertTrue(link.sockets[0].closed, "the old one is closed")
        XCTAssertEqual(link.sockets[0].sent.count, 0)
        XCTAssertTrue(link.sockets[1].isHello)
        XCTAssertEqual(log.backoffs, [])
        log.release(TerminalStream.attachWaitCap)
    }

    /// The socket grows too old while the stream still waits: it is closed then, and the start
    /// that follows the attach opens its own.
    func testASocketThatGrowsOldDuringTheWaitIsClosedAndAFreshOneOpensAfterTheAttach() async {
        let link = FakeLink()
        let (_, sink, log, pass) = await waitingForAttach(link)
        pass(EarlySocket.ageLimit)
        log.releaseEarly()
        let closed = await eventually { link.sockets[0].closed }
        XCTAssertTrue(closed, "closed at its age limit")
        XCTAssertEqual(link.attachWaits.waiting, 1, "the wait goes on")
        XCTAssertEqual(link.sockets.count, 1)
        link.attachWaits.attach(["session:test"])
        let live = await eventually { sink.statuses.last == .live }
        XCTAssertTrue(live)
        XCTAssertEqual(link.sockets.count, 2)
        XCTAssertEqual(hellos(link), 1)
        XCTAssertEqual(log.backoffs, [])
        log.release(TerminalStream.attachWaitCap)
    }

    /// The server ends the idle socket during the wait (REJECT, or a close): one fresh socket
    /// for the ticket, and no failed start.
    func testASocketTheServerEndsDuringTheWaitIsReplacedOnceAndIsNoFailedStart() async {
        for rejected in [true, false] {
            let link = FakeLink()
            let (_, sink, log, _) = await waitingForAttach(link)
            if rejected { link.sockets[0].push([0x82, 0x05]) } else { link.sockets[0].drop(code: 1002) }
            await settle()
            XCTAssertEqual(link.sockets.count, 1, "nothing is opened while it waits")
            link.attachWaits.attach(["session:test"])
            let live = await eventually { sink.statuses.last == .live }
            XCTAssertTrue(live, "\(rejected)")
            XCTAssertEqual(link.sockets.count, 2, "one fresh socket: \(rejected)")
            XCTAssertTrue(link.sockets[0].closed)
            XCTAssertEqual(link.sockets[0].sent.count, 0, "no HELLO on a socket that ended")
            XCTAssertTrue(link.sockets[1].isHello)
            XCTAssertEqual(log.backoffs, [], "not counted toward the backoff")
            XCTAssertFalse(sink.statuses.contains { if case .failed = $0 { return true } else { return false } })
            log.release(TerminalStream.attachWaitCap)
            log.releaseEarly()
        }
    }

    /// The socket ended before the first ticket came: the same.
    func testASocketThatEndedBeforeTheTicketCameIsReplacedOnce() async {
        let link = FakeLink()
        link.held = ["data.connect"]
        let (stream, sink, log, _) = make(link)
        stream.start()
        let asked = await eventually { link.waitingCount == 1 }
        XCTAssertTrue(asked)
        link.sockets[0].drop()
        await settle()
        link.release()
        let live = await eventually { sink.statuses.last == .live }
        XCTAssertTrue(live)
        XCTAssertEqual(link.sockets.count, 2)
        XCTAssertEqual(link.sockets[0].sent.count, 0)
        XCTAssertEqual(link.count("data.connect"), 1, "the same ticket")
        XCTAssertEqual(log.backoffs, [])
    }

    /// The cap of the wait passes with no attach: no socket stays open over the retry's pause.
    func testTheCapOfTheWaitClosesTheSocket() async {
        let link = FakeLink()
        let (_, sink, log, _) = await waitingForAttach(link)
        log.held.insert(TerminalStream.attachRetryDelay)
        log.release(TerminalStream.attachWaitCap)
        let closed = await eventually { link.sockets[0].closed }
        XCTAssertTrue(closed)
        XCTAssertEqual(open(link), 0)
        log.release(TerminalStream.attachRetryDelay)
        let live = await eventually { sink.statuses.last == .live }
        XCTAssertTrue(live)
        XCTAssertEqual(link.sockets.count, 2)
    }

    // MARK: Other failures

    /// Any other failure of the ticket closes the socket at once; the start fails as before.
    func testAnotherTicketFailureClosesTheSocketAtOnce() async {
        let link = FakeLink()
        let (stream, sink, log, _) = make(link)
        log.held = [.seconds(3)]
        link.failures["data.connect"] = [RexError(code: "internal", message: "no", status: 500)]
        stream.start()
        let failed = await eventually { sink.statuses.contains { if case .failed = $0 { return true } else { return false } } }
        XCTAssertTrue(failed)
        XCTAssertEqual(link.sockets.count, 1)
        XCTAssertTrue(link.sockets[0].closed, "closed at once")
        XCTAssertEqual(link.sockets[0].sent.count, 0)
        XCTAssertEqual(log.backoffs, [.seconds(3)], "a failed start, as before")
        log.release(.seconds(3))
        let live = await eventually { sink.statuses.last == .live }
        XCTAssertTrue(live)
        XCTAssertEqual(link.sockets.count, 2)
    }

    /// A busy terminal's retries keep their order: a ticket, then a socket.
    func testABusyTerminalsRetryOpensItsSocketAfterItsTicket() async {
        let link = FakeLink()
        link.plans = [.reject(0x02)]
        let (stream, sink, _, _) = make(link)
        link.onOpen = { _ in
            // The first socket opens before any ticket came; the retry's opens after its own.
            XCTAssertEqual(link.count("data.connect"), link.sockets.count == 1 ? 0 : 2)
        }
        stream.start()
        let live = await eventually { sink.statuses.last == .live }
        XCTAssertTrue(live)
        XCTAssertEqual(link.sockets.count, 2)
        XCTAssertEqual(link.count("data.connect"), 2)
    }

    // MARK: No socket is left open

    func testParkStopAndRestartDuringTheWaitLeaveNoSocketOpen() async {
        for step in ["park", "stop", "restart"] {
            let link = FakeLink()
            let (stream, _, log, _) = await waitingForAttach(link)
            XCTAssertEqual(open(link), 1)
            if step == "restart" { link.held = ["data.connect"] }
            switch step {
            case "park": stream.park()
            case "stop": stream.stop()
            default: stream.restart()
            }
            XCTAssertTrue(link.sockets[0].closed, step)
            XCTAssertEqual(link.attachWaits.waiting, 0, step)
            await settle()
            // A restart starts again, with a socket of its own; the others leave nothing.
            XCTAssertEqual(open(link), step == "restart" ? 1 : 0, step)
            stream.stop()
            XCTAssertEqual(open(link), 0, step)
            log.release(TerminalStream.attachWaitCap)
            log.releaseEarly()
        }
    }

    func testStopParkAndRestartBeforeTheTicketCameLeaveNoSocketOpen() async {
        for step in ["park", "stop", "restart"] {
            let link = FakeLink()
            link.held = ["data.connect"]
            let (stream, _, _, _) = make(link)
            stream.start()
            let asked = await eventually { link.waitingCount == 1 }
            XCTAssertTrue(asked)
            XCTAssertEqual(open(link), 1)
            switch step {
            case "park": stream.park()
            case "stop": stream.stop()
            default: stream.restart()
            }
            XCTAssertTrue(link.sockets[0].closed, step)
            link.release()
            await settle()
            XCTAssertEqual(link.sockets[0].sent.count, 0, "the ticket of a start that is over goes nowhere: \(step)")
            stream.stop()
            XCTAssertEqual(open(link), 0, step)
        }
    }

    /// The control connection is lost while the stream waits: the wait ends, the socket closes,
    /// and nothing is opened or asked until the connection is back.
    func testALostConnectionDuringTheWaitClosesTheSocketAndOpensNoOther() async {
        let link = FakeLink()
        let (stream, sink, log, _) = await waitingForAttach(link)
        link.disconnect()
        let closed = await eventually { link.sockets[0].closed }
        XCTAssertTrue(closed)
        let waiting = await eventually { stream.waitingForControl }
        XCTAssertTrue(waiting)
        await settle()
        XCTAssertEqual(link.sockets.count, 1, "no socket toward a host that is not there")
        XCTAssertEqual(link.count("data.connect"), 1)
        link.connect()
        let live = await eventually { sink.statuses.last == .live }
        XCTAssertTrue(live)
        XCTAssertEqual(link.sockets.count, 2)
        log.release(TerminalStream.attachWaitCap)
        log.releaseEarly()
    }

    /// With no control connection nothing is opened: the gate comes first.
    func testNoEarlySocketWithoutTheControlConnection() async {
        let link = FakeLink(connected: false)
        let (stream, _, _, _) = make(link)
        stream.start()
        let waiting = await eventually { stream.waitingForControl }
        XCTAssertTrue(waiting)
        await settle()
        XCTAssertEqual(link.sockets.count, 0)
        XCTAssertEqual(link.count("data.connect"), 0)
    }
}
