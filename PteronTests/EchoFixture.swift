import Foundation
import RexKit
import Synchronization
import XCTest
@testable import Pteron

/// A recorded typing session for predicted echo (`PteronTests/Fixtures/echo`, written by
/// `scripts/record-echo-fixtures.py`): what a real shell in a pty wrote, when each key was typed, when its write
/// was answered, and the tty's (echo, canonical) state and foreground program, all on the
/// client's clock with a simulated round trip.
struct EchoFixture: Decodable {
    struct Step: Decodable {
        var t: Double
        /// One message of the data socket, in hex.
        var out: String?
        var key: UInt8?
        var back: Bool?
        var boundary: Bool?
        var newLine: Bool?
        var seq: Int?
        /// The write holding input through this number was answered.
        var answered: Int?
        /// The tty's (echo, canonical) from now on, with the program in front (`fg`).
        var mode: [Bool]?
        var fg: String?
        /// A named point of the script, for a test to assert from.
        var mark: String?
        var resize: [Int]?
    }

    var name: String
    var source: String
    var cols: Int
    var rows: Int
    var rtt: Double
    var steps: [Step]

    static func load(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws -> EchoFixture {
        let url = try XCTUnwrap(Bundle(for: EchoPlayer.self).url(forResource: "echo-\(name)", withExtension: "json"), file: file, line: line)
        return try JSONDecoder().decode(EchoFixture.self, from: Data(contentsOf: url))
    }

    static func bytes(hex: String) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(hex.count / 2)
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            out.append(UInt8(hex[i..<j], radix: 16) ?? 0)
            i = j
        }
        return out
    }
}

/// A clock a test moves, readable from the feed queue.
final class EchoTestClock: Sendable {
    private let value = Mutex(0.0)
    var now: Double {
        get { value.withLock { $0 } }
        set { value.withLock { $0 = newValue } }
    }
    func advance(_ seconds: Double) { value.withLock { $0 += seconds } }
}

/// Plays a fixture through a real `GhosttyCore` and its predictor, as the pane's host will: keys,
/// answers and settles go to the feed queue in order with the output, an `input_mode` request is
/// answered one round trip later with the tty's state as recorded for that moment, and the
/// predictor's deadlines run every 50 ms of the fixture's time. No wall time is involved.
final class EchoPlayer {
    enum Event: Equatable {
        case output
        case typed(EchoInputKind)
        case answered
        case settled
        case modeReply
        case tick
        case resized
        case mark(String)
    }

    /// The pane right after one event, with everything parsed.
    struct Moment {
        var time: Double
        var event: Event
        /// The last mark passed, if any.
        var mark: String?
        var overlay: EchoOverlay?
    }

    let fixture: EchoFixture
    let core: GhosttyCore
    let clock = EchoTestClock()
    /// Splits every output message in two at its middle, as two messages of the data socket.
    var splitsOutput = false
    /// The generations of the `input_mode` readings asked for on the feed queue and not yet
    /// picked up.
    private final class Asked: Sendable {
        private let list = Mutex<[Int]>([])
        func add(_ generation: Int) { list.withLock { $0.append(generation) } }
        func take() -> [Int] {
            list.withLock {
                let all = $0
                $0 = []
                return all
            }
        }
    }
    private let asked = Asked()
    /// `input_mode` readings the predictor asked for.
    private(set) var modeRequests = 0
    private(set) var modeReplies: [EchoInputMode?] = []

    init(_ fixture: EchoFixture, level: EchoLevel = .slow) {
        self.fixture = fixture
        core = GhosttyCore(cols: fixture.cols, rows: fixture.rows)
        let clock = clock
        core.echo.clock = { clock.now }
        let asked = asked
        core.onEcho = { event in
            if case .inputMode(let generation) = event { asked.add(generation) }
        }
        core.setEchoLevel(level, ack: (lastSeq: 0, answeredThrough: 0, settled: true))
        core.sync()
    }

    private enum Derived {
        case settle(Double)
        case reply(Int)
    }

    func play(_ each: (Moment) -> Void) {
        var derived: [(time: Double, what: Derived)] = []
        var tick = 1
        var mark: String?
        var mode: EchoInputMode?
        var foreground: String?

        func after(_ event: Event) {
            core.sync()
            for generation in asked.take() {
                modeRequests += 1
                derived.append((clock.now + fixture.rtt, .reply(generation)))
            }
            each(Moment(time: clock.now, event: event, mark: mark, overlay: core.publishedEcho))
        }

        func run(until t: Double) {
            while true {
                let next = derived.enumerated().min { $0.element.time < $1.element.time }
                let tickAt = Double(tick) * 0.05
                let dueAt = min(next?.element.time ?? .infinity, tickAt)
                guard dueAt <= t else { return }
                clock.now = dueAt
                if let next, next.element.time <= tickAt {
                    derived.remove(at: next.offset)
                    switch next.element.what {
                    case .settle(let answer):
                        core.echoSettled(after: answer)
                        after(.settled)
                    case .reply(let generation):
                        modeReplies.append(mode)
                        core.echoInputMode(mode, foreground: foreground, generation: generation)
                        after(.modeReply)
                    }
                } else {
                    tick += 1
                    core.echoTick()
                    after(.tick)
                }
            }
        }

        for step in fixture.steps {
            run(until: step.t)
            clock.now = step.t
            if let m = step.mode, m.count == 2 {
                mode = EchoInputMode(echo: m[0], canonical: m[1])
                foreground = step.fg
            } else if let hex = step.out {
                let bytes = EchoFixture.bytes(hex: hex)
                if splitsOutput, bytes.count > 1 {
                    core.feed(Array(bytes[..<(bytes.count / 2)]))
                    after(.output)
                    core.feed(Array(bytes[(bytes.count / 2)...]))
                } else {
                    core.feed(bytes)
                }
                after(.output)
            } else if let seq = step.answered {
                core.echoAnswered(through: seq, at: step.t)
                derived.removeAll { if case .settle = $0.what { return true } else { return false } }
                derived.append((step.t + EchoPredictor.settle, .settle(step.t)))
                after(.answered)
            } else if let name = step.mark {
                mark = name
                after(.mark(name))
            } else if let size = step.resize, size.count == 2 {
                core.resize(cols: size[0], rows: size[1], cellWidthPx: 8, cellHeightPx: 16)
                after(.resized)
            } else if let seq = step.seq {
                let kind: EchoInputKind
                if let key = step.key {
                    kind = .char(key)
                } else if step.back == true {
                    kind = .backspace
                } else {
                    kind = .boundary(newLine: step.newLine ?? false)
                }
                core.echoTyped(kind, seq: seq, at: step.t)
                after(.typed(kind))
            }
        }
        run(until: (fixture.steps.last?.t ?? 0) + 2)
    }

    /// The character the grid shows at an active-area cell, 0 for none.
    func shown(col: Int, row: Int) -> UInt32 {
        let text = Array(core.rowText(row).unicodeScalars)
        guard col >= 0, col < text.count else { return 0 }
        return text[col].value == 0x20 ? 0 : text[col].value
    }

    var counters: EchoPredictor.Counters { core.echoCounters ?? EchoPredictor.Counters() }
}
