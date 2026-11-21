import XCTest
@testable import RexKit

/// A screen read's blob comes in chunks sized for the link (`BlobChunks`): whole and in order,
/// all or nothing, and no chunk so large that a live host looks silent while it arrives.
@MainActor
final class BlobChunksTests: XCTestCase {
    /// A server holding `blob`, answering `blob_read` as Rex does: at most the size asked, never
    /// the end of the bytes cut inside a character, `eof` with the last of it.
    private final class Server {
        let blob: [UInt8]
        var asked: [(offset: Int, size: Int)] = []
        /// Fails the read with this number (from 1).
        var failAt: Int?
        /// Gives this many bytes fewer than asked, as when the size counts the encoded text.
        var short = 0
        init(_ text: String) { blob = Array(text.utf8) }

        func read(_ offset: Int, _ size: Int) throws -> JSONObject {
            asked.append((offset, size))
            if asked.count == failAt { throw RexError.local("connection lost") }
            var end = min(blob.count, offset + max(1, size - short))
            // Never inside a character.
            while end < blob.count, blob[end] & 0xC0 == 0x80 { end -= 1 }
            let data = String(decoding: blob[offset..<end], as: UTF8.self)
            return ["data": data, "total": blob.count, "eof": end == blob.count]
        }
    }

    private func text(_ bytes: Int) -> String {
        var s = ""
        var n = 0
        while s.utf8.count < bytes {
            s += "line \(n) of the output, with an é and a 界 in it\n"
            n += 1
        }
        return s
    }

    func testABlobLargerThanOneChunkArrivesWholeAndInOrder() async throws {
        let whole = text(700_000)
        let server = Server(whole)
        let got = try await BlobChunks.read(from: 0, total: whole.utf8.count, now: { 0 }) { try server.read($0, $1) }
        XCTAssertEqual(got, whole)
        XCTAssertGreaterThan(server.asked.count, 8, "many chunks, not one")
        XCTAssertTrue(server.asked.allSatisfy { $0.size >= BlobChunks.floor && $0.size <= BlobChunks.ceiling })
        // Each read starts where the one before ended.
        var at = 0
        for (i, a) in server.asked.enumerated() {
            XCTAssertEqual(a.offset, at, "read \(i)")
            at = min(server.blob.count, a.offset + a.size)
            while at < server.blob.count, server.blob[at] & 0xC0 == 0x80 { at -= 1 }
        }
    }

    func testFromTheMiddleAndWithRepliesShorterThanAskedTheRestStillArrivesWhole() async throws {
        let whole = text(300_000)
        let server = Server(whole)
        server.short = 9_000
        let start = whole.utf8.count - 200_000
        var cut = start
        while server.blob[cut] & 0xC0 == 0x80 { cut += 1 }
        let got = try await BlobChunks.read(from: cut, total: whole.utf8.count, now: { 0 }) { try server.read($0, $1) }
        XCTAssertEqual(got, String(decoding: server.blob[cut...], as: UTF8.self))
    }

    func testAnErrorInTheMiddleLeavesNoPartialResult() async {
        let whole = text(700_000)
        let server = Server(whole)
        server.failAt = 4
        var got: String?
        do {
            got = try await BlobChunks.read(from: 0, total: whole.utf8.count, now: { 0 }) { try server.read($0, $1) }
            XCTFail("a failed read returned")
        } catch {
            XCTAssertEqual((error as? RexError)?.message, "connection lost")
        }
        XCTAssertNil(got, "three chunks came, and none of them is handed on")
        XCTAssertEqual(server.asked.count, 4, "and nothing is read after the failure")
    }

    func testAnEmptyBlobAndAnEmptyReplyEndTheRead() async throws {
        let server = Server("")
        let got = try await BlobChunks.read(from: 0, total: 0, now: { 0 }) { try server.read($0, $1) }
        XCTAssertEqual(got, "")
        XCTAssertEqual(server.asked.count, 1)
    }

    // MARK: The sizes

    func testAChunkIsBetween64And256KiBAndFollowsTheRate() {
        var s = BlobChunks()
        XCTAssertEqual(s.next, 64 * 1024, "the first is the smallest")
        s.measured(bytes: 64 * 1024, seconds: 8)
        XCTAssertEqual(s.next, 64 * 1024, "a slow link stays at the smallest")
        s.measured(bytes: 64 * 1024, seconds: 0.05)
        XCTAssertEqual(s.next, 128 * 1024, "100 ms of what the link carried")
        s.measured(bytes: 128 * 1024, seconds: 0.001)
        XCTAssertEqual(s.next, 256 * 1024, "never more than the largest")
        s.measured(bytes: 0, seconds: 1)
        s.measured(bytes: 10, seconds: 0)
        XCTAssertEqual(s.next, 256 * 1024, "a reading that says nothing changes nothing")
    }

    /// The reason for the sizes: nothing counts as heard from the host until a whole reply is
    /// in, and a pong waits behind it. On the slowest link the policy assumes, the smallest
    /// chunk arrives inside the watchdog's wait and the pong deadline together, on Wi-Fi and
    /// on cellular. The old fixed 900 000 bytes did not.
    func testOnTheSlowestLinkTheSmallestChunkArrivesBeforeTheWatchdogAndThePongRunOut() {
        let p = ReconnectPolicy.standard
        XCTAssertEqual(p.slowestRate, 8 * 1024)
        let seconds = Double(BlobChunks.floor) / p.slowestRate
        XCTAssertEqual(seconds, 8)
        for expensive in [false, true] {
            let allowed = p.activityTimeout(expensive: expensive) + p.pongDeadline(expensive: expensive)
            XCTAssertLessThan(seconds, allowed, expensive ? "cellular" : "Wi-Fi")
        }
        XCTAssertGreaterThan(900_000 / p.slowestRate, p.activityTimeout(expensive: true) + p.pongDeadline(expensive: true))
        // A larger chunk is only asked for on a link that carries it in a tenth of a second.
        var s = BlobChunks()
        s.measured(bytes: BlobChunks.floor, seconds: Double(BlobChunks.floor) / p.slowestRate)
        XCTAssertEqual(s.next, BlobChunks.floor)
    }
}
