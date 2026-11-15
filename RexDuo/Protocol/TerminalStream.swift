import Foundation

/// Splits Rex's own APC messages (`ESC _ rex1;<nonce>;<json> ESC \`) out of a terminal stream,
/// and drops the leading Ghostty snapshot (everything before the first Rex message).
struct APCFilter {
    private let marker: [UInt8]
    private(set) var skippingSnapshot = true
    private var pending: [UInt8] = []

    init(nonce: UInt64) {
        marker = Array("\u{1b}_rex1;\(nonce);".utf8)
    }

    mutating func process(_ chunk: [UInt8]) -> (out: [UInt8], messages: [JSONObject]) {
        var data = pending
        data.append(contentsOf: chunk)
        pending.removeAll(keepingCapacity: true)
        var out: [UInt8] = []
        out.reserveCapacity(data.count)
        var msgs: [JSONObject] = []
        var i = 0
        let n = data.count
        var cursor = 0  // start of bytes not yet emitted/dropped

        func emit(_ upTo: Int) {
            if upTo > cursor {
                if !skippingSnapshot { out.append(contentsOf: data[cursor..<upTo]) }
            }
            cursor = upTo
        }

        while i < n {
            if data[i] == 0x1b {
                // Potential marker.
                let remain = n - i
                if remain < marker.count {
                    if Array(data[i..<n]) == Array(marker[0..<remain]) {
                        emit(i)
                        pending = Array(data[i..<n])
                        return (out, msgs)
                    }
                    i += 1
                    continue
                }
                if data[i..<(i + marker.count)].elementsEqual(marker) {
                    // Find ST (ESC \) after the JSON.
                    var j = i + marker.count
                    var end = -1
                    while j + 1 < n {
                        if data[j] == 0x1b && data[j + 1] == 0x5c { end = j; break }
                        j += 1
                    }
                    if end < 0 {
                        emit(i)
                        pending = Array(data[i..<n])
                        if pending.count > 4 * 1024 * 1024 { pending.removeAll() }  // malformed; give up
                        return (out, msgs)
                    }
                    emit(i)
                    let json = Data(data[(i + marker.count)..<end])
                    if let m = JSONCodec.decode(json) { msgs.append(m) }
                    skippingSnapshot = false
                    i = end + 2
                    cursor = i
                    continue
                }
            }
            i += 1
        }
        if skippingSnapshot {
            cursor = n  // drop snapshot bytes
        } else {
            emit(n)
        }
        return (out, msgs)
    }
}

protocol TerminalSink: AnyObject {
    @MainActor func streamReset(cols: Int, rows: Int)
    @MainActor func streamFeed(_ bytes: [UInt8])
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

    // Input is sent one write at a time; block methods are not ordered by the server.
    private var inputBuffer: [UInt8] = []
    private var writing = false

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

    private func fullStart() async {
        gen += 1
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
            sink?.streamFeed(Array(initial.utf8))

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

    private func readScreen() async throws -> String {
        var args: JSONObject = ["format": "vt", "max_bytes": 900_000]
        for k in ["extra_charsets", "extra_cursor", "extra_hyperlink", "extra_keyboard", "extra_kitty_keyboard",
                  "extra_modes", "extra_palette", "extra_protection", "extra_scrolling_region", "extra_style", "extra_tabstops"] {
            args[k] = true
        }
        let r = try await control.blockCall("com.superlogical.terminal.format", session: sessionID, block: blockID, args: args)
        var content = r.str("content") ?? ""
        var id = r.int("id")
        var guardCount = 0
        while let blob = id, guardCount < 40 {
            guardCount += 1
            let more = try await control.blockCall("com.superlogical.terminal.blob_read", session: sessionID, block: blockID,
                                                   args: ["id": blob, "offset": content.utf8.count, "max_bytes": 900_000])
            content += more.str("data") ?? ""
            if more.bool("eof") == true || (more.str("data") ?? "").isEmpty { id = nil }
        }
        return content
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
                    self.consume([UInt8](d))
                    self.receive(task, gen: myGen)
                case .success:
                    self.receive(task, gen: myGen)
                case .failure:
                    self.handleDataDrop(task, gen: myGen)
                }
            }
        }
    }

    private func consume(_ bytes: [UInt8]) {
        guard var f = filter else { return }
        let (out, msgs) = f.process(bytes)
        filter = f
        for m in msgs {
            switch m.str("type") {
            case "resize":
                let c = m.int("cols") ?? serverCols, r = m.int("rows") ?? serverRows
                owner = m["owner"] as? String
                if c != serverCols || r != serverRows || true {
                    serverCols = max(c, 2); serverRows = max(r, 2)
                    sink?.streamResized(cols: serverCols, rows: serverRows, owner: owner)
                }
            case "theme":
                sink?.streamTheme(m)
            case "child_exited":
                sink?.streamExited(code: m.int("exit_code"))
            default: break
            }
        }
        if !out.isEmpty { sink?.streamFeed(out) }
    }

    private func handleDataDrop(_ task: URLSessionWebSocketTask, gen myGen: Int) {
        guard !stopped, myGen == gen else { return }
        if let code = Optional(task.closeCode.rawValue), code == 4000 {
            sink?.streamStatus(.ended("pane closed"))
            return
        }
        sink?.streamStatus(.reconnecting)
        resumeAttempts += 1
        guard let tok = token, resumeAttempts <= 3 else {
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

    private func pump() {
        guard !writing, !inputBuffer.isEmpty else { return }
        writing = true
        let chunk = inputBuffer
        inputBuffer.removeAll()
        let text = String(decoding: chunk, as: UTF8.self)
        Task {
            _ = try? await control.blockCall("com.superlogical.terminal.write", session: sessionID, block: blockID, args: ["data": text])
            self.writing = false
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
