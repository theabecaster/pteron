import XCTest
@testable import RexKit

/// The control connection's pings, held until the test answers them: the test decides when the
/// network has carried what went before each one. No clock decides anything.
@MainActor
private final class HeldPings {
    /// Each ping that is waiting, with the file's bytes the socket had taken when it went out.
    private var waiting: [(sentBefore: Int, answer: CheckedContinuation<Void, Error>)] = []
    private var arrival: CheckedContinuation<Void, Never>?
    var sent: () -> Int = { 0 }

    func ping() async throws {
        try await withCheckedThrowingContinuation { c in
            waiting.append((sent(), c))
            arrival?.resume()
            arrival = nil
        }
    }

    /// Answers the oldest ping, once there is one; returns the bytes it vouches for.
    func answerOldest() async -> Int {
        if waiting.isEmpty { await withCheckedContinuation { arrival = $0 } }
        let p = waiting.removeFirst()
        p.answer.resume()
        return p.sentBefore
    }

    func failAll() {
        let w = waiting
        waiting = []
        for p in w { p.answer.resume(throwing: URLError(.networkConnectionLost)) }
    }
}

@MainActor
final class UploadPacerTests: XCTestCase {
    private static let ticket: JSONObject = ["ticket": "AAECAwQFBgcICQoLDA0ODw", "expires_in_ms": 60000]
    private static let window = 256 * 1024

    /// A link whose server takes the file and closes with 1000 at its end message.
    private func serving() -> FakeLink {
        let link = FakeLink()
        link.replies["com.superlogical.terminal.upload_begin"] = Self.ticket
        link.onOpen = { s in s.onSend = { [weak s] d in if d.isEmpty { s?.drop(code: 1000) } } }
        return link
    }

    /// An uploader whose waits take no wall time: a message's turn comes at once, and the waits
    /// for a ping's answer (`UploadPacer.windowWait`) or the server's close last until cancelled,
    /// unless `windowWaitEnds`.
    private func uploader(_ link: FakeLink, windowWaitEnds: Bool = false) -> FileUploader {
        let up = FileUploader(link: link, sessionID: "session:s", blockID: "block:b")
        up.sleep = { d in
            if d >= UploadPacer.windowWait, !(windowWaitEnds && d == UploadPacer.windowWait) {
                try? await Task.sleep(for: .seconds(3600))
            } else {
                await Task.yield()
            }
        }
        return up
    }

    private func fileBytes(_ link: FakeLink) -> Int {
        link.sockets.first.map { $0.sent.dropFirst().reduce(0) { $0 + $1.count } } ?? 0
    }

    private func data(_ size: Int) -> Data { Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 7) }) }

    /// Rex never confirms an upload's bytes before its end, so a control ping stands in. The phone
    /// never hands the network more than 256 KiB beyond what an answered ping vouches for: a
    /// burst queues as packets in the Tailscale extension, which iOS kills past about 50 MB of
    /// memory (the tunnel is then gone for 30 to 60 s), and on a slow uplink the control
    /// connection's pings, calls and keys wait behind it. Unpaced, the whole file went at once.
    ///
    /// Driven by events only: each time the file waits for a ping, the bytes handed out are
    /// checked and the oldest ping is answered. No timer and no wall clock.
    func testTheNetworkIsNeverHandedMoreThan256KiBBeyondWhatAPingConfirmed() async throws {
        let link = serving()
        let pings = HeldPings()
        pings.sent = { [unowned self] in self.fileBytes(link) }
        link.onPing = { try await pings.ping() }
        let size = 2_000_000
        let file = data(size)
        let up = uploader(link)
        let (stalls, stalled) = AsyncStream<Int>.makeStream()
        up.onWindowFull = { [unowned self] in stalled.yield(self.fileBytes(link)) }
        let send = Task { @MainActor in
            defer { stalled.finish() }
            try await up.send([FileUploader.Item(name: "big.png", size: Int64(size)) { DataSource(file) }]) { _, _ in }
        }

        var first: Int?
        var vouched = 0
        var peak = 0
        var answers = 0
        for await now in stalls {
            if first == nil {
                // Nothing answered yet: the file stops at the window.
                first = now
                print("UPLOAD_PACING no ping answered: \(now) bytes handed out of \(size)")
            }
            // At most a window past what the last answer vouched for, and one message more, which
            // may have gone between the ping and the moment it was counted.
            peak = max(peak, now - vouched)
            XCTAssertLessThanOrEqual(now - vouched, Self.window + BytesStream.maxMessage,
                                     "\(now - vouched) bytes beyond what a ping vouched for")
            vouched = max(vouched, await pings.answerOldest())
            answers += 1
        }
        try await send.value
        pings.failAll()
        print("UPLOAD_PACING peak beyond the last answered ping: \(peak) bytes, \(answers) answers")
        XCTAssertEqual(first, Self.window, "the file stops at 256 KiB until a ping is answered")
        XCTAssertEqual(Data(link.sockets[0].sent.dropFirst().joined()), file, "the file arrives whole and in order")
        XCTAssertTrue(link.sockets[0].sent.dropFirst().allSatisfy { $0.count <= BytesStream.maxMessage })
    }

    /// A failed ping vouches for nothing, but must not hold the file back: the rate alone paces.
    func testAFailedControlPingNeverHoldsTheFileBack() async throws {
        let link = serving()
        link.onPing = { throw URLError(.networkConnectionLost) }
        let size = 1_000_000
        let file = data(size)
        try await uploader(link).send([FileUploader.Item(name: "a", size: Int64(size)) { DataSource(file) }]) { _, _ in }
        XCTAssertEqual(Data(link.sockets[0].sent.dropFirst().joined()), file)
    }

    /// A control connection that never answers holds the file at most `windowWait` per window,
    /// then the rate alone paces: an upload never stalls on the control connection.
    func testAControlPingThatNeverAnswersOnlyDelaysTheFile() async throws {
        let link = serving()
        let pings = HeldPings()
        link.onPing = { try await pings.ping() }
        let size = 1_000_000
        let file = data(size)
        try await uploader(link, windowWaitEnds: true)
            .send([FileUploader.Item(name: "a", size: Int64(size)) { DataSource(file) }]) { _, _ in }
        XCTAssertEqual(Data(link.sockets[0].sent.dropFirst().joined()), file)
        pings.failAll()
    }

    func testTheRateDoublesWhileNothingQueuesThenHalvesPastTheTarget() {
        var r = UploadRate()
        let start = r.rate
        r.answered(rtt: .milliseconds(20))  // the base: nothing queued
        XCTAssertEqual(r.rate, start * 2)
        r.answered(rtt: .milliseconds(25))  // 5 ms queued: under half the target
        XCTAssertEqual(r.rate, start * 4)
        XCTAssertFalse(r.congested)
        r.answered(rtt: .milliseconds(100))  // 80 ms: between half and the target, so it holds
        XCTAssertEqual(r.rate, start * 4)
        r.answered(rtt: .milliseconds(200))  // 180 ms: past the target
        XCTAssertEqual(r.rate, start * 2)
        XCTAssertTrue(r.congested)
    }

    func testAGrowingQueueStopsTheGrowthBeforeTheTarget() {
        var r = UploadRate()
        r.answered(rtt: .milliseconds(20))
        let rate = r.rate
        r.answered(rtt: .milliseconds(56))  // 36 ms queued, from none: the link is full
        XCTAssertEqual(r.rate, rate)
        XCTAssertTrue(r.congested)
    }

    func testADrainingQueueIsLeftToDrain() {
        var r = UploadRate()
        r.answered(rtt: .milliseconds(10))
        r.answered(rtt: .milliseconds(1010))  // 1 s queued
        let slowed = r.rate
        r.answered(rtt: .milliseconds(610))  // 600 ms: still past the target, but shrinking
        XCTAssertEqual(r.rate, slowed)
        r.answered(rtt: .milliseconds(700))  // growing again
        XCTAssertEqual(r.rate, slowed / 2)
    }

    func testOnceAQueueFormedTheRateGrowsByAQuarter() {
        var r = UploadRate()
        r.answered(rtt: .milliseconds(10))
        r.answered(rtt: .milliseconds(500))
        let slowed = r.rate
        r.answered(rtt: .milliseconds(10))
        XCTAssertEqual(r.rate, slowed * 1.25)
    }

    func testALatePingSlowsTheRateBeforeItsAnswer() {
        var r = UploadRate()
        r.answered(rtt: .milliseconds(10))
        let rate = r.rate
        XCTAssertFalse(r.late(.milliseconds(90)), "80 ms of queue is within the target")
        XCTAssertTrue(r.late(.milliseconds(300)))
        XCTAssertEqual(r.rate, rate / 2)
        XCTAssertFalse(r.late(.milliseconds(250)), "no longer than the queue it already slowed for")
    }

    func testTheRateStaysBetweenItsBounds() {
        var r = UploadRate()
        r.answered(rtt: .zero)
        for _ in 0..<40 { _ = r.late(.seconds(Double(r.lastQueued.components.seconds) + 1)) }
        XCTAssertEqual(r.rate, r.minRate)
        var f = UploadRate()
        for _ in 0..<60 { f.answered(rtt: .zero) }
        XCTAssertEqual(f.rate, f.maxRate)
    }

    func testAMessageIsAboutTheTargetAtTheRate() {
        var r = UploadRate()
        r.rate = 250_000
        XCTAssertEqual(r.messageBytes(max: 65_536), 25_000)
        r.rate = 32_768
        XCTAssertEqual(r.messageBytes(max: 65_536), r.minMessage)
        r.rate = 10_000_000
        XCTAssertEqual(r.messageBytes(max: 65_536), 65_536)
        XCTAssertEqual(r.messageBytes(max: 100), 100, "never past what is left of the file")
    }
}
