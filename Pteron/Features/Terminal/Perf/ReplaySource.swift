import Foundation
import RexKit

// Debug and benchmark builds only (`BENCH`, set by scripts/bench/run.sh for its optimized build):
// driven by launch arguments, not in a shipped app.
#if DEBUG || BENCH
/// How fast a replay hands out its chunks.
enum ReplayRate: Equatable {
    /// As recorded: a timed file's own delays. Files without times go as fast as the host takes them.
    case recorded
    /// As fast as the host takes them.
    case max
    case bytesPerSecond(Int)

    init?(argument: String?) {
        guard let argument, !argument.isEmpty else { self = .recorded; return }
        if argument == "max" { self = .max; return }
        guard let n = Int(argument), n > 0 else { return nil }
        self = .bytesPerSecond(n)
    }

    var description: String {
        switch self {
        case .recorded: "recorded"
        case .max: "max"
        case .bytesPerSecond(let n): "\(n)"
        }
    }
}

/// A file to replay, cut into the chunks the host will get.
///
/// Three formats, told apart by how the file starts:
/// - `rex`: a raw Rex data stream as `scripts/ghostty-tools/capture.mjs` writes it. It starts
///   with a `GHOSTSNP` snapshot, then `ESC _ rex1;<nonce>;…ESC \` messages mixed with program
///   output.
/// - `timed`: `REXTIMED1\n`, then records of `delay u32 | length u32 | bytes` (little-endian,
///   delay in microseconds since the record before). Each record is one chunk, as one WebSocket
///   message would be, and the delays give a redraw loop its real pace.
/// - `vt`: anything else is plain program output, cut every `chunk` bytes.
struct ReplayCapture {
    enum Format: String { case vt, timed, rex }

    struct Chunk: Equatable {
        var range: Range<Int>
        /// Seconds after the replay's start at which the chunk becomes available.
        var due: Double
    }

    static let timedMagic = Array("REXTIMED1\n".utf8)
    static let snapshotMagic = Array("GHOSTSNP".utf8)
    static let defaultChunk = 16 * 1024

    let format: Format
    /// The bytes to hand out (a timed file's records, joined).
    let data: Data
    let chunks: [Chunk]
    /// The nonce of a `rex` capture's messages. 0 for the other formats.
    let nonce: UInt64
    /// A `rex` capture's first `resize` message: the server's grid.
    let grid: (cols: Int, rows: Int)?

    /// `nonce` is the capture's `.nonce` file, if there is one; otherwise the first message's.
    init(file: Data, nonce given: UInt64? = nil, chunk: Int = ReplayCapture.defaultChunk, rate: ReplayRate = .recorded) {
        let size = max(1, chunk)
        var pieces: [Chunk] = []
        var payload = file
        if file.starts(with: Self.timedMagic) {
            format = .timed
            payload = Data()
            var at = Self.timedMagic.count, clock = 0.0
            file.withUnsafeBytes { raw in
                func u32(_ i: Int) -> Int { Int(raw.loadUnaligned(fromByteOffset: i, as: UInt32.self).littleEndian) }
                while at + 8 <= raw.count {
                    let delay = u32(at), length = u32(at + 4)
                    guard at + 8 + length <= raw.count else { break }
                    clock += Double(delay) / 1e6
                    pieces.append(Chunk(range: payload.count..<payload.count + length, due: clock))
                    payload.append(contentsOf: UnsafeRawBufferPointer(rebasing: raw[(at + 8)..<(at + 8 + length)]))
                    at += 8 + length
                }
            }
        } else {
            format = file.starts(with: Self.snapshotMagic) ? .rex : .vt
            var at = 0
            while at < file.count {
                let end = min(at + size, file.count)
                pieces.append(Chunk(range: at..<end, due: 0))
                at = end
            }
        }
        switch rate {
        case .recorded: break
        case .max: for i in pieces.indices { pieces[i].due = 0 }
        case .bytesPerSecond(let n): for i in pieces.indices { pieces[i].due = Double(pieces[i].range.lowerBound) / Double(n) }
        }
        data = payload
        chunks = pieces
        if format == .rex {
            let n = given ?? Self.firstNonce(in: file) ?? 0
            nonce = n
            grid = Self.firstResize(in: file, nonce: n)
        } else {
            nonce = 0
            grid = nil
        }
    }

    /// The nonce of the first `ESC _ rex1;<nonce>;` in a capture.
    static func firstNonce(in file: Data) -> UInt64? {
        guard let r = file.range(of: Data("\u{1b}_rex1;".utf8)) else { return nil }
        let digits = file[r.upperBound...].prefix { $0 >= 0x30 && $0 <= 0x39 }
        return UInt64(String(decoding: digits, as: UTF8.self))
    }

    private static func firstResize(in file: Data, nonce: UInt64) -> (cols: Int, rows: Int)? {
        var filter = APCFilter(nonce: nonce)
        var grid: (cols: Int, rows: Int)?
        filter.process(file, output: { _ in }, message: { m in
            guard grid == nil, m.str("type") == "resize", let c = m.int("cols"), let r = m.int("rows") else { return }
            grid = (c, r)
        })
        return grid
    }

    /// The message Rex sends after the snapshot of every fresh stream. A replay of plain output
    /// starts with one, so the same filter runs and the host gets its grid the usual way.
    static func resizeMessage(cols: Int, rows: Int, nonce: UInt64 = 0) -> Data {
        Data("\u{1b}_rex1;\(nonce);{\"type\":\"resize\",\"cols\":\(cols),\"rows\":\(rows)}\u{1b}\\".utf8)
    }
}

/// Feeds a capture to a `TerminalSink` the way `TerminalStream` would, with no server.
///
/// It makes the calls `TerminalStream` documents, in the same order, through the same
/// `APCFilter`, one chunk per main-actor turn:
///
/// - A `rex` capture: `streamStatus(.connecting)`, `streamStatus(.live)`, then the chunks:
///   `streamGhosttySnapshot` parts, `streamResized` from the message that follows, then output
///   and messages. If the sink refuses the snapshot, the seed is used instead at the first
///   message (`streamReset`, `streamResized`, `streamSnapshot`), as the stream does. The seed
///   stands for `terminal.format`'s answer; a replay has no server to ask.
/// - `vt` and `timed` files hold no snapshot and no messages. They go through the filter behind
///   one `resize` message, so the sink sees `streamResized`, then `streamFeed` per chunk.
///
/// Like the stream, it asks for the next chunk only after the sink took the one before, and
/// each chunk arrives from another queue with a hop to the main actor. So a busy main thread
/// slows delivery here as it does on a socket.
@MainActor
final class ReplaySource {
    weak var sink: (any TerminalSink)?
    /// Called once the sink has taken the last chunk.
    var onFinished: (() -> Void)?

    private let capture: ReplayCapture
    private let seed: String
    private let grid: (cols: Int, rows: Int)
    private let delay: TimeInterval
    private var filter: APCFilter
    /// Stands in for the socket's delegate queue.
    private let io = DispatchQueue(label: "rex.replay.io", qos: .userInitiated)
    /// Counts starts and stops; a chunk scheduled under an older value is dropped.
    private var gen = 0
    private enum SnapshotState { case none, awaiting, restoring, refused }
    private var snapshotState = SnapshotState.none

    /// `grid` is the server's size for `vt` and `timed` files, and for a `rex` capture without a
    /// `resize` message. `delay` is waited between `.live` and the first chunk of a file that
    /// holds no snapshot, so the output doesn't land in the middle of the app's launch.
    init(capture: ReplayCapture, seed: String = "", grid: (cols: Int, rows: Int), delay: TimeInterval = 0) {
        self.capture = capture
        self.seed = seed
        self.grid = capture.grid ?? grid
        self.delay = capture.format == .rex ? 0 : delay
        filter = APCFilter(nonce: capture.nonce)
    }

    func start() {
        gen += 1
        let passes = capture.format == .rex
        filter = APCFilter(nonce: capture.nonce, passesSnapshot: passes)
        snapshotState = passes ? .awaiting : .none
        sink?.streamStatus(.connecting)
        sink?.streamStatus(.live)
        if capture.format != .rex { consume(ReplayCapture.resizeMessage(cols: grid.cols, rows: grid.rows)) }
        next(0, from: .now() + delay, gen: gen)
    }

    func stop() { gen += 1 }

    private func redrawFromSeed() {
        sink?.streamReset(cols: grid.cols, rows: grid.rows)
        sink?.streamResized(cols: grid.cols, rows: grid.rows, owner: nil)
        sink?.streamSnapshot(seed)
    }

    private func next(_ index: Int, from start: DispatchTime, gen myGen: Int) {
        guard index < capture.chunks.count else {
            onFinished?()
            return
        }
        let chunk = capture.chunks[index]
        let data = capture.data
        io.asyncAfter(deadline: start + chunk.due) {
            // Its own buffer, like a message off the socket.
            let piece = data.subdata(in: chunk.range)
            Task { @MainActor in
                guard myGen == self.gen else { return }
                self.consume(piece)
                guard myGen == self.gen else { return }
                self.next(index + 1, from: start, gen: myGen)
            }
        }
    }

    private func handleSnapshot(_ part: GhosttySnapshotPart) -> Bool {
        var offer = snapshotState == .restoring
        if snapshotState == .awaiting, case .begin = part { offer = true }
        let ok = offer && sink?.streamGhosttySnapshot(part) == true
        if case .end(let complete) = part {
            if ok, complete {
                snapshotState = .none
                return true
            }
        } else if ok {
            snapshotState = .restoring
            return true
        }
        snapshotState = .refused
        return false
    }

    /// Splits a chunk and passes it on, as `TerminalStream.consume` does.
    private func consume(_ chunk: Data) {
        let sink = sink
        filter.process(chunk, snapshot: { part in
            self.handleSnapshot(part)
        }, output: { out in
            sink?.streamFeed(out)
        }, message: { m in
            if self.snapshotState == .refused {
                self.snapshotState = .none
                self.redrawFromSeed()
            }
            switch m.str("type") {
            case "resize":
                sink?.streamResized(cols: max(m.int("cols") ?? self.grid.cols, 2), rows: max(m.int("rows") ?? self.grid.rows, 2),
                                    owner: m["owner"] as? String)
            case "theme":
                sink?.streamTheme(m)
            case "child_exited":
                sink?.streamExited(code: m.int("exit_code"))
            default: break
            }
        })
    }
}
#endif
