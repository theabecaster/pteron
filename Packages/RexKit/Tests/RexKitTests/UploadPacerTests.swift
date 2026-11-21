import XCTest
@testable import RexKit

/// A phone's uplink: one queue, drained at `bytesPerSecond`, that an upload's messages and the
/// control connection's pings share. A send returns at once, as a socket's does once the system
/// has its bytes; the bytes leave later, in order.
@MainActor
private final class SlowUplink {
    private let bytesPerSecond: Double
    private var queue: [(bytes: Int, left: () -> Void)] = []
    private var pumping = false
    /// The upload's bytes in the queue now, and the most there ever were.
    private var inFlight = 0
    private(set) var peakInFlight = 0

    init(bytesPerSecond: Double) { self.bytesPerSecond = bytesPerSecond }

    func enqueue(_ bytes: Int, left: @escaping () -> Void = {}) {
        queue.append((bytes, left))
        pump()
    }

    /// An upload's message: counted in flight until it has left.
    func send(_ bytes: Int, left: @escaping () -> Void = {}) {
        inFlight += bytes
        peakInFlight = max(peakInFlight, inFlight)
        enqueue(bytes) { [unowned self] in
            self.inFlight -= bytes
            left()
        }
    }

    /// A ping and its answer: returns once everything queued before it has left.
    func ping() async {
        await withCheckedContinuation { c in enqueue(64) { c.resume() } }
    }

    private func pump() {
        guard !pumping else { return }
        pumping = true
        Task { @MainActor in
            while let first = queue.first {
                try? await Task.sleep(for: .seconds(Double(first.bytes) / bytesPerSecond))
                queue.removeFirst()
                first.left()
            }
            pumping = false
        }
    }
}

@MainActor
final class UploadPacerTests: XCTestCase {
    private static let ticket: JSONObject = ["ticket": "AAECAwQFBgcICQoLDA0ODw", "expires_in_ms": 60000]

    private struct Run {
        var worstPing: Duration
        var pings: Int
        var peakInFlight: Int
        var took: Duration
    }

    /// Sends `size` bytes as one file over an uplink of `bytesPerSecond` that the control
    /// connection's pings share, while a control ping goes every 40 ms.
    private func upload(_ size: Int, over bytesPerSecond: Double) async throws -> Run {
        let uplink = SlowUplink(bytesPerSecond: bytesPerSecond)
        let link = FakeLink()
        link.replies["com.superlogical.terminal.upload_begin"] = Self.ticket
        link.onOpen = { s in
            s.onSend = { [weak s] d in
                // The server closes with 1000 once the file's end message has reached it.
                uplink.send(max(d.count, 1)) { if d.isEmpty { s?.drop(code: 1000) } }
            }
        }
        link.onPing = { await uplink.ping() }

        let clock = ContinuousClock()
        var waits: [Duration] = []
        var sending = true
        let prober = Task { @MainActor in
            while sending {
                let start = clock.now
                await uplink.ping()
                waits.append(clock.now - start)
                try? await Task.sleep(for: .milliseconds(40))
            }
        }
        let data = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        let up = FileUploader(link: link, sessionID: "session:s", blockID: "block:b")
        var last: Int64 = 0
        let start = clock.now
        try await up.send([FileUploader.Item(name: "big.png", size: Int64(size)) { DataSource(data) }]) { sent, _ in
            last = sent
        }
        let took = clock.now - start
        sending = false
        await prober.value

        XCTAssertEqual(last, Int64(size))
        let messages = link.sockets[0].sent.dropFirst()
        XCTAssertEqual(Data(messages.joined()), data, "the file arrives whole and in order")
        XCTAssertTrue(messages.allSatisfy { $0.count <= BytesStream.maxMessage })
        return Run(worstPing: waits.max() ?? .zero, pings: waits.count, peakInFlight: uplink.peakInFlight, took: took)
    }

    /// A large file over a slow uplink must leave room for the control connection: its pings (and
    /// the calls and keys behind them) must not wait for the file, and the network is never handed
    /// more than about 256 KiB of it at once. Scaled down to run in about a second: 4 MB over
    /// 4 MB/s. Unpaced, the whole file is in flight at once and a ping waits about a second behind
    /// it, as a 7.5 MB photo over a 2 Mbit/s uplink held one for 10 s and more, past every liveness
    /// check (`RexControl.wakeTimeout`, a stream's wake ping).
    func testASlowLargeUploadLeavesRoomForTheControlConnection() async throws {
        let run = try await upload(4_000_000, over: 4_000_000)
        print("UPLOAD_PACING slow link: peak in flight \(run.peakInFlight) bytes, worst control ping \(run.worstPing), took \(run.took)")
        XCTAssertGreaterThan(run.pings, 5)
        XCTAssertLessThan(run.worstPing, .milliseconds(400), "a control ping waited \(run.worstPing) behind the file")
        XCTAssertLessThanOrEqual(run.peakInFlight, 256 * 1024, "\(run.peakInFlight) bytes of the file were in flight at once")
    }

    /// On a fast link a time target alone would let megabytes queue (100 ms of 40 MB/s is 4 MB),
    /// and on an iPhone those queue inside the Tailscale extension, which iOS kills past about
    /// 50 MB. The byte ceiling holds there too, and the file still goes near the link's speed.
    func testAFastUploadNeverPutsMoreThanTheCeilingInFlight() async throws {
        let run = try await upload(8_000_000, over: 40_000_000)
        print("UPLOAD_PACING fast link: peak in flight \(run.peakInFlight) bytes, worst control ping \(run.worstPing), took \(run.took)")
        XCTAssertLessThanOrEqual(run.peakInFlight, 256 * 1024, "\(run.peakInFlight) bytes of the file were in flight at once")
        XCTAssertLessThan(run.took, .seconds(2), "8 MB over 40 MB/s took \(run.took)")
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
