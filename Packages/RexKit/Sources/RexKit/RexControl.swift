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
        case failed(String)
    }

    public static let apiRevision = 13

    public let baseURL: URL
    public let client: ClientInfo
    public private(set) var state: State = .idle { didSet { onStateChange?(state) } }
    public private(set) var clientID: String?
    public private(set) var maxMessageBytes = 65536

    public var onEvent: ((_ seq: Int, _ event: JSONObject) -> Void)?
    public var onStateChange: ((State) -> Void)?
    /// Called after a dropped connection is re-established (state must be re-read).
    public var onReconnected: ((_ resumed: Bool) -> Void)?

    private var task: URLSessionWebSocketTask?
    private let session: URLSession
    private var pending: [String: CheckedContinuation<Any, Error>] = [:]
    private var nextID = 0
    private var reconnectToken: String?
    private var welcomeWaiter: CheckedContinuation<Void, Error>?
    private var pingTimer: Timer?
    private var generation = 0
    private var wantConnected = false
    private var retryDelay: Double = 1

    public init(baseURL: URL, client: ClientInfo) {
        self.baseURL = baseURL
        self.client = client
        let cfg = URLSessionConfiguration.default
        cfg.waitsForConnectivity = false
        cfg.timeoutIntervalForRequest = 20
        self.session = URLSession(configuration: cfg)
    }

    public var wsBase: URL {
        var c = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        if c.scheme == "https" { c.scheme = "wss" } else if c.scheme == "http" { c.scheme = "ws" }
        c.path = ""
        return c.url!
    }

    // MARK: Connection

    public func connect() async throws {
        wantConnected = true
        try await openSocket()
    }

    public func disconnect() {
        wantConnected = false
        pingTimer?.invalidate()
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        failAll(RexError.local("disconnected"))
        state = .idle
    }

    private func openSocket() async throws {
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
                Task { @MainActor in
                    if let w = self.welcomeWaiter, gen == self.generation {
                        self.welcomeWaiter = nil
                        w.resume(throwing: err)
                    }
                }
            }
            // Welcome timeout.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                if let w = self.welcomeWaiter, gen == self.generation {
                    self.welcomeWaiter = nil
                    w.resume(throwing: RexError.local("Timed out waiting for the server. Is Tailscale on?"))
                }
            }
        }
        startPings(gen: gen)
    }

    private func startPings(gen: Int) {
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, gen == self.generation, let t = self.task else { return }
                t.sendPing { err in
                    if err != nil {
                        Task { @MainActor in self.handleDrop(gen: gen, reason: "ping failed") }
                    }
                }
            }
        }
    }

    private func receiveLoop(_ t: URLSessionWebSocketTask, gen: Int) {
        t.receive { [weak self] result in
            Task { @MainActor in
                guard let self, gen == self.generation else { return }
                switch result {
                case .success(let msg):
                    switch msg {
                    case .string(let s): self.handle(text: s)
                    case .data(let d): self.handle(text: String(decoding: d, as: UTF8.self))
                    @unknown default: break
                    }
                    self.receiveLoop(t, gen: gen)
                case .failure(let err):
                    self.handleDrop(gen: gen, reason: err.localizedDescription)
                }
            }
        }
    }

    private func handleDrop(gen: Int, reason: String) {
        guard gen == generation else { return }
        generation += 1
        pingTimer?.invalidate()
        task?.cancel()
        task = nil
        failAll(RexError.local("connection lost"))
        if let w = welcomeWaiter {
            welcomeWaiter = nil
            w.resume(throwing: RexError.local(reason))
        }
        state = .failed(reason)
        guard wantConnected else { return }
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 15)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard self.wantConnected, self.task == nil else { return }
            do {
                let hadToken = self.reconnectToken != nil
                try await self.openSocket()
                self.retryDelay = 1
                self.onReconnected?(hadToken)
            } catch {
                self.handleDrop(gen: self.generation, reason: error.localizedDescription)
            }
        }
    }

    /// Reconnect immediately (e.g. when the app returns to the foreground).
    public func kick() {
        guard wantConnected else { return }
        if task == nil || state != .connected {
            retryDelay = 0.2
            handleDrop(gen: generation, reason: "reconnecting")
        }
    }

    private func failAll(_ err: Error) {
        let p = pending
        pending.removeAll()
        for (_, c) in p { c.resume(throwing: err) }
    }

    private func handle(text: String) {
        guard let m = JSONCodec.decode(text), let type = m.str("type") else { return }
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
                c.resume(returning: m["payload"] ?? NSNull())
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
        guard let t = task, state == .connected else { throw RexError.local("not connected") }
        nextID += 1
        let id = String(nextID)
        var req: JSONObject = ["type": "request", "id": id, "method": method]
        if let payload { req["payload"] = payload }
        let text = JSONCodec.encode(req)
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<Any, Error>) in
            pending[id] = c
            t.send(.string(text)) { err in
                if let err {
                    Task { @MainActor in
                        if let c = self.pending.removeValue(forKey: id) { c.resume(throwing: err) }
                    }
                }
            }
        }
    }

    /// Calls a block method: payload is `{session_id, block_id, args}`.
    @discardableResult
    public func blockCall(_ method: String, session: String, block: String, args: JSONObject = [:]) async throws -> JSONObject {
        try await call(method, ["session_id": session, "block_id": block, "args": args])
    }
}
