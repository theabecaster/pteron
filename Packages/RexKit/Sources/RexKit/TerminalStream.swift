import Foundation

/// One step of a Ghostty snapshot (`GHOSTSNP`) on its way from the stream to whatever restores it.
/// A snapshot is `begin`, `bytes` one or more times, `ready` once among them, then `end`.
public enum GhosttySnapshotPart {
    /// A snapshot starts. Anything left of an earlier, unfinished one is to be thrown away.
    case begin
    /// The snapshot's next bytes, in order. The buffer is only valid during the call.
    case bytes(UnsafeBufferPointer<UInt8>)
    /// The bytes so far end exactly after the READY record: they hold the screen, the modes and
    /// unfinished input, enough for `ghostty_snapshot_decoder_ready()`. Older history follows.
    case ready
    /// No more bytes. `complete` is true when the bytes ended exactly after the FINISH record, and
    /// false when the snapshot was cut short or grew past the limit and can't be restored.
    case end(complete: Bool)
}

/// Splits Rex's own APC messages (`ESC _ rex1;<nonce>;<json> ESC \`) out of a terminal stream,
/// and drops the leading Ghostty snapshot (everything before the first Rex message).
/// Output and messages are reported in stream order, so a resize applies exactly where the server
/// put it. Output is handed out as views into the received chunk, without copying.
///
/// With `passesSnapshot`, the leading snapshot is passed on instead of dropped, as
/// `GhosttySnapshotPart`s, all of them before the first message and before any output. Its bytes
/// are views into the received chunks too: the filter keeps none of them, so a restore can start
/// while the history is still arriving. (Only a 10-byte header cut by a chunk boundary is joined.)
///
/// Where the snapshot ends comes from its own framing, not from the first Rex message. Ghostty's
/// snapshot guide gives the layout: a 10-byte envelope (`GHOSTSNP`, then a u16 version), then
/// records of `tag u16 | payload_len u32 | CRC32C u32 | payload`, all little-endian, with an empty
/// READY record (tag 5) after the renderable state and an empty FINISH record (tag 6) at the end.
/// "Bytes after FINISH belong to the containing transport."
/// Walking the record lengths is exact, needs no scan of the payload, and can't be fooled by
/// payload bytes: a CONTINUATION record holds unfinished program input verbatim, which may be the
/// start of an APC. (A program can't guess the 64-bit nonce, so the marker scan is safe in
/// practice too; the framing is simply the stronger and cheaper test.) CRCs are left to the
/// decoder.
///
/// The snapshot ends with `end(complete: false)`, and the filter goes back to dropping everything
/// before the first Rex message, in three cases: the stream doesn't start with a version 1
/// envelope (then there is no `begin` either); a record would take the snapshot past
/// `snapshotLimit` (known from the record's header, before its payload); or a Rex message starts
/// where a record should (a snapshot cut short has no FINISH).
public struct APCFilter {
    /// The largest snapshot passed on, in bytes. The filter holds none of it; the limit protects
    /// whoever restores it.
    public static let defaultSnapshotLimit = 64 << 20

    private let marker: [UInt8]
    public private(set) var skippingSnapshot = true
    /// The start of a message split across chunks.
    private var pending: [UInt8] = []

    // Snapshot framing.
    private var inSnapshot: Bool
    private let snapshotLimit: Int
    /// True until the envelope has been read.
    private var atEnvelope = true
    /// Bytes of the current record's payload still to come.
    private var need = 0
    /// What the current record's end means.
    private var recordEnd = RecordEnd.nothing
    /// The snapshot's length so far, counting the current record in full.
    private var snapshotBytes = 0
    /// A header cut by a chunk boundary, held until it is whole and checked.
    private var header: [UInt8] = []

    private enum RecordEnd { case nothing, ready, finish }
    private static let headerSize = 10  // the envelope and a record header are both 10 bytes
    private static let magic = Array("GHOSTSNP".utf8)
    private static let version: UInt16 = 1
    private static let readyTag: UInt16 = 5
    private static let finishTag: UInt16 = 6

    public init(nonce: UInt64, passesSnapshot: Bool = false, snapshotLimit: Int = APCFilter.defaultSnapshotLimit) {
        marker = Array("\u{1b}_rex1;\(nonce);".utf8)
        inSnapshot = passesSnapshot
        self.snapshotLimit = snapshotLimit
    }

    /// `snapshot` is only called by a filter made with `passesSnapshot`.
    public mutating func process(_ chunk: Data,
                                 snapshot: (GhosttySnapshotPart) -> Void = { _ in },
                          output: (UnsafeBufferPointer<UInt8>) -> Void,
                          message: (JSONObject) -> Void) {
        if inSnapshot {
            chunk.withUnsafeBytes { raw in
                let buf = raw.bindMemory(to: UInt8.self)
                let used = passSnapshot(buf, snapshot: snapshot)
                guard used < buf.count else { return }
                // What follows the snapshot in this chunk is scanned in place.
                let rest = UnsafeBufferPointer(rebasing: buf[used...])
                if pending.isEmpty {
                    scan(rest, output: output, message: message)
                } else {
                    var data = pending
                    pending = []
                    data.append(contentsOf: rest)
                    data.withUnsafeBufferPointer { scan($0, output: output, message: message) }
                }
            }
            return
        }
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

    /// Passes on the snapshot bytes at the front of `buf`, walking the records.
    /// Returns how many bytes of `buf` belonged to the snapshot; it is over if any are left.
    private mutating func passSnapshot(_ buf: UnsafeBufferPointer<UInt8>, snapshot: (GhosttySnapshotPart) -> Void) -> Int {
        guard let base = buf.baseAddress else { return 0 }
        let n = buf.count
        var off = 0
        var sent = 0  // bytes of `buf` before this have been passed on
        func flush(_ to: Int) {
            if to > sent { snapshot(.bytes(UnsafeBufferPointer(rebasing: buf[sent..<to]))) }
            sent = to
        }
        while true {
            if need > 0 {
                let take = min(need, n - off)
                off += take
                need -= take
                if need > 0 { break }
            }
            // A record has just ended.
            switch recordEnd {
            case .nothing: break
            case .ready:
                flush(off)
                recordEnd = .nothing
                snapshot(.ready)
            case .finish:
                // Everything after FINISH is the stream.
                flush(off)
                inSnapshot = false
                skippingSnapshot = false
                snapshot(.end(complete: true))
                return off
            }
            // The next header: read in place when this chunk has all of it, joined otherwise.
            // Its bytes are passed on only once it has been checked.
            if header.isEmpty, n - off >= Self.headerSize {
                let wasEnvelope = atEnvelope
                guard let payload = readHeader(base + off) else {
                    // The bytes from here on are scanned as the old path would.
                    flush(off)
                    inSnapshot = false
                    snapshot(.end(complete: false))
                    return off
                }
                if wasEnvelope { snapshot(.begin) }
                off += Self.headerSize
                need = payload
            } else {
                flush(off)
                let take = min(Self.headerSize - header.count, n - off)
                header.append(contentsOf: UnsafeBufferPointer(rebasing: buf[off..<off + take]))
                off += take
                sent = off
                if header.count < Self.headerSize { return off }
                let wasEnvelope = atEnvelope
                guard let payload = header.withUnsafeBufferPointer({ readHeader($0.baseAddress!) }) else {
                    pending = header
                    header = []
                    inSnapshot = false
                    snapshot(.end(complete: false))
                    return off
                }
                if wasEnvelope { snapshot(.begin) }
                header.withUnsafeBufferPointer { snapshot(.bytes($0)) }
                header.removeAll(keepingCapacity: true)
                need = payload
            }
        }
        flush(off)
        return off
    }

    /// Checks the 10 bytes at `p` as the envelope or a record header. Returns the payload length
    /// that follows, or nil if the snapshot can't go on from here.
    private mutating func readHeader(_ p: UnsafePointer<UInt8>) -> Int? {
        if atEnvelope {
            guard memcmp(p, Self.magic, Self.magic.count) == 0,
                  UInt16(p[8]) | UInt16(p[9]) << 8 == Self.version else { return nil }
            atEnvelope = false
            snapshotBytes = Self.headerSize
            return 0
        }
        // A Rex message where a record should start: the snapshot was cut short.
        if memcmp(p, marker, min(Self.headerSize, marker.count)) == 0 { return nil }
        let tag = UInt16(p[0]) | UInt16(p[1]) << 8
        let len = Int(p[2]) | Int(p[3]) << 8 | Int(p[4]) << 16 | Int(p[5]) << 24
        snapshotBytes += Self.headerSize + len
        if snapshotBytes > snapshotLimit { return nil }
        recordEnd = tag == Self.finishTag ? .finish : tag == Self.readyTag ? .ready : .nothing
        return len
    }

    private mutating func scan(_ buf: UnsafeBufferPointer<UInt8>,
                               output: (UnsafeBufferPointer<UInt8>) -> Void,
                               message: (JSONObject) -> Void) {
        guard let base = buf.baseAddress, !buf.isEmpty else { return }
        let n = buf.count
        let m = marker.count
        var cursor = 0  // start of bytes not yet emitted/dropped
        var i = 0
        while i < n {
            // Jump to the next ESC.
            guard let hit = memchr(base + i, 0x1b, n - i) else { break }
            i = UnsafeRawPointer(base).distance(to: UnsafeRawPointer(hit))
            let remain = n - i
            let isMarker = marker.withUnsafeBufferPointer { mk in
                memcmp(base + i, mk.baseAddress!, min(remain, m)) == 0
            }
            guard isMarker else { i += 1; continue }
            if remain < m {
                // A marker may continue in the next chunk.
                if i > cursor, !skippingSnapshot { output(UnsafeBufferPointer(rebasing: buf[cursor..<i])) }
                pending = Array(buf[i..<n])
                return
            }
            // Find ST (ESC \) after the JSON.
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
                if pending.count > 4 * 1024 * 1024 { pending.removeAll() }  // malformed; give up
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

public protocol TerminalSink: AnyObject {
    /// Clears the terminal and sets the server's grid; a snapshot follows.
    @MainActor func streamReset(cols: Int, rows: Int)
    /// The screen and scrollback as escape sequences, applied at once.
    @MainActor func streamSnapshot(_ text: String)
    /// The whole terminal as a Ghostty snapshot (`GHOSTSNP`), in parts as it arrives. Only sent
    /// when the stream's `restoresGhosttySnapshot` is set. The parts come in this order: `begin`;
    /// `bytes` as often as chunks arrive; `ready` once, right after the bytes that end the READY
    /// record; more `bytes` (older history); `end`.
    ///
    /// The snapshot replaces everything: screen, scrollback, modes and the grid size (the restore
    /// makes a new terminal). No `streamReset` comes first, so at `begin` the sink drops output it
    /// still has queued, and anything left of an earlier snapshot that never got its `end`.
    /// Nothing else is sent between `begin` and `end`. The server's size and owner follow `end`
    /// in `streamResized`.
    ///
    /// A sink can show the terminal at `ready` (`ghostty_snapshot_decoder_ready()` on the bytes so
    /// far), before a long history has come down the wire, or just join the bytes and decode them
    /// at `end(complete: true)`.
    ///
    /// Return false from any part if the snapshot can't be restored. The sink then gets no more
    /// parts of it; once the snapshot's bytes have gone by, the stream sends `streamReset`,
    /// `streamResized` and `streamSnapshot` (from `terminal.format`) instead, as it does after
    /// `end(complete: false)`. If a restore fails after `end`, call `snapshotRestoreFailed()`.
    ///
    /// The bytes are borrowed views of the received chunks. The filter copies nothing, and the
    /// sink makes the one copy a restore needs: into the buffer its decoder reads, which has to
    /// outlive the call anyway. One array at the end would cost the same copy and hide `ready`;
    /// `Data` would add an allocation per chunk.
    @MainActor func streamGhosttySnapshot(_ part: GhosttySnapshotPart) -> Bool
    /// Live program output. The buffer is only valid during the call.
    @MainActor func streamFeed(_ bytes: UnsafeBufferPointer<UInt8>)
    @MainActor func streamResized(cols: Int, rows: Int, owner: String?)
    @MainActor func streamTheme(_ theme: JSONObject)
    @MainActor func streamExited(code: Int?)
    @MainActor func streamStatus(_ status: TerminalStream.Status)
}

extension TerminalSink {
    /// A sink that restores no snapshots refuses the first part.
    @MainActor public func streamGhosttySnapshot(_ part: GhosttySnapshotPart) -> Bool { false }
}

/// Streams one terminal block's output over `GET /api/data` (subprotocol rex.data.terminal.v1)
/// and sends typed input back over the control connection.
///
/// What the sink sees, after `streamStatus(.connecting)` and `streamStatus(.live)`:
///
/// - Normally (`restoresGhosttySnapshot` off): `streamReset`, `streamResized` and `streamSnapshot`
///   (from `terminal.format`, all three before `.live`), then `streamFeed` and messages in stream
///   order.
/// - With `restoresGhosttySnapshot`, on a fresh stream (HELLO: `start()`, `restart()`, `resync()`,
///   or a reconnect that could not resume): `streamGhosttySnapshot` with `begin`, `bytes`…,
///   `ready`, `bytes`…, `end(complete: true)`; then `streamResized` from the `resize` message that
///   follows the snapshot, then `streamTheme` if the server sends one, then `streamFeed` and
///   messages in stream order. There is no `streamReset`, and nothing is fed between `.live` and
///   the snapshot's `end`. Until `begin` the sink keeps showing what it had.
/// - On a resume (RESUME), either way: `streamStatus(.reconnecting)`, `streamStatus(.live)`, then
///   the stream goes on from the first byte not yet received, which may be in the middle of the
///   snapshot. No reset and no new snapshot.
/// - If the Ghostty snapshot can't be used (the sink returns false for a part, the snapshot ends
///   with `end(complete: false)` or never begins, or `snapshotRestoreFailed()` is called): the
///   data stream stays open. Once the snapshot's bytes have gone by, the stream's output is
///   dropped while `terminal.size` and `terminal.format` are read, then come `streamReset`,
///   `streamResized`, `streamSnapshot`, and output again. Messages (`streamResized` and the
///   others) still arrive meanwhile. From then on this stream behaves as if
///   `restoresGhosttySnapshot` were off.
@MainActor
public final class TerminalStream {
    public enum Status: Equatable { case connecting, live, reconnecting, ended(String), failed(String) }

    /// The most scrollback (bytes of escape sequences) a snapshot reads; older history is skipped.
    public static let snapshotLimit = 1 << 20

    public let control: RexControl
    public let sessionID: String
    public let blockID: String
    public weak var sink: TerminalSink?
    /// Called with a short message when a key-bound server action fails.
    public var onActionFailed: (@MainActor (String) -> Void)?

    public private(set) var serverCols = 80
    public private(set) var serverRows = 24
    public private(set) var owner: String?
    private var ws: URLSessionWebSocketTask?
    private var gen = 0
    private var filter: APCFilter?
    private var token: [UInt8]?
    private var nonce: UInt64 = 0
    private var received: UInt64 = 0
    private var stopped = false
    private var resumeAttempts = 0
    /// True while a resync reads the screen; stream output is dropped meanwhile.
    private var resyncing = false
    private var resyncSeq = 0

    /// Restore the terminal from the Ghostty snapshot that starts every fresh data stream, instead
    /// of reading it as escape sequences with `terminal.format`. Set it before `start()`.
    /// It saves the `terminal.size`, `terminal.format` and `blob_read` round trips, and the server
    /// places the snapshot exactly in the stream, so no output is lost or repeated around it.
    public var restoresGhosttySnapshot = false
    /// True once a Ghostty snapshot could not be restored. The stream then reads the screen with
    /// `terminal.format` for the rest of its life.
    public private(set) var ghosttySnapshotFailed = false
    /// Where a fresh stream's snapshot stands: expected, being passed to the sink, or going by
    /// unused (the old path takes over at its end).
    private enum SnapshotState { case none, awaiting, restoring, refused }
    private var snapshotState = SnapshotState.none
    private var usesGhosttySnapshot: Bool { restoresGhosttySnapshot && !ghosttySnapshotFailed }

    // Input is sent one write at a time; block methods are not ordered by the server.
    private var inputBuffer: [UInt8] = []
    private var writing = false
    private var inputRetry: Task<Void, Never>?
    /// Server actions bound to keys, each run after the keys typed before it.
    private var orderedWork: [@MainActor () async -> Void] = []
    private var runningWork = false
    private var workToken = 0

    public init(control: RexControl, sessionID: String, blockID: String) {
        self.control = control
        self.sessionID = sessionID
        self.blockID = blockID
    }

    public func start() {
        stopped = false
        Task { await self.fullStart() }
    }

    public func stop() {
        stopped = true
        inputRetry?.cancel()
        inputRetry = nil
        orderedWork.removeAll()
        gen += 1
        ws?.cancel(with: .normalClosure, reason: nil)
        ws = nil
    }

    /// Re-read the whole screen and open a fresh stream.
    public func restart() {
        gen += 1
        ws?.cancel(with: .normalClosure, reason: nil)
        ws = nil
        stopped = false
        Task { await self.fullStart() }
    }

    /// Re-read the screen (and scrollback) and redraw it, keeping the data stream open.
    /// Stream output that arrives while the read is in flight is dropped: the snapshot already holds it.
    ///
    /// With `restoresGhosttySnapshot` it opens a fresh data stream instead (`restart()`), whose
    /// snapshot redraws everything. That costs a ticket and a WebSocket handshake where the read
    /// costs two or three calls on the open control connection (about 5 to 16 ms against 2 ms on
    /// the same host), but it is the one that is exact: the snapshot holds all history, both
    /// screens, every mode and unfinished input, and sits at a known place in the stream. A read
    /// taken beside a running stream can drop or repeat output around it, and is cut to
    /// `snapshotLimit`. The old stream is closed first: the server refuses a second connection to
    /// the same terminal (REJECT 0x02), and a close with status 1000 ends the old stream.
    public func resync() {
        guard !stopped, ws != nil else { return }
        if usesGhosttySnapshot { restart() } else { readScreenAndRedraw() }
    }

    /// The sink could not restore a Ghostty snapshot it had accepted. Redraws from
    /// `terminal.format` on the open data stream (no reconnect), and stops using snapshots.
    public func snapshotRestoreFailed() {
        guard !ghosttySnapshotFailed else { return }
        ghosttySnapshotFailed = true
        // A snapshot still on its way gets no more parts and ends in the old path by itself.
        guard snapshotState == .none else { return }
        readScreenAndRedraw()
    }

    /// Passes one part of the stream's snapshot to the sink, or lets it go by after a refusal.
    private func handleSnapshot(_ part: GhosttySnapshotPart, sink: TerminalSink?) {
        var offer = snapshotState == .restoring
        if snapshotState == .awaiting, case .begin = part { offer = true }
        if offer {
            if !ghosttySnapshotFailed, sink?.streamGhosttySnapshot(part) == true {
                snapshotState = .restoring
            } else {
                snapshotState = .refused
                ghosttySnapshotFailed = true
            }
        }
        guard case .end(let complete) = part else { return }
        let restored = snapshotState == .restoring && complete && !ghosttySnapshotFailed
        snapshotState = .none
        if !restored {
            // Draw the screen the old way, on this same stream.
            ghosttySnapshotFailed = true
            readScreenAndRedraw()
        }
    }

    private func readScreenAndRedraw() {
        guard !stopped, ws != nil else { return }
        let myGen = gen
        resyncSeq += 1
        let mySeq = resyncSeq
        resyncing = true
        Task {
            defer { if mySeq == self.resyncSeq { self.resyncing = false } }
            do {
                let size = try await control.blockCall("com.superlogical.terminal.size", session: sessionID, block: blockID)
                let screen = try await readScreen()
                // A newer resync or a full restart supersedes this one.
                guard myGen == gen, mySeq == resyncSeq, !stopped else { return }
                serverCols = max(size.int("columns") ?? serverCols, 2)
                serverRows = max(size.int("rows") ?? serverRows, 2)
                owner = size.str("owner")
                sink?.streamReset(cols: serverCols, rows: serverRows)
                sink?.streamResized(cols: serverCols, rows: serverRows, owner: owner)
                sink?.streamSnapshot(screen)
            } catch {
                guard myGen == gen, mySeq == resyncSeq, !stopped else { return }
                restart()
            }
        }
    }

    private func fullStart() async {
        gen += 1
        resyncing = false
        snapshotState = .none
        let myGen = gen
        // The stream's own snapshot replaces step 1; the size comes from the `resize` after it.
        let fromSnapshot = usesGhosttySnapshot
        sink?.streamStatus(.connecting)
        do {
            if !fromSnapshot {
                // 1. Size and current contents, as escape sequences.
                let size = try await control.blockCall("com.superlogical.terminal.size", session: sessionID, block: blockID)
                serverCols = max(size.int("columns") ?? 80, 2)
                serverRows = max(size.int("rows") ?? 24, 2)
                owner = size.str("owner")
                let initial = try await readScreen()
                guard myGen == gen, !stopped else { return }
                sink?.streamReset(cols: serverCols, rows: serverRows)
                sink?.streamResized(cols: serverCols, rows: serverRows, owner: owner)
                sink?.streamSnapshot(initial)
            }

            // 2. Ticket, then the data WebSocket.
            let t = try await control.call("data.connect", [
                "session_id": sessionID, "block_id": blockID,
                "data_ref_id": "terminal", "subprotocol": "rex.data.terminal.v1",
            ])
            guard let ticketStr = t.str("ticket"), let hello = DataFrame.ticketHello(ticketStr) else {
                throw RexError.local("bad ticket")
            }
            guard myGen == gen, !stopped else { return }
            try await openData(hello: hello, gen: myGen, fresh: true, collectSnapshot: fromSnapshot)
        } catch {
            guard myGen == gen, !stopped else { return }
            sink?.streamStatus(.failed(error.localizedDescription))
            // Retry later.
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if myGen == gen, !stopped, control.state == .connected { await fullStart() }
        }
    }

    /// The screen and the newest scrollback as escape sequences (`format` vt).
    /// A long history is cut to its last `snapshotLimit` bytes, keeping the leading palette.
    private func readScreen() async throws -> String {
        var args: JSONObject = ["format": "vt", "max_bytes": 65_536]
        for k in ["extra_charsets", "extra_cursor", "extra_hyperlink", "extra_keyboard", "extra_kitty_keyboard",
                  "extra_modes", "extra_palette", "extra_protection", "extra_scrolling_region", "extra_style", "extra_tabstops"] {
            args[k] = true
        }
        let r = try await control.blockCall("com.superlogical.terminal.format", session: sessionID, block: blockID, args: args)
        var content = r.str("content") ?? ""
        guard let id = r.int("id") else { return content }
        let total = r.int("total") ?? 0
        var offset = content.utf8.count
        var skipPartialLine = false
        if total - offset > Self.snapshotLimit {
            content = Self.leadingOSC(content) + "\u{1b}[0m"
            offset = total - Self.snapshotLimit
            skipPartialLine = true
        }
        var tail = ""
        for _ in 0..<40 {
            let more = try await control.blockCall("com.superlogical.terminal.blob_read", session: sessionID, block: blockID,
                                                   args: ["id": id, "offset": offset, "max_bytes": 900_000])
            let data = more.str("data") ?? ""
            tail += data
            offset += data.utf8.count
            if more.bool("eof") == true || data.isEmpty { break }
        }
        if skipPartialLine, let nl = tail.firstIndex(of: "\n") {
            tail = String(tail[tail.index(after: nl)...])
        }
        return content + tail
    }

    /// The OSC sequences (palette and the like) at the start of a vt snapshot.
    private static func leadingOSC(_ s: String) -> String {
        let u = Array(s.utf8)
        var i = 0
        while i + 1 < u.count, u[i] == 0x1b, u[i + 1] == 0x5d {
            var j = i + 2
            var next = -1
            while j < u.count {
                if u[j] == 0x07 { next = j + 1; break }
                if u[j] == 0x1b, j + 1 < u.count, u[j + 1] == 0x5c { next = j + 2; break }
                j += 1
            }
            guard next > 0 else { break }
            i = next
        }
        return String(decoding: u[0..<i], as: UTF8.self)
    }

    private func openData(hello: [UInt8], gen myGen: Int, fresh: Bool, collectSnapshot: Bool = false) async throws {
        guard let base = control.wsBase else { throw RexError.local("invalid server address") }
        let url = base.appendingPathComponent("api/data")
        let task = control.session.webSocketTask(with: url, protocols: ["rex.data.terminal.v1"])
        task.maximumMessageSize = 1 << 20
        ws = task
        task.resume()
        try await task.send(.data(Data(hello)))
        let first = try await task.receive()
        guard case .data(let d) = first else { throw RexError.local("bad handshake") }
        let welcome = try DataFrame.welcome([UInt8](d))
        token = welcome.token
        // A resume keeps its filter: it may be partway through the snapshot or a message.
        if fresh { beginStream(nonce: welcome.nonce, collectSnapshot: collectSnapshot) }
        resumeAttempts = 0
        sink?.streamStatus(.live)
        receive(task, gen: myGen)
    }

    private func receive(_ task: URLSessionWebSocketTask, gen myGen: Int) {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, myGen == self.gen else { return }
                switch result {
                case .success(.data(let d)):
                    self.received += UInt64(d.count)
                    self.consume(d)
                    self.receive(task, gen: myGen)
                case .success:
                    self.receive(task, gen: myGen)
                case .failure:
                    self.handleDataDrop(task, gen: myGen)
                }
            }
        }
    }

    /// A fresh stream starts: byte count zero and a new filter. (Internal for tests.)
    func beginStream(nonce nn: UInt64, collectSnapshot: Bool) {
        nonce = nn
        received = 0
        filter = APCFilter(nonce: nn, passesSnapshot: collectSnapshot)
        snapshotState = collectSnapshot ? .awaiting : .none
    }

    /// Splits a chunk of the stream and passes it on. (Internal for tests.)
    func consume(_ chunk: Data) {
        guard filter != nil else { return }
        let sink = self.sink
        // In order: a resize applies between the bytes written before and after it.
        filter!.process(chunk, snapshot: { part in
            self.handleSnapshot(part, sink: sink)
        }, output: { out in
            // While a resync reads the screen, its snapshot replaces this output.
            if !self.resyncing { sink?.streamFeed(out) }
        }, message: { m in
            switch m.str("type") {
            case "resize":
                let c = m.int("cols") ?? self.serverCols, r = m.int("rows") ?? self.serverRows
                self.owner = m["owner"] as? String
                self.serverCols = max(c, 2); self.serverRows = max(r, 2)
                sink?.streamResized(cols: self.serverCols, rows: self.serverRows, owner: self.owner)
            case "theme":
                sink?.streamTheme(m)
            case "child_exited":
                sink?.streamExited(code: m.int("exit_code"))
            default: break
            }
        })
    }

    private func handleDataDrop(_ task: URLSessionWebSocketTask, gen myGen: Int) {
        guard !stopped, myGen == gen else { return }
        if task.closeCode.rawValue == 4000 {
            sink?.streamStatus(.ended("pane closed"))
            return
        }
        sink?.streamStatus(.reconnecting)
        resumeAttempts += 1
        // 1013: the server dropped the stream (e.g. too much output piled up); a resume can't work.
        // Any failed resume (stale token, byte count off) also ends in a fresh read of the screen.
        guard let tok = token, resumeAttempts <= 3, task.closeCode.rawValue != 1013 else {
            Task { await self.fullStart() }
            return
        }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(400_000_000 * resumeAttempts))
            guard myGen == self.gen, !self.stopped else { return }
            do {
                try await self.openData(hello: DataFrame.resumeHello(token: tok, received: self.received), gen: myGen, fresh: false)
            } catch {
                await self.fullStart()
            }
        }
    }

    // MARK: Input

    public func send(_ bytes: [UInt8]) {
        inputBuffer.append(contentsOf: bytes)
        pump()
    }

    public func send(text: String) { send(Array(text.utf8)) }

    /// Sends typed input now. Keys typed while a write is in flight go out together right after it.
    /// Input is never dropped by a lost connection: it waits and goes out once the server is back.
    private func pump() {
        guard !writing, !runningWork, !stopped else { return }
        guard !inputBuffer.isEmpty else { runOrderedWork(); return }
        guard control.state == .connected else { retryInput(); return }
        writing = true
        let chunk = inputBuffer
        inputBuffer.removeAll()
        let text = String(decoding: chunk, as: UTF8.self)
        Task {
            do {
                _ = try await control.blockCall("com.superlogical.terminal.write", session: sessionID, block: blockID, args: ["data": text])
            } catch let e as RexError where e.code != "client" {
                // The server refused it (e.g. the pane closed); resending won't help.
            } catch {
                // Connection trouble: keep the keys, in order, ahead of anything typed since.
                self.inputBuffer.insert(contentsOf: chunk, at: 0)
                self.writing = false
                self.retryInput()
                return
            }
            self.writing = false
            self.pump()
        }
    }

    /// Runs `work` once every key typed before it has been written; keys typed after wait for it.
    private func afterInput(_ work: @escaping @MainActor () async -> Void) {
        orderedWork.append(work)
        pump()
    }

    private func runOrderedWork() {
        guard !runningWork, !writing, inputBuffer.isEmpty, !orderedWork.isEmpty, !stopped else { return }
        runningWork = true
        workToken += 1
        let token = workToken
        let work = orderedWork.removeFirst()
        // A slow action (a Lua function may run for seconds) holds typing back at most this long.
        let release = { @MainActor in
            guard self.runningWork, self.workToken == token else { return }
            self.runningWork = false
            self.pump()
        }
        Task { await work(); release() }
        Task { try? await Task.sleep(nanoseconds: 1_500_000_000); release() }
    }

    /// Runs a block or configuration-file action on this pane (`client.action`), as a key binding
    /// does on the Mac. Returns the client actions the server asks this client to perform.
    public func perform(action: String, args: JSONObject?, then: @escaping @MainActor ([JSONObject]) -> Void) {
        afterInput { [sessionID, blockID, control, weak self] in
            var p: JSONObject = ["action": action, "origin": "key", "session_id": sessionID, "block_id": blockID]
            if let args, !args.isEmpty { p["args"] = args }
            do {
                let r = try await control.call("client.action", p)
                then(r.arr("client_actions"))
            } catch {
                self?.onActionFailed?("Couldn't run \(action). \((error as? RexError)?.message ?? error.localizedDescription)")
            }
        }
    }

    /// Sends a key to the server's Lua key bindings (`client.key`); unhandled, it reaches this pane.
    public func forward(key: JSONObject) {
        afterInput { [sessionID, blockID, control] in
            _ = try? await control.call("client.key", ["session_id": sessionID, "block_id": blockID, "key": key])
        }
    }

    private func retryInput() {
        guard inputRetry == nil, !stopped else { return }
        inputRetry = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            self.inputRetry = nil
            self.pump()
        }
    }

    // MARK: Ownership / sizing

    public func claimAndResize(cols: Int, rows: Int) async {
        _ = try? await control.call("session.own_block", ["session_id": sessionID, "block_ids": [blockID], "mode": "take"])
        _ = try? await control.blockCall("com.superlogical.terminal.resize", session: sessionID, block: blockID,
                                         args: ["columns": cols, "rows": rows])
    }

    public func release() async {
        _ = try? await control.call("session.disown_block", ["session_id": sessionID, "block_ids": [blockID]])
    }
}
