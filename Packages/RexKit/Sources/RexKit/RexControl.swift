import Foundation

/// Who this client is. Sent in the hello; Rex shows it in `rex client list`.
public struct ClientInfo: Sendable, Equatable {
    public var kind: String
    public var platform: String
    public var name: String
    public var version: String
    /// Shown next to the name. Rex caps labels at 64 bytes.
    public var label: String

    public init(kind: String = "app", platform: String = "ios", name: String, version: String, label: String) {
        self.kind = kind
        self.platform = platform
        self.name = name
        self.version = version
        self.label = label
    }
}

/// One control connection (`GET /api/control`, subprotocol `rex.control.v1`) to a Rex server.
/// Every method call and event goes through here. See the server's /llms.txt.
@MainActor
public final class RexControl {
    public enum State: Equatable {
        case idle
        case connecting
        case connected
        case failed(ConnectionFailure)
    }

    /// The newest API revision this client speaks. The hello sends it with no `api_min_revision`,
    /// so a server on any revision from 0 up to this one connects, and a newer server translates
    /// down to it.
    public nonisolated static let apiRevision = 18

    /// The server address as configured.
    public let address: String
    /// `wss://host` for the address; nil when the address is invalid (`connect()` then fails).
    public let wsBase: URL?
    public let client: ClientInfo
    public private(set) var state: State = .idle {
        didSet {
            inputActivity.connection(state == .connected)
            onStateChange?(state)
            if state == .connected, oldValue != .connected { notifyConnected() }
        }
    }
    public private(set) var clientID: String?
    public private(set) var maxMessageBytes = 65536
    /// The API revision this connection uses, from the latest welcome (`api_revision`; a server
    /// that leaves it out speaks revision 0). 0 before the first welcome.
    public private(set) var negotiatedRevision = 0
    /// The newest revision the server speaks (`api_server_revision`; left out means 0).
    public private(set) var serverRevision = 0
    /// Optional behaviors the server lists in its welcome. Names this build doesn't know are
    /// kept and never looked at.
    public private(set) var features: Set<String> = []
    /// The server refused the connection because the two sides share no API revision, and retries
    /// have stopped: nothing changes until Rex or the app is updated. `kick()` and `wake()` (the
    /// user asked, or the app came back) still try once.
    public private(set) var retryStopped = false

    /// Which of this connection's terminal streams have typed input on its way.
    public let inputActivity = InputActivity()

    public var onEvent: ((_ seq: Int, _ event: JSONObject) -> Void)?
    public var onStateChange: ((State) -> Void)?
    /// Called after a dropped connection is re-established (state must be re-read).
    public var onReconnected: ((_ resumed: Bool) -> Void)?

    private var task: URLSessionWebSocketTask?
    /// Also used by `TerminalStream` for the data sockets, so both share one configuration.
    let session: URLSession
    /// Calls waiting for their answer, by request id.
    private var pending: [String: (Result<DecodedJSON, Error>) -> Void] = [:]
    private var nextID = 0
    private var reconnectToken: String?
    private var welcomeWaiter: CheckedContinuation<Void, Error>?
    private var pingTimer: Timer?
    private var generation = 0
    private var wantConnected = false
    private var retryDelay: Double = 1
    private var retryTask: Task<Void, Never>?
    private var connectedObservers: [@MainActor () -> Bool] = []
    /// The terminal streams that run on this connection, by block. Weak: a stream that went
    /// without `stop()` is simply not found.
    private var streams: [String: WeakStream] = [:]
    private struct WeakStream {
        weak var stream: TerminalStream?
    }

    /// `address` is the server's HTTPS address, e.g. `https://mac.tailnet.ts.net`.
    public init(address: String, client: ClientInfo) {
        self.address = address
        self.wsBase = Self.webSocketBase(for: address)
        self.client = client
        let cfg = URLSessionConfiguration.default
        cfg.waitsForConnectivity = false
        cfg.timeoutIntervalForRequest = 20
        self.session = URLSession(configuration: cfg)
    }

    /// The WebSocket origin (`wss://host[:port]`) for a server address, or nil if the address has
    /// no host or isn't http(s) or ws(s).
    public nonisolated static func webSocketBase(for address: String) -> URL? {
        guard var c = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = c.host, !host.isEmpty else { return nil }
        switch c.scheme?.lowercased() {
        case "https", "wss": c.scheme = "wss"
        case "http", "ws": c.scheme = "ws"
        default: return nil
        }
        c.path = ""
        c.query = nil
        c.fragment = nil
        return c.url
    }

    // MARK: Connection

    /// Connects, and keeps the connection while it's wanted: after any failure, the first one
    /// included, it retries with backoff (1 s doubling to 15 s) until `disconnect()`. Throws if this
    /// first attempt fails; `state` and `onReconnected` report the later ones.
    public func connect() async throws {
        guard wsBase != nil else {
            let f = ConnectionFailure.invalidAddress(address)
            state = .failed(f)
            throw f
        }
        wantConnected = true
        try await openSocket()
    }

    public func disconnect() {
        wantConnected = false
        retryTask?.cancel()
        retryTask = nil
        generation += 1
        pingTimer?.invalidate()
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        failAll(RexError.local("disconnected"))
        resumeWelcome(throwing: RexError.local("disconnected"))
        state = .idle
    }

    /// The longest `invalidate` waits for the socket to finish closing before it drops it.
    static let closeLimit: TimeInterval = 1.5

    /// Disconnects for good and releases the URLSession, which otherwise keeps its delegate queue
    /// and connection pool for the life of the process. For a connection made for one short job;
    /// the control must not be used again.
    public func invalidate() {
        let closing = task
        disconnect()
        // `disconnect` asked the socket to close with a close frame. The session must outlive
        // that: cancelling it at once drops the TCP connection under the frame, and the server
        // then sees a client that vanished instead of one that left. So wait for the socket task
        // itself to finish (the frame is out and the connection is down), and only then end the
        // session. The limit covers a server that stopped reading, and a socket cancelled before
        // it finished opening, whose connection would otherwise stay in the session's pool.
        let session = session
        session.finishTasksAndInvalidate()
        let deadline = Date().addingTimeInterval(Self.closeLimit)
        Task.detached { [weak closing] in
            while let state = closing?.state, state != .completed, Date() < deadline {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            session.invalidateAndCancel()
        }
    }

    /// Opens a socket and waits for the welcome. Every failure goes through `handleDrop`, which
    /// records it and schedules the next attempt; the throw only tells the caller.
    private func openSocket() async throws {
        guard let wsBase else { throw ConnectionFailure.invalidAddress(address) }
        retryStopped = false
        // An attempt still waiting for its welcome is superseded by this one.
        resumeWelcome(throwing: RexError.local("superseded"))
        task?.cancel()
        generation += 1
        let gen = generation
        state = .connecting
        #if DEBUG
        if unreachableForTesting != nil {
            let f = ConnectionFailure(URLError(.cannotConnectToHost))
            handleDrop(gen: gen, failure: f)
            throw f
        }
        #endif
        let url = wsBase.appendingPathComponent("api/control")
        let t = session.webSocketTask(with: url, protocols: ["rex.control.v1"])
        t.maximumMessageSize = 8 * 1024 * 1024
        task = t
        t.resume()

        let helloText = JSONCodec.encode(Self.hello(client: client, reconnectToken: reconnectToken))
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            welcomeWaiter = c
            receiveLoop(t, gen: gen)
            t.send(.string(helloText)) { err in
                guard let err else { return }
                Task { @MainActor in self.handleDrop(gen: gen, failure: self.failure(err, t)) }
            }
            // Welcome timeout.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                if self.welcomeWaiter != nil, gen == self.generation { self.handleDrop(gen: gen, failure: .timedOut()) }
            }
        }
        startPings(gen: gen)
    }

    /// The hello: the newest revision this client speaks and no minimum, so the server picks the
    /// newest one both sides have.
    nonisolated static func hello(client: ClientInfo, reconnectToken: String?) -> JSONObject {
        var hello: JSONObject = [
            "type": "hello",
            "api_revision": apiRevision,
            "client": [
                "kind": client.kind,
                "platform": client.platform,
                "name": client.name,
                "version": client.version,
                "label": client.label,
            ] as JSONObject,
        ]
        if let reconnectToken { hello["reconnect_token"] = reconnectToken }
        return hello
    }

    private func resumeWelcome(throwing error: Error) {
        guard let w = welcomeWaiter else { return }
        welcomeWaiter = nil
        w.resume(throwing: error)
    }

    /// The failure plus what the socket task knows: the upgrade's HTTP status, the close code and
    /// the reason sent with it.
    private func failure(_ error: Error, _ t: URLSessionWebSocketTask?) -> ConnectionFailure {
        let status = (t?.response as? HTTPURLResponse)?.statusCode
        let close = t.flatMap { $0.closeCode == .invalid ? nil : $0.closeCode.rawValue }
        let reason = close == nil ? nil : t?.closeReason.flatMap { String(data: $0, encoding: .utf8) }
        return ConnectionFailure(error, httpStatus: status == 101 ? nil : status, closeCode: close,
                                 closeReason: reason?.isEmpty == true ? nil : reason)
    }

    private func startPings(gen: Int) {
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, gen == self.generation, let t = self.task else { return }
                t.sendPing { err in
                    if let err {
                        Task { @MainActor in self.handleDrop(gen: gen, failure: self.failure(err, t)) }
                    }
                }
            }
        }
    }

    private func receiveLoop(_ t: URLSessionWebSocketTask, gen: Int) {
        t.receive { [weak self] result in
            // Decode here, on URLSession's queue: a screen-read reply is up to ~1 MB and takes
            // milliseconds to parse. Order is kept because the next receive starts only after this
            // message is handled on the main actor.
            let parsed = result.map { msg -> DecodedJSON? in
                switch msg {
                case .string(let s): return JSONCodec.decode(s).map(DecodedJSON.init)
                case .data(let d): return JSONCodec.decode(d).map(DecodedJSON.init)
                @unknown default: return nil
                }
            }
            Task { @MainActor in
                guard let self, gen == self.generation else { return }
                switch parsed {
                case .success(let m):
                    if let m = m?.value as? JSONObject { self.handle(m) }
                    self.receiveLoop(t, gen: gen)
                case .failure(let err):
                    self.handleDrop(gen: gen, failure: self.failure(err, t))
                }
            }
        }
    }

    /// The one place a failed or dropped socket is handled: once per generation, so a socket that
    /// fails several ways at once counts once and backs off once.
    private func handleDrop(gen: Int, failure: ConnectionFailure) {
        guard gen == generation else { return }
        generation += 1
        pingTimer?.invalidate()
        task?.cancel()
        task = nil
        failAll(RexError.local("connection lost"))
        resumeWelcome(throwing: failure)
        state = .failed(failure)
        guard wantConnected else { return }
        // No common API revision: the next attempt would be refused the same way, so stop here.
        // Only that reason stops; any other close, 1008 `event backlog exceeded` included, retries.
        if failure.revisionRefusal != nil {
            retryStopped = true
            retryTask?.cancel()
            retryTask = nil
            return
        }
        if Date() < retryAtOnceUntil {
            retryAtOnceUntil = .distantPast
            scheduleRetry(after: 0)
            return
        }
        scheduleRetry(after: retryDelay)
        retryDelay = min(retryDelay * 2, 15)
    }

    private func scheduleRetry(after delay: Double) {
        retryTask?.cancel()
        retryTask = Task { @MainActor [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard let self, !Task.isCancelled, self.wantConnected, self.task == nil else { return }
            self.retryTask = nil
            await self.attempt()
        }
    }

    private func attempt() async {
        let hadToken = reconnectToken != nil
        do {
            try await openSocket()
            retryDelay = 1
            onReconnected?(hadToken)
        } catch {
            // Already handled: `handleDrop` recorded it and scheduled the next try.
        }
    }

    /// Tries now instead of waiting out the backoff: back in the foreground, the network changed,
    /// or the user asked. Does nothing while connected or not wanted.
    public func kick() {
        guard wantConnected, state != .connected else { return }
        retryDelay = 1
        retryTask?.cancel()
        retryTask = nil
        Task { @MainActor in await self.attempt() }
    }

    /// How long `wake()` waits for a pong before it takes the connection for dead.
    public static let wakeTimeout: Double = 2.5
    /// The generation `wake()` pinged, until the pong.
    private var unansweredPing: Int?
    /// A drop before this time is retried at once, once: the app just came back (`wake()`).
    private var retryAtOnceUntil = Date.distantPast

    /// Back in the foreground. A connection that looks up may have died while the app was
    /// suspended, and calls on it would hang until they time out. So it is pinged: no pong within
    /// `wakeTimeout`, or a failed ping, counts as a drop, and the next attempt starts at once
    /// instead of after the backoff. Not connected: tries now, as `kick()` does.
    public func wake() {
        #if DEBUG
        if unreachableForTesting == false { unreachableForTesting = nil }
        #endif
        guard wantConnected else { return }
        guard state == .connected, let t = task else { kick(); return }
        let gen = generation
        unansweredPing = gen
        // The socket usually fails by itself moments after the app wakes; that drop retries at once too.
        retryAtOnceUntil = Date().addingTimeInterval(Self.wakeTimeout + 0.5)
        t.sendPing { [weak self] err in
            Task { @MainActor in
                guard let self, self.unansweredPing == gen else { return }
                self.unansweredPing = nil
                if let err { self.handleDrop(gen: gen, failure: self.failure(err, t)) } else { self.retryAtOnceUntil = .distantPast }
            }
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.wakeTimeout * 1_000_000_000))
            guard let self, self.unansweredPing == gen else { return }
            self.unansweredPing = nil
            self.handleDrop(gen: gen, failure: .timedOut())
        }
    }

    #if DEBUG
    /// Testing: attempts fail as an unreachable host's do until `wake()` (false), or always (true).
    private var unreachableForTesting: Bool?

    /// Testing (`-wakeTest`): loses the connection as iOS does a suspended app's sockets, and
    /// attempts fail until the app is back, as a suspended app makes none. With `unreachable`,
    /// they keep failing after it.
    public func dropForTesting(unreachable: Bool) {
        unreachableForTesting = unreachable
        guard task != nil else { return }
        handleDrop(gen: generation, failure: ConnectionFailure(URLError(.networkConnectionLost)))
    }
    #endif

    /// Calls `body` each time the connection becomes connected, the first time and after every
    /// reconnect, until it returns false. This connection is the only thing that retries; what
    /// depends on it (a `TerminalStream`) waits here instead of polling or retrying on its own.
    /// `body` runs as soon as `state` is `.connected`, before `onReconnected`.
    public func observeConnected(_ body: @escaping @MainActor () -> Bool) {
        connectedObservers.append(body)
    }

    private func notifyConnected() {
        // An observer added from inside a call is kept for the next time.
        let current = connectedObservers
        connectedObservers = []
        let kept = current.filter { $0() }
        connectedObservers = kept + connectedObservers
    }

    private func failAll(_ err: Error) {
        let p = pending
        pending.removeAll()
        for (_, c) in p { c(.failure(err)) }
    }

    private func handle(_ m: JSONObject) {
        guard let type = m.str("type") else { return }
        switch type {
        case "welcome":
            if let c = m.obj("client") {
                clientID = c.str("id")
                reconnectToken = c.str("reconnect_token")
            }
            if let lim = m.obj("limits"), let mx = lim.int("max_message_bytes") { maxMessageBytes = mx }
            // Every welcome, a resumed one included: the server may have been updated or
            // downgraded since the last. Set before `state`, whose observers read them.
            negotiatedRevision = m.int("api_revision") ?? 0
            serverRevision = m.int("api_server_revision") ?? 0
            features = Set((m["features"] as? [Any])?.compactMap { $0 as? String } ?? [])
            state = .connected
            welcomeWaiter?.resume()
            welcomeWaiter = nil
        case "response":
            guard let id = m.str("id"), let c = pending.removeValue(forKey: id) else { return }
            if let e = m.obj("error") {
                c(.failure(RexError(code: e.str("code") ?? "internal", message: e.str("message") ?? "error", status: e.int("status") ?? 500)))
            } else {
                c(.success(DecodedJSON(m["payload"] ?? NSNull())))
            }
        case "event":
            onEvent?(m.int("seq") ?? 0, m.obj("payload") ?? [:])
        default:
            break
        }
    }

    // MARK: Streams

    func streamStarted(_ stream: TerminalStream) {
        streams[stream.blockID] = WeakStream(stream: stream)
    }

    func streamStopped(_ stream: TerminalStream) {
        if streams[stream.blockID]?.stream === stream { streams[stream.blockID] = nil }
    }

    /// The running stream of a block, whose queue every input to that pane goes through. Nil
    /// when no pane of this connection shows the block.
    public func stream(block: String) -> TerminalStream? {
        streams[block]?.stream
    }

    // MARK: Calls

    @discardableResult
    public func call(_ method: String, _ payload: JSONObject? = nil) async throws -> JSONObject {
        let any = try await callAny(method, payload)
        return any as? JSONObject ?? [:]
    }

    public func callAny(_ method: String, _ payload: JSONObject? = nil) async throws -> Any {
        // `neverSent`: a caller that must not repeat a request (typed input) may send this one again.
        guard let t = task, state == .connected else { throw RexError.unsent("not connected") }
        // A method newer than this connection's revision: the answer is known, so don't ask.
        if let e = Self.tooNew(method, for: negotiatedRevision) { throw e }
        let reply = try await withCheckedThrowingContinuation { (c: CheckedContinuation<DecodedJSON, Error>) in
            send(method, payload, on: t) { c.resume(with: $0) }
        }
        return reply.value
    }

    /// Sends every request in `calls` in this one turn of the main actor, in order, then waits
    /// for all the answers, which come back in the same order whatever order they arrive in.
    ///
    /// The socket keeps the order of sends, and the server runs its ordered methods (`move_block`,
    /// `block.close`, `new_window`, …) in arrival order on a connection. Separate calls, `async
    /// let` or a task group promise no order, so a sequence that depends on it goes through here.
    /// One failing call doesn't stop the others: they have left already.
    public func callInOrder(_ calls: [(method: String, payload: JSONObject)]) async -> [Result<JSONObject, Error>] {
        guard !calls.isEmpty else { return [] }
        guard let t = task, state == .connected else {
            return calls.map { _ in .failure(RexError.unsent("not connected")) }
        }
        let revision = negotiatedRevision
        let replies = await withCheckedContinuation { (done: CheckedContinuation<[Result<DecodedJSON, Error>], Never>) in
            var results = [Result<DecodedJSON, Error>?](repeating: nil, count: calls.count)
            var left = calls.count
            func finish(_ i: Int, _ r: Result<DecodedJSON, Error>) {
                results[i] = r
                left -= 1
                if left == 0 { done.resume(returning: results.map { $0! }) }
            }
            for (i, c) in calls.enumerated() {
                if let e = Self.tooNew(c.method, for: revision) {
                    finish(i, .failure(e))
                } else {
                    send(c.method, c.payload, on: t) { finish(i, $0) }
                }
            }
        }
        return replies.map { r in r.map { $0.value as? JSONObject ?? [:] } }
    }

    /// `revision_too_low`, never sent, for a method this connection's revision doesn't have.
    private static func tooNew(_ method: String, for revision: Int) -> RexError? {
        let needs = RexAPI.minimum(for: method)
        guard revision < needs else { return nil }
        var e = RexError(code: "revision_too_low", message: "\(method) needs API revision \(needs).", status: 400)
        e.neverSent = true
        return e
    }

    /// Registers `answer` for a new request and hands the request to the socket, in this turn.
    private func send(_ method: String, _ payload: JSONObject?, on t: URLSessionWebSocketTask,
                      answer: @escaping (Result<DecodedJSON, Error>) -> Void) {
        nextID += 1
        let id = String(nextID)
        var req: JSONObject = ["type": "request", "id": id, "method": method]
        if let payload { req["payload"] = payload }
        pending[id] = answer
        t.send(.string(JSONCodec.encode(req))) { err in
            guard let err else { return }
            Task { @MainActor in
                // The socket didn't take the message, so the server never saw it. (A request
                // that was sent and then lost its connection fails in `failAll`.)
                if let c = self.pending.removeValue(forKey: id) {
                    c(.failure(RexError.unsent(err.localizedDescription)))
                }
            }
        }
    }

    /// Sends a request and doesn't wait for its answer, which is dropped when it comes. The
    /// message is handed to the socket before this returns, in the caller's turn of the main
    /// actor. For answers the server asked for (`client.reply`), where nothing can be done about
    /// a failure. Returns false when there is no connection to send on.
    @discardableResult
    public func post(_ method: String, _ payload: JSONObject) -> Bool {
        guard let t = task, state == .connected else { return false }
        nextID += 1
        let req: JSONObject = ["type": "request", "id": String(nextID), "method": method, "payload": payload]
        t.send(.string(JSONCodec.encode(req))) { _ in }
        return true
    }

    /// Calls a block method: payload is `{session_id, block_id, args}`.
    @discardableResult
    public func blockCall(_ method: String, session: String, block: String, args: JSONObject = [:]) async throws -> JSONObject {
        try await call(method, ["session_id": session, "block_id": block, "args": args])
    }
}
