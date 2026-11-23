import RexKit
import Synchronization
import XCTest
@testable import Pteron

/// Predicted echo with its real threads: the feed queue parses, judges and publishes while
/// another thread builds frames as the render thread does. Whatever the interleaving, a frame's
/// guesses belong to its rows: no frame shows a guess on a cell where its own rows show the
/// server's text, and none shows a guess outside its grid.
final class EchoRaceTests: XCTestCase {
    /// What the frame thread saw.
    private final class Seen: Sendable {
        let frames = Atomic<Int>(0)
        let withGuess = Atomic<Int>(0)
        let stop = Atomic<Bool>(false)
        let faults = Mutex<[String]>([])
        func fault(_ text: String) { faults.withLock { if $0.count < 5 { $0.append(text) } } }
    }

    /// Builds frames until told to stop, checking each.
    private func frameThread(_ core: GhosttyCore, _ seen: Seen) -> Thread {
        let thread = Thread {
            let frame = GhosttyFrameBuilder(atlas: GhosttyGlyphAtlas(pointSize: 12, scale: 2))
            while !seen.stop.load(ordering: .relaxed) {
                _ = frame.update(core: core)
                seen.frames.add(1, ordering: .relaxed)
                let cols = frame.cols, rows = frame.rowCount
                if !frame.echoGlyphs.isEmpty { seen.withGuess.add(1, ordering: .relaxed) }
                let masked = Set(frame.echoMasks.map { Int($0.row) << 16 | Int($0.x) })
                let cellWidth = frame.builder.atlas.metrics.cellWidth
                for g in frame.echoGlyphs {
                    let col = Int(g.col), row = Int(g.row)
                    guard col < cols, row < rows, row < frame.rows.count else {
                        seen.fault("a guess at \(col),\(row) in a frame of \(cols)x\(rows)")
                        continue
                    }
                    if masked.contains(row << 16 | col * cellWidth) { continue }
                    let glyphs = frame.rows[row].glyphs
                    for i in 0..<glyphs.count where Int(glyphs[i].col) == col {
                        seen.fault("a guess and the server's text in one frame at \(col),\(row)")
                    }
                }
                for line in frame.echoLines + frame.echoMasks where Int(line.row) >= rows || Int(line.x) >= cols * cellWidth {
                    seen.fault("an underline or a mask outside a frame of \(cols)x\(rows)")
                }
            }
        }
        thread.start()
        return thread
    }

    /// The script's choices, from a seed: a failure prints it, and the same seed makes the same
    /// script again (the threads' interleaving is still the machine's).
    private struct Choices: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// `TEST_RUNNER_ECHO_RACE_SEED=<number>` runs the script of that seed.
    func testThreadedFramesNeverPairAGuessWithOtherRows() {
        let seed = ProcessInfo.processInfo.environment["ECHO_RACE_SEED"].flatMap { UInt64($0) } ?? UInt64.random(in: 0...UInt64.max)
        let core = GhosttyCore(cols: 40, rows: 6)
        let clock = EchoTestClock()
        core.echo.clock = { clock.now }
        core.feed(Array(EchoPane.prompt.utf8))
        core.setEchoLevel(.slow, ack: (lastSeq: 0, answeredThrough: 0, settled: true))
        core.sync()
        let seen = Seen()
        let thread = frameThread(core, seen)

        var rng = Choices(state: seed)
        var seq = 0
        // The clock is moved here, and read on the feed queue when it gets to each call. So
        // however far this thread runs ahead of that queue is time that passes, for the
        // predictor, between a key's answer and its echo, though both are already queued: after
        // 1.5 s of it (`EchoPredictor.cap`) a guess is cleared for want of an echo that was only
        // waiting its turn. A phone's clock does not run ahead of its feed queue. So this
        // thread never moves the clock more than half the cap past what the queue has done.
        let lead = EchoPredictor.cap / 2
        var ahead = 0.0
        func catchUp() {
            core.sync()
            ahead = 0
        }
        func pass(_ seconds: Double) {
            if ahead + seconds > lead { catchUp() }
            clock.advance(seconds)
            ahead += seconds
        }
        let letters = Array("abcdefghijklmnopqrstuvwxyz".utf8)
        func type(_ b: UInt8) {
            seq += 1
            core.echoTyped(.char(b), seq: seq, at: clock.now)
        }
        func answer() {
            let at = clock.now
            core.echoAnswered(through: seq, at: at)
            pass(EchoPredictor.settle)
            core.echoSettled(after: at)
        }
        /// A new prompt line, as the shell writes it after Enter.
        func newLine() {
            seq += 1
            core.echoTyped(.boundary(newLine: true), seq: seq, at: clock.now)
            answer()
            core.feed(Array(("\u{1b}]133;C\u{07}\r\n\u{1b}]133;D\u{07}" + EchoPane.prompt).utf8))
        }
        var wide = true
        var confirms = 0, mismatches = 0
        for round in 0..<1500 {
            // A first key, answered and echoed: its epoch is confirmed.
            let first = letters.randomElement(using: &rng)!
            type(first)
            answer()
            core.feed([first])
            // Guesses, then what the server makes of them.
            let word = (0..<Int.random(in: 1...6, using: &rng)).map { _ in letters.randomElement(using: &rng)! }
            for b in word { type(b) }
            // Now and then the feed queue catches up here, so frames with guesses get built.
            if round % 8 == 0 {
                catchUp()
                Thread.sleep(forTimeInterval: 0.002)
            }
            switch Int.random(in: 0..<10, using: &rng) {
            case 0..<5:
                // The right echo, whole or in pieces, answered before or after.
                confirms += 1
                if Bool.random(using: &rng) { answer() }
                let cut = Int.random(in: 0...word.count, using: &rng)
                core.feed(Array(word[..<cut]))
                core.feed(Array(word[cut...]))
                answer()
            case 5..<8:
                // Something else at the first guessed cell, in two messages.
                mismatches += 1
                core.feed([UInt8(ascii: "#")])
                core.feed(Array(word.dropFirst()))
                answer()
            case 8:
                wide.toggle()
                core.resize(cols: wide ? 40 : 12, rows: wide ? 6 : 3, cellWidthPx: 8, cellHeightPx: 16)
            default:
                core.reset()
                core.feed(Array(EchoPane.prompt.utf8))
            }
            newLine()
            if round % 50 == 49 { catchUp() }
        }
        core.sync()
        seen.stop.store(true, ordering: .relaxed)
        while !thread.isFinished { Thread.sleep(forTimeInterval: 0.005) }

        XCTAssertEqual(seen.faults.withLock { $0 }, [], "no frame pairs a guess with rows of another moment (seed \(seed))")
        XCTAssertGreaterThan(seen.frames.load(ordering: .relaxed), 100)
        XCTAssertGreaterThan(seen.withGuess.load(ordering: .relaxed), 0, "frames with guesses were built, so the check had something to see")
        let counters = try? XCTUnwrap(core.echoCounters)
        XCTAssertGreaterThan(counters?.confirmed ?? 0, confirms, "guesses were confirmed")
        XCTAssertGreaterThan(counters?.mismatched ?? 0, 0, "and wrong ones found")
        XCTAssertEqual(counters?.vanished, 0, "none was taken back for want of an echo (seed \(seed), \(counters?.capped ?? 0) cleared at the cap)")
        _ = mismatches
    }
}
