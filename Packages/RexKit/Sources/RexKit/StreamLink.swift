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
    /// Hands a request to the socket before it returns, in the caller's turn of the main actor,
    /// and returns true; `answer` is then called once with what `call` would return or throw.
    /// Returns false, having done nothing, when the request can't leave in this turn (no
    /// connection, a delayed link, a method the server doesn't have): the caller uses `call`,
    /// which says why. Typed text leaves this way (`TerminalStream.pump`), so a key doesn't
    /// wait for a task to start.
    func start(_ method: String, _ payload: JSONObject?, answer: @escaping @MainActor (Result<JSONObject, Error>) -> Void) -> Bool
    /// A new socket to `GET /api/data` with `subprotocol`, before its handshake: a terminal stream
    /// (`rex.data.terminal.v1`) or a file's bytes (`rex.data.bytes.v1`).
    func openDataSocket(subprotocol: String) throws -> any StreamSocket
    /// Returns when the control connection answers a ping; throws when it isn't connected or
    /// fails first. An upload measures the queue it adds with it (`UploadPacer`).
    func ping() async throws
    /// How long a data socket may wait for the answer to its handshake, in seconds.
    var dataHandshakeDeadline: Double { get }
    /// The largest request the server takes (`RexControl.maxMessageBytes`).
    var maxMessageBytes: Int { get }
    /// See `RexControl.clientGeneration`: what was welcomed under an earlier count is gone.
    var clientGeneration: Int { get }
    /// Calls `done(true)` once the server has answered an attach of `session` on this connection,
    /// or `done(false)` when the wait is cancelled (`cancelAttachWait`, a lost or stopped
    /// connection, the background). Returns nil, having called nothing, when there is nothing to
    /// wait for: the session is attached already. It only waits: it asks the server nothing.
    func whenAttached(_ session: String, _ done: @escaping @MainActor (Bool) -> Void) -> Int?
    func cancelAttachWait(_ id: Int)
    /// A line for the connection log (`RexControl.onNote`).
    func note(_ event: ConnectionEvent)
    /// One ping of the control connection for an upload to pace itself by (`UploadPacer`). It
    /// only measures: whatever comes of it, the host is not dropped for it. The wait always
    /// ends.
    func paceProbe() async -> PaceSample
}

/// What came of a pacing ping.
enum PaceSample: Equatable, Sendable {
    /// The pong came: the time since the ping left is the sample.
    case answered
    /// No pong within the pong deadline: a slow sample.
    case slow
    /// No sample: not connected, lost, or the app went to the background.
    case none
}

extension StreamLink {
    var dataHandshakeDeadline: Double { ReconnectPolicy.standard.connectDeadline }
    /// A link with no server behind it (a replay, a test) takes what Rex takes by default.
    var maxMessageBytes: Int { 1 << 20 }

    var clientGeneration: Int { 0 }
    func whenAttached(_ session: String, _ done: @escaping @MainActor (Bool) -> Void) -> Int? { nil }
    func cancelAttachWait(_ id: Int) {}
    func note(_ event: ConnectionEvent) {}

    func paceProbe() async -> PaceSample {
        (try? await ping()) != nil ? .answered : .none
    }

    func start(_ method: String, _ payload: JSONObject?, answer: @escaping @MainActor (Result<JSONObject, Error>) -> Void) -> Bool {
        false
    }
}

/// A data socket got no answer to its handshake in time.
struct HandshakeTimeout: Error {}

/// Whether a handshake's deadline has passed; set by the deadline and read by what waited.
@MainActor
final class HandshakeClock {
    private(set) var expired = false
    private var task: Task<Void, Never>?
    private let expire: @MainActor () -> Void

    /// Starts the one wait: after `seconds`, `expire` runs, unless `end()` came first. `expire`
    /// must end the socket's wait (`abort()` or `close()`), which is how the waiting side wakes.
    init(seconds: Double, sleep: @escaping @MainActor (Duration) async -> Void,
         expire: @escaping @MainActor () -> Void) {
        self.expire = expire
        task = Task { @MainActor [weak self] in
            await sleep(.milliseconds(Int64((seconds * 1000).rounded())))
            guard !Task.isCancelled, let self, self.task != nil else { return }
            self.task = nil
            self.expired = true
            expire()
        }
    }

    /// The handshake is over, one way or another: the deadline does nothing from here on.
    func end() {
        task?.cancel()
        task = nil
    }

    /// Ends the wait as the deadline would, now. Nothing if it is over already.
    func expireNow() {
        guard task != nil else { return }
        end()
        expired = true
        expire()
    }
}

extension StreamSocket {
    /// Sends `hello` and returns the answer, both within `seconds`. No answer by then: the
    /// socket is dropped with no close frame, and `HandshakeTimeout` is thrown. For a socket
    /// that carries a file's bytes, which has no stream to keep.
    func handshake(_ hello: Data, within seconds: Double,
                   sleep: @escaping @MainActor (Duration) async -> Void) async throws -> Data? {
        let deadline = HandshakeClock(seconds: seconds, sleep: sleep) { [weak self] in self?.abort() }
        defer { deadline.end() }
        do {
            try await send(hello)
            return try await receive()
        } catch {
            throw deadline.expired ? HandshakeTimeout() : error
        }
    }
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

    func whenAttached(_ session: String, _ done: @escaping @MainActor (Bool) -> Void) -> Int? {
        attachWaits.wait(for: session, done)
    }

    func cancelAttachWait(_ id: Int) { attachWaits.cancel(id) }

    func note(_ event: ConnectionEvent) { onNote?(event) }

    func openDataSocket(subprotocol: String) throws -> any StreamSocket {
        guard let base = wsBase else { throw RexError.local("invalid server address") }
        // The host's one gate, here so that no caller can go around it: no data socket without
        // the control connection's welcome, and no terminal stream in the background or, after
        // it, before that connection has answered (`holdsData`). A file's socket is not held
        // then: it follows the answer to its `…_begin` call, so the connection answered a
        // moment ago, and a send the user started goes on when they leave the app.
        guard state == .connected, subprotocol != "rex.data.terminal.v1" || !holdsData else {
            throw RexError.unsent("not connected")
        }
        let task = session.webSocketTask(with: base.appendingPathComponent("api/data"), protocols: [subprotocol])
        task.maximumMessageSize = 1 << 20
        task.resume()
        let socket = URLSessionStreamSocket(task)
        opened(socket)
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
            // Once only, as the pong handler (`ResumeOnce`): the same task calls both back.
            let once = ResumeOnce(c)
            task.receive { result in
                switch result {
                case .success(.data(let d)): once.resume(returning: d)
                case .success: once.resume(returning: nil)
                case .failure(let e): once.resume(throwing: e)
                }
            }
        }
    }

    func close() { task.cancel(with: .normalClosure, reason: nil) }

    func ping() async throws { try await task.awaitPong() }

    func abort() { task.cancel() }

    var closeCode: Int { task.closeCode == .invalid ? 0 : task.closeCode.rawValue }
}
