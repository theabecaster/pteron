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
/// before the first Rex message, in these cases: the stream doesn't start with a version 1
/// envelope (then there is no `begin` either); a record is longer than `recordLimit` or would
/// take the snapshot past `snapshotLimit` (known from the record's header, before its payload);
/// or a Rex message starts where a record should (a snapshot cut short has no FINISH).
///
/// The framing is only trusted while someone restores the snapshot. A wrong length in a damaged
/// record would make the filter take what follows, Rex messages included, for payload. So when
/// `snapshot` returns false, or `abandonSnapshot()` is called, the filter stops walking records
/// at once and scans for the first Rex message again. The record limit bounds what a wrong length
/// can take before that.
public struct APCFilter {
    /// The largest snapshot passed on, in bytes. The filter holds none of it; the limit protects
    /// whoever restores it.
    public static let defaultSnapshotLimit = 16 << 20
    /// The longest record payload accepted. The format has no limit of its own (the length is a
    /// u32). Real records are far smaller: a page is a few KB, READY and FINISH are empty, and
    /// only unfinished input (the decoder's default limit is 65 MiB) and the pixels of a Kitty
    /// image can grow. A larger record is treated as damage.
    public static let defaultRecordLimit = 8 << 20

    private let marker: [UInt8]
    public private(set) var skippingSnapshot = true
    /// The start of a message split across chunks.
    private var pending: [UInt8] = []

    // Snapshot framing.
    private var inSnapshot: Bool
    private let snapshotLimit: Int
    private let recordLimit: Int
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

    public init(nonce: UInt64, passesSnapshot: Bool = false, snapshotLimit: Int = APCFilter.defaultSnapshotLimit,
                recordLimit: Int = APCFilter.defaultRecordLimit) {
        marker = Array("\u{1b}_rex1;\(nonce);".utf8)
        inSnapshot = passesSnapshot
        self.snapshotLimit = snapshotLimit
        self.recordLimit = recordLimit
    }

    /// Stops passing the snapshot on, without an `end`: what is left of it is dropped by scanning
    /// for the first Rex message, as when snapshots aren't passed at all.
    public mutating func abandonSnapshot() {
        guard inSnapshot else { return }
        inSnapshot = false
        pending = header
        header = []
    }

    /// `snapshot` is only called by a filter made with `passesSnapshot`. Returning false from it
    /// abandons the snapshot: no more parts follow.
    public mutating func process(_ chunk: Data,
                                 snapshot: (GhosttySnapshotPart) -> Bool = { _ in true },
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
    private mutating func passSnapshot(_ buf: UnsafeBufferPointer<UInt8>, snapshot: (GhosttySnapshotPart) -> Bool) -> Int {
        guard let base = buf.baseAddress else { return 0 }
        let n = buf.count
        var off = 0
        var sent = 0  // bytes of `buf` before this have been passed on
        /// Passes on the bytes up to `to`. False if the snapshot was refused.
        func flush(_ to: Int) -> Bool {
            defer { sent = to }
            return to > sent ? snapshot(.bytes(UnsafeBufferPointer(rebasing: buf[sent..<to]))) : true
        }
        // After a refusal the framing is no longer trusted: the bytes from `off` on, which may
        // not be what the record lengths say, are scanned for the first Rex message.
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
                recordEnd = .nothing
                guard flush(off), snapshot(.ready) else { inSnapshot = false; return off }
            case .finish:
                // Everything after FINISH is the stream.
                let passed = flush(off)
                inSnapshot = false
                skippingSnapshot = false
                if passed { _ = snapshot(.end(complete: true)) }
                return off
            }
            // The next header: read in place when this chunk has all of it, joined otherwise.
            // Its bytes are passed on only once it has been checked.
            if header.isEmpty, n - off >= Self.headerSize {
                let wasEnvelope = atEnvelope
                guard let payload = readHeader(base + off) else {
                    // The bytes from here on are scanned as the old path would.
                    let passed = flush(off)
                    inSnapshot = false
                    if passed { _ = snapshot(.end(complete: false)) }
                    return off
                }
                if wasEnvelope, !snapshot(.begin) { inSnapshot = false; return off }
                off += Self.headerSize
                need = payload
            } else {
                guard flush(off) else { inSnapshot = false; return off }
                let take = min(Self.headerSize - header.count, n - off)
                header.append(contentsOf: UnsafeBufferPointer(rebasing: buf[off..<off + take]))
                off += take
                sent = off
                if header.count < Self.headerSize { return off }
                let wasEnvelope = atEnvelope
                let held = header
                header.removeAll(keepingCapacity: true)
                let payload = held.withUnsafeBufferPointer { readHeader($0.baseAddress!) }
                guard let payload else {
                    pending = held
                    inSnapshot = false
                    _ = snapshot(.end(complete: false))
                    return off
                }
                if wasEnvelope, !snapshot(.begin) { inSnapshot = false; pending = held; return off }
                guard held.withUnsafeBufferPointer({ snapshot(.bytes($0)) }) else { inSnapshot = false; return off }
                need = payload
            }
        }
        if !flush(off) { inSnapshot = false }
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
        if len > recordLimit || snapshotBytes > snapshotLimit { return nil }
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
    /// Clears the terminal and sets the server's grid; `streamSnapshot` follows. Only after a
    /// Ghostty snapshot could not be restored.
    @MainActor func streamReset(cols: Int, rows: Int)
    /// The screen and scrollback as escape sequences, applied at once: the fallback for a
    /// Ghostty snapshot that could not be restored.
    @MainActor func streamSnapshot(_ text: String)
    /// The whole terminal as a Ghostty snapshot (`GHOSTSNP`), in parts as it arrives, at the
    /// start of every fresh stream. The parts come in this order: `begin`;
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
    /// The catch-up fence went up or came down (`TerminalStream.isFenced`). While it is up the
    /// screen may be behind the program, and typed input is held, not sent. `screen` is false
    /// when it goes up over a pane that has shown nothing yet.
    @MainActor func streamFence(_ up: Bool, screen: Bool)
    /// Calls `done` once everything passed to the sink so far has been parsed into the screen.
    /// A sink that parses as it is fed calls it at once.
    @MainActor func streamWhenParsed(_ done: @escaping @MainActor () -> Void)
}

public extension TerminalSink {
    @MainActor func streamFence(_ up: Bool, screen: Bool) {}
    @MainActor func streamWhenParsed(_ done: @escaping @MainActor () -> Void) { done() }
}

/// Streams one terminal block's output over `GET /api/data` (subprotocol rex.data.terminal.v1)
/// and sends typed input back over the control connection.
///
/// What the sink sees, after `streamStatus(.connecting)` and `streamStatus(.live)`:
///
/// - On a fresh stream (HELLO: `start()`, `restart()`, `resync()`, or a reconnect that could
///   not resume): `streamGhosttySnapshot` with `begin`, `bytes`…,
///   `ready`, `bytes`…, `end(complete: true)`; then `streamResized` from the `resize` message that
///   follows the snapshot, then `streamTheme` if the server sends one, then `streamFeed` and
///   messages in stream order. There is no `streamReset`, and nothing is fed between `.live` and
///   the snapshot's `end`. Until `begin` the sink keeps showing what it had.
/// - On a resume (RESUME): `streamStatus(.reconnecting)`, `streamStatus(.live)`, then
///   the stream goes on from the first byte not yet received, which may be in the middle of the
///   snapshot. No reset and no new snapshot.
/// - If the Ghostty snapshot can't be used (the sink returns false for a part, the snapshot ends
///   with `end(complete: false)` or never begins, or `snapshotRestoreFailed()` is called): the
///   data stream stays open. Once the snapshot's bytes have gone by, the stream's output is
///   dropped while `terminal.size` and `terminal.format` are read, then come `streamReset`,
///   `streamResized`, `streamSnapshot`, and output again. Messages (`streamResized` and the
///   others) still arrive meanwhile. From then on this stream uses no snapshots
///   (`ghosttySnapshotFailed`): a fresh start sends `streamReset`, `streamResized` and
///   `streamSnapshot` (from `terminal.format`) before `.live`, then `streamFeed` and messages in
///   stream order, and `resync()` reads the screen the same way.
///
/// Backpressure. `pauseReading()` stops the stream from asking its data socket for more, so
/// output piles up at the server (which holds a bounded buffer and drops the stream past it:
/// close 1013, then a fresh start with a snapshot) instead of in the sink. `resumeReading()`
/// goes on with the next message, in order. Control messages and input are not affected.
///
/// Reconnecting. `RexControl` is the only thing that retries a lost connection. The stream:
///
/// - When its data socket drops, sends one RESUME after `resumeDelay`, if the server can still
///   have the stream (`canResume`). A RESUME needs no control connection.
/// - If that fails, or can't be tried, makes a fresh start (ticket, HELLO), which needs the control
///   connection. Without one it does nothing but wait (`waitingForControl`), showing
///   `.reconnecting`; `RexControl` tells it when it is connected again (`observeConnected`), and
///   it then makes exactly one start: a RESUME if the server still keeps the stream, else a fresh
///   one.
/// - If a fresh start fails although the control connection is up (the server refused the ticket
///   or the HELLO, the data socket failed), tries again after `retryDelays`: 3 s, doubling, at most
///   30 s, back to 3 s after the next WELCOME. It reports `.failed` meanwhile.
///
/// `stop()` and `restart()` end whatever was waiting: every wait checks `gen` when it wakes.
///
/// The catch-up fence. Input goes out only while the screen is known to be current. From a
/// start, a drop, a wake or a restart until the stream has caught up (`CatchUpFence` has the
/// rules), typed bytes are held and everything else is dropped; the sink hears `streamFence`.
@MainActor
public final class TerminalStream {
    public enum Status: Equatable { case connecting, live, reconnecting, ended(String), failed(String) }

    /// The most scrollback (bytes of escape sequences) a snapshot reads; older history is skipped.
    public static let snapshotLimit = 1 << 20

    public let control: RexControl
    /// `control`, or a fake in tests. Everything the stream does on the control connection goes
    /// through here.
    private let link: any StreamLink
    public let sessionID: String
    public let blockID: String
    public weak var sink: TerminalSink?
    /// Called with a short message for the user when a key-bound server action fails, or when
    /// typed input was dropped because the connection broke while it was being sent (see `send`).
    public var onActionFailed: (@MainActor (String) -> Void)?

    public private(set) var serverCols = 80
    public private(set) var serverRows = 24
    public private(set) var owner: String?
    private var ws: (any StreamSocket)?
    /// Counts starts and stops. Work begun under an older value is stale and must do nothing.
    private(set) var gen = 0
    private var filter: APCFilter?
    /// True while a chunk is being split: the filter is in use and can't be changed.
    private var consuming = false
    /// The latest WELCOME's reconnect token; nil once the server can't resume the stream.
    private var token: [UInt8]?
    private var nonce: UInt64 = 0
    private var received: UInt64 = 0
    private var stopped = false
    /// True from a WELCOME until the socket drops or the stream is stopped or restarted.
    private var live = false
    /// How long the server keeps a dropped stream for a RESUME (from the WELCOME).
    private var resumeWindow: Duration = .zero
    /// When the data socket dropped.
    private var droppedAt: ContinuousClock.Instant?
    /// A start is owed as soon as the control connection is back. (Internal for tests.)
    private(set) var waitingForControl = false
    /// Counts the control connection's connects, to tell a start that failed on an old connection.
    private var connectEpoch = 0
    /// Fresh starts that failed in a row with the control connection up; indexes `retryDelays`.
    private var failedStarts = 0
    /// True while a resync reads the screen; stream output is dropped meanwhile.
    private var resyncing = false
    private var resyncSeq = 0
    /// True between `pauseReading()` and `resumeReading()`.
    public private(set) var readingPaused = false
    /// The receive loop, waiting to be allowed its next read.
    private var readWaiter: CheckedContinuation<Void, Never>?

    /// True once a Ghostty snapshot could not be restored. The stream then reads the screen with
    /// `terminal.format` for the rest of its life. Until then the terminal is restored from the
    /// snapshot that starts every fresh data stream: no `terminal.size`, `terminal.format` and
    /// `blob_read` round trips, and the server places the snapshot exactly in the stream, so no
    /// output is lost or repeated around it.
    public private(set) var ghosttySnapshotFailed = false
    /// Where a fresh stream's snapshot stands: expected, being passed to the sink, or going by
    /// unused (the old path takes over at the first Rex message, which follows the snapshot).
    private enum SnapshotState { case none, awaiting, restoring, refused }
    private var snapshotState = SnapshotState.none
    private var usesGhosttySnapshot: Bool { !ghosttySnapshotFailed }

    /// The server refused the HELLO or RESUME (REJECT).
    struct Refused: LocalizedError {
        let reason: UInt8
        var errorDescription: String? { "stream refused (reason \(reason)) (client)" }
    }
    /// REJECT 0x02: this client still has a connection to the terminal. After `restart()` that is
    /// the old socket, whose close the server hasn't handled yet; it is gone moments later.
    static let busyReason: UInt8 = 0x02
    static let busyRetryLimit = 6
    static let busyRetryDelay: UInt64 = 50_000_000
    /// Whether a refused HELLO is worth another try right away, with a new ticket.
    static func retriesHello(reason: UInt8, attempt: Int) -> Bool {
        reason == busyReason && attempt < busyRetryLimit
    }
    /// The pause before the one RESUME after a drop, so a network that is changing can settle.
    var resumeDelay: Duration = .milliseconds(400)
    /// The pause before each further fresh start while the control connection is up and starts
    /// keep failing; the last one repeats. A terminal that stays busy (REJECT 0x02) costs
    /// `busyRetryLimit + 1` tickets on the first start and one on each later one.
    static let retryDelays: [Duration] = [.seconds(3), .seconds(6), .seconds(12), .seconds(24), .seconds(30)]
    static func retryDelay(afterFailures n: Int) -> Duration { retryDelays[min(max(n, 1), retryDelays.count) - 1] }
    /// Right after the control connection is back, a ticket is refused (`conflict`) until the
    /// app's resync has attached the session again. That is moments away, so those starts are
    /// tried again after `attachRetryDelay`, up to `attachRetryLimit` times, before the backoff.
    static let attachRetryDelay: Duration = .milliseconds(250)
    static let attachRetryLimit = 8
    private var attachRetries = 0
    /// Every wait goes through here, so tests can see the waits and skip them.
    var sleep: @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) } {
        didSet { fence.sleep = sleep }
    }

    /// Holds input while the screen may be behind the program (`CatchUpFence`).
    let fence = CatchUpFence()
    /// The screen may be behind the program: typed input is held and everything else dropped.
    public var isFenced: Bool { fence.isUp }
    /// What the user is told when the fence dropped input.
    public static let fenceDroppedMessage = "The pane changed. Nothing was sent."
    /// True once the sink has been given a screen (a snapshot or a screen read).
    private var hasScreen = false

    public convenience init(control: RexControl, sessionID: String, blockID: String) {
        self.init(control: control, link: control, sessionID: sessionID, blockID: blockID)
    }

    /// `link` stands in for `control` in tests.
    init(control: RexControl, link: any StreamLink, sessionID: String, blockID: String) {
        self.control = control
        self.link = link
        self.sessionID = sessionID
        self.blockID = blockID
        link.observeConnected { [weak self] in
            guard let self else { return false }
            self.controlConnected()
            return true
        }
        wireFence()
    }

    /// The fence's four ties to the stream.
    private func wireFence() {
        fence.onChange = { [weak self] up in
            guard let self else { return }
            self.sink?.streamFence(up, screen: self.hasScreen)
            // What waited in the queue behind the fence goes now.
            if !up { self.pump() }
        }
        fence.onStale = { [weak self] in
            guard let self, !self.inputQueue.isEmpty else { return false }
            self.dropQueue(ended: true)
            return true
        }
        // Held keys go out through the same queue as any typed key.
        fence.onFlush = { [weak self] bytes in self?.enqueueText(bytes) }
        fence.onDropped = { [weak self] in self?.onActionFailed?(Self.fenceDroppedMessage) }
        fence.drained = { [weak self] done in
            guard let sink = self?.sink else { return done() }
            sink.streamWhenParsed(done)
        }
    }

    /// The host asked the server for a new size for this pane (true), or that ended: the pane
    /// was resized, the claim was given up, or another client took it. While one is on its way
    /// a raised fence stays up: the resize changes the screen.
    public func setClaimPending(_ pending: Bool) { fence.setClaimPending(pending) }
    public var isClaimPending: Bool { fence.claimPending }

    /// Runs `body` once the screen is current: now if the fence is down, else when it comes
    /// down. Never, if the stream stops first.
    public func whenCurrent(_ body: @escaping @MainActor () -> Void) { fence.whenDown(body) }

    /// The caller dropped input of its own because the fence is up (a mouse report says
    /// nothing; a typed path or a key's action tells the user, once per fence).
    public func noteFenceDrop() { fence.noteDropped() }

    public func start() {
        stopped = false
        failedStarts = 0
        attachRetries = 0
        control.streamStarted(self)
        fence.raise(exact: false)
        Task { await self.fullStart() }
    }

    /// Ends the stream for a pane that is closed or off screen. Input still queued is dropped:
    /// keys typed for a pane must not go out when it is opened again later.
    public func stop() {
        stopped = true
        gen += 1
        live = false
        waitingForControl = false
        token = nil
        failedStarts = 0
        attachRetries = 0
        dropInput()
        fence.reset()
        hasScreen = false
        // A write still out ends on its own; a read waiting for this pane's input waits no more.
        hasPendingInput = false
        control.inputActivity.remove(ObjectIdentifier(self))
        control.streamStopped(self)
        ws?.close()
        ws = nil
        wakeReader()
    }

    deinit {
        // A stream that goes without `stop()` takes its input out of the count, so no read
        // waits on it.
        let activity = control.inputActivity, key = ObjectIdentifier(self)
        Task { @MainActor in activity.remove(key) }
    }

    /// Re-read the whole screen and open a fresh stream. Queued input is kept.
    public func restart() {
        fence.raise(exact: hasScreen)
        gen += 1
        live = false
        waitingForControl = false
        // The old stream is over: a status 1000 close ends it on the server.
        token = nil
        ws?.close()
        ws = nil
        wakeReader()
        stopped = false
        Task { await self.fullStart() }
    }

    /// How long `wake()` waits for the data socket to answer a ping before it drops it.
    var wakeTimeout: Duration = .milliseconds(2500)
    /// The socket `wake()` pinged, until it answers.
    private var unansweredPing: ObjectIdentifier?

    /// Back in the foreground. A data socket that looks open may have died while the app was
    /// suspended, and the screen would stay frozen until it times out. So it is pinged: a socket
    /// that fails is handled like any drop, and one that doesn't answer within `wakeTimeout` is
    /// dropped (`abort`, no status 1000). Either way the stream goes on with a RESUME while the
    /// server keeps it, with no new snapshot and no control connection, else with a fresh start.
    /// A socket that answers is live, and nothing happens.
    public func wake() {
        guard !stopped, live, let socket = ws else { return }
        let myGen = gen, sleep = self.sleep, timeout = wakeTimeout
        let id = ObjectIdentifier(socket)
        unansweredPing = id
        // Until the socket answers, nobody knows what the program wrote meanwhile.
        fence.raise(exact: hasScreen)
        Task { [weak self] in
            let answered = (try? await socket.ping()) != nil
            guard let self, self.unansweredPing == id else { return }
            self.unansweredPing = nil
            // The waiting `receive` fails with the socket and handles the drop.
            if !answered { self.drop(socket, gen: myGen) } else if myGen == self.gen, self.live { self.fence.arrived() }
        }
        Task { [weak self] in
            await sleep(timeout)
            guard let self, self.unansweredPing == id else { return }
            self.unansweredPing = nil
            self.drop(socket, gen: myGen)
        }
    }

    /// Ends a socket that stopped answering, if it is still this stream's: its `receive` fails,
    /// and `handleDataDrop` takes it from there.
    private func drop(_ socket: any StreamSocket, gen myGen: Int) {
        guard myGen == gen, !stopped, ws === socket else { return }
        socket.abort()
    }

    /// Stops reading the data socket: the message being waited for, if any, is still taken and
    /// passed on, and no further one is asked for until `resumeReading()`. For a sink that has
    /// more output than it can hold (see "Backpressure" above). The state outlives reconnects,
    /// `stop()` and `restart()`: only `resumeReading()` ends it. The byte count a RESUME sends
    /// is not affected: it counts what was taken.
    public func pauseReading() { readingPaused = true }

    /// Goes on reading where `pauseReading()` stopped.
    public func resumeReading() {
        readingPaused = false
        wakeReader()
    }

    /// Lets a paused receive loop look again: reading was resumed, or its stream is over (`gen`).
    private func wakeReader() {
        readWaiter?.resume()
        readWaiter = nil
    }

    /// Returns once reading is allowed, or at once when `myGen` is no longer the stream's.
    private func waitToRead(gen myGen: Int) async {
        while readingPaused, myGen == gen {
            await withCheckedContinuation { readWaiter = $0 }
        }
    }

    /// The control connection is connected (again).
    private func controlConnected() {
        connectEpoch += 1
        attachRetries = 0
        if waitingForControl, !stopped {
            waitingForControl = false
            let myGen = gen
            Task {
                guard myGen == self.gen, !self.stopped else { return }
                if self.canResume { await self.resume(gen: myGen) } else { await self.fullStart() }
            }
        }
        pump()
    }

    /// Nothing can be done until the control connection is back; `controlConnected()` goes on.
    private func waitForControl() {
        waitingForControl = true
        sink?.streamStatus(.reconnecting)
    }

    /// Whether the server can still have the dropped stream: there was a WELCOME, no refusal
    /// since, and the time it keeps a stream for hasn't passed.
    private var canResume: Bool {
        guard token != nil, let droppedAt else { return false }
        return ContinuousClock.now - droppedAt < resumeWindow
    }

    /// Re-read the screen (and scrollback) and redraw it, keeping the data stream open.
    /// Stream output that arrives while the read is in flight is dropped, on the assumption that
    /// the read holds it. That is not exact, because the read and the stream aren't tied together:
    /// output the program writes after the server has formatted the screen, and that arrives
    /// before the read's last call returns, is dropped and lost; output from before the format
    /// whose frames arrive after the read is drawn a second time.
    ///
    /// That is the path of a stream whose snapshot failed. Otherwise it opens a fresh data
    /// stream instead (`restart()`), whose snapshot redraws everything. That costs a ticket and a WebSocket handshake where the read
    /// costs two or three calls on the open control connection (about 5 to 16 ms against 2 ms on
    /// the same host), but it is the one that is exact: the snapshot holds all history, both
    /// screens, every mode and unfinished input, and sits at a known place in the stream. A read
    /// taken beside a running stream can drop or repeat output around it, and is cut to
    /// `snapshotLimit`. The old stream is closed first: the server refuses a second connection to
    /// the same terminal (REJECT 0x02), and a close with status 1000 ends the old stream.
    ///
    /// It does nothing while the stream isn't live. A start that is under way, or owed once the
    /// connection is back, draws everything anyway, and a second one would only cost a ticket.
    public func resync() {
        guard !stopped, ws != nil else { return }
        if !usesGhosttySnapshot { readScreenAndRedraw() } else if live { restart() }
    }

    /// The sink could not restore a Ghostty snapshot it had accepted. Redraws from
    /// `terminal.format` on the open data stream (no reconnect), and stops using snapshots.
    public func snapshotRestoreFailed() {
        guard !ghosttySnapshotFailed else { return }
        ghosttySnapshotFailed = true
        switch snapshotState {
        case .none:
            readScreenAndRedraw()
        case .awaiting, .restoring:
            // The snapshot is still on its way. It gets no more parts, and its framing is no
            // longer trusted: the filter scans for the first Rex message, where the read starts.
            // (Called from inside a part, the filter is told by that part's false result.)
            snapshotState = .refused
            if !consuming { filter?.abandonSnapshot() }
        case .refused:
            break
        }
    }

    /// Passes one part of the stream's snapshot to the sink. False once the snapshot can't be
    /// restored: the filter then stops walking its records.
    private func handleSnapshot(_ part: GhosttySnapshotPart, sink: TerminalSink?) -> Bool {
        var offer = snapshotState == .restoring
        if snapshotState == .awaiting, case .begin = part { offer = true }
        var ok = false
        if offer, !ghosttySnapshotFailed {
            // The sink may also report a failure from inside the call.
            ok = sink?.streamGhosttySnapshot(part) == true && !ghosttySnapshotFailed
        }
        if case .end(let complete) = part {
            if ok, complete {
                snapshotState = .none
                hasScreen = true
                fence.arrived()
                return true
            }
        } else if ok {
            snapshotState = .restoring
            return true
        }
        // Draw the screen the old way, on this same stream, from the first Rex message on.
        ghosttySnapshotFailed = true
        snapshotState = .refused
        return false
    }

    /// Reads the screen with `terminal.format` and redraws it. Stream output is dropped until the
    /// read is done; see `resync()` for what that can lose or repeat.
    private func readScreenAndRedraw() {
        guard !stopped, ws != nil else { return }
        let myGen = gen
        resyncSeq += 1
        let mySeq = resyncSeq
        resyncing = true
        Task {
            defer { if mySeq == self.resyncSeq { self.resyncing = false } }
            do {
                let size = try await blockCall("com.superlogical.terminal.size")
                let screen = try await readScreen()
                // A newer resync or a full restart supersedes this one.
                guard myGen == gen, mySeq == resyncSeq, !stopped else { return }
                serverCols = max(size.int("columns") ?? serverCols, 2)
                serverRows = max(size.int("rows") ?? serverRows, 2)
                owner = size.str("owner")
                fence.changed()
                sink?.streamReset(cols: serverCols, rows: serverRows)
                sink?.streamResized(cols: serverCols, rows: serverRows, owner: owner)
                sink?.streamSnapshot(screen)
                hasScreen = true
                if live { fence.arrived() }
            } catch {
                guard myGen == gen, mySeq == resyncSeq, !stopped else { return }
                restart()
            }
        }
    }

    private func fullStart() async {
        // `stop()` may have run between the call that asked for this start and the start itself.
        guard !stopped else { return }
        gen += 1
        wakeReader()
        resyncing = false
        snapshotState = .none
        live = false
        waitingForControl = false
        let myGen = gen
        // The stream's own snapshot replaces step 1; the size comes from the `resize` after it.
        let fromSnapshot = usesGhosttySnapshot
        // Step 1 redraws the sink, so the old stream can't go on after it. With a snapshot the
        // sink is untouched until the HELLO, and the old stream stays resumable until then.
        if !fromSnapshot { token = nil }
        // A fresh start needs a ticket, and so the control connection. It isn't tried without.
        guard link.isConnected else { waitForControl(); return }
        let epoch = connectEpoch
        sink?.streamStatus(.connecting)
        do {
            if !fromSnapshot {
                // 1. Size and current contents, as escape sequences.
                let size = try await blockCall("com.superlogical.terminal.size")
                serverCols = max(size.int("columns") ?? 80, 2)
                serverRows = max(size.int("rows") ?? 24, 2)
                owner = size.str("owner")
                let initial = try await readScreen()
                guard myGen == gen, !stopped else { return }
                fence.changed()
                sink?.streamReset(cols: serverCols, rows: serverRows)
                sink?.streamResized(cols: serverCols, rows: serverRows, owner: owner)
                sink?.streamSnapshot(initial)
                hasScreen = true
            }

            // 2. Ticket, then the data WebSocket.
            var busyRetries = 0
            while true {
                let t = try await link.call("data.connect", [
                    "session_id": sessionID, "block_id": blockID,
                    "data_ref_id": "terminal", "subprotocol": "rex.data.terminal.v1",
                ])
                guard let ticketStr = t.str("ticket"), let hello = DataFrame.ticketHello(ticketStr) else {
                    throw RexError.local("bad ticket")
                }
                guard myGen == gen, !stopped else { return }
                // A HELLO ends the stream the server may still keep for a RESUME.
                token = nil
                do {
                    try await openData(hello: hello, gen: myGen, fresh: true, collectSnapshot: fromSnapshot)
                    break
                } catch let refused as Refused
                            where failedStarts == 0 && Self.retriesHello(reason: refused.reason, attempt: busyRetries) {
                    // The old socket's close hasn't reached the server yet. A refused HELLO used
                    // up its ticket, so each try gets a new one. Past the limit it is a failure,
                    // and the starts that follow a failure ask once each: a terminal that is
                    // still busy seconds later isn't waiting for a close.
                    busyRetries += 1
                    await sleep(.nanoseconds(Int64(Self.busyRetryDelay)))
                    guard myGen == gen, !stopped else { return }
                }
            }
        } catch {
            startFailed(error, gen: myGen, epoch: epoch)
        }
    }

    /// A fresh start failed. Decides who tries next: `RexControl` (the stream waits for it), or,
    /// with the control connection up, the stream itself after a growing pause.
    private func startFailed(_ error: Error, gen myGen: Int, epoch: Int) {
        guard myGen == gen, !stopped else { return }
        if link.isConnected, epoch != connectEpoch {
            // The control connection came back while this start was failing on the old one.
            // Nothing was waiting for that, so this is the one start it is owed.
            Task {
                guard myGen == self.gen, !self.stopped else { return }
                await self.fullStart()
            }
            return
        }
        guard link.isConnected else { waitForControl(); return }
        if (error as? RexError)?.code == "conflict", failedStarts == 0, attachRetries < Self.attachRetryLimit {
            attachRetries += 1
            let sleep = self.sleep
            Task { [weak self] in
                await sleep(Self.attachRetryDelay)
                guard let self, myGen == self.gen, !self.stopped else { return }
                await self.fullStart()
            }
            return
        }
        failedStarts += 1
        sink?.streamStatus(.failed(error.localizedDescription))
        let delay = Self.retryDelay(afterFailures: failedStarts)
        let sleep = self.sleep
        Task { [weak self] in
            await sleep(delay)
            guard let self, myGen == self.gen, !self.stopped else { return }
            // Still not connected by now: `fullStart` waits for the control connection.
            await self.fullStart()
        }
    }

    private func blockCall(_ method: String, args: JSONObject = [:]) async throws -> JSONObject {
        try await link.call(method, ["session_id": sessionID, "block_id": blockID, "args": args])
    }

    /// The screen and the newest scrollback as escape sequences (`format` vt).
    /// A long history is cut to its last `snapshotLimit` bytes, keeping the leading palette.
    private func readScreen() async throws -> String {
        var args: JSONObject = ["format": "vt", "max_bytes": 65_536]
        for k in ["extra_charsets", "extra_cursor", "extra_hyperlink", "extra_keyboard", "extra_kitty_keyboard",
                  "extra_modes", "extra_palette", "extra_protection", "extra_scrolling_region", "extra_style", "extra_tabstops"] {
            args[k] = true
        }
        let r = try await blockCall("com.superlogical.terminal.format", args: args)
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
            let more = try await blockCall("com.superlogical.terminal.blob_read",
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
        let socket = try link.openDataSocket(subprotocol: "rex.data.terminal.v1")
        ws = socket
        do {
            // `stop()` or `restart()` may run during either wait. A handshake that finishes
            // after that must change nothing.
            try await socket.send(Data(hello))
            guard myGen == gen, !stopped else { throw CancellationError() }
            guard let d = try await socket.receive() else { throw RexError.local("bad handshake") }
            try acceptWelcome([UInt8](d), gen: myGen, fresh: fresh, collectSnapshot: collectSnapshot)
        } catch {
            // This socket is of no use, to this start or a newer one. Status 1000 also ends a
            // stream the server may have opened for it.
            socket.close()
            if ws === socket { ws = nil }
            throw error
        }
        receive(socket, gen: myGen)
    }

    /// Takes the server's answer to a HELLO or RESUME. Throws `Refused` for a REJECT, and
    /// `CancellationError`, with nothing changed, if the stream was stopped or restarted since
    /// `myGen`. (Internal for tests.)
    func acceptWelcome(_ b: [UInt8], gen myGen: Int, fresh: Bool, collectSnapshot: Bool) throws {
        guard myGen == gen, !stopped else { throw CancellationError() }
        // A REJECT gets its own error (a busy terminal is retried); `DataFrame` checks the rest.
        if b.first == 0x82 { throw Refused(reason: b.count > 1 ? b[1] : 0) }
        let welcome = try DataFrame.welcome(b)
        token = welcome.token
        resumeWindow = .milliseconds(Int64(welcome.resumeWindowMs))
        droppedAt = nil
        // A resume keeps its filter: it may be partway through the snapshot or a message.
        if fresh { beginStream(nonce: welcome.nonce, collectSnapshot: collectSnapshot) }
        failedStarts = 0
        attachRetries = 0
        live = true
        sink?.streamStatus(.live)
        // A resume goes on where it stopped, and a stream without a snapshot was just seeded:
        // what comes now is new. A snapshot arrives first otherwise (`handleSnapshot`).
        if !fresh || !collectSnapshot { fence.arrived() }
    }

    /// Reads the socket until it fails or the stream moves on (`gen`). While reading is paused
    /// it asks for nothing (`pauseReading()`).
    private func receive(_ socket: any StreamSocket, gen myGen: Int) {
        Task { [weak self] in
            while true {
                // Holds the stream while it waits: a paused stream lives until it is resumed
                // or stopped.
                await self?.waitToRead(gen: myGen)
                let message: Data?
                do {
                    message = try await socket.receive()
                } catch {
                    self?.handleDataDrop(socket, gen: myGen)
                    return
                }
                guard let self, myGen == self.gen else { return }
                guard let message else { continue }
                // Counted as it is used: a RESUME must give exactly the bytes taken so far.
                self.received += UInt64(message.count)
                self.consume(message)
                // The sink may have stopped or restarted the stream from inside a callback.
                guard myGen == self.gen else { return }
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
        // A sink may call `stop()`, `restart()` or `resync()` from inside any of these calls.
        // The rest of the chunk then belongs to a stream that is over, and none of it is passed on.
        let myGen = gen
        consuming = true
        defer { consuming = false }
        // In order: a resize applies between the bytes written before and after it.
        let fence = self.fence
        filter!.process(chunk, snapshot: { part in
            guard self.gen == myGen else { return false }
            fence.changed()
            return self.handleSnapshot(part, sink: sink)
        }, output: { out in
            guard self.gen == myGen else { return }
            fence.changed()
            // While a resync reads the screen, this output is dropped (see `resync()`).
            if !self.resyncing { sink?.streamFeed(out) }
        }, message: { m in
            guard self.gen == myGen else { return }
            if m.str("type") == "resize", let me = self.link.clientID, m["owner"] as? String == me {
                fence.resizeEchoed()
            } else {
                fence.changed()
            }
            // The first message follows the snapshot. If the snapshot went unused, the screen
            // is read from here.
            if self.snapshotState == .refused {
                self.snapshotState = .none
                self.readScreenAndRedraw()
            }
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

    private func handleDataDrop(_ socket: any StreamSocket, gen myGen: Int) {
        guard !stopped, myGen == gen else { return }
        live = false
        if ws === socket { ws = nil }
        let code = socket.closeCode
        if code == 4000 {
            token = nil
            // Keys held for a pane that is gone are dropped, and say so.
            if fence.heldCount > 0 { fence.noteDropped() }
            fence.reset()
            sink?.streamStatus(.ended("pane closed"))
            return
        }
        fence.raise(exact: hasScreen)
        sink?.streamStatus(.reconnecting)
        droppedAt = .now
        // 1013: the server dropped the stream (e.g. too much output piled up); a resume can't work.
        if code == 1013 { token = nil }
        let sleep = self.sleep, delay = resumeDelay
        Task {
            if self.canResume {
                await sleep(delay)
                guard myGen == self.gen, !self.stopped else { return }
                await self.resume(gen: myGen)
            } else {
                guard myGen == self.gen, !self.stopped else { return }
                await self.fullStart()
            }
        }
    }

    /// One RESUME. It needs no ticket and no control connection. If it fails, for any reason
    /// (the network is still down, a stale token, a byte count the server doesn't accept), a fresh
    /// start follows, which reads the whole screen again and waits for the control connection if
    /// it has to. There is no second RESUME: after a refusal the server has ended the stream.
    private func resume(gen myGen: Int) async {
        guard myGen == gen, !stopped, let tok = token else { return }
        do {
            try await openData(hello: DataFrame.resumeHello(token: tok, received: received), gen: myGen, fresh: false)
        } catch {
            // Not after `stop()`, and not on top of a newer start.
            guard myGen == gen, !stopped else { return }
            if error is Refused { token = nil }
            await fullStart()
        }
    }

    // MARK: Input

    // What `com.superlogical.terminal.write` gives us to work with (Rex API revision 14):
    //
    // - It takes `data`, a string, and nothing else. JSON strings hold Unicode text, so only
    //   valid UTF-8 can be typed; there is no bytes or base64 form.
    // - It has no sequence number or idempotency key, and the server doesn't order block methods:
    //   "To type text in two calls, wait for the first call's response before you send the second".
    //   `client.key` and `client.action` do run in the order they arrive, but not relative to a
    //   write.
    //
    // So input and the server actions bound to keys go through one queue, in the order they were
    // made, one request at a time, and each is sent at most once after it has left this client:
    //
    // - Not sent (no connection, or the socket didn't take the message; `RexError.neverSent`):
    //   the item stays at the front and goes out when the control connection is back.
    // - Refused by the server (the pane closed, say): dropped; sending it again can't help.
    // - Sent, and the connection broke before the answer: nobody can know whether the server ran
    //   it. Sending it again could run `rm x⏎` twice, which is worse than losing a keystroke the
    //   user can see is missing and type again. So it is dropped, together with everything that
    //   was queued behind it (typed on the assumption that it had arrived), and the user is told
    //   (`onActionFailed`).

    private enum InputItem {
        case text(String)
        case work(Work)
    }
    /// A server call bound to a key (`client.action`, `client.key`).
    private struct Work {
        /// The action's name, for the message when it fails; nil for a forwarded key.
        let action: String?
        /// Picked from the palette: dropped, never sent later, if it can't leave now.
        var fromPalette = false
        /// Told once how the call ended: true when the server answered without an error. Not
        /// called for work that `stop()` dropped.
        var ended: (@MainActor (Bool) -> Void)?
        /// Set for input that goes once or not at all (`sendOnce`): told how it ended, always,
        /// and never reported through `onActionFailed`.
        var once: (@MainActor (Delivery) -> Void)?
        let run: @MainActor () async throws -> Void
    }
    private enum Fate { case unsent, refused, unknown }

    /// What is still to send, oldest first. Text typed in a row is one item.
    private var inputQueue: [InputItem] = [] { didSet { inputChanged() } }
    /// True while an item's request is out; the next one waits for it.
    private var inFlight = false { didSet { inputChanged() } }
    /// True while input is on its way: an item's request is out, or items wait to go. Read-only
    /// for others: a long read on the same connection waits for it (`RexControl.inputActivity`).
    public private(set) var hasPendingInput = false

    private func inputChanged() {
        let pending = inFlight || !inputQueue.isEmpty
        guard pending != hasPendingInput else { return }
        hasPendingInput = pending
        control.inputActivity.set(self, pending: pending)
    }
    private var flightID = 0
    /// Counts `stop()`s. An answer for an item sent before the last one changes nothing.
    private var inputEpoch = 0
    private var inputRetryScheduled = false
    /// A slow action (a Lua function may run for seconds) holds typing back at most this long.
    var actionHold: Duration = .milliseconds(1500)
    static let inputLostMessage = "The connection dropped while sending. Check the pane before typing that again."

    /// Types `bytes` into the terminal. Returns false if they were dropped, which happens in two
    /// cases: the stream is stopped, or the bytes aren't valid UTF-8.
    ///
    /// `terminal.write` takes a JSON string, so bytes that aren't UTF-8 can't be sent at all, and
    /// decoding them loosely would type U+FFFD (three other bytes) in their place: a report the
    /// program then reads as garbage. They are legacy encodings a program must ask for (an X10
    /// mouse report past column 95, 8-bit meta keys). The whole call is dropped instead, so a
    /// caller passes one key, report or paste per call. The mouse encoder uses the SGR or UTF-8
    /// format whenever the program has asked for one, and both are plain UTF-8.
    ///
    /// Keys typed while a request is out go together right after it. Input typed without a
    /// connection waits and goes out, in order, once the server is back. See the note above for
    /// what happens when the connection breaks in the middle of a write.
    @discardableResult
    public func send(_ bytes: [UInt8]) -> Bool {
        guard !bytes.isEmpty else { return true }
        guard !stopped, let text = String(bytes: bytes, encoding: .utf8) else { return false }
        // Behind the fence the bytes wait, and go out only if the screen was exact.
        if fence.hold(bytes) { return true }
        append(text)
        return true
    }

    /// Bytes for the program that describe a place or a state of the screen, not a key: a
    /// mouse or wheel report, a focus report, a tap that moves the cursor. They are right only
    /// for the screen they were made on, so behind the fence they are dropped, never held.
    /// Returns false when they were dropped.
    @discardableResult
    public func send(report bytes: [UInt8]) -> Bool {
        guard !fence.isUp else { return false }
        return send(bytes)
    }

    /// Held keys the fence lets through: checked as UTF-8 when they were typed.
    private func enqueueText(_ bytes: [UInt8]) {
        guard !stopped, let text = String(bytes: bytes, encoding: .utf8) else { return }
        append(text)
    }

    private func append(_ text: String) {
        if case .text(let have)? = inputQueue.last {
            inputQueue[inputQueue.count - 1] = .text(have + text)
        } else {
            inputQueue.append(.text(text))
        }
        pump()
    }

    @discardableResult
    public func send(text: String) -> Bool { send(Array(text.utf8)) }

    /// Sends the next item, unless one is out, the queue is empty, there is no connection
    /// (`controlConnected()` pumps again) or the fence is up (it pumps when it comes down).
    private func pump() {
        // Nothing leaves while the screen may be behind: the queue waits for the fence.
        guard !inFlight, !stopped, !inputQueue.isEmpty, link.isConnected, !fence.isUp else { return }
        // In flight first, so the stream never looks idle between the two.
        inFlight = true
        let item = inputQueue.removeFirst()
        flightID += 1
        let id = flightID, epoch = inputEpoch
        switch item {
        case .text(let text):
            Task {
                var failure: Error?
                do {
                    _ = try await self.blockCall("com.superlogical.terminal.write", args: ["data": text])
                } catch { failure = error }
                self.finished(item, failure: failure, id: id, epoch: epoch)
            }
        case .work(let work):
            Task {
                var failure: Error?
                do { try await work.run() } catch { failure = error }
                self.finished(item, failure: failure, id: id, epoch: epoch)
            }
            // Typing goes on after `actionHold` even if the action hasn't answered.
            let sleep = self.sleep, hold = actionHold
            Task { [weak self] in
                await sleep(hold)
                guard let self, self.inFlight, self.flightID == id else { return }
                self.inFlight = false
                self.pump()
            }
        }
    }

    /// The request for `item` ended.
    private func finished(_ item: InputItem, failure: Error?, id: Int, epoch: Int) {
        // False for an action that `actionHold` gave up waiting for: later items have gone out.
        let current = inFlight && flightID == id
        if current { inFlight = false }
        if case .work(let work) = item, let once = work.once {
            // Told whatever happened since, a `stop()` too: its request did leave, or didn't.
            let delivery = Delivery(failure: failure)
            // Nobody knows whether it ran: what was typed behind it goes, as for a key.
            if delivery == .unknown, current, epoch == inputEpoch { dropQueue() }
            once(delivery)
            if current { pump() }
            return
        }
        if case .work(let work) = item, epoch == inputEpoch { work.ended?(failure == nil) }
        // After `stop()` there is nothing to keep or to report; the queue is already empty.
        guard let failure, epoch == inputEpoch else {
            if current { pump() }
            return
        }
        if case .work(let work) = item, work.fromPalette {
            paletteWorkFailed(work, failure: failure, current: current)
            return
        }
        switch Self.fate(of: failure) {
        case .unsent where current:
            // It never left, so it goes first again, ahead of anything typed since.
            if case .text(let text) = item, case .text(let next)? = inputQueue.first {
                inputQueue[0] = .text(text + next)
            } else {
                inputQueue.insert(item, at: 0)
            }
            // Normally the connection is down and `controlConnected()` sends it. If the socket
            // refused one message and the connection still stands, try again shortly.
            if link.isConnected { retryInputSoon() }
        case .unsent, .refused:
            if case .work(let work) = item, let action = work.action {
                onActionFailed?("Couldn't run \(action). \((failure as? RexError)?.message ?? failure.localizedDescription)")
            }
            if current { pump() }
        case .unknown:
            if current { dropQueue() }
            if case .work(let work) = item, let action = work.action {
                onActionFailed?("Couldn't run \(action). The connection dropped.")
            } else {
                onActionFailed?(Self.inputLostMessage)
            }
            if current { pump() }
        }
    }

    /// A palette pick that failed. One that never left is dropped, not queued for the next
    /// connection: the user picked it for now. One whose answer was lost ends quietly, as nobody
    /// knows whether it ran; what was typed behind it goes, as for a key.
    private func paletteWorkFailed(_ work: Work, failure: Error, current: Bool) {
        let title = work.action ?? "the action"
        switch Self.fate(of: failure) {
        case .unsent:
            onActionFailed?(Self.droppedMessage(title))
        case .refused:
            onActionFailed?("Couldn't run \(title). \((failure as? RexError)?.message ?? failure.localizedDescription)")
        case .unknown:
            if current { dropQueue() }
        }
        if current { pump() }
    }

    /// What a palette pick says when it couldn't leave.
    public static func droppedMessage(_ title: String) -> String { "Didn't run \(title): the connection dropped." }

    private nonisolated static func fate(of error: Error) -> Fate {
        guard let e = error as? RexError else { return .unknown }
        if e.neverSent { return .unsent }
        return e.code == "client" ? .unknown : .refused
    }

    private func retryInputSoon() {
        guard !inputRetryScheduled else { return }
        inputRetryScheduled = true
        let sleep = self.sleep
        Task { [weak self] in
            await sleep(.milliseconds(250))
            self?.inputRetryScheduled = false
            self?.pump()
        }
    }

    private func dropInput() {
        inputEpoch += 1
        dropQueue()
    }

    /// Empties the queue. Input that goes once or not at all is told that it never left.
    private func dropQueue(ended: Bool = false) {
        let dropped = inputQueue
        inputQueue.removeAll()
        for case .work(let work) in dropped {
            work.once?(.unsent)
            // The fence dropped it while the stream goes on: whoever waits for it hears.
            if ended, work.once == nil { work.ended?(false) }
        }
    }

    /// How input that goes once or not at all ended (`sendOnce`).
    public enum Delivery: Equatable, Sendable {
        /// The server took it.
        case delivered
        /// It never left this client: nothing was typed.
        case unsent
        /// The server refused it (the pane is gone, say): nothing was typed.
        case refused
        /// It left and the connection broke before the answer: nobody knows whether it ran.
        case unknown

        /// From what a call threw, or nil when it answered.
        public init(failure: Error?) {
            guard let failure else { self = .delivered; return }
            switch TerminalStream.fate(of: failure) {
            case .unsent: self = .unsent
            case .refused: self = .refused
            case .unknown: self = .unknown
            }
        }
    }

    /// Types `text` for someone who is not at this keyboard (an answer from the watch): now or
    /// not at all, and once. It waits its turn in the queue behind what was typed before it,
    /// but for `limit` at most: after that, and without a connection, it is dropped and never
    /// sent later, when what it answered may be gone. `ended` is told once how it went.
    public func sendOnce(text: String, within limit: Duration = .seconds(4),
                         ended: @escaping @MainActor (Delivery) -> Void) {
        // Behind the fence it is not sent later either: what it answered may be gone.
        guard !stopped, link.isConnected, !text.isEmpty, !fence.isUp else { ended(.unsent); return }
        let latest = ContinuousClock.now + limit
        var work = Work(action: nil) { [sessionID, blockID, link] in
            guard ContinuousClock.now <= latest else { throw RexError.unsent("too late") }
            _ = try await link.call("com.superlogical.terminal.write", ["session_id": sessionID, "block_id": blockID, "args": ["data": text]])
        }
        work.once = ended
        enqueue(work)
    }

    /// Queues `work` behind every key typed before it; keys typed after it wait for it. It is
    /// held, like typed text, until there is a connection to run it on.
    private func enqueue(_ work: Work) {
        guard !stopped else { return }
        inputQueue.append(.work(work))
        pump()
    }

    /// What started an action, as `client.action` reports it to the action (`ctx.origin`).
    public enum ActionOrigin: String, Sendable {
        case key, palette
    }

    /// Runs a block or configuration-file action on this pane (`client.action`), as a key binding
    /// does on the Mac. Returns the client actions the server asks this client to perform.
    ///
    /// From a key it waits in the queue like a keystroke, also for a connection. From the palette
    /// it goes now or not at all: without a connection it fails at once, and one that can't leave
    /// is dropped, never sent later; its failure notices name it by `title`. `ended` is told once
    /// how the call ended (not for work that `stop()` dropped).
    public func perform(action: String, args: JSONObject?, origin: ActionOrigin = .key, title: String? = nil,
                        ended: (@MainActor (Bool) -> Void)? = nil,
                        then: @escaping @MainActor ([JSONObject]) -> Void) {
        let palette = origin == .palette
        if palette, stopped || !link.isConnected {
            onActionFailed?(Self.droppedMessage(title ?? action))
            ended?(false)
            return
        }
        // An action acts on the pane as it is now, which the screen may not show: dropped.
        if fence.isUp {
            fence.noteDropped()
            ended?(false)
            return
        }
        var work = Work(action: palette ? (title ?? action) : action) { [sessionID, blockID, link] in
            var p: JSONObject = ["action": action, "origin": origin.rawValue, "session_id": sessionID, "block_id": blockID]
            if let args, !args.isEmpty { p["args"] = args }
            let r = try await link.call("client.action", p)
            then(r.arr("client_actions"))
        }
        work.fromPalette = palette
        work.ended = ended
        enqueue(work)
    }

    /// Sends a key to the server's Lua key bindings (`client.key`); unhandled, it reaches this pane.
    public func forward(key: JSONObject) {
        if fence.isUp {
            fence.noteDropped()
            return
        }
        enqueue(Work(action: nil) { [sessionID, blockID, link] in
            _ = try await link.call("client.key", ["session_id": sessionID, "block_id": blockID, "key": key])
        })
    }

    // MARK: Ownership

    public func release() async {
        _ = try? await link.call("session.disown_block", ["session_id": sessionID, "block_ids": [blockID]])
    }
}
