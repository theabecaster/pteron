import Foundation
import XCTest
@testable import RexKit

/// The server's message limit (`limits.max_message_bytes`): a request over it would close the
/// control connection with 1009. Long input goes as several writes under it, in order, and any
/// other request over it fails alone, unsent.
@MainActor
final class MessageSizeTests: XCTestCase {
    private static let write = "com.superlogical.terminal.write"

    private func control(_ address: String) -> RexControl {
        RexControl(address: address, client: ClientInfo(name: "Sample App", version: "0.1.0", label: "test"))
    }

    private func waitFor(_ condition: @MainActor () -> Bool, seconds: Double = 30) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while !condition(), Date() < end { try? await Task.sleep(for: .milliseconds(5)) }
        return condition()
    }

    /// Text of at least `bytes` UTF-8 bytes that a careless cut would break: emoji with skin
    /// tones and joiners, flags, CJK, combining accents, CR LF, and what JSON escapes.
    private static func paste(bytes: Int) -> String {
        let parts = [
            "👨‍👩‍👧‍👦", "🏳️‍🌈", "🇯🇵🇫🇷", "👍🏽", "漢字かなカナ한국어", "e\u{301}\u{302}", "\r\n", "\"q\" \\ /",
            "\u{1b}[31mred\u{1b}[0m", "\t", "plain ascii text ", "\u{2028}", "Ω≈ç√∫", "🧑🏿‍🚀",
        ]
        var s = ""
        var i = 0
        while s.utf8.count < bytes {
            s += parts[i % parts.count]
            i += 1
        }
        return s
    }

    // MARK: Cutting

    func testTheCostIsNeverBelowWhatTheEncoderWrites() {
        var scalars: [Unicode.Scalar] = (0..<0x80).compactMap(Unicode.Scalar.init)
        scalars += ["é", "€", "漢", "\u{2028}", "\u{2029}", "\u{FEFF}", "😀", "\u{10FFFF}"]
        let empty = JSONCodec.data(["d": ""]).count
        for s in scalars {
            let real = JSONCodec.data(["d": String(s)]).count - empty
            XCTAssertGreaterThanOrEqual(WriteChunks.cost(s), real, "U+\(String(s.value, radix: 16))")
        }
    }

    func testPiecesKeepEveryClusterWholeAndJoinBackExactly() {
        let text = Self.paste(bytes: 200_000)
        for budget in [7, 64, 1000, 65_000] {
            let pieces = WriteChunks.split(text, budget: budget)
            XCTAssertEqual(pieces.joined(), text, "budget \(budget)")
            // Seven bytes is less than a family emoji takes: only there may a cluster be cut.
            if budget > 7 {
                XCTAssertEqual(pieces.map(\.count).reduce(0, +), text.count, "a cluster was cut at budget \(budget)")
            }
            XCTAssertTrue(pieces.allSatisfy { WriteChunks.cost(of: $0) <= budget }, "budget \(budget)")
            XCTAssertFalse(pieces.contains(""))
        }
    }

    func testAClusterOverTheBudgetIsCutBetweenScalars() {
        // One letter with 5000 combining marks: one grapheme cluster of 10001 bytes.
        let zalgo = "a" + String(repeating: "\u{301}", count: 5000)
        let pieces = WriteChunks.split(zalgo + "b", budget: 1000)
        XCTAssertEqual(pieces.joined(), zalgo + "b")
        XCTAssertTrue(pieces.allSatisfy { WriteChunks.cost(of: $0) <= 1000 })
        XCTAssertGreaterThan(pieces.count, 10)
        // Every piece is whole scalars: valid UTF-8 that round-trips.
        for p in pieces { XCTAssertEqual(String(decoding: Array(p.utf8), as: UTF8.self), p) }
    }

    func testShortTextIsNeverCut() {
        XCTAssertNil(WriteChunks.cut("ls -la\r", budget: 100))
        XCTAssertNil(WriteChunks.cut(String(repeating: "x", count: 100), budget: 100))
        XCTAssertNotNil(WriteChunks.cut(String(repeating: "x", count: 101), budget: 100))
        XCTAssertEqual(WriteChunks.split("", budget: 10), [""])
    }

    // MARK: Through a server

    /// A 3 MiB paste through a real control connection: several writes, each under the limit,
    /// one after another, byte-exact and in order, and the connection never closes.
    private func pasteArrivesWhole(limit: Int, bytes: Int) async throws {
        let server = try FakeRexServer(revision: 19, serverRevision: 19, maxMessageBytes: limit)
        let address = await server.start()
        defer { server.stop() }
        server.reply(Self.write, [:])
        let c = control(address)
        defer { c.disconnect() }
        try await c.connect()
        XCTAssertEqual(c.maxMessageBytes, limit)

        let stream = TerminalStream(control: c, sessionID: "session:test", blockID: "block:test")
        let text = Self.paste(bytes: bytes)
        XCTAssertTrue(stream.send(text: text))
        // A key typed while the paste is on its way goes after all of it.
        XCTAssertTrue(stream.send(text: "Z"))
        let done = await waitFor { !stream.hasPendingInput }
        XCTAssertTrue(done, server.reads)

        let writes = server.calls(Self.write).compactMap { $0.obj("args")?.str("data") }
        XCTAssertEqual(writes.joined(), text + "Z", "byte-exact, in order")
        XCTAssertEqual(Array(writes.joined().utf8), Array((text + "Z").utf8))
        XCTAssertGreaterThan(writes.count, bytes / TerminalStream.writeMessageCap)
        XCTAssertEqual(writes.map(\.count).reduce(0, +), (text + "Z").count, "no cluster was cut")
        XCTAssertEqual(server.messagesTooLarge, 0, "no 1009")
        XCTAssertLessThanOrEqual(server.largestMessage, min(limit, TerminalStream.writeMessageCap))
        XCTAssertEqual(c.state, .connected)
        XCTAssertEqual(server.helloCount, 1, "the connection never dropped")
    }

    func testA3MiBPasteArrivesWholeInOrderUnderTheDefaultLimit() async throws {
        try await pasteArrivesWhole(limit: 1_048_576, bytes: 3 * 1_048_576)
    }

    func testA3MiBPasteArrivesWholeUnderTheSmallestLimit() async throws {
        try await pasteArrivesWhole(limit: 65_536, bytes: 3 * 1_048_576)
    }

    func testARequestOverTheLimitFailsAloneAndTheConnectionStays() async throws {
        let server = try FakeRexServer(revision: 19, serverRevision: 19, maxMessageBytes: 65_536)
        let address = await server.start()
        defer { server.stop() }
        server.reply("session.list", ["sessions": [JSONObject]()])
        let c = control(address)
        defer { c.disconnect() }
        try await c.connect()

        let label = String(repeating: "x", count: 70_000)
        do {
            try await c.call("session.set_label", ["session_id": "s", "label": label])
            XCTFail("a request over the limit must not leave")
        } catch let e as RexError {
            XCTAssertEqual(e.code, "message_too_large")
            XCTAssertFalse(e.neverSent, "sending it again can't help")
            XCTAssertTrue(e.message.contains("65536"), e.message)
        }
        let replies = await c.callInOrder([
            (method: "session.set_label", payload: ["session_id": "s", "label": label]),
            (method: "session.list", payload: [:]),
        ])
        XCTAssertEqual((replies[0].failure as? RexError)?.code, "message_too_large")
        XCTAssertNotNil(try? replies[1].get(), "the one beside it went")
        XCTAssertFalse(c.post("client.reply", ["call_id": "c", "text": label]))

        try await c.call("session.list")
        XCTAssertEqual(server.count("session.set_label"), 0)
        XCTAssertEqual(server.count("session.list"), 2)
        XCTAssertEqual(server.messagesTooLarge, 0)
        XCTAssertEqual(c.state, .connected)
        XCTAssertEqual(server.helloCount, 1)
    }

    // MARK: The queue

    func testKeysTypedDuringALongPasteJoinItsRestAndKeepTheirOrder() async {
        let link = FakeLink()
        link.maxMessageBytes = 65_536
        let (s, _) = makeStream(link: link, sink: StreamSnapshotHandoffTests.Sink())
        link.held = [Self.write]
        let text = String(repeating: "a", count: 150_000)
        s.send(text: text)
        _ = await eventually { link.waitingCount == 1 }
        s.send(text: "b")
        s.send(text: "c")
        var rounds = 0
        while s.hasPendingInput, rounds < 20 {
            _ = await eventually { link.waitingCount == 1 || !s.hasPendingInput }
            if link.waitingCount == 1 { link.release() }
            rounds += 1
            await settle()
        }
        let writes = link.written
        XCTAssertEqual(writes.joined(), text + "bc")
        XCTAssertEqual(writes.count, 3, "three writes of under 64 KiB")
        XCTAssertTrue(writes.allSatisfy { $0.utf8.count <= s.writeBudget })
        XCTAssertTrue(writes.last?.hasSuffix("bc") == true, "the keys went with the paste's last piece")
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let e) = self { return e }
        return nil
    }
}
