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

    public static let apiRevision = 13

    /// The server address as configured.
    public let address: String
    /// `wss://host` for the address; nil when the address is invalid (`connect()` then fails).
    public let wsBase: URL?
    public let client: ClientInfo
    public private(set) var state: State = .idle {
        didSet {
            onStateChange?(state)
            if state == .connected, oldValue != .connected { notifyConnected() }
        }
    }
    public private(set) var clientID: String?
    public private(set) var maxMessageBytes = 65536

    public var onEvent: ((_ seq: Int, _ event: JSONObject) -> Void)?
    public var onStateChange: ((State) -> Void)?
    /// Called after a dropped connection is re-established (state must be re-read).
    public var onReconnected: ((_ resumed: Bool) -> Void)?

    private var task: URLSessionWebSocketTask?
    /// Also used by `TerminalStream` for the data sockets, so both share one configuration.
    let session: URLSession
    private var pending: [String: CheckedContinuation<DecodedJSON, Error>] = [:]
    private var nextID = 0
    private var reconnectToken: String?
    private var welcomeWaiter: CheckedContinuation<Void, Error>?
    private var pingTimer: Timer?
    private var generation = 0
    private var wantConnected = false
    private var retryDelay: Double = 1
    private var retryTask: Task<Void, Never>?
    private var connectedObservers: [@MainActor () -> Bool] = []

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
        // An attempt still waiting for its welcome is superseded by this one.
        resumeWelcome(throwing: RexError.local("superseded"))
        task?.cancel()
        generation += 1
        let gen = generation
        state = .connecting
        let url = wsBase.appendingPathComponent("api/control")
        let t = session.webSocketTask(with: url, protocols: ["rex.control.v1"])
        t.maximumMessageSize = 8 * 1024 * 1024
        task = t
        t.resume()

        var hello: JSONObject = [
            "type": "hello",
            "api_revision": Self.apiRevision,
            "client": [
                "kind": client.kind,
                "platform": client.platform,
                "name": client.name,
                "version": client.version,
                "label": client.label,
            ] as JSONObject,
        ]
        if let tok = reconnectToken { hello["reconnect_token"] = tok }
        let helloText = JSONCodec.encode(hello)
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

    private func resumeWelcome(throwing error: Error) {
        guard let w = welcomeWaiter else { return }
        welcomeWaiter = nil
        w.resume(throwing: error)
    }

    /// The failure plus what the socket task knows: the upgrade's HTTP status and the close code.
    private func failure(_ error: Error, _ t: URLSessionWebSocketTask?) -> ConnectionFailure {
        let status = (t?.response as? HTTPURLResponse)?.statusCode
        let close = t.flatMap { $0.closeCode == .invalid ? nil : $0.closeCode.rawValue }
        return ConnectionFailure(error, httpStatus: status == 101 ? nil : status, closeCode: close)
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
        for (_, c) in p { c.resume(throwing: err) }
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
            state = .connected
            welcomeWaiter?.resume()
            welcomeWaiter = nil
        case "response":
            guard let id = m.str("id"), let c = pending.removeValue(forKey: id) else { return }
            if let e = m.obj("error") {
                c.resume(throwing: RexError(code: e.str("code") ?? "internal", message: e.str("message") ?? "error", status: e.int("status") ?? 500))
            } else {
                c.resume(returning: DecodedJSON(m["payload"] ?? NSNull()))
            }
        case "event":
            onEvent?(m.int("seq") ?? 0, m.obj("payload") ?? [:])
        default:
            break
        }
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
        nextID += 1
        let id = String(nextID)
        var req: JSONObject = ["type": "request", "id": id, "method": method]
        if let payload { req["payload"] = payload }
        let text = JSONCodec.encode(req)
        let reply = try await withCheckedThrowingContinuation { (c: CheckedContinuation<DecodedJSON, Error>) in
            pending[id] = c
            t.send(.string(text)) { err in
                if let err {
                    Task { @MainActor in
                        // The socket didn't take the message, so the server never saw it. (A
                        // request that was sent and then lost its connection fails in `failAll`.)
                        if let c = self.pending.removeValue(forKey: id) {
                            c.resume(throwing: RexError.unsent(err.localizedDescription))
                        }
                    }
                }
            }
        }
        return reply.value
    }

    /// Calls a block method: payload is `{session_id, block_id, args}`.
    @discardableResult
    public func blockCall(_ method: String, session: String, block: String, args: JSONObject = [:]) async throws -> JSONObject {
        try await call(method, ["session_id": session, "block_id": block, "args": args])
    }
}
