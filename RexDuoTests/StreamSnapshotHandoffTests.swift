import XCTest
@testable import RexDuo

/// What `TerminalStream` tells its sink for a stream's bytes, with no server: the tests start a
/// stream as a WELCOME would and feed it recorded chunks.
@MainActor
final class StreamSnapshotHandoffTests: XCTestCase {
    final class Sink: TerminalSink {
        enum Call: Equatable {
            case reset(Int, Int)
            case snapshot(Int)
            case ghostty(StreamEvent)
            case feed([UInt8])
            case resized(Int, Int, String?)
            case theme
            case exited

            var isGhostty: Bool { if case .ghostty = self { return true } else { return false } }
        }
        var calls: [Call] = []
        /// Answers each snapshot part; true by default.
        var answer: (StreamEvent) -> Bool = { _ in true }

        var statuses: [TerminalStream.Status] = []
        /// Runs inside `streamFeed` and `streamResized`, after the call is recorded.
        var during: ((Call) -> Void)?

        func streamReset(cols: Int, rows: Int) { calls.append(.reset(cols, rows)) }
        func streamSnapshot(_ text: String) { calls.append(.snapshot(text.utf8.count)) }
        func streamGhosttySnapshot(_ part: GhosttySnapshotPart) -> Bool {
            let e = StreamEvent(part)
            if case .snapshotBytes(let more) = e, case .ghostty(.snapshotBytes(let have))? = calls.last {
                calls[calls.count - 1] = .ghostty(.snapshotBytes(have + more))
            } else {
                calls.append(.ghostty(e))
            }
            return answer(e)
        }
        func streamFeed(_ bytes: UnsafeBufferPointer<UInt8>) {
            if case .feed(let have)? = calls.last {
                calls[calls.count - 1] = .feed(have + Array(bytes))
            } else {
                calls.append(.feed(Array(bytes)))
            }
            during?(.feed(Array(bytes)))
        }
        func streamResized(cols: Int, rows: Int, owner: String?) {
            calls.append(.resized(cols, rows, owner))
            during?(.resized(cols, rows, owner))
        }
        func streamTheme(_ theme: JSONObject) { calls.append(.theme) }
        func streamExited(code: Int?) { calls.append(.exited) }
        func streamStatus(_ status: TerminalStream.Status) { statuses.append(status) }

        var ghostty: [StreamEvent] { calls.compactMap { if case .ghostty(let e) = $0 { return e } else { return nil } } }
    }

    /// A sink that doesn't know about Ghostty snapshots, like TerminalHost today.
    final class OldSink: TerminalSink {
        var fed = 0
        func streamReset(cols: Int, rows: Int) {}
        func streamSnapshot(_ text: String) {}
        func streamFeed(_ bytes: UnsafeBufferPointer<UInt8>) { fed += bytes.count }
        func streamResized(cols: Int, rows: Int, owner: String?) {}
        func streamTheme(_ theme: JSONObject) {}
        func streamExited(code: Int?) {}
        func streamStatus(_ status: TerminalStream.Status) {}
    }

    private func makeStream(_ sink: TerminalSink) -> TerminalStream {
        // Never connected: nothing here reaches a server.
        let s = TerminalStream(control: RexControl(baseURL: URL(string: "http://127.0.0.1:9")!), sessionID: "session:test", blockID: "block:test")
        s.sink = sink
        s.restoresGhosttySnapshot = true
        return s
    }

    private func feed(_ stream: TerminalStream, _ bytes: [UInt8], chunk: Int) {
        var at = 0
        while at < bytes.count {
            let end = min(at + chunk, bytes.count)
            stream.consume(Data(bytes[at..<end]))
            at = end
        }
    }

    func testFreshStreamHandsOverTheSnapshotThenTheResizeThenOutput() throws {
        for name in StreamFixture.names {
            let fx = try StreamFixture.load(name)
            var perChunkSize: [[Sink.Call]] = []
            for chunk in [fx.bytes.count, 1, 7, 1000] {
                let sink = Sink(), stream = makeStream(sink)
                stream.beginStream(nonce: fx.nonce, collectSnapshot: true)
                feed(stream, fx.bytes, chunk: chunk)

                // begin, bytes through READY, ready, history, end: then the resize.
                let parts = Snapshots.parts(fx.bytes)
                XCTAssertEqual(parts.count, 5)
                XCTAssertEqual(Array(sink.calls.prefix(5)), parts.map { .ghostty($0) }, name)
                XCTAssertEqual(sink.ghostty.count, 5, name)
                guard case .resized(let cols, let rows, let owner)? = sink.calls.dropFirst(5).first else {
                    return XCTFail("\(name): the resize must follow the snapshot")
                }
                XCTAssertEqual(cols, 80); XCTAssertEqual(rows, 24)
                XCTAssertEqual(owner?.hasPrefix("client:"), true)
                XCTAssertEqual(stream.serverCols, name == "resize" ? 61 : 80)
                XCTAssertEqual(stream.serverRows, name == "resize" ? 19 : 24)
                XCTAssertFalse(stream.ghosttySnapshotFailed)
                // No reset and no terminal.format snapshot on this path.
                XCTAssertFalse(sink.calls.contains { if case .reset = $0 { return true }; if case .snapshot = $0 { return true }; return false })
                perChunkSize.append(sink.calls)
            }
            XCTAssertTrue(perChunkSize.allSatisfy { $0 == perChunkSize[0] }, name)
        }
    }

    func testFlagOffSeesTheSameCallsWithoutTheSnapshot() throws {
        for name in StreamFixture.names {
            let fx = try StreamFixture.load(name)
            let onSink = Sink(), on = makeStream(onSink)
            on.beginStream(nonce: fx.nonce, collectSnapshot: true)
            feed(on, fx.bytes, chunk: 512)

            let offSink = Sink(), off = makeStream(offSink)
            off.restoresGhosttySnapshot = false
            off.beginStream(nonce: fx.nonce, collectSnapshot: false)
            feed(off, fx.bytes, chunk: 512)

            XCTAssertFalse(offSink.calls.contains(where: \.isGhostty), name)
            XCTAssertEqual(onSink.calls.filter { !$0.isGhostty }, offSink.calls, name)
            XCTAssertFalse(off.ghosttySnapshotFailed)
        }
    }

    func testSinkThatRefusesAtBeginGetsNoMoreParts() throws {
        let fx = try StreamFixture.load("scroll")
        let sink = Sink(), stream = makeStream(sink)
        sink.answer = { _ in false }
        stream.beginStream(nonce: fx.nonce, collectSnapshot: true)
        feed(stream, fx.bytes, chunk: 300)
        XCTAssertTrue(stream.ghosttySnapshotFailed)
        XCTAssertEqual(sink.ghostty, [.snapshotBegin])
        guard case .resized(80, 24, _)? = sink.calls.dropFirst().first else { return XCTFail("\(sink.calls.prefix(3))") }

        // The next fresh stream doesn't offer one, even if it was opened to pass it.
        sink.calls = []
        sink.answer = { _ in true }
        stream.beginStream(nonce: fx.nonce, collectSnapshot: true)
        feed(stream, fx.bytes, chunk: 300)
        XCTAssertTrue(sink.ghostty.isEmpty)
        guard case .resized(80, 24, _)? = sink.calls.first else { return XCTFail("expected the resize first: \(sink.calls.prefix(2))") }
    }

    func testSinkThatFailsPartwayGetsNoMoreParts() throws {
        let fx = try StreamFixture.load("scroll")
        // At `ready` (a decoder that rejects the renderable part), and at the end.
        for failAt in [StreamEvent.snapshotReady, .snapshotEnd(true)] {
            let sink = Sink(), stream = makeStream(sink)
            sink.answer = { $0 != failAt }
            stream.beginStream(nonce: fx.nonce, collectSnapshot: true)
            feed(stream, fx.bytes, chunk: 300)
            XCTAssertTrue(stream.ghosttySnapshotFailed)
            XCTAssertEqual(sink.ghostty.last, failAt)
            XCTAssertEqual(sink.ghostty.filter { $0 == failAt }.count, 1)
            // The stream goes on: the resize and the output still arrive.
            XCTAssertTrue(sink.calls.contains { if case .resized = $0 { return true } else { return false } })
        }
    }

    func testSinkWithoutSnapshotSupportUsesTheDefault() throws {
        let fx = try StreamFixture.load("live")
        let sink = OldSink(), stream = makeStream(sink)
        stream.beginStream(nonce: fx.nonce, collectSnapshot: true)
        feed(stream, fx.bytes, chunk: 4096)
        XCTAssertTrue(stream.ghosttySnapshotFailed)
        XCTAssertGreaterThan(sink.fed, 0)
    }

    func testRestoreFailureReportedLaterTurnsSnapshotsOff() throws {
        let fx = try StreamFixture.load("fresh")
        let sink = Sink(), stream = makeStream(sink)
        stream.beginStream(nonce: fx.nonce, collectSnapshot: true)
        feed(stream, fx.bytes, chunk: 300)
        XCTAssertFalse(stream.ghosttySnapshotFailed)
        stream.snapshotRestoreFailed()
        XCTAssertTrue(stream.ghosttySnapshotFailed)
        stream.snapshotRestoreFailed()  // harmless twice
        XCTAssertTrue(stream.ghosttySnapshotFailed)
    }

    func testRestoreFailureReportedWhileTheSnapshotArrives() throws {
        // A sink that decodes on another queue may report a failure between two chunks, or from
        // inside a part's call. Either way it gets no more parts.
        let fx = try StreamFixture.load("scroll")
        let half = fx.framedSnapshotLength / 2

        let sink = Sink(), stream = makeStream(sink)
        stream.beginStream(nonce: fx.nonce, collectSnapshot: true)
        feed(stream, Array(fx.bytes[0..<half]), chunk: 300)
        let before = sink.calls
        stream.snapshotRestoreFailed()
        feed(stream, Array(fx.bytes[half...]), chunk: 300)
        XCTAssertTrue(stream.ghosttySnapshotFailed)
        XCTAssertEqual(sink.calls.filter(\.isGhostty), before)
        XCTAssertNotEqual(sink.ghostty.last, .snapshotEnd(true))

        let sink2 = Sink(), stream2 = makeStream(sink2)
        sink2.answer = { [unowned stream2] part in
            if part == .snapshotReady { stream2.snapshotRestoreFailed() }
            return true
        }
        stream2.beginStream(nonce: fx.nonce, collectSnapshot: true)
        feed(stream2, fx.bytes, chunk: 300)
        XCTAssertTrue(stream2.ghosttySnapshotFailed)
        XCTAssertEqual(sink2.ghostty.last, .snapshotReady)
    }

    func testSnapshotOverTheLimitEndsIncomplete() {
        // A first record that claims 3 GB: the snapshot ends incomplete and the stream falls back.
        let sink = Sink(), stream = makeStream(sink)
        stream.beginStream(nonce: 5, collectSnapshot: true)
        var bytes = Snapshots.envelope + [3, 0, 0, 0, 0, 0xC0, 0, 0, 0, 0] + [UInt8](repeating: 7, count: 100)
        bytes += Array("\u{1b}_rex1;5;{\"type\":\"resize\",\"cols\":100,\"rows\":40,\"owner\":null}\u{1b}\\ok".utf8)
        stream.consume(Data(bytes))
        XCTAssertTrue(stream.ghosttySnapshotFailed)
        XCTAssertEqual(sink.calls, [.ghostty(.snapshotBegin), .ghostty(.snapshotBytes(Snapshots.envelope)), .ghostty(.snapshotEnd(false)),
                                    .resized(100, 40, nil), .feed(Array("ok".utf8))])
    }

    // MARK: Damaged snapshots

    func testDamagedSnapshotDoesNotSwallowTheStreamOnceTheSinkGivesUp() throws {
        let fx = try StreamFixture.load("scroll")
        // A page that claims more than the rest of the capture: trusted, it would take the resize
        // message and the output for payload.
        let bad = Snapshots.withWrongLength(fx.bytes, extra: 30_000)
        let after = "after-scroll"

        // The sink's decoder rejects the snapshot at `ready`.
        let sink = Sink(), stream = makeStream(sink)
        sink.answer = { $0 != .snapshotReady }
        stream.beginStream(nonce: fx.nonce, collectSnapshot: true)
        feed(stream, bad, chunk: 300)
        XCTAssertTrue(stream.ghosttySnapshotFailed)
        XCTAssertEqual(sink.ghostty.last, .snapshotReady)
        let rest = sink.calls.filter { !$0.isGhostty }
        guard case .resized(80, 24, _)? = rest.first, case .feed(let out)? = rest.dropFirst().first else { return XCTFail("\(rest.prefix(2))") }
        XCTAssertTrue(String(decoding: out, as: UTF8.self).contains(after))

        // The sink reports the failure from its decoder's queue, between two chunks.
        let sink2 = Sink(), stream2 = makeStream(sink2)
        stream2.beginStream(nonce: fx.nonce, collectSnapshot: true)
        feed(stream2, Array(bad[0..<9000]), chunk: 300)
        stream2.snapshotRestoreFailed()
        let partsBefore = sink2.ghostty
        feed(stream2, Array(bad[9000...]), chunk: 300)
        XCTAssertEqual(sink2.ghostty, partsBefore)
        let rest2 = sink2.calls.filter { !$0.isGhostty }
        guard case .resized(80, 24, _)? = rest2.first, case .feed(let out2)? = rest2.dropFirst().first else { return XCTFail("\(rest2.prefix(2))") }
        XCTAssertEqual(out2, out)

        // And from inside a part's call.
        let sink3 = Sink(), stream3 = makeStream(sink3)
        sink3.answer = { [unowned stream3] part in
            if part == .snapshotReady { stream3.snapshotRestoreFailed() }
            return true
        }
        stream3.beginStream(nonce: fx.nonce, collectSnapshot: true)
        feed(stream3, bad, chunk: 300)
        XCTAssertEqual(sink3.calls.filter { !$0.isGhostty }, rest)
    }

    // MARK: Handshake

    private func welcome(nonce: UInt64) -> [UInt8] {
        var b: [UInt8] = [0x81] + [UInt8](repeating: 0xAB, count: 16) + [0, 0, 0] + [0x60, 0xEA, 0, 0]
        for k in 0..<8 { b.append(UInt8((nonce >> (8 * UInt64(k))) & 0xff)) }
        return b
    }

    func testWelcomeStartsTheStream() throws {
        let fx = try StreamFixture.load("fresh")
        let sink = Sink(), stream = makeStream(sink)
        try stream.acceptWelcome(welcome(nonce: fx.nonce), gen: stream.gen, fresh: true, collectSnapshot: true)
        XCTAssertEqual(sink.statuses, [.live])
        feed(stream, fx.bytes, chunk: 500)
        XCTAssertEqual(sink.ghostty.last, .snapshotEnd(true))
        XCTAssertTrue(sink.calls.contains { if case .resized = $0 { return true } else { return false } })
    }

    func testStaleWelcomeChangesNothing() throws {
        // `stop()` while the handshake is in flight: the welcome that arrives afterwards must
        // not start a stream, report `.live`, or replace the filter.
        let fx = try StreamFixture.load("fresh")
        let sink = Sink(), stream = makeStream(sink)
        let started = stream.gen
        stream.stop()
        XCTAssertNotEqual(stream.gen, started)
        XCTAssertThrowsError(try stream.acceptWelcome(welcome(nonce: fx.nonce), gen: started, fresh: true, collectSnapshot: true)) {
            XCTAssertTrue($0 is CancellationError)
        }
        // Stopped: not even with the current generation.
        XCTAssertThrowsError(try stream.acceptWelcome(welcome(nonce: fx.nonce), gen: stream.gen, fresh: true, collectSnapshot: true))
        XCTAssertEqual(sink.statuses, [])
        feed(stream, fx.bytes, chunk: 500)
        XCTAssertEqual(sink.calls, [])

        // A welcome for an older start, on a stream that is running: the running stream's filter
        // and byte position stay as they are.
        let sink2 = Sink(), stream2 = makeStream(sink2)
        try stream2.acceptWelcome(welcome(nonce: fx.nonce), gen: stream2.gen, fresh: true, collectSnapshot: true)
        feed(stream2, Array(fx.bytes[0..<700]), chunk: 100)
        XCTAssertThrowsError(try stream2.acceptWelcome(welcome(nonce: 999), gen: stream2.gen - 1, fresh: true, collectSnapshot: false))
        feed(stream2, Array(fx.bytes[700...]), chunk: 100)
        XCTAssertEqual(sink2.statuses, [.live])
        XCTAssertEqual(sink2.ghostty, Snapshots.parts(fx.bytes))
    }

    func testRejectIsReportedWithItsReasonAndBusyIsRetried() throws {
        let sink = Sink(), stream = makeStream(sink)
        XCTAssertThrowsError(try stream.acceptWelcome([0x82, 0x02], gen: stream.gen, fresh: true, collectSnapshot: true)) { error in
            XCTAssertEqual((error as? TerminalStream.Refused)?.reason, TerminalStream.busyReason)
            XCTAssertEqual(error.localizedDescription, "stream refused (reason 2) (client)")
        }
        XCTAssertThrowsError(try stream.acceptWelcome([0x82, 0x03], gen: stream.gen, fresh: true, collectSnapshot: true)) { error in
            XCTAssertEqual((error as? TerminalStream.Refused)?.reason, 3)
        }
        XCTAssertEqual(sink.statuses, [])

        // Only "already connected" (0x02) is retried at once, and only a few times.
        XCTAssertEqual(TerminalStream.busyReason, 0x02)
        XCTAssertTrue(TerminalStream.retriesHello(reason: 0x02, attempt: 0))
        XCTAssertTrue(TerminalStream.retriesHello(reason: 0x02, attempt: TerminalStream.busyRetryLimit - 1))
        XCTAssertFalse(TerminalStream.retriesHello(reason: 0x02, attempt: TerminalStream.busyRetryLimit))
        for reason: UInt8 in [0x00, 0x01, 0x03, 0x04, 0x05, 0x06, 0x07, 0xff] {
            XCTAssertFalse(TerminalStream.retriesHello(reason: reason, attempt: 0), "reason \(reason)")
        }
        // All the tries together stay well under a second.
        XCTAssertLessThanOrEqual(UInt64(TerminalStream.busyRetryLimit) * TerminalStream.busyRetryDelay, 500_000_000)
        XCTAssertGreaterThanOrEqual(TerminalStream.busyRetryLimit, 3)
    }

    // MARK: Calls back into the stream

    func testStopFromInsideACallbackEndsDeliveryOfTheChunk() throws {
        let fx = try StreamFixture.load("resize")
        let whole = Data(fx.bytes)

        // From a snapshot part: nothing more of the chunk arrives, not even the resize.
        for at in [StreamEvent.snapshotBegin, .snapshotReady, .snapshotEnd(true)] {
            let sink = Sink(), stream = makeStream(sink)
            sink.answer = { [unowned stream] part in
                if part == at { stream.stop() }
                return true
            }
            stream.beginStream(nonce: fx.nonce, collectSnapshot: true)
            stream.consume(whole)
            XCTAssertEqual(sink.calls.last, .ghostty(at), "\(at)")
            XCTAssertFalse(sink.calls.contains { !$0.isGhostty }, "\(at)")
        }

        // From the first resize: no output, and not the second resize.
        let sink = Sink(), stream = makeStream(sink)
        sink.during = { [unowned stream] call in
            if case .resized = call { stream.stop() }
        }
        stream.beginStream(nonce: fx.nonce, collectSnapshot: false)
        stream.consume(whole)
        XCTAssertEqual(sink.calls.count, 1)
        guard case .resized(80, 24, _)? = sink.calls.first else { return XCTFail("\(sink.calls)") }

        // From the first output: the second resize and the output after it don't arrive.
        let sink2 = Sink(), stream2 = makeStream(sink2)
        sink2.during = { [unowned stream2] call in
            if case .feed = call { stream2.stop() }
        }
        stream2.beginStream(nonce: fx.nonce, collectSnapshot: false)
        stream2.consume(whole)
        XCTAssertEqual(sink2.calls.count, 2)
        guard case .feed(let out)? = sink2.calls.last else { return XCTFail("\(sink2.calls)") }
        XCTAssertFalse(String(decoding: out, as: UTF8.self).contains("after-resize\r\n"))

        // Without the stop, the same chunk delivers more.
        let sink3 = Sink(), stream3 = makeStream(sink3)
        stream3.beginStream(nonce: fx.nonce, collectSnapshot: false)
        stream3.consume(whole)
        XCTAssertEqual(sink3.calls.count, 4)
    }

    func testStreamWithoutASnapshotNeverBegins() {
        let sink = Sink(), stream = makeStream(sink)
        stream.beginStream(nonce: 5, collectSnapshot: true)
        stream.consume(Data("\u{1b}_rex1;5;{\"type\":\"resize\",\"cols\":100,\"rows\":40,\"owner\":null}\u{1b}\\ok".utf8))
        XCTAssertTrue(stream.ghosttySnapshotFailed)
        XCTAssertEqual(sink.calls, [.resized(100, 40, nil), .feed(Array("ok".utf8))])
    }
}
