import Foundation

/// Splits Rex's own APC messages (`ESC _ rex1;<nonce>;<json> ESC \`) out of a terminal stream,
/// and drops the leading Ghostty snapshot (everything before the first Rex message).
/// Output and messages are reported in stream order, so a resize applies exactly where the server
/// put it. Output is handed out as views into the received chunk, without copying.
struct APCFilter {
    private let marker: [UInt8]
    private(set) var skippingSnapshot = true
    /// The start of a message split across chunks.
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

protocol TerminalSink: AnyObject {
    /// Clears the terminal and sets the server's grid; a snapshot follows.
    @MainActor func streamReset(cols: Int, rows: Int)
    /// The screen and scrollback as escape sequences, applied at once.
    @MainActor func streamSnapshot(_ text: String)
    /// Live program output. The buffer is only valid during the call.
    @MainActor func streamFeed(_ bytes: UnsafeBufferPointer<UInt8>)
    @MainActor func streamResized(cols: Int, rows: Int, owner: String?)
    @MainActor func streamTheme(_ theme: JSONObject)
    @MainActor func streamExited(code: Int?)
    @MainActor func streamStatus(_ status: TerminalStream.Status)
}

/// Streams one terminal block's output over `GET /api/data` (subprotocol rex.data.terminal.v1)
/// and sends typed input back over the control connection.
@MainActor
final class TerminalStream {
    enum Status: Equatable { case connecting, live, reconnecting, ended(String), failed(String) }

    /// The most scrollback (bytes of escape sequences) a snapshot reads; older history is skipped.
    static let snapshotLimit = 1 << 20

    let control: RexControl
    let sessionID: String
    let blockID: String
    weak var sink: TerminalSink?

    private(set) var serverCols = 80
    private(set) var serverRows = 24
    private(set) var owner: String?
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

    // Input is sent one write at a time; block methods are not ordered by the server.
    private var inputBuffer: [UInt8] = []
    private var writing = false
    private var inputRetry: Task<Void, Never>?

    init(control: RexControl, sessionID: String, blockID: String) {
        self.control = control
        self.sessionID = sessionID
        self.blockID = blockID
    }

    func start() {
        stopped = false
        Task { await self.fullStart() }
    }

    func stop() {
        stopped = true
        inputRetry?.cancel()
        inputRetry = nil
        gen += 1
        ws?.cancel(with: .normalClosure, reason: nil)
        ws = nil
    }

    /// Re-read the whole screen and open a fresh stream.
    func restart() {
        gen += 1
        ws?.cancel(with: .normalClosure, reason: nil)
        ws = nil
        stopped = false
        Task { await self.fullStart() }
    }

    /// Re-read the screen (and scrollback) and redraw it, keeping the data stream open.
    /// Stream output that arrives while the read is in flight is dropped: the snapshot already holds it.
    func resync() {
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
        let myGen = gen
        sink?.streamStatus(.connecting)
        do {
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

            // 2. Ticket, then the data WebSocket.
            let t = try await control.call("data.connect", [
                "session_id": sessionID, "block_id": blockID,
                "data_ref_id": "terminal", "subprotocol": "rex.data.terminal.v1",
            ])
            guard let ticketStr = t.str("ticket"), let ticket = Self.base64url(ticketStr), ticket.count == 16 else {
                throw RexError.local("bad ticket")
            }
            guard myGen == gen, !stopped else { return }
            try await openData(hello: [0x01] + ticket, gen: myGen, fresh: true)
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

    private func openData(hello: [UInt8], gen myGen: Int, fresh: Bool) async throws {
        let url = control.wsBase.appendingPathComponent("api/data")
        let task = URLSession.shared.webSocketTask(with: url, protocols: ["rex.data.terminal.v1"])
        task.maximumMessageSize = 1 << 20
        ws = task
        task.resume()
        try await task.send(.data(Data(hello)))
        let first = try await task.receive()
        guard case .data(let d) = first else { throw RexError.local("bad handshake") }
        let b = [UInt8](d)
        if b.first == 0x82 {
            throw RexError.local("stream refused (reason \(b.count > 1 ? Int(b[1]) : 0))")
        }
        guard b.count == 32, b[0] == 0x81 else { throw RexError.local("bad welcome") }
        token = Array(b[1..<17])
        var nn: UInt64 = 0
        for k in 0..<8 { nn |= UInt64(b[24 + k]) << (8 * UInt64(k)) }
        if fresh {
            nonce = nn
            received = 0
            filter = APCFilter(nonce: nn)
        }
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

    private func consume(_ chunk: Data) {
        guard filter != nil else { return }
        let sink = self.sink
        // In order: a resize applies between the bytes written before and after it.
        filter!.process(chunk, output: { out in
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
        if let code = Optional(task.closeCode.rawValue), code == 4000 {
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
            var hello: [UInt8] = [0x02] + tok
            var c = self.received
            for _ in 0..<8 { hello.append(UInt8(c & 0xff)); c >>= 8 }
            do {
                try await self.openData(hello: hello, gen: myGen, fresh: false)
            } catch {
                await self.fullStart()
            }
        }
    }

    // MARK: Input

    func send(_ bytes: [UInt8]) {
        inputBuffer.append(contentsOf: bytes)
        pump()
    }

    func send(text: String) { send(Array(text.utf8)) }

    /// Sends typed input now. Keys typed while a write is in flight go out together right after it.
    /// Input is never dropped by a lost connection: it waits and goes out once the server is back.
    private func pump() {
        guard !writing, !inputBuffer.isEmpty, !stopped else { return }
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

    private func retryInput() {
        guard inputRetry == nil, !stopped else { return }
        inputRetry = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            self.inputRetry = nil
            self.pump()
        }
    }

    // MARK: Ownership / sizing

    func claimAndResize(cols: Int, rows: Int) async {
        _ = try? await control.call("session.own_block", ["session_id": sessionID, "block_ids": [blockID], "mode": "take"])
        _ = try? await control.blockCall("com.superlogical.terminal.resize", session: sessionID, block: blockID,
                                         args: ["columns": cols, "rows": rows])
    }

    func release() async {
        _ = try? await control.call("session.disown_block", ["session_id": sessionID, "block_ids": [blockID]])
    }

    static func base64url(_ s: String) -> [UInt8]? {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        guard let d = Data(base64Encoded: b) else { return nil }
        return [UInt8](d)
    }
}
