import CryptoKit
import Foundation
import Network

/// Where a Rex server listens: its local Unix socket, or an HTTP(S) address such as its
/// Tailscale URL.
public enum RexEndpoint: Equatable, Sendable, CustomStringConvertible {
    case unix(String)
    case url(URL)

    /// Parses `unix:///path/to/server.sock` (percent-encoded, as Rex prints it) or an
    /// `http(s)://` / `ws(s)://` address.
    public init?(string: String) {
        guard let u = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = u.scheme?.lowercased() else { return nil }
        switch scheme {
        case "unix":
            guard !u.path.isEmpty else { return nil }
            self = .unix(u.path)
        case "http", "https", "ws", "wss":
            guard u.host != nil else { return nil }
            self = .url(u)
        default:
            return nil
        }
    }

    public var description: String {
        switch self {
        case .unix(let p): return "unix:\(p)"
        case .url(let u): return u.absoluteString
        }
    }
}

/// A small RFC 6455 WebSocket client on Network.framework. It exists because `URLSession`
/// can't reach a Unix socket and `NWProtocolWebSocket` can't set the request path on one.
/// Everything runs on the main queue and is driven by socket events: there are no timers.
/// The server's pings are answered here; a dead local server shows up as end of file.
@MainActor
final class WebSocket {
    enum WSError: LocalizedError {
        case handshake(String)
        case closed(UInt16?, String)
        case protocolError(String)

        var errorDescription: String? {
            switch self {
            case .handshake(let s): return "WebSocket handshake failed: \(s)"
            case .closed(let code, let reason):
                return "closed" + (code.map { " \($0)" } ?? "") + (reason.isEmpty ? "" : " \(reason)")
            case .protocolError(let s): return "WebSocket protocol error: \(s)"
            }
        }
    }

    var maxMessageSize = 16 * 1024 * 1024
    private let conn: NWConnection
    private let hostHeader: String
    private var buffer = Data()
    private var closeSent = false

    init(endpoint: RexEndpoint) {
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 10
        switch endpoint {
        case .unix(let path):
            conn = NWConnection(to: .unix(path: path), using: NWParameters(tls: nil, tcp: tcp))
            hostHeader = "localhost"   // any host name works over the socket
        case .url(let u):
            let secure = ["https", "wss"].contains(u.scheme?.lowercased() ?? "")
            let host = u.host ?? "localhost"
            let port = u.port ?? (secure ? 443 : 80)
            // Kernel keepalive notices a vanished remote server without waking this process.
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 60
            tcp.keepaliveInterval = 15
            tcp.keepaliveCount = 4
            conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: UInt16(port)) ?? 443,
                                using: NWParameters(tls: secure ? NWProtocolTLS.Options() : nil, tcp: tcp))
            hostHeader = u.port.map { "\(host):\($0)" } ?? host
        }
    }

    // MARK: Opening

    /// Connects and performs the HTTP upgrade.
    func open(path: String, subprotocol: String) async throws {
        try await connect()
        let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        let request = "GET \(path) HTTP/1.1\r\nHost: \(hostHeader)\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            + "Sec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Protocol: \(subprotocol)\r\n"
            + "User-Agent: RexConnectHelper\r\n\r\n"
        try await write(Data(request.utf8))

        let separator = Data("\r\n\r\n".utf8)
        var end = buffer.range(of: separator)
        while end == nil {
            guard buffer.count < 64 * 1024 else { throw WSError.handshake("response headers too long") }
            try await fill()
            end = buffer.range(of: separator)
        }
        let head = String(decoding: buffer[buffer.startIndex..<end!.lowerBound], as: UTF8.self)
        buffer = Data(buffer[end!.upperBound...])

        let lines = head.components(separatedBy: "\r\n")
        let status = lines.first ?? ""
        guard status.split(separator: " ").dropFirst().first == "101" else {
            throw WSError.handshake(status.isEmpty ? "no status line" : status)
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8)))
            .base64EncodedString()
        guard headers["sec-websocket-accept"] == accept else { throw WSError.handshake("bad Sec-WebSocket-Accept") }
    }

    private func connect() async throws {
        final class Once: @unchecked Sendable { var done = false }
        let once = Once()
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            conn.stateUpdateHandler = { [conn] state in
                switch state {
                case .ready:
                    if !once.done { once.done = true; c.resume() }
                case .failed(let e), .waiting(let e):
                    // `.waiting` would retry on its own schedule; the caller owns the backoff.
                    conn.cancel()
                    if !once.done { once.done = true; c.resume(throwing: e) }
                case .cancelled:
                    if !once.done { once.done = true; c.resume(throwing: WSError.closed(nil, "cancelled")) }
                default:
                    break
                }
            }
            conn.start(queue: .main)
        }
    }

    // MARK: Reading

    /// The next text or binary message. Answers pings; throws once the connection closes.
    func receive() async throws -> Data {
        var message = Data()
        var inMessage = false
        while true {
            let f = try await readFrame()
            switch f.opcode {
            case 0x1, 0x2:
                message = f.payload
                inMessage = true
            case 0x0:
                guard inMessage else { throw WSError.protocolError("unexpected continuation frame") }
                message.append(f.payload)
            case 0x8:
                let code = f.payload.count >= 2 ? UInt16(f.payload[f.payload.startIndex]) << 8 | UInt16(f.payload[f.payload.startIndex + 1]) : nil
                let reason = f.payload.count > 2 ? String(decoding: f.payload.dropFirst(2), as: UTF8.self) : ""
                close(code: code ?? 1000)
                throw WSError.closed(code, reason)
            case 0x9:
                try await write(Self.frame(opcode: 0xA, payload: f.payload))
                continue
            case 0xA:
                continue
            default:
                throw WSError.protocolError("unknown opcode \(f.opcode)")
            }
            guard message.count <= maxMessageSize else { throw WSError.protocolError("message too large") }
            if f.fin { return message }
        }
    }

    private func byte(_ i: Int) -> UInt8 { buffer[buffer.startIndex + i] }

    private func need(_ n: Int) async throws {
        while buffer.count < n { try await fill() }
    }

    private func readFrame() async throws -> (fin: Bool, opcode: UInt8, payload: Data) {
        try await need(2)
        let b0 = byte(0), b1 = byte(1)
        var length = Int(b1 & 0x7F)
        var offset = 2
        if length == 126 {
            try await need(4)
            length = Int(byte(2)) << 8 | Int(byte(3))
            offset = 4
        } else if length == 127 {
            try await need(10)
            var v: UInt64 = 0
            for i in 2..<10 { v = v << 8 | UInt64(byte(i)) }
            guard v <= UInt64(maxMessageSize) else { throw WSError.protocolError("frame too large") }
            length = Int(v)
            offset = 10
        }
        guard length <= maxMessageSize else { throw WSError.protocolError("frame too large") }
        var mask: [UInt8] = []
        if b1 & 0x80 != 0 {
            try await need(offset + 4)
            mask = (0..<4).map { byte(offset + $0) }
            offset += 4
        }
        try await need(offset + length)
        let start = buffer.startIndex + offset
        var payload = Data(buffer[start..<start + length])
        buffer = Data(buffer[(start + length)...])
        if !mask.isEmpty {
            payload.withUnsafeMutableBytes { p in for i in 0..<p.count { p[i] ^= mask[i & 3] } }
        }
        return (b0 & 0x80 != 0, b0 & 0x0F, payload)
    }

    private func fill() async throws {
        let chunk: Data = try await withCheckedThrowingContinuation { c in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, isComplete, error in
                if let data, !data.isEmpty { c.resume(returning: data) }
                else if let error { c.resume(throwing: error) }
                else if isComplete { c.resume(throwing: WSError.closed(nil, "connection closed")) }
                else { c.resume(returning: Data()) }
            }
        }
        buffer.append(chunk)
    }

    // MARK: Writing

    func send(text: String) async throws {
        try await write(Self.frame(opcode: 0x1, payload: Data(text.utf8)))
    }

    /// Sends a close frame, then drops the connection once it's out. Rex then forgets this
    /// client at once instead of holding it as `lost`.
    func close(code: UInt16 = 1000) {
        guard !closeSent else { return }
        closeSent = true
        let f = Self.frame(opcode: 0x8, payload: Data([UInt8(code >> 8), UInt8(code & 0xFF)]))
        conn.send(content: f, completion: .contentProcessed { [conn] _ in conn.cancel() })
    }

    /// Drops the connection without a close frame.
    func cancel() { conn.cancel() }

    private func write(_ d: Data) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            conn.send(content: d, completion: .contentProcessed { err in
                if let err { c.resume(throwing: err) } else { c.resume() }
            })
        }
    }

    /// A client frame: final, masked as RFC 6455 requires.
    static func frame(opcode: UInt8, payload: Data) -> Data {
        var f = Data([0x80 | opcode])
        let n = payload.count
        if n < 126 {
            f.append(0x80 | UInt8(n))
        } else if n <= 0xFFFF {
            f.append(contentsOf: [0x80 | 126, UInt8(n >> 8), UInt8(n & 0xFF)])
        } else {
            f.append(0x80 | 127)
            for i in (0..<8).reversed() { f.append(UInt8((UInt64(n) >> (UInt64(i) * 8)) & 0xFF)) }
        }
        let mask = (0..<4).map { _ in UInt8.random(in: 0...255) }
        f.append(contentsOf: mask)
        var body = payload
        body.withUnsafeMutableBytes { p in for i in 0..<p.count { p[i] ^= mask[i & 3] } }
        f.append(body)
        return f
    }
}
