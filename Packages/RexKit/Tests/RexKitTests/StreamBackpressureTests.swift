import XCTest
@testable import RexKit

/// `pauseReading()` and `resumeReading()`: a paused stream asks its data socket for nothing,
/// and goes on in order when resumed.
@MainActor
final class StreamBackpressureTests: XCTestCase {
    typealias Sink = StreamSnapshotHandoffTests.Sink
    private static let write = "com.superlogical.terminal.write"

    /// Nothing else owns a stream: its tasks hold it weakly, as in the app.
    private var streams: [TerminalStream] = []

    /// The start of a fresh stream: a (tiny) snapshot and the resize message that follows it.
    private static let snapshot = Snapshots.envelope + Snapshots.record(tag: 1, payload: [1, 2, 3])
        + Snapshots.record(tag: 5) + Snapshots.record(tag: 6)
    private static func message(_ json: String) -> [UInt8] { Array("\u{1b}_rex1;\(FakeLink.nonce);\(json)\u{1b}\\".utf8) }
    private static let head = snapshot + message(#"{"type":"resize","cols":90,"rows":30,"owner":null}"#)

    /// A live stream that has taken `head`, and what its sink had seen by then.
    private func liveStream(_ link: FakeLink) async -> (TerminalStream, Sink, FakeSocket, [Sink.Call]) {
        let sink = Sink()
        let (stream, _) = makeStream(link: link, sink: sink)
        streams.append(stream)
        stream.start()
        let live = await eventually { sink.statuses.last == .live }
        XCTAssertTrue(live)
        let socket = link.sockets[0]
        socket.push(Self.head)
        let resized = await eventually { sink.calls.last == .resized(90, 30, nil) }
        XCTAssertTrue(resized)
        await settle()
        return (stream, sink, socket, sink.calls)
    }

    func testPausedStreamReadsNothingAndGoesOnInOrderWhenResumed() async {
        let link = FakeLink()
        let (stream, sink, socket, head) = await liveStream(link)
        // The loop is waiting for its next message.
        let asked = socket.receives
        stream.pauseReading()
        XCTAssertTrue(stream.readingPaused)

        // The read that was already under way still delivers; no other is started.
        socket.push(Array("one ".utf8))
        await settle()
        XCTAssertEqual(sink.calls, head + [.feed(Array("one ".utf8))])
        XCTAssertEqual(socket.receives, asked)

        // The server goes on sending: nothing is taken, nothing reaches the sink.
        socket.push(Array("two ".utf8))
        socket.push(Self.message(#"{"type":"resize","cols":70,"rows":20,"owner":null}"#))
        socket.push(Array("three".utf8))
        await settle()
        XCTAssertEqual(sink.calls, head + [.feed(Array("one ".utf8))])
        XCTAssertEqual(socket.receives, asked)

        stream.resumeReading()
        XCTAssertFalse(stream.readingPaused)
        let all = head + [.feed(Array("one two ".utf8)), .resized(70, 20, nil), .feed(Array("three".utf8))]
        let caught = await eventually { sink.calls == all }
        XCTAssertTrue(caught, "\(sink.calls.dropFirst(head.count))")
        XCTAssertEqual(sink.statuses, [.connecting, .live])
        // And it reads as before: one read per message, and one waiting.
        XCTAssertEqual(socket.receives, asked + 4)
    }

    func testPausingTwiceAndResumingWithoutAPauseAreHarmless() async {
        let link = FakeLink()
        let (stream, sink, socket, head) = await liveStream(link)
        stream.resumeReading()
        stream.pauseReading()
        stream.pauseReading()
        socket.push([0x61])
        socket.push([0x62])
        await settle()
        XCTAssertEqual(sink.calls, head + [.feed([0x61])])
        stream.resumeReading()
        stream.resumeReading()
        let caught = await eventually { sink.calls == head + [.feed([0x61, 0x62])] }
        XCTAssertTrue(caught)
    }

    /// A RESUME gives the bytes the stream took, not those the server sent: what waited in the
    /// socket while reading was paused is counted only once it is read.
    func testResumeCountsOnlyWhatWasTaken() async {
        let link = FakeLink()
        let (stream, sink, socket, _) = await liveStream(link)
        stream.pauseReading()
        socket.push([1, 2, 3])  // the read under way
        socket.push([4, 5])  // waits in the socket
        await settle()
        // The connection drops while paused: nobody is reading, so nobody notices yet.
        socket.drop()
        await settle()
        XCTAssertEqual(sink.statuses, [.connecting, .live])
        XCTAssertEqual(link.sockets.count, 1)

        stream.resumeReading()
        let resumed = await eventually { link.sockets.count == 2 && sink.statuses.last == .live }
        XCTAssertTrue(resumed)
        XCTAssertEqual(sink.statuses, [.connecting, .live, .reconnecting, .live])
        XCTAssertTrue(link.sockets[1].isResume)
        XCTAssertEqual(link.sockets[1].resumeCount, UInt64(Self.head.count + 5))
    }

    func testInputAndControlCallsGoOutWhilePaused() async {
        let link = FakeLink()
        let (stream, _, socket, _) = await liveStream(link)
        stream.pauseReading()
        stream.send(text: "ls\r")
        stream.perform(action: "pane.clear", args: nil) { _ in }
        let sent = await eventually { link.inputTrace == ["w:ls\r", "client.action"] }
        XCTAssertTrue(sent, "\(link.inputTrace)")
        XCTAssertFalse(socket.closed)
    }

    func testStopEndsAPausedStreamAndALaterStartIsStillPaused() async {
        let link = FakeLink()
        let (stream, sink, socket, head) = await liveStream(link)
        stream.pauseReading()
        socket.push([0x61])
        await settle()
        stream.stop()
        await settle()
        XCTAssertTrue(socket.closed)
        XCTAssertTrue(stream.readingPaused, "only resumeReading() ends a pause")

        // The next stream handshakes as usual and then waits to be resumed.
        stream.start()
        let live = await eventually { link.sockets.count == 2 && sink.statuses.last == .live }
        XCTAssertTrue(live)
        let second = link.sockets[1]
        second.push(Self.head)
        await settle()
        XCTAssertEqual(second.receives, 1, "the WELCOME only")
        XCTAssertEqual(sink.calls, head + [.feed([0x61])])
        stream.resumeReading()
        let caught = await eventually { sink.calls.count == head.count * 2 + 1 }
        XCTAssertTrue(caught)
    }

    func testRestartWhilePausedOpensAFreshStreamThatWaits() async {
        let link = FakeLink()
        let (stream, sink, socket, head) = await liveStream(link)
        stream.pauseReading()
        stream.restart()
        let live = await eventually { link.sockets.count == 2 && sink.statuses.last == .live }
        XCTAssertTrue(live)
        XCTAssertTrue(socket.closed)
        XCTAssertTrue(link.sockets[1].isHello)
        link.sockets[1].push(Self.head)
        await settle()
        XCTAssertEqual(sink.calls, head)
        stream.resumeReading()
        let caught = await eventually { sink.calls == head + head }
        XCTAssertTrue(caught)
    }
}
