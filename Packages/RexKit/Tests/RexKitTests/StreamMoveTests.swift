import XCTest
@testable import RexKit

/// A pane whose tab moves to another session (`session.transfer_window`): the server ends the
/// stream opened through the old session, and the stream opens again through the new one, once,
/// with the screen kept behind the fence (docs/terminal.md, A tab that moves).
@MainActor
final class StreamMoveTests: XCTestCase {
    typealias Sink = StreamSnapshotHandoffTests.Sink
    private var streams: [TerminalStream] = []

    override func tearDown() async throws {
        for s in streams { s.stop() }
        streams = []
    }

    private func liveStream(_ link: FakeLink) async -> (TerminalStream, Sink) {
        let sink = Sink()
        let (stream, _) = makeStream(link: link, sink: sink)
        streams.append(stream)
        stream.start()
        let live = await eventually { sink.statuses.last == .live }
        XCTAssertTrue(live)
        // A screen, and the fence down: what a pane on screen has before its tab moves.
        await catchUp(stream, link)
        return (stream, sink)
    }

    private func sessions(_ link: FakeLink) -> [String] {
        link.calls.filter { $0.method == "data.connect" }.compactMap { $0.payload.str("session_id") }
    }

    func testTheEndOfAMovingStreamWaitsAndTheNewSessionOpensItOnce() async {
        let link = FakeLink()
        let (stream, sink) = await liveStream(link)
        stream.expectMove()
        // The server ends the stream through the session the tab left.
        link.sockets[0].drop(code: 4000)
        await settle()
        XCTAssertFalse(sink.statuses.contains(.ended("pane closed")), "the pane didn't close: its tab moved")
        XCTAssertFalse(sink.statuses.contains(.reconnecting))
        XCTAssertEqual(link.sockets.count, 1, "no RESUME and no start before the move's end")
        XCTAssertTrue(stream.isFenced)
        stream.moved(to: "session:other")
        let live = await eventually { link.sockets.count == 2 && sink.statuses.last == .live }
        XCTAssertTrue(live)
        XCTAssertTrue(link.sockets[1].isHello, "a fresh start: the old stream can't be resumed")
        XCTAssertEqual(sessions(link), ["session:test", "session:other"])
        XCTAssertEqual(stream.sessionID, "session:other")
        XCTAssertFalse(stream.isMoving)
    }

    func testAMoveWhoseAnswerComesFirstRestartsAndIgnoresTheLateEnd() async {
        let link = FakeLink()
        let (stream, sink) = await liveStream(link)
        stream.expectMove()
        stream.moved(to: "session:other")
        let live = await eventually { link.sockets.count == 2 && sink.statuses.last == .live }
        XCTAssertTrue(live)
        // The old stream's end arrives after the new one began.
        link.sockets[0].drop(code: 4000)
        await settle()
        XCTAssertEqual(sink.statuses.last, .live)
        XCTAssertFalse(sink.statuses.contains(.ended("pane closed")))
        XCTAssertEqual(link.sockets.count, 2)
        XCTAssertEqual(sessions(link), ["session:test", "session:other"])
    }

    func testAFailedMoveGoesOnAsTheDropWould() async {
        let link = FakeLink()
        let (stream, sink) = await liveStream(link)
        stream.expectMove()
        link.sockets[0].drop()
        await settle()
        XCTAssertEqual(link.sockets.count, 1)
        stream.moveFailed()
        let live = await eventually { link.sockets.count == 2 && sink.statuses.last == .live }
        XCTAssertTrue(live)
        XCTAssertTrue(link.sockets[1].isResume, "the stream stayed in its session: it resumes")
        XCTAssertEqual(stream.sessionID, "session:test")
    }

    func testAFailedMoveWithNoDropChangesNothing() async {
        let link = FakeLink()
        let (stream, sink) = await liveStream(link)
        stream.expectMove()
        stream.moveFailed()
        await settle()
        XCTAssertEqual(link.sockets.count, 1)
        XCTAssertEqual(sink.statuses, [.connecting, .live])
        XCTAssertFalse(stream.isFenced)
    }

    func testAParkedPaneThatMovedStartsThroughTheNewSessionWhenShown() async {
        let link = FakeLink()
        let (stream, sink) = await liveStream(link)
        stream.park()
        stream.moved(to: "session:other")
        await settle()
        XCTAssertEqual(link.sockets.count, 1, "nothing opens while parked")
        stream.unpark()
        let live = await eventually { link.sockets.count == 2 && sink.statuses.last == .live }
        XCTAssertTrue(live)
        XCTAssertTrue(link.sockets[1].isHello, "no RESUME of the stream the move ended")
        XCTAssertEqual(sessions(link), ["session:test", "session:other"])
    }

    func testQueuedInputIsNotSentThroughTheNewSession() async {
        let link = FakeLink()
        let (stream, _) = await liveStream(link)
        link.held = ["com.superlogical.terminal.write"]
        stream.send(text: "a")
        _ = await eventually { link.waitingCount == 1 }
        stream.send(text: "b")
        stream.expectMove()
        stream.moved(to: "session:other")
        link.held = []
        link.release()
        _ = await eventually { !stream.isFenced }
        await settle()
        XCTAssertEqual(link.written, ["a"], "what had left is not sent again, what waited is gone")
        XCTAssertFalse(stream.hasPendingInput)
    }
}
