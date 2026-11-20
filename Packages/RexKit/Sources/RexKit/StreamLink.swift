import Foundation

/// What a `TerminalStream` needs from the control connection: calls, whether it is connected, a
/// word when it connects again, and data sockets to the same server. `RexControl` is the real one;
/// tests use a fake, so the stream's reconnect and input rules run without a server.
@MainActor
protocol StreamLink: AnyObject {
    var isConnected: Bool { get }
    /// This client's id on the control connection: the `owner` of a pane it resized.
    var clientID: String? { get }
    /// See `RexControl.observeConnected`.
    func observeConnected(_ body: @escaping @MainActor () -> Bool)
    /// Throws a `RexError`: with `neverSent` when the request never left, with the server's code
    /// when the server refused it, and a plain local one when the connection broke after the send.
    func call(_ method: String, _ payload: JSONObject?) async throws -> JSONObject
    /// A new socket to `GET /api/data` with `subprotocol`, before its handshake: a terminal stream
    /// (`rex.data.terminal.v1`) or a file's bytes (`rex.data.bytes.v1`).
    func openDataSocket(subprotocol: String) throws -> any StreamSocket
}

/// One data WebSocket.
@MainActor
protocol StreamSocket: AnyObject {
    func send(_ data: Data) async throws
    /// The next binary message, or nil for a text message (the server sends none). Throws when
    /// the socket closes or fails.
    func receive() async throws -> Data?
    /// Closes with status 1000, which also ends the stream on the server.
    func close()
    /// Returns when the server answers a ping; throws when the socket fails first.
    func ping() async throws
    /// Drops the connection without a status 1000 close, so the server keeps the stream for a RESUME.
    /// A `receive` that is waiting throws.
    func abort()
    /// The server's close status, or 0 if there is none (yet).
    var closeCode: Int { get }
}

extension RexControl: StreamLink {
    var isConnected: Bool { state == .connected }

    func openDataSocket(subprotocol: String) throws -> any StreamSocket {
        guard let base = wsBase else { throw RexError.local("invalid server address") }
        let task = session.webSocketTask(with: base.appendingPathComponent("api/data"), protocols: [subprotocol])
        task.maximumMessageSize = 1 << 20
        task.resume()
        let socket = URLSessionStreamSocket(task)
        // Only terminal streams: a file's or a tunnel's bytes are not what the delay measures.
        guard !linkDelay.isZero, subprotocol == "rex.data.terminal.v1" else { return socket }
        return DelayedStreamSocket(socket, delay: linkDelay)
    }
}

@MainActor
final class URLSessionStreamSocket: StreamSocket {
    private let task: URLSessionWebSocketTask

    init(_ task: URLSessionWebSocketTask) { self.task = task }

    func send(_ data: Data) async throws { try await task.send(.data(data)) }

    func receive() async throws -> Data? {
        let task = self.task
        return try await withCheckedThrowingContinuation { c in
            task.receive { result in
                switch result {
                case .success(.data(let d)): c.resume(returning: d)
                case .success: c.resume(returning: nil)
                case .failure(let e): c.resume(throwing: e)
                }
            }
        }
    }

    func close() { task.cancel(with: .normalClosure, reason: nil) }

    func ping() async throws {
        let task = self.task
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            task.sendPing { err in
                if let err { c.resume(throwing: err) } else { c.resume() }
            }
        }
    }

    func abort() { task.cancel() }

    var closeCode: Int { task.closeCode == .invalid ? 0 : task.closeCode.rawValue }
}
