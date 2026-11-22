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

    /// The stream's echo clock: it moves only when a test moves it, and counts its readings.
    @MainActor
    final class Clock {
        var now = 100.0
        var reads = 0
        func attach(to stream: TerminalStream) {
            stream.echoNow = {
                self.reads += 1
                return self.now
            }
        }
    }

    private var streams: [TerminalStream] = []
    private var recorders: [Recorder] = []
    private var sinks: [Sink] = []
    private let clock = Clock()

    private func stream(_ link: FakeLink, gate: EchoGate? = nil, observed: Bool = true,
                        syncCalls: CallGate? = nil, cellular: Bool = false) -> (TerminalStream, Recorder, SleepLog) {
        let control = RexControl(address: "http://127.0.0.1:9", client: ClientInfo(name: "test", version: "0", label: "test"))
        if cellular { control.pathChanged(satisfied: true, expensive: true, interfaceChanged: false) }
        let s = TerminalStream(control: control, link: link, sessionID: "session:test", blockID: "block:test",
                               echoGate: gate, syncCalls: syncCalls)
        let sink = Sink()
        sinks.append(sink)
        s.sink = sink
        let log = SleepLog()
        log.attach(to: s)
        clock.attach(to: s)
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
        // Typed while the first write is out: it waits 200 ms in the queue.
        s.send(text: "b")
        clock.now += 0.2
        link.release()
        _ = await eventually { link.waitingCount == 1 && link.written == ["a", "b"] }
        XCTAssertEqual(gate.roundTrip.last ?? 0, 200, accuracy: 0.001)
        clock.now += 0.03
        link.release()
        _ = await eventually { gate.roundTrip.samples == 2 }
        XCTAssertEqual(gate.roundTrip.samples, 2)
        // The second write left when the first was answered: its sample is its own flight
        // only. Had the wait counted, it would be 230 ms.
        XCTAssertEqual(gate.roundTrip.last ?? 0, 30, accuracy: 0.001)
        XCTAssertEqual(gate.roundTrip.srtt ?? 0, 200 + (30 - 200) / 8, accuracy: 0.001)
    }

    // MARK: The off path

    func testWithoutAnObserverAnInputCallIsNotNumberedOrTimed() async {
        // No gate, no observer: nothing is counted and the clock is never read.
        do {
            let link = FakeLink()
            let (s, _, _) = stream(link, observed: false)
            let before = clock.reads
            for b in Array("ls -la".utf8) { s.send([b]) }
            s.send([0x7f])
            s.send(text: "\r")
            s.send(report: Array("\u{1b}[I".utf8))
            s.perform(action: "pane.clear", args: nil) { _ in }
            s.forward(key: ["key": "F5"])
            s.sendOnce(text: "y") { _ in }
            _ = await eventually { !s.hasPendingInput }
            await settle()
            XCTAssertEqual(s.inputSeq, 0, "no number is given")
            XCTAssertEqual(s.answeredSeq, 0)
            XCTAssertNil(s.lastAnswerAt)
            XCTAssertEqual(clock.reads, before, "the clock is never read")
            XCTAssertFalse(link.written.isEmpty)
        }
        // With the server's gate and no observer: two readings for each write of typed text
        // (not for each key, and none for an action), and still no numbers.
        do {
            let link = FakeLink()
            link.held = [Self.write]
            let gate = EchoGate()
            let (s, _, _) = stream(link, gate: gate, observed: false)
            let before = clock.reads
            s.send(text: "a")
            _ = await eventually { link.waitingCount == 1 }
            for b in Array("bcdef".utf8) { s.send([b]) }
            XCTAssertEqual(clock.reads, before + 1, "one reading when the write left, none for the keys behind it")
            link.release()
            _ = await eventually { link.waitingCount == 1 }
            link.release()
            _ = await eventually { !s.hasPendingInput }
            link.held = []
            s.perform(action: "pane.clear", args: nil) { _ in }
            _ = await eventually { link.count("client.action") == 1 && !s.hasPendingInput }
            await settle()
            XCTAssertEqual(link.written, ["a", "bcdef"])
            XCTAssertEqual(clock.reads, before + 4)
            XCTAssertEqual(gate.roundTrip.samples, 2)
            XCTAssertEqual(s.inputSeq, 0)
            XCTAssertNil(s.lastAnswerAt)
        }
    }

    func testAnObserverSetOverUnseenInputWaitsForItsAnswers() async {
        let link = FakeLink()
        link.held = [Self.write]
        let (s, r, log) = stream(link, observed: false)
        log.held = [.milliseconds(50)]
        s.send(text: "a")
        _ = await eventually { link.waitingCount == 1 }
        s.send(text: "b")
        XCTAssertEqual(s.inputSeq, 0)
        // The pane's level leaves `.off` with a write out and a key behind it.
        s.inputObserver = r
        s.writeObserver = r
        XCTAssertEqual(s.echoAck.lastSeq, 1, "one number stands for all unseen input")
        XCTAssertEqual(s.echoAck.answeredThrough, 0, "and none of it is answered")
        XCTAssertFalse(s.echoAck.settled, "unobserved answers left no time: not settled yet")
        s.send(text: "c")
        XCTAssertEqual(r.inputs, [.char(0x63)])
        XCTAssertTrue(r.events.contains(.input(.char(0x63), 2)))
        link.release()
        _ = await eventually { link.waitingCount == 1 && r.answers == [1] }
        XCTAssertEqual(r.answers, [1], "the unseen write answers as the number that stands for it")
        XCTAssertEqual(link.written, ["a", "bc"])
        XCTAssertTrue(r.events.contains(.left(2)))
        link.release()
        _ = await eventually { r.answers == [1, 2] }
        XCTAssertEqual(r.answers, [1, 2])
        // The settle ops: only the newest answer's fires.
        await settle()
        XCTAssertEqual(r.settledAfter, [])
        log.release(.milliseconds(50))
        _ = await eventually { !r.settledAfter.isEmpty }
        await settle()
        XCTAssertEqual(r.settledAfter, [r.answerTimes[1]])
    }

    func testAnObserverSetOnAnIdleStreamSettlesFiftyMillisecondsLater() async {
        let link = FakeLink()
        let (s, r, log) = stream(link, observed: false)
        log.held = [.milliseconds(50)]
        s.send(text: "a")
        _ = await eventually { !s.hasPendingInput }
        s.inputObserver = r
        s.writeObserver = r
        XCTAssertEqual(s.echoAck.lastSeq, 0)
        XCTAssertEqual(s.echoAck.answeredThrough, 0)
        XCTAssertFalse(s.echoAck.settled)
        clock.now += 0.049
        XCTAssertFalse(s.echoAck.settled)
        clock.now += 0.002
        XCTAssertTrue(s.echoAck.settled)
        await settle()
        log.release(.milliseconds(50))
        _ = await eventually { r.settledAfter.count == 1 }
        XCTAssertEqual(r.settledAfter, [100.0])
    }

    // MARK: Samples

    func testAnAnswerAfterStopOrParkIsNoSample() async {
        for park in [false, true] {
            let link = FakeLink()
            link.held = [Self.write]
            let gate = EchoGate()
            let (s, _, _) = stream(link, gate: gate)
            s.send(text: "a")
            _ = await eventually { link.waitingCount == 1 }
            if park { s.park() } else { s.stop() }
            clock.now += 0.4
            link.release()
            await settle()
            XCTAssertEqual(gate.roundTrip.samples, 0, "a write answered after \(park ? "park" : "stop") measures nothing of this link now")
        }
        // The same write on a stream that goes on is a sample.
        let link = FakeLink()
        link.held = [Self.write]
        let gate = EchoGate()
        let (s, _, _) = stream(link, gate: gate)
        s.send(text: "a")
        _ = await eventually { link.waitingCount == 1 }
        clock.now += 0.4
        link.release()
        _ = await eventually { gate.roundTrip.samples == 1 }
        XCTAssertEqual(gate.roundTrip.last ?? 0, 400, accuracy: 0.001)
    }

    /// A sync read that ends when the test says so.
    @MainActor
    private final class SyncRead {
        private var waiting: [CheckedContinuation<Void, Never>] = []
        private(set) var started = 0
        func run() async {
            started += 1
            await withCheckedContinuation { waiting.append($0) }
        }
        func answer() { if !waiting.isEmpty { waiting.removeFirst().resume() } }
    }

    private func turn() async { for _ in 0..<30 { await Task.yield() } }

    func testAWriteTimedDuringASyncBurstIsNoSample() async {
        let link = FakeLink()
        link.held = [Self.write]
        let gate = EchoGate(), syncCalls = CallGate(), read = SyncRead()
        let (s, r, _) = stream(link, gate: gate, syncCalls: syncCalls, cellular: true)

        // A sync read is out when the write leaves.
        let first = Task { @MainActor in await syncCalls.run { await read.run() } }
        await turn()
        s.send(text: "a")
        _ = await eventually { link.waitingCount == 1 }
        clock.now += 0.3
        read.answer()
        await first.value
        link.release()
        _ = await eventually { r.answers == [1] }
        XCTAssertEqual(gate.roundTrip.samples, 0, "it shared the connection with the sync")
        XCTAssertEqual(r.answers, [1], "the answer still counts for the acknowledgement")

        // A sync read starts and ends while the write is out.
        s.send(text: "b")
        _ = await eventually { link.waitingCount == 1 }
        let second = Task { @MainActor in await syncCalls.run { await read.run() } }
        await turn()
        read.answer()
        await second.value
        clock.now += 0.3
        link.release()
        _ = await eventually { r.answers == [1, 2] }
        XCTAssertEqual(gate.roundTrip.samples, 0)

        // A sync read is still out when the answer comes.
        s.send(text: "c")
        _ = await eventually { link.waitingCount == 1 }
        let third = Task { @MainActor in await syncCalls.run { await read.run() } }
        await turn()
        link.release()
        _ = await eventually { r.answers == [1, 2, 3] }
        XCTAssertEqual(gate.roundTrip.samples, 0)
        read.answer()
        await third.value

        // A read for the user is no sync: a write beside it is a sample.
        s.send(text: "d")
        _ = await eventually { link.waitingCount == 1 }
        let mine = Task { @MainActor in await syncCalls.run(priority: .user) { await read.run() } }
        await turn()
        clock.now += 0.07
        link.release()
        _ = await eventually { r.answers == [1, 2, 3, 4] }
        XCTAssertEqual(gate.roundTrip.samples, 1)
        XCTAssertEqual(gate.roundTrip.last ?? 0, 70, accuracy: 0.001)
        read.answer()
        await mine.value

        // With the sync over, writes are samples again.
        s.send(text: "e")
        _ = await eventually { link.waitingCount == 1 }
        clock.now += 0.05
        link.release()
        _ = await eventually { gate.roundTrip.samples == 2 }
        XCTAssertEqual(gate.roundTrip.last ?? 0, 50, accuracy: 0.001)
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
        log.held = [.milliseconds(50)]
        s.send(text: "a")
        _ = await eventually { link.waitingCount == 1 }
        s.send(text: "b")
        clock.now += 0.01
        link.release()
        _ = await eventually { link.waitingCount == 1 }
        clock.now += 0.01
        link.release()
        _ = await eventually { r.answers.count == 2 }
        await settle()
        XCTAssertEqual(r.settledAfter, [], "not before the 50 ms have passed")
        log.release(.milliseconds(50))
        _ = await eventually { !r.settledAfter.isEmpty }
        await settle()
        XCTAssertEqual(r.answerTimes.count, 2)
        XCTAssertEqual(r.answerTimes[0], 100.01, accuracy: 1e-6)
        XCTAssertEqual(r.answerTimes[1], 100.02, accuracy: 1e-6)
        XCTAssertEqual(r.settledAfter, [r.answerTimes[1]], "one settle op, for the later answer")
        XCTAssertTrue(log.asked.contains(.milliseconds(50)))
    }

    // MARK: input_mode

    private static let inputMode = "com.superlogical.terminal.input_mode"

    func testInputModeParses() async {
        let link = FakeLink()
        let (s, _, _) = stream(link, gate: EchoGate(forced: .on))
        link.replies[Self.inputMode] = ["echo": false, "canonical": true]
        let mode = await s.inputMode(marked: false)
        XCTAssertEqual(mode, EchoInputMode(echo: false, canonical: true))
        link.replies[Self.inputMode] = ["echo": false]
        let missing = await s.inputMode(marked: false)
        XCTAssertNil(missing, "a missing field gives nil")
        XCTAssertEqual(link.count(Self.inputMode), 2)
    }

    func testInputModeIsNotReadWhileTheGateIsOffOrTheShellMarksItsPrompt() async {
        let link = FakeLink()
        link.replies[Self.inputMode] = ["echo": true, "canonical": true]
        // No gate, and a gate that is off: nothing predicts, so nothing is asked.
        let (none, _, _) = stream(link)
        let a = await none.inputMode(marked: false)
        let gate = EchoGate()
        let (off, _, _) = stream(link, gate: gate)
        let b = await off.inputMode(marked: false)
        XCTAssertNil(a)
        XCTAssertNil(b)
        XCTAssertEqual(link.count(Self.inputMode), 0)
        // On, in a pane whose shell sends OSC 133: its marks answer.
        gate.forced = .slow
        let c = await off.inputMode(marked: true)
        XCTAssertNil(c)
        XCTAssertEqual(link.count(Self.inputMode), 0)
        // On, with no marks: the one read.
        let d = await off.inputMode(marked: false)
        XCTAssertEqual(d, EchoInputMode(echo: true, canonical: true))
        XCTAssertEqual(link.count(Self.inputMode), 1)
    }

    func testInputModeGoesAheadOfASyncsReadsOnACostlyPath() async {
        let link = FakeLink()
        link.held = [Self.inputMode]
        link.replies[Self.inputMode] = ["echo": false, "canonical": false]
        let syncCalls = CallGate(limit: 2), read = SyncRead()
        let (s, _, _) = stream(link, gate: EchoGate(forced: .on), syncCalls: syncCalls, cellular: true)
        // A sync is under way: two reads out, three waiting their turn.
        let sync = Task { @MainActor in await syncCalls.each(Array(0..<5)) { _ in await read.run() } }
        await turn()
        XCTAssertEqual(read.started, 2)
        var mode: EchoInputMode?
        let asked = Task { @MainActor in mode = await s.inputMode(marked: false) }
        _ = await eventually { link.count(Self.inputMode) == 1 }
        XCTAssertEqual(link.count(Self.inputMode), 1, "it left at once, behind no sync read")
        XCTAssertEqual(syncCalls.userInFlight, 1)
        // It holds one of the two places: a sync read that ends lets no other start.
        read.answer()
        await turn()
        XCTAssertEqual(read.started, 2)
        link.release()
        await asked.value
        XCTAssertEqual(mode, EchoInputMode(echo: false, canonical: false))
        await turn()
        XCTAssertEqual(syncCalls.userInFlight, 0)
        XCTAssertEqual(read.started, 3, "and the sync goes on when it is answered")
        while read.started < 5 {
            read.answer()
            await turn()
        }
        read.answer()
        read.answer()
        await sync.value
    }

    func testInputModeOnWifiDoesNotTouchTheSyncsGate() async {
        let link = FakeLink()
        link.held = [Self.inputMode]
        let syncCalls = CallGate()
        let (s, _, _) = stream(link, gate: EchoGate(forced: .on), syncCalls: syncCalls)
        let asked = Task { @MainActor in _ = await s.inputMode(marked: false) }
        _ = await eventually { link.waitingCount == 1 }
        XCTAssertEqual(syncCalls.userInFlight, 0)
        link.release()
        await asked.value
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
