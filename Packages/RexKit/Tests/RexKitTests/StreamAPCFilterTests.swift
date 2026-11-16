import XCTest
@testable import RexKit

final class StreamAPCFilterTests: XCTestCase {
    /// The old filter's trace with these snapshot parts in front.
    private func expected(_ parts: [StreamEvent], then legacy: StreamTrace) -> StreamTrace {
        StreamTrace(parts + legacy.events)
    }

    // MARK: Real captures, fed whole

    func testFixturesHoldASnapshotThenTheResizeMessage() throws {
        for name in StreamFixture.names {
            let fx = try StreamFixture.load(name)
            let end = fx.framedSnapshotLength
            XCTAssertEqual(Array(fx.bytes[0..<8]), Snapshots.magic, name)
            XCTAssertLessThan(fx.framedReadyLength, end, name)
            // Rex's docs: a `resize` "comes right after the snapshot".
            XCTAssertEqual(Array(fx.bytes[end..<end + fx.marker.count]), fx.marker, name)
        }
    }

    func testPassesTheSnapshotBeforeTheFirstMessage() throws {
        for name in StreamFixture.names {
            let fx = try StreamFixture.load(name)
            let t = runFilter([Data(fx.bytes)], nonce: fx.nonce, collectsSnapshot: true)
            let end = fx.framedSnapshotLength, ready = fx.framedReadyLength

            // The bytes are the snapshot, whole and nothing more.
            XCTAssertEqual(Array(t.snapshotBytes.prefix(8)), Snapshots.magic, name)
            XCTAssertEqual(t.snapshotBytes.count, end, name)
            XCTAssertEqual(t.snapshotBytes, Array(fx.bytes[0..<end]), name)

            // Order: begin, the bytes through READY, ready, the history, end; then the resize.
            XCTAssertEqual(Array(t.events.prefix(5)), [
                .snapshotBegin, .snapshotBytes(Array(fx.bytes[0..<ready])), .snapshotReady,
                .snapshotBytes(Array(fx.bytes[ready..<end])), .snapshotEnd(true),
            ], name)
            XCTAssertEqual(t.snapshotParts.count, 5, name)
            guard case .message(let first)? = t.events.dropFirst(5).first else {
                return XCTFail("\(name): no message after the snapshot: \(t.events)")
            }
            XCTAssertTrue(first.contains("\"type\":\"resize\""), name)
            XCTAssertTrue(first.contains("\"cols\":80"), name)

            // Everything after the snapshot is the same as without it.
            let legacy = runLegacyFilter([Data(fx.bytes)], nonce: fx.nonce)
            XCTAssertEqual(Array(t.events.dropFirst(5)), legacy.events, name)
            XCTAssertEqual(t, expected(Snapshots.parts(fx.bytes), then: legacy), name)
        }
    }

    func testOutputAndMessagesOfTheCaptures() throws {
        let live = try StreamFixture.load("live")
        let t = runFilter([Data(live.bytes)], nonce: live.nonce, collectsSnapshot: true)
        XCTAssertEqual(t.messages.count, 1)
        let text = String(decoding: t.output, as: UTF8.self)
        XCTAssertTrue(text.contains("hello-live"))
        // An APC with another nonce is the program's output, not a message.
        XCTAssertTrue(text.contains("\u{1b}_rex1;123;{\"type\":\"resize\"}\u{1b}\\"))

        let resize = try StreamFixture.load("resize")
        let r = runFilter([Data(resize.bytes)], nonce: resize.nonce, collectsSnapshot: false)
        XCTAssertEqual(r.messages.count, 2)
        XCTAssertTrue(r.messages[1].contains("\"cols\":61") && r.messages[1].contains("\"rows\":19"))
        // The second resize sits between the output before and after it.
        let kinds = r.events.map { e -> String in
            switch e { case .message: return "m"; case .output: return "o"; default: return "s" }
        }
        XCTAssertEqual(kinds, ["m", "o", "m", "o"])
        guard case .output(let before) = r.events[1], case .output(let after) = r.events[3] else { return XCTFail() }
        XCTAssertTrue(String(decoding: before, as: UTF8.self).contains("before-resize"))
        XCTAssertFalse(String(decoding: before, as: UTF8.self).contains("after-resize\r\n"))
        XCTAssertTrue(String(decoding: after, as: UTF8.self).contains("after-resize"))

        let scroll = try StreamFixture.load("scroll")
        XCTAssertGreaterThan(scroll.framedSnapshotLength, 20_000)
        // The renderable part is a small fraction of a snapshot with history.
        XCTAssertLessThan(scroll.framedReadyLength, 2_500)
        let s = runFilter([Data(scroll.bytes)], nonce: scroll.nonce, collectsSnapshot: true)
        XCTAssertTrue(String(decoding: s.output, as: UTF8.self).contains("after-scroll"))
    }

    func testSnapshotBytesAreViewsOfTheChunk() throws {
        // Nothing is copied when a chunk holds whole headers: every view lies inside the chunk.
        let fx = try StreamFixture.load("scroll")
        var f = APCFilter(nonce: fx.nonce, passesSnapshot: true)
        let chunk = Data(fx.bytes)
        chunk.withUnsafeBytes { raw in
            let lo = UInt(bitPattern: raw.baseAddress!), hi = lo + UInt(raw.count)
            var views = 0
            f.process(chunk, snapshot: { part in
                guard case .bytes(let b) = part else { return }
                let p = UInt(bitPattern: b.baseAddress!)
                XCTAssertTrue(p >= lo && p + UInt(b.count) <= hi)
                views += 1
            }, output: { _ in }, message: { _ in })
            XCTAssertEqual(views, 2)  // through READY, then the history
        }
    }

    // MARK: Chunk boundaries

    func testByteByByte() throws {
        for name in StreamFixture.names {
            let fx = try StreamFixture.load(name)
            let bytes = fx.bytes.map { Data([$0]) }
            let whole = [Data(fx.bytes)]
            XCTAssertEqual(runFilter(bytes, nonce: fx.nonce, collectsSnapshot: true),
                           runFilter(whole, nonce: fx.nonce, collectsSnapshot: true), name)
            XCTAssertEqual(runFilter(bytes, nonce: fx.nonce, collectsSnapshot: false),
                           runLegacyFilter(whole, nonce: fx.nonce), name)
        }
    }

    func testEveryTwoChunkSplitOfTheSmallCaptures() throws {
        for name in ["fresh", "live", "resize"] {
            let fx = try StreamFixture.load(name)
            let whole = [Data(fx.bytes)]
            let on = runFilter(whole, nonce: fx.nonce, collectsSnapshot: true)
            let off = runLegacyFilter(whole, nonce: fx.nonce)
            for cut in 1..<fx.bytes.count {
                let parts = chunks(fx.bytes, cuts: [cut])
                XCTAssertEqual(runFilter(parts, nonce: fx.nonce, collectsSnapshot: true), on, "\(name) cut \(cut)")
                XCTAssertEqual(runFilter(parts, nonce: fx.nonce, collectsSnapshot: false), off, "\(name) cut \(cut)")
                XCTAssertEqual(runLegacyFilter(parts, nonce: fx.nonce), off, "\(name) cut \(cut)")
            }
        }
    }

    /// Two cuts, both anywhere from before the READY record through the first message and into
    /// the output: every way the snapshot's end, the marker and the message can be divided.
    func testEveryThreeChunkSplitAroundTheHandoff() throws {
        let fx = try StreamFixture.load("fresh")
        let whole = [Data(fx.bytes)]
        let on = runFilter(whole, nonce: fx.nonce, collectsSnapshot: true)
        let off = runLegacyFilter(whole, nonce: fx.nonce)
        let lo = fx.framedReadyLength - 30, hi = fx.bytes.count - 1
        for a in lo..<hi {
            for b in (a + 1)...hi {
                let parts = chunks(fx.bytes, cuts: [a, b])
                XCTAssertEqual(runFilter(parts, nonce: fx.nonce, collectsSnapshot: true), on, "cuts \(a) \(b)")
                XCTAssertEqual(runFilter(parts, nonce: fx.nonce, collectsSnapshot: false), off, "cuts \(a) \(b)")
            }
        }
        // And every pair of cuts inside the envelope and the first record headers.
        for a in 1..<24 {
            for b in (a + 1)..<40 {
                let parts = chunks(fx.bytes, cuts: [a, b])
                XCTAssertEqual(runFilter(parts, nonce: fx.nonce, collectsSnapshot: true), on, "cuts \(a) \(b)")
            }
        }
    }

    func testRandomSplitsOfEveryCapture() throws {
        var rng = SplitMix64(state: 0x1C)
        for name in StreamFixture.names {
            let fx = try StreamFixture.load(name)
            let whole = [Data(fx.bytes)]
            let on = runFilter(whole, nonce: fx.nonce, collectsSnapshot: true)
            let off = runLegacyFilter(whole, nonce: fx.nonce)
            for round in 0..<400 {
                // Mostly small chunks, sometimes large ones.
                let most = [3, 17, 200, 5000][round % 4]
                var cuts: [Int] = []
                var at = 0
                while true {
                    at += 1 + rng.below(most)
                    if at >= fx.bytes.count { break }
                    cuts.append(at)
                }
                let parts = chunks(fx.bytes, cuts: cuts)
                XCTAssertEqual(parts.reduce(0) { $0 + $1.count }, fx.bytes.count)
                XCTAssertEqual(runFilter(parts, nonce: fx.nonce, collectsSnapshot: true), on, "\(name) round \(round)")
                XCTAssertEqual(runFilter(parts, nonce: fx.nonce, collectsSnapshot: false), off, "\(name) round \(round)")
            }
        }
    }

    func testMarkerAndMessageSplitAcrossChunks() {
        let nonce: UInt64 = 987_654_321
        let snapshot = Snapshots.envelope + Snapshots.record(tag: 1, payload: [9, 9, 9]) + Snapshots.record(tag: 6)
        let msg = Array("\u{1b}_rex1;\(nonce);{\"type\":\"resize\",\"cols\":90,\"rows\":30}\u{1b}\\".utf8)
        let theme = Array("\u{1b}_rex1;\(nonce);{\"type\":\"theme\",\"background\":\"000000\"}\u{1b}\\".utf8)
        let stream = snapshot + msg + Array("ab\u{1b}[1mcd".utf8) + theme + Array("tail\u{1b}".utf8)
        let after: [StreamEvent] = [
            .message("{\"cols\":90,\"rows\":30,\"type\":\"resize\"}"),
            .output(Array("ab\u{1b}[1mcd".utf8)),
            .message("{\"background\":\"000000\",\"type\":\"theme\"}"),
            .output(Array("tail".utf8)),  // a lone ESC at the end waits for what follows it
        ]
        let expected = [.snapshotBegin, .snapshotBytes(snapshot), .snapshotEnd(true)] + after
        XCTAssertEqual(runFilter([Data(stream)], nonce: nonce, collectsSnapshot: true).events, expected)
        for a in 1..<stream.count {
            XCTAssertEqual(runFilter(chunks(stream, cuts: [a]), nonce: nonce, collectsSnapshot: true).events, expected, "cut \(a)")
            XCTAssertEqual(runFilter(chunks(stream, cuts: [a]), nonce: nonce, collectsSnapshot: false).events, after, "cut \(a)")
            for b in (a + 1)..<stream.count {
                XCTAssertEqual(runFilter(chunks(stream, cuts: [a, b]), nonce: nonce, collectsSnapshot: true).events, expected, "cuts \(a) \(b)")
            }
        }
    }

    // MARK: Snapshot passing off

    func testPassingOffNeverReportsASnapshot() throws {
        for name in StreamFixture.names {
            let fx = try StreamFixture.load(name)
            let t = runFilter([Data(fx.bytes)], nonce: fx.nonce, collectsSnapshot: false)
            XCTAssertTrue(t.snapshotParts.isEmpty, name)
            XCTAssertEqual(t, runLegacyFilter([Data(fx.bytes)], nonce: fx.nonce), name)
        }
    }

    func testDefaultArgumentsAreTheOldFilter() throws {
        let fx = try StreamFixture.load("live")
        var f = APCFilter(nonce: fx.nonce)
        var t = StreamTrace()
        XCTAssertTrue(f.skippingSnapshot)
        f.process(Data(fx.bytes), output: { t.add(.output(Array($0))) }, message: { t.add(.message(StreamTrace.canonical($0))) })
        XCTAssertFalse(f.skippingSnapshot)
        XCTAssertEqual(t, runLegacyFilter([Data(fx.bytes)], nonce: fx.nonce))
    }

    // MARK: Limits and bad snapshots

    func testSnapshotOverTheLimitFallsBack() throws {
        for name in ["fresh", "scroll"] {
            let fx = try StreamFixture.load(name)
            let end = fx.framedSnapshotLength
            let legacy = runLegacyFilter([Data(fx.bytes)], nonce: fx.nonce)

            // One byte short: everything up to the FINISH header, then an incomplete end and
            // exactly the old behaviour.
            let short = expected(Snapshots.parts(fx.bytes, upTo: end - 10, complete: false), then: legacy)
            for parts in [[Data(fx.bytes)], fx.bytes.map { Data([$0]) }, chunks(fx.bytes, cuts: [end - 5, end + 5])] {
                XCTAssertEqual(runFilter(parts, nonce: fx.nonce, collectsSnapshot: true, limit: end - 1), short, name)
            }
            // A tiny limit gives up at the first record header.
            let tiny = expected([.snapshotBegin, .snapshotBytes(Snapshots.envelope), .snapshotEnd(false)], then: legacy)
            XCTAssertEqual(runFilter([Data(fx.bytes)], nonce: fx.nonce, collectsSnapshot: true, limit: 64), tiny, name)
            XCTAssertEqual(runFilter(fx.bytes.map { Data([$0]) }, nonce: fx.nonce, collectsSnapshot: true, limit: 64), tiny, name)
            // A limit that just fits passes all of it.
            let fits = runFilter([Data(fx.bytes)], nonce: fx.nonce, collectsSnapshot: true, limit: end)
            XCTAssertEqual(fits, expected(Snapshots.parts(fx.bytes), then: legacy), name)
        }
    }

    func testOverTheLimitIsKnownFromTheRecordHeader() {
        // A record that claims 3 GB: the filter gives up at its header, before any payload.
        let nonce: UInt64 = 5
        var stream = Snapshots.envelope + [3, 0, 0, 0, 0, 0xC0, 0, 0, 0, 0]
        stream += [UInt8](repeating: 7, count: 4096)
        stream += Array("\u{1b}_rex1;5;{\"type\":\"resize\",\"cols\":80,\"rows\":24}\u{1b}\\ok".utf8)
        let want: [StreamEvent] = [.snapshotBegin, .snapshotBytes(Snapshots.envelope), .snapshotEnd(false),
                                   .message("{\"cols\":80,\"rows\":24,\"type\":\"resize\"}"), .output(Array("ok".utf8))]
        XCTAssertEqual(runFilter([Data(stream)], nonce: nonce, collectsSnapshot: true).events, want)
        XCTAssertEqual(runFilter(stream.map { Data([$0]) }, nonce: nonce, collectsSnapshot: true).events, want)
    }

    func testStreamThatIsNotASnapshotFallsBack() throws {
        let fx = try StreamFixture.load("live")
        let legacy = runLegacyFilter([Data(fx.bytes)], nonce: fx.nonce)
        // No `begin`: nothing was ever handed over.
        let want = expected([.snapshotEnd(false)], then: legacy)

        var badMagic = fx.bytes
        badMagic[7] = UInt8(ascii: "X")
        var badVersion = fx.bytes
        badVersion[8] = 2
        for bytes in [badMagic, badVersion] {
            XCTAssertEqual(runFilter([Data(bytes)], nonce: fx.nonce, collectsSnapshot: true), want)
            XCTAssertEqual(runFilter(bytes.map { Data([$0]) }, nonce: fx.nonce, collectsSnapshot: true), want)
            for cut in 1..<24 {
                XCTAssertEqual(runFilter(chunks(bytes, cuts: [cut]), nonce: fx.nonce, collectsSnapshot: true), want, "cut \(cut)")
            }
        }

        // No snapshot at all: the stream starts with a message.
        let rest = Array(fx.bytes[fx.framedSnapshotLength...])
        for parts in [[Data(rest)], rest.map { Data([$0]) }, chunks(rest, cuts: [4]), chunks(rest, cuts: [10]), chunks(rest, cuts: [11])] {
            XCTAssertEqual(runFilter(parts, nonce: fx.nonce, collectsSnapshot: true), want)
        }
    }

    func testSnapshotCutShortFallsBack() throws {
        // Without FINISH (an encoder that failed partway), the resize message starts where a
        // record header should.
        let fx = try StreamFixture.load("fresh")
        let end = fx.framedSnapshotLength
        let cutShort = Array(fx.bytes[0..<end - 10]) + Array(fx.bytes[end...])
        let legacy = runLegacyFilter([Data(fx.bytes)], nonce: fx.nonce)
        let want = expected(Snapshots.parts(fx.bytes, upTo: end - 10, complete: false), then: legacy)
        XCTAssertEqual(runFilter([Data(cutShort)], nonce: fx.nonce, collectsSnapshot: true), want)
        XCTAssertEqual(runFilter(cutShort.map { Data([$0]) }, nonce: fx.nonce, collectsSnapshot: true), want)
        for cut in (end - 20)..<(end + 20) {
            XCTAssertEqual(runFilter(chunks(cutShort, cuts: [cut]), nonce: fx.nonce, collectsSnapshot: true), want, "cut \(cut)")
        }
    }

    func testMarkerBytesInsideTheSnapshotAreSnapshotBytes() {
        // A CONTINUATION record holds unfinished program input verbatim. Even a whole look-alike
        // message there, with the right nonce, is part of the snapshot: the framing decides.
        let nonce: UInt64 = 4242
        let fake = Array("\u{1b}_rex1;4242;{\"type\":\"resize\",\"cols\":1,\"rows\":1}\u{1b}\\".utf8)
        let snapshot = Snapshots.envelope + Snapshots.record(tag: 1, payload: [1, 2, 3])
            + Snapshots.record(tag: 7, payload: fake) + Snapshots.record(tag: 5) + Snapshots.record(tag: 6)
        let real = Array("\u{1b}_rex1;4242;{\"type\":\"resize\",\"cols\":80,\"rows\":24}\u{1b}\\".utf8)
        let stream = snapshot + real + Array("$ ".utf8)
        let want = Snapshots.parts(snapshot) + [.message("{\"cols\":80,\"rows\":24,\"type\":\"resize\"}"), .output(Array("$ ".utf8))]
        XCTAssertEqual(want.count, 7)
        XCTAssertEqual(runFilter([Data(stream)], nonce: nonce, collectsSnapshot: true).events, want)
        for cut in 1..<stream.count {
            XCTAssertEqual(runFilter(chunks(stream, cuts: [cut]), nonce: nonce, collectsSnapshot: true).events, want, "cut \(cut)")
        }
        // The marker scan alone takes the look-alike for the first message.
        XCTAssertEqual(runLegacyFilter([Data(stream)], nonce: nonce).messages.count, 2)
    }

    func testBytesBetweenFinishAndTheFirstMessageAreOutput() {
        // Ghostty: "Bytes after FINISH belong to the containing transport". Rex puts the resize
        // message there, but anything else is the program's output.
        let nonce: UInt64 = 77
        let snapshot = Snapshots.envelope + Snapshots.record(tag: 6)
        let stream = snapshot + Array("early".utf8) + Array("\u{1b}_rex1;77;{\"type\":\"resize\"}\u{1b}\\late".utf8)
        XCTAssertEqual(runFilter([Data(stream)], nonce: nonce, collectsSnapshot: true).events,
                       [.snapshotBegin, .snapshotBytes(snapshot), .snapshotEnd(true),
                        .output(Array("early".utf8)), .message("{\"type\":\"resize\"}"), .output(Array("late".utf8))])
    }

    func testSnapshotEndsWithoutAnythingAfterIt() {
        // The end is reported with FINISH's last byte, not when the next bytes arrive.
        let snapshot = Snapshots.envelope + Snapshots.record(tag: 5) + Snapshots.record(tag: 6)
        XCTAssertEqual(runFilter([Data(snapshot)], nonce: 1, collectsSnapshot: true).events, Snapshots.parts(snapshot))
        XCTAssertEqual(runFilter(snapshot.map { Data([$0]) }, nonce: 1, collectsSnapshot: true).events, Snapshots.parts(snapshot))
    }

    func testEmptyChunks() throws {
        let fx = try StreamFixture.load("fresh")
        let whole = runFilter([Data(fx.bytes)], nonce: fx.nonce, collectsSnapshot: true)
        let parts = [Data(), Data(fx.bytes[0..<5]), Data(), Data(fx.bytes[5...]), Data()]
        XCTAssertEqual(runFilter(parts, nonce: fx.nonce, collectsSnapshot: true), whole)
    }
}
