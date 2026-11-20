import XCTest
@testable import RexKit

/// What the stream tells predicted echo: every input call classified in one funnel, what
/// happens to queued input, and write round trips. It never changes what is sent.
@MainActor
final class StreamEchoTests: XCTestCase {
    typealias Sink = StreamSnapshotHandoffTests.Sink
    private static let write = "com.superlogical.terminal.write"

    /// Records everything the stream tells the predictor.
    @MainActor
    final class Recorder: EchoInputObserver, EchoWriteObserver {
        enum Event: Equatable {
            case input(EchoInputKind, Int)
            case left(Int)
            case answered(Int)
            case settled
            case cleared(EchoClearReason)
        }
        var events: [Event] = []
        var answerTimes: [Double] = []
        var settledAfter: [Double] = []

        func input(_ kind: EchoInputKind, seq: Int) { events.append(.input(kind, seq)) }
        func left(through seq: Int) { events.append(.left(seq)) }
        func answered(through seq: Int, at time: Double) {
            events.append(.answered(seq))
            answerTimes.append(time)
        }
        func settled(after answer: Double) {
            events.append(.settled)
            settledAfter.append(answer)
        }
        func cleared(_ reason: EchoClearReason, through seq: Int) { events.append(.cleared(reason)) }

        var inputs: [EchoInputKind] {
            events.compactMap { if case .input(let k, _) = $0 { return k } else { return nil } }
        }
        var clears: [EchoClearReason] {
            events.compactMap { if case .cleared(let r) = $0 { return r } else { return nil } }
        }
        var answers: [Int] {
            events.compactMap { if case .answered(let s) = $0 { return s } else { return nil } }
        }
    }

    private var streams: [TerminalStream] = []
    private var recorders: [Recorder] = []

    private func stream(_ link: FakeLink, gate: EchoGate? = nil, observed: Bool = true) -> (TerminalStream, Recorder, SleepLog) {
        let control = RexControl(address: "http://127.0.0.1:9", client: ClientInfo(name: "test", version: "0", label: "test"))
        let s = TerminalStream(control: control, link: link, sessionID: "session:test", blockID: "block:test", echoGate: gate)
        s.sink = Sink()
        let log = SleepLog()
        log.attach(to: s)
        let r = Recorder()
        if observed {
            s.inputObserver = r
            s.writeObserver = r
        }
        streams.append(s)
        recorders.append(r)
        return (s, r, log)
    }

    func testFunnelClassifies() async {
        let link = FakeLink()
        let (s, r, _) = stream(link)
        s.send([0x63])
        s.send([0x7f])
        s.send([0x03])
        s.send(Array("\u{1b}[A".utf8))
        s.send([0x7f, 0x61])
        s.send(text: "ab")
        s.send(text: "\t")
        s.send(text: "\r")
        s.send(report: [0x63])
        s.perform(action: "pane.clear", args: nil) { _ in }
        s.forward(key: ["key": "F5"])
        s.sendOnce(text: "\r") { _ in }
        s.sendOnce(text: "y") { _ in }
        XCTAssertEqual(r.inputs, [
            .char(0x63), .backspace, .boundary(newLine: true), .boundary(newLine: false), .boundary(newLine: false),
            .boundary(newLine: false), .boundary(newLine: false), .boundary(newLine: true),
            .boundary(newLine: false), .boundary(newLine: true), .boundary(newLine: true),
            .boundary(newLine: true), .boundary(newLine: false),
        ])
        let seqs = r.events.compactMap { if case .input(_, let n) = $0 { return n } else { return nil } }
        XCTAssertEqual(seqs, Array(1...13), "every call has the next number")
        XCTAssertEqual(s.inputSeq, 13)
        await settle()
    }

    func testWritesIdenticalWithObserver() async {
        var payloads: [[String]] = []
        for observed in [false, true] {
            let link = FakeLink()
            link.held = [Self.write]
            let (s, _, _) = stream(link, gate: EchoGate(forced: .slow), observed: observed)
            var rng = SeededGenerator(seed: 42)
            var typed = 0
            while typed < 500 {
                let burst = Int.random(in: 1...6, using: &rng)
                for _ in 0..<burst where typed < 500 {
                    let b = UInt8.random(in: 0x20...0x7e, using: &rng)
                    s.send(Int.random(in: 0..<10, using: &rng) == 0 ? [0x7f] : [b])
                    typed += 1
                }
                if link.waitingCount > 0 { link.release() }
                _ = await eventually { link.waitingCount > 0 || !s.hasPendingInput }
            }
            while s.hasPendingInput {
                if link.waitingCount > 0 { link.release() }
                _ = await eventually { link.waitingCount > 0 || !s.hasPendingInput }
            }
            payloads.append(link.written)
        }
        XCTAssertEqual(payloads[0], payloads[1], "the predictor never touches bytes")
        XCTAssertEqual(payloads[1].joined().utf8.count, 500)
    }

    func testObserverClearedOnEveryDrop() async {
        // A write sent and lost: fate unknown.
        do {
            let link = FakeLink()
            link.failures[Self.write] = [RexError.local("connection lost")]
            let (s, r, _) = stream(link)
            s.send(text: "a")
            _ = await eventually { !r.clears.isEmpty }
            await settle()
            XCTAssertEqual(r.clears, [.unknown])
        }
        // Refused: text writes drop silently.
        do {
            let link = FakeLink()
            link.failures[Self.write] = [RexError(code: "not_found", message: "no block", status: 404)]
            let (s, r, _) = stream(link)
            s.send(text: "a")
            _ = await eventually { !r.clears.isEmpty }
            await settle()
            XCTAssertEqual(r.clears, [.refused])
        }
        // Unsent: queued again and merged, a conservative clear.
        do {
            let link = FakeLink()
            link.failures[Self.write] = [RexError.unsent("socket busy")]
            let (s, r, _) = stream(link)
            s.send(text: "a")
            _ = await eventually { link.written == ["a"] }
            await settle()
            XCTAssertEqual(r.clears, [.unsent])
            XCTAssertEqual(link.written, ["a"], "the bytes still go out")
        }
        // stop() drops the queue.
        do {
            let link = FakeLink()
            link.held = [Self.write]
            let (s, r, _) = stream(link)
            s.send(text: "a")
            _ = await eventually { link.waitingCount == 1 }
            s.send(text: "b")
            s.stop()
            XCTAssertEqual(r.clears, [.stopped])
            link.release()
            await settle()
            XCTAssertEqual(r.clears, [.stopped])
        }
        // park() too.
        do {
            let link = FakeLink()
            let (s, r, _) = stream(link)
            s.start()
            _ = await eventually { link.sockets.count == 1 }
            s.park()
            XCTAssertEqual(r.clears, [.stopped])
            await settle()
        }
        // The control connection is back.
        do {
            let link = FakeLink(connected: false)
            let (s, r, _) = stream(link)
            s.send(text: "a")
            link.connect()
            _ = await eventually { link.written == ["a"] }
            XCTAssertEqual(r.clears, [.reconnected])
            _ = s
        }
        // Input that goes once and whose answer was lost drops what was typed behind it.
        do {
            let link = FakeLink()
            link.held = [Self.write]
            let (s, r, _) = stream(link)
            s.sendOnce(text: "\r") { _ in }
            _ = await eventually { link.waitingCount == 1 }
            s.send(text: "a")
            link.disconnect()
            _ = await eventually { !r.clears.isEmpty }
            await settle()
            XCTAssertEqual(r.clears, [.unknown])
        }
    }

    func testStaleAnswerIgnored() async {
        for park in [false, true] {
            let link = FakeLink()
            link.held = [Self.write]
            let (s, r, _) = stream(link)
            s.send(text: "a")
            _ = await eventually { link.waitingCount == 1 }
            if park { s.park() } else { s.stop() }
            link.release()
            await settle()
            XCTAssertEqual(r.answers, [], "an answer after \(park ? "park" : "stop") says nothing")
        }
    }

    func testSamplesExcludeQueueWait() async {
        let link = FakeLink()
        link.held = [Self.write]
        let gate = EchoGate()
        let (s, _, _) = stream(link, gate: gate)
        s.send(text: "a")
        _ = await eventually { link.waitingCount == 1 }
        // Typed while the first write is out: it waits ~200 ms in the queue.
        s.send(text: "b")
        try? await Task.sleep(for: .milliseconds(200))
        link.release()
        _ = await eventually { link.waitingCount == 1 }
        link.release()
        _ = await eventually { gate.roundTrip.samples == 2 }
        XCTAssertEqual(gate.roundTrip.samples, 2)
        // The second write left when the first was answered: its sample is its own flight
        // only. Had the wait counted, it would be 200 ms like the first.
        XCTAssertLessThan(gate.roundTrip.last ?? .infinity, 100)
        XCTAssertGreaterThan(gate.roundTrip.srtt ?? 0, 150)
    }

    func testNoSampleForWork() async {
        let link = FakeLink()
        let gate = EchoGate()
        let (s, r, _) = stream(link, gate: gate)
        s.perform(action: "pane.clear", args: nil) { _ in }
        _ = await eventually { r.answers == [1] }
        await settle()
        XCTAssertEqual(r.answers, [1], "the acknowledgement rule waits for work too")
        XCTAssertEqual(gate.roundTrip.samples, 0, "round trips are of text writes only")
    }

    func testSequenceThroughMerge() async {
        let link = FakeLink()
        link.held = [Self.write]
        let (s, r, _) = stream(link)
        s.send(text: "a")
        _ = await eventually { link.waitingCount == 1 }
        s.send(text: "b")
        s.send(text: "c")
        link.release()
        _ = await eventually { link.waitingCount == 1 }
        XCTAssertEqual(link.written, ["a", "bc"])
        link.release()
        _ = await eventually { r.answers.count == 2 }
        XCTAssertEqual(r.answers, [1, 3], "keys coalesced into one item report the last number they hold")
        XCTAssertTrue(r.events.contains(.left(3)))
    }

    func testSettleTimer() async {
        let link = FakeLink()
        link.held = [Self.write]
        let (s, r, log) = stream(link)
        log.real.insert(.milliseconds(50))
        s.send(text: "a")
        _ = await eventually { link.waitingCount == 1 }
        s.send(text: "b")
        link.release()
        _ = await eventually { link.waitingCount == 1 }
        link.release()
        _ = await eventually { r.answers.count == 2 }
        _ = await eventually { !r.settledAfter.isEmpty }
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(r.settledAfter, [r.answerTimes[1]], "one settle op, for the later answer")
        XCTAssertTrue(log.asked.contains(.milliseconds(50)))
    }

    func testInputModeParses() async {
        let link = FakeLink()
        let (s, _, _) = stream(link)
        link.replies["com.superlogical.terminal.input_mode"] = ["echo": false, "canonical": true]
        let mode = await s.inputMode()
        XCTAssertEqual(mode, EchoInputMode(echo: false, canonical: true))
        link.replies["com.superlogical.terminal.input_mode"] = ["echo": false]
        let missing = await s.inputMode()
        XCTAssertNil(missing, "a missing field gives nil")
        XCTAssertEqual(link.count("com.superlogical.terminal.input_mode"), 2)
    }

    func testEchoAckDescribesTheQueue() async {
        let link = FakeLink()
        link.held = [Self.write]
        let (s, _, _) = stream(link, observed: false)
        XCTAssertEqual(s.echoAck.lastSeq, 0)
        XCTAssertTrue(s.echoAck.settled)
        s.send(text: "a")
        _ = await eventually { link.waitingCount == 1 }
        XCTAssertEqual(s.echoAck.answeredThrough, 0, "a write is out")
        link.release()
        _ = await eventually { !s.hasPendingInput }
        XCTAssertEqual(s.echoAck.answeredThrough, 1)
        XCTAssertFalse(s.echoAck.settled, "the answer is fresh")
    }
}

/// A small deterministic generator (SplitMix64), so a random test types the same keys each run.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
