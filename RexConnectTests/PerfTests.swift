import RexKit
import XCTest
@testable import RexConnect

/// Records what a replay (or a stream) tells its sink, one entry per call.
@MainActor
private final class SinkLog: TerminalSink {
    var calls: [String] = []
    var snapshot: [UInt8] = []
    var fed: [UInt8] = []
    var acceptsSnapshot = true

    /// The calls with runs of the same call folded into one.
    var shape: [String] {
        calls.reduce(into: [String]()) { out, c in if out.last != c { out.append(c) } }
    }

    func streamReset(cols: Int, rows: Int) { calls.append("reset \(cols)x\(rows)") }
    func streamSnapshot(_ text: String) { calls.append("seed \(text)") }
    func streamGhosttySnapshot(_ part: GhosttySnapshotPart) -> Bool {
        switch part {
        case .begin: calls.append("snapshot begin")
        case .bytes(let b):
            calls.append("snapshot bytes")
            snapshot.append(contentsOf: b)
        case .ready: calls.append("snapshot ready")
        case .end(let complete): calls.append("snapshot end \(complete)")
        }
        return acceptsSnapshot
    }
    func streamFeed(_ bytes: UnsafeBufferPointer<UInt8>) {
        calls.append("feed")
        fed.append(contentsOf: bytes)
    }
    func streamResized(cols: Int, rows: Int, owner: String?) { calls.append("resized \(cols)x\(rows)") }
    func streamTheme(_ theme: JSONObject) { calls.append("theme") }
    func streamExited(code: Int?) { calls.append("exited") }
    func streamStatus(_ status: TerminalStream.Status) { calls.append("status \(status)") }
}

@MainActor
final class PerfTests: XCTestCase {
    // MARK: The probe is off without its flag

    func testProbeIsOffWithoutTheLaunchArgument() throws {
        XCTAssertNil(PerfProbe.make(name: nil))
        XCTAssertNil(PerfProbe.make(name: ""))
        XCTAssertNil(PerfProbe.make(name: "/"), "a name with no usable characters")
        try XCTSkipIf(UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)[PerfProbe.argument] != nil)
        XCTAssertNil(PerfProbe.active)
        XCTAssertNil(ReplayConfig.current)
    }

    func testProbeWithoutAPaneWritesNothing() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("perf-\(UUID().uuidString)")
        let probe = PerfProbe.make(name: "a/b c.1", directory: dir)
        XCTAssertEqual(probe?.name, "abc.1", "only letters, digits, dot, dash and underscore reach the file name")
        // No pane was opened: nothing is installed and no file appears.
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }

    /// A pane made without the flag doesn't reach a probe, and none is made for it.
    func testHostRunsWithoutAProbe() throws {
        try XCTSkipIf(PerfProbe.active != nil)
        let control = RexControl(address: "", client: ClientInfo(name: "test", version: "0", label: "test"))
        let stream = TerminalStream(control: control, sessionID: "s", blockID: "b")
        let host = TerminalHost(stream: stream, sizing: .mirror, fontSize: 11, theme: ThemeStore.theme("github-dark-dimmed"),
                                engine: .swiftTerm)
        stream.sink = nil
        host.streamStatus(.live)
        Array("hello".utf8).withUnsafeBufferPointer { host.streamFeed($0) }
        XCTAssertNil(PerfProbe.active)
    }

    // MARK: Gap and busy maths

    func testGapsCountOnlyThoseOverTheThreshold() {
        // Ticks every 10 ms, with one 40 ms and one 30 ms gap.
        let t = [0.00, 0.01, 0.02, 0.06, 0.07, 0.10, 0.11]
        let s = PerfGapStats.measure(t, in: PerfWindow(from: 0, to: 0.11), threshold: 0.025)
        XCTAssertEqual(s.events, 6, "the tick on the window's start is its edge, not an event inside")
        XCTAssertEqual(s.over, 2)
        XCTAssertEqual(s.overSeconds, 0.07, accuracy: 1e-9)
        XCTAssertEqual(s.worstSeconds, 0.04, accuracy: 1e-9)
    }

    func testAGapOfExactlyTheThresholdIsNotCounted() {
        let s = PerfGapStats.measure([0, 0.025, 0.05], in: PerfWindow(from: 0, to: 0.05), threshold: 0.025)
        XCTAssertEqual(s.over, 0)
        XCTAssertEqual(s.worstSeconds, 0.025, accuracy: 1e-12)
    }

    func testGapsAreCutToTheWindow() {
        // A 100 ms stall from 0.95 to 1.05 around the window's start at 1.0, and one from 1.96 to 2.08 around its end.
        let t = [0.90, 0.95, 1.05, 1.06, 1.96, 2.08, 2.09]
        let s = PerfGapStats.measure(t, in: PerfWindow(from: 1, to: 2), threshold: 0.025)
        XCTAssertEqual(s.events, 3)
        XCTAssertEqual(s.over, 3, "the stall's part inside each edge, and the long gap between")
        XCTAssertEqual(s.overSeconds, 0.05 + 0.90 + 0.04, accuracy: 1e-9)
        XCTAssertEqual(s.worstSeconds, 0.90, accuracy: 1e-9)
    }

    func testGapsWithNoEventBeforeTheWindowStartAtTheFirstInside() {
        // Presented frames: none before the output began at 1.0.
        let s = PerfGapStats.measure([1.20, 1.21, 1.30], in: PerfWindow(from: 1, to: 1.30), threshold: 0.025)
        XCTAssertEqual(s.events, 3)
        XCTAssertEqual(s.over, 1)
        XCTAssertEqual(s.worstSeconds, 0.09, accuracy: 1e-9)
    }

    func testGapsOfNothing() {
        XCTAssertEqual(PerfGapStats.measure([], in: PerfWindow(from: 0, to: 1), threshold: 0.025), PerfGapStats())
        XCTAssertEqual(PerfGapStats.measure([5], in: PerfWindow(from: 0, to: 1), threshold: 0.025), PerfGapStats())
        XCTAssertEqual(PerfGapStats.measure([0.5], in: PerfWindow(from: 0, to: 1), threshold: 0.025).events, 1)
    }

    func testBusyTimeIsCutToTheWindow() {
        let slices = [PerfWindow(from: 0.0, to: 0.5), PerfWindow(from: 0.9, to: 1.1), PerfWindow(from: 1.5, to: 1.6),
                      PerfWindow(from: 1.9, to: 2.4), PerfWindow(from: 3, to: 4)]
        let s = PerfBusyStats.measure(slices, in: PerfWindow(from: 1, to: 2))
        XCTAssertEqual(s.totalSeconds, 0.1 + 0.1 + 0.1, accuracy: 1e-9)
        XCTAssertEqual(s.worstSeconds, 0.1, accuracy: 1e-9)
    }

    // MARK: Capture files

    func testPlainOutputIsCutIntoChunks() {
        let c = ReplayCapture(file: Data(repeating: 0x61, count: 2500), chunk: 1000, rate: .max)
        XCTAssertEqual(c.format, .vt)
        XCTAssertEqual(c.chunks.map(\.range), [0..<1000, 1000..<2000, 2000..<2500])
        XCTAssertEqual(c.chunks.map(\.due), [0, 0, 0])
        let paced = ReplayCapture(file: Data(repeating: 0x61, count: 2500), chunk: 1000, rate: .bytesPerSecond(1000))
        XCTAssertEqual(paced.chunks.map(\.due), [0, 1, 2])
    }

    func testTimedFileKeepsItsRecordsAndDelays() {
        var file = Data(ReplayCapture.timedMagic)
        func record(_ delay: UInt32, _ text: String) {
            withUnsafeBytes(of: delay.littleEndian) { file.append(contentsOf: $0) }
            withUnsafeBytes(of: UInt32(text.utf8.count).littleEndian) { file.append(contentsOf: $0) }
            file.append(contentsOf: text.utf8)
        }
        record(0, "one")
        record(500_000, "three")
        record(250_000, "")
        record(250_000, "x")
        let c = ReplayCapture(file: file)
        XCTAssertEqual(c.format, .timed)
        XCTAssertEqual(String(decoding: c.data, as: UTF8.self), "onethreex")
        XCTAssertEqual(c.chunks.map(\.range), [0..<3, 3..<8, 8..<8, 8..<9])
        XCTAssertEqual(c.chunks.map(\.due), [0, 0.5, 0.75, 1.0])
        XCTAssertEqual(ReplayCapture(file: file, rate: .max).chunks.map(\.due), [0, 0, 0, 0])
        // A record cut short ends the file there.
        XCTAssertEqual(ReplayCapture(file: file.dropLast(1) + Data()).chunks.count, 3)
    }

    func testRateArgument() {
        XCTAssertEqual(ReplayRate(argument: nil), .recorded)
        XCTAssertEqual(ReplayRate(argument: "max"), .max)
        XCTAssertEqual(ReplayRate(argument: "2000000"), .bytesPerSecond(2_000_000))
        XCTAssertNil(ReplayRate(argument: "fast"))
    }

    // MARK: The replay makes the calls a stream makes

    private func replay(_ capture: ReplayCapture, seed: String = "", snapshots: Bool, accept: Bool = true) async -> SinkLog {
        let log = SinkLog()
        log.acceptsSnapshot = accept
        let source = ReplaySource(capture: capture, seed: seed, grid: (60, 20), restoresSnapshot: snapshots)
        source.sink = log
        let done = expectation(description: "replay finished")
        source.onFinished = { done.fulfill() }
        source.start()
        await fulfillment(of: [done], timeout: 10)
        return log
    }

    /// What `APCFilter` makes of the whole capture in one piece: the reference for any chunking.
    private func reference(_ file: [UInt8], nonce: UInt64, snapshots: Bool) -> (snapshot: [UInt8], fed: [UInt8]) {
        var filter = APCFilter(nonce: nonce, passesSnapshot: snapshots)
        var snapshot: [UInt8] = [], fed: [UInt8] = []
        filter.process(Data(file), snapshot: { part in
            if case .bytes(let b) = part { snapshot.append(contentsOf: b) }
            return true
        }, output: { fed.append(contentsOf: $0) }, message: { _ in })
        return (snapshot, fed)
    }

    /// `TerminalStream`, with `restoresGhosttySnapshot`: connecting, live, the snapshot's parts,
    /// `streamResized` from the message after it, then output.
    func testReplayOfACaptureRestoringTheSnapshot() async throws {
        let file = try ghosttyFixture("ghostty-history")
        for chunk in [97, 1800, 1 << 20] {
            let capture = ReplayCapture(file: Data(file), chunk: chunk)
            XCTAssertEqual(capture.format, .rex)
            XCTAssertEqual(capture.nonce, 16_849_154_322_261_473_715)
            XCTAssertEqual(capture.grid?.cols, 80)
            let log = await replay(capture, snapshots: true)
            XCTAssertEqual(log.shape, [
                "status connecting", "status live",
                "snapshot begin", "snapshot bytes", "snapshot ready", "snapshot bytes", "snapshot end true",
                "resized 80x24", "feed",
            ], "chunk \(chunk)")
            let want = reference(file, nonce: capture.nonce, snapshots: true)
            XCTAssertEqual(log.snapshot, want.snapshot, "chunk \(chunk)")
            XCTAssertEqual(log.fed, want.fed, "chunk \(chunk)")
            XCTAssertTrue(GhosttyCore.isSnapshot(log.snapshot))
        }
    }

    /// `TerminalStream`, without: connecting, reset, resized and the screen as text, live, then
    /// the stream with its snapshot dropped.
    func testReplayOfACaptureSeedingTheScreen() async throws {
        let file = try ghosttyFixture("ghostty-history")
        let capture = ReplayCapture(file: Data(file), chunk: 1800)
        let log = await replay(capture, seed: "SEED", snapshots: false)
        XCTAssertEqual(log.shape, [
            "status connecting", "reset 80x24", "resized 80x24", "seed SEED", "status live",
            "resized 80x24", "feed",
        ])
        XCTAssertEqual(log.fed, reference(file, nonce: capture.nonce, snapshots: false).fed)
        XCTAssertTrue(log.snapshot.isEmpty)
    }

    /// A sink that refuses the snapshot gets the screen as text at the first message instead.
    func testReplayFallsBackWhenTheSnapshotIsRefused() async throws {
        let file = try ghosttyFixture("ghostty-history")
        let log = await replay(ReplayCapture(file: Data(file), chunk: 1800), seed: "SEED", snapshots: true, accept: false)
        XCTAssertEqual(log.shape, [
            "status connecting", "status live", "snapshot begin",
            "reset 80x24", "resized 80x24", "seed SEED", "resized 80x24", "feed",
        ])
    }

    /// Plain output has no snapshot and no messages: one `resize`, then a feed per chunk.
    func testReplayOfPlainOutput() async {
        let text = Array("1\r\n2\r\n\u{1b}[31m3\u{1b}[0m\r\n".utf8)
        for snapshots in [true, false] {
            let log = await replay(ReplayCapture(file: Data(text), chunk: 4), snapshots: snapshots)
            let start = snapshots ? ["status connecting", "status live"]
                : ["status connecting", "reset 60x20", "resized 60x20", "seed ", "status live"]
            XCTAssertEqual(log.shape, start + ["resized 60x20", "feed"])
            XCTAssertEqual(log.fed, text)
            XCTAssertEqual(log.calls.filter { $0 == "feed" }.count, 5, "one call per chunk")
        }
    }
}
