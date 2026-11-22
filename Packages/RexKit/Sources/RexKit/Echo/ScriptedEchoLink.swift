import Foundation

/// A terminal stream with no server behind it, for the benchmark's predicted-echo scenario: the
/// stream's own queue, funnel and round-trip samples run as they do against a server, while a
/// script plays the server. `terminal.write` is answered after `writeDelay`, and the data
/// socket carries `opening` after its handshake and then whatever `deliver` is given, when it
/// is given.
///
/// `StreamLink` stays internal: this is the one way from outside the package to a stream on a
/// link that is not a `RexControl`, and it is not part of the package's ordinary API
/// (`@_spi(Bench)`).
@_spi(Bench)
@MainActor
public final class ScriptedEchoLink {
    private let link: Link

    /// The nonce of the scripted stream's own messages (`APCFilter`).
    public nonisolated static let nonce: UInt64 = 1

    /// The server's message for a pane of this size, as the data socket carries it.
    public nonisolated static func resize(cols: Int, rows: Int) -> [UInt8] {
        Array("\u{1b}_rex1;\(nonce);{\"type\":\"resize\",\"cols\":\(cols),\"rows\":\(rows),\"owner\":\"client:scripted\"}\u{1b}\\".utf8)
    }

    /// `opening` is what the data socket carries first, where a server sends the pane's
    /// snapshot and its size: a recorded one, or by default the size alone, which starts the
    /// pane empty. `sleep` is how `writeDelay` passes; a test passes its own.
    public init(writeDelay: Duration, opening: [UInt8] = ScriptedEchoLink.resize(cols: 80, rows: 24),
                sleep: @escaping @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        link = Link(writeDelay: writeDelay, opening: opening, sleep: sleep)
    }

    /// The texts of the writes the stream sent, in order.
    public var written: [String] { link.written }
    /// The stream has opened its data socket: what `deliver` is given now arrives.
    public var isOpen: Bool { link.socket != nil }

    /// A stream on this link. `control` is never connected: the stream only keeps its books on
    /// it (pending input, the path's cost).
    public func stream(control: RexControl, sessionID: String, blockID: String, echoGate: EchoGate?) -> TerminalStream {
        TerminalStream(control: control, link: link, sessionID: sessionID, blockID: blockID, echoGate: echoGate)
    }

    /// Output of the program, as one message of the data socket. Dropped before the stream has
    /// opened its socket.
    public func deliver(_ bytes: [UInt8]) { link.socket?.deliver(.success(Data(bytes))) }

    @MainActor
    private final class Link: StreamLink {
        let writeDelay: Duration
        let opening: [UInt8]
        let sleep: @MainActor (Duration) async -> Void
        var written: [String] = []
        var socket: Socket?

        init(writeDelay: Duration, opening: [UInt8], sleep: @escaping @MainActor (Duration) async -> Void) {
            self.writeDelay = writeDelay
            self.opening = opening
            self.sleep = sleep
        }

        var isConnected: Bool { true }
        var clientID: String? { "client:scripted" }
        // Always connected: there is never a reconnect to tell of.
        func observeConnected(_ body: @escaping @MainActor () -> Bool) {}

        func call(_ method: String, _ payload: JSONObject?) async throws -> JSONObject {
            switch method {
            case "data.connect":
                // Sixteen bytes, as the server's ticket is.
                return ["ticket": "AAECAwQFBgcICQoLDA0ODw"]
            case "com.superlogical.terminal.write":
                written.append(payload?.obj("args")?.str("data") ?? "")
                await sleep(writeDelay)
                return [:]
            default:
                return [:]
            }
        }

        func openDataSocket(subprotocol: String) throws -> any StreamSocket {
            socket?.close()
            let s = Socket(opening: opening)
            socket = s
            return s
        }

        func ping() async throws {}
    }

    @MainActor
    private final class Socket: StreamSocket {
        private let opening: [UInt8]
        private var handshaken = false

        init(opening: [UInt8]) { self.opening = opening }
        private var inbox: [Result<Data?, Error>] = []
        private var waiter: CheckedContinuation<Data?, Error>?
        private(set) var closeCode = 0

        func send(_ data: Data) async throws {
            // Only the handshake is answered: a WELCOME that keeps the stream a minute, then
            // the opening.
            guard !handshaken else { return }
            handshaken = true
            var b: [UInt8] = [0x81] + [UInt8](repeating: 0xAB, count: 16) + [0, 0, 0]
            let keepMs: UInt32 = 60_000, nonce = ScriptedEchoLink.nonce
            for k in 0..<4 { b.append(UInt8((keepMs >> (8 * UInt32(k))) & 0xff)) }
            for k in 0..<8 { b.append(UInt8((nonce >> (8 * UInt64(k))) & 0xff)) }
            deliver(.success(Data(b)))
            if !opening.isEmpty { deliver(.success(Data(opening))) }
        }

        func receive() async throws -> Data? {
            if !inbox.isEmpty { return try inbox.removeFirst().get() }
            return try await withCheckedThrowingContinuation { waiter = $0 }
        }

        func close() { deliver(.failure(URLError(.cancelled))) }
        func abort() { deliver(.failure(URLError(.cancelled))) }
        func ping() async throws {}

        func deliver(_ r: Result<Data?, Error>) {
            if let w = waiter {
                waiter = nil
                w.resume(with: r)
            } else {
                inbox.append(r)
            }
        }
    }
}
