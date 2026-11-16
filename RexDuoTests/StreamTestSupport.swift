import XCTest
@testable import RexDuo

/// A recorded Rex data stream (`scripts/ghostty-tools/capture.mjs`) and the nonce of its WELCOME.
struct StreamFixture {
    let name: String
    let bytes: [UInt8]
    let nonce: UInt64

    /// fresh: a new shell. live: output typed after the snapshot, with a look-alike APC that has
    /// the wrong nonce. scroll: after `seq 1 3000`. resize: a resize in the middle of the output.
    static let names = ["fresh", "live", "scroll", "resize"]

    static func load(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws -> StreamFixture {
        let bundle = Bundle(for: StreamFixtureAnchor.self)
        let bin = try XCTUnwrap(bundle.url(forResource: "stream-\(name)", withExtension: "bin"), file: file, line: line)
        let nonceURL = try XCTUnwrap(bundle.url(forResource: "stream-\(name).bin", withExtension: "nonce"), file: file, line: line)
        let text = try String(contentsOf: nonceURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        return StreamFixture(name: name, bytes: [UInt8](try Data(contentsOf: bin)), nonce: try XCTUnwrap(UInt64(text)))
    }

    var marker: [UInt8] { Array("\u{1b}_rex1;\(nonce);".utf8) }

    /// The snapshot's length by Ghostty's framing: a 10-byte envelope, then records of
    /// `tag u16 | payload_len u32 | CRC32C u32 | payload` up to and including FINISH (tag 6).
    var framedSnapshotLength: Int { Snapshots.framedLength(bytes)! }
    /// Where the READY record (tag 5) ends.
    var framedReadyLength: Int { Snapshots.framedLength(bytes, through: 5)! }
}

private final class StreamFixtureAnchor {}

enum Snapshots {
    static let magic = Array("GHOSTSNP".utf8)

    /// Walks the record framing on its own, as the snapshot guide describes it. Nil if `b` doesn't
    /// hold a whole snapshot.
    static func framedLength(_ b: [UInt8], through last: Int = 6) -> Int? {
        guard b.count >= 10, Array(b[0..<8]) == magic, b[8] == 1, b[9] == 0 else { return nil }
        var o = 10
        while o + 10 <= b.count {
            let tag = Int(b[o]) | Int(b[o + 1]) << 8
            let len = Int(b[o + 2]) | Int(b[o + 3]) << 8 | Int(b[o + 4]) << 16 | Int(b[o + 5]) << 24
            o += 10 + len
            if tag == last { return o <= b.count ? o : nil }
            if tag == 6 { return nil }
        }
        return nil
    }

    /// A stream whose snapshot has a damaged record: the first history page (the first PAGE record
    /// after READY) claims `extra` more payload bytes than it has, so a filter that trusts the
    /// framing takes the bytes after the snapshot, Rex messages included, for payload.
    static func withWrongLength(_ b: [UInt8], extra: Int) -> [UInt8] {
        var out = b
        var o = framedLength(b, through: 5)!
        while true {
            let tag = Int(b[o]) | Int(b[o + 1]) << 8
            let len = Int(b[o + 2]) | Int(b[o + 3]) << 8 | Int(b[o + 4]) << 16 | Int(b[o + 5]) << 24
            if tag == 3 {
                let wrong = len + extra
                for k in 0..<4 { out[o + 2 + k] = UInt8((wrong >> (8 * k)) & 0xff) }
                return out
            }
            precondition(tag != 6, "no history page")
            o += 10 + len
        }
    }

    /// The parts a filter reports for the snapshot at the start of `b`: its first `upTo` bytes,
    /// with `ready` where the READY record ends, if those bytes reach it.
    static func parts(_ b: [UInt8], upTo: Int? = nil, complete: Bool = true) -> [StreamEvent] {
        let end = upTo ?? framedLength(b)!
        var out: [StreamEvent] = [.snapshotBegin]
        if let ready = framedLength(b, through: 5), ready <= end {
            out += [.snapshotBytes(Array(b[0..<ready])), .snapshotReady]
            if end > ready { out.append(.snapshotBytes(Array(b[ready..<end]))) }
        } else {
            out.append(.snapshotBytes(Array(b[0..<end])))
        }
        out.append(.snapshotEnd(complete))
        return out
    }

    /// One record with a zero CRC (the filter leaves CRCs to the decoder).
    static func record(tag: UInt16, payload: [UInt8] = []) -> [UInt8] {
        let n = UInt32(payload.count)
        return [UInt8(tag & 0xff), UInt8(tag >> 8),
                UInt8(n & 0xff), UInt8((n >> 8) & 0xff), UInt8((n >> 16) & 0xff), UInt8(n >> 24),
                0, 0, 0, 0] + payload
    }

    static let envelope: [UInt8] = magic + [1, 0]
}

/// What a filter reported, in order. Output and snapshot bytes that arrive in several pieces are
/// joined, so a trace doesn't depend on where the chunks were cut.
enum StreamEvent: Equatable, CustomStringConvertible {
    case snapshotBegin
    case snapshotBytes([UInt8])
    case snapshotReady
    case snapshotEnd(Bool)
    case output([UInt8])
    case message(String)

    init(_ part: GhosttySnapshotPart) {
        switch part {
        case .begin: self = .snapshotBegin
        case .bytes(let b): self = .snapshotBytes(Array(b))
        case .ready: self = .snapshotReady
        case .end(let complete): self = .snapshotEnd(complete)
        }
    }

    var isSnapshotPart: Bool {
        switch self {
        case .output, .message: return false
        default: return true
        }
    }

    var description: String {
        switch self {
        case .snapshotBegin: return "begin"
        case .snapshotBytes(let b): return "bytes(\(b.count))"
        case .snapshotReady: return "ready"
        case .snapshotEnd(let c): return "end(\(c))"
        case .output(let b): return "output(\(b.count))"
        case .message(let m): return "message(\(m))"
        }
    }
}

struct StreamTrace: Equatable {
    private(set) var events: [StreamEvent] = []

    init(_ events: [StreamEvent] = []) { events.forEach { add($0) } }

    mutating func add(_ e: StreamEvent) {
        switch (e, events.last) {
        case (.output(let more), _) where more.isEmpty: return
        case (.snapshotBytes(let more), _) where more.isEmpty: return
        case (.output(let more), .output(let have)?): events[events.count - 1] = .output(have + more)
        case (.snapshotBytes(let more), .snapshotBytes(let have)?): events[events.count - 1] = .snapshotBytes(have + more)
        default: events.append(e)
        }
    }

    var snapshotParts: [StreamEvent] { events.filter(\.isSnapshotPart) }
    /// Every snapshot byte reported, joined.
    var snapshotBytes: [UInt8] {
        events.flatMap { e -> [UInt8] in if case .snapshotBytes(let b) = e { return b } else { return [] } }
    }
    var messages: [String] {
        var out: [String] = []
        for case .message(let m) in events { out.append(m) }
        return out
    }
    var output: [UInt8] { events.flatMap { e -> [UInt8] in if case .output(let b) = e { return b } else { return [] } } }

    static func canonical(_ m: JSONObject) -> String {
        let d = try! JSONSerialization.data(withJSONObject: m, options: [.sortedKeys])
        return String(decoding: d, as: UTF8.self)
    }
}

/// Cuts `bytes` after each offset in `cuts` (ascending, inside the array).
func chunks(_ bytes: [UInt8], cuts: [Int]) -> [Data] {
    var out: [Data] = []
    var from = 0
    for c in cuts where c > from && c < bytes.count {
        out.append(Data(bytes[from..<c]))
        from = c
    }
    out.append(Data(bytes[from...]))
    return out
}

func runFilter(_ chunks: [Data], nonce: UInt64, collectsSnapshot: Bool,
               limit: Int = APCFilter.defaultSnapshotLimit, keep: (StreamEvent) -> Bool = { _ in true }) -> StreamTrace {
    var f = APCFilter(nonce: nonce, passesSnapshot: collectsSnapshot, snapshotLimit: limit)
    var t = StreamTrace()
    for c in chunks {
        f.process(c, snapshot: { t.add(StreamEvent($0)); return keep(StreamEvent($0)) },
                  output: { t.add(.output(Array($0))) },
                  message: { t.add(.message(StreamTrace.canonical($0))) })
    }
    return t
}

func runLegacyFilter(_ chunks: [Data], nonce: UInt64) -> StreamTrace {
    var f = LegacyAPCFilter(nonce: nonce)
    var t = StreamTrace()
    for c in chunks {
        f.process(c, output: { t.add(.output(Array($0))) },
                  message: { t.add(.message(StreamTrace.canonical($0))) })
    }
    return t
}

/// A small fixed-seed generator, so random splits are the same on every run.
struct SplitMix64 {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func below(_ n: Int) -> Int { Int(next() % UInt64(n)) }
}

/// `APCFilter` exactly as it was before snapshot collection (commit 6121c6b), kept as the
/// reference for the unchanged path and as the benchmark baseline.
struct LegacyAPCFilter {
    private let marker: [UInt8]
    private(set) var skippingSnapshot = true
    private var pending: [UInt8] = []

    init(nonce: UInt64) {
        marker = Array("\u{1b}_rex1;\(nonce);".utf8)
    }

    mutating func process(_ chunk: Data,
                          output: (UnsafeBufferPointer<UInt8>) -> Void,
                          message: (JSONObject) -> Void) {
        if pending.isEmpty {
            chunk.withUnsafeBytes { raw in
                scan(raw.bindMemory(to: UInt8.self), output: output, message: message)
            }
        } else {
            var data = pending
            pending = []
            data.append(contentsOf: chunk)
            data.withUnsafeBufferPointer { scan($0, output: output, message: message) }
        }
    }

    private mutating func scan(_ buf: UnsafeBufferPointer<UInt8>,
                               output: (UnsafeBufferPointer<UInt8>) -> Void,
                               message: (JSONObject) -> Void) {
        guard let base = buf.baseAddress, !buf.isEmpty else { return }
        let n = buf.count
        let m = marker.count
        var cursor = 0
        var i = 0
        while i < n {
            guard let hit = memchr(base + i, 0x1b, n - i) else { break }
            i = UnsafeRawPointer(base).distance(to: UnsafeRawPointer(hit))
            let remain = n - i
            let isMarker = marker.withUnsafeBufferPointer { mk in
                memcmp(base + i, mk.baseAddress!, min(remain, m)) == 0
            }
            guard isMarker else { i += 1; continue }
            if remain < m {
                if i > cursor, !skippingSnapshot { output(UnsafeBufferPointer(rebasing: buf[cursor..<i])) }
                pending = Array(buf[i..<n])
                return
            }
            var end = -1
            var j = i + m
            while j + 1 < n, let e = memchr(base + j, 0x1b, n - j - 1) {
                let k = UnsafeRawPointer(base).distance(to: UnsafeRawPointer(e))
                if base[k + 1] == 0x5c { end = k; break }
                j = k + 1
            }
            if i > cursor, !skippingSnapshot { output(UnsafeBufferPointer(rebasing: buf[cursor..<i])) }
            if end < 0 {
                pending = Array(buf[i..<n])
                if pending.count > 4 * 1024 * 1024 { pending.removeAll() }
                return
            }
            if let msg = JSONCodec.decode(Data(bytes: base + i + m, count: end - i - m)) { message(msg) }
            skippingSnapshot = false
            i = end + 2
            cursor = i
        }
        if !skippingSnapshot, n > cursor { output(UnsafeBufferPointer(rebasing: buf[cursor..<n])) }
    }
}
