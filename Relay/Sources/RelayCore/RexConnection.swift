import Foundation

/// A minimal Rex control-API client (`/api/control`, subprotocol `rex.control.v1`).
/// It connects, keeps the connection alive, and reconnects forever with backoff.
/// Protocol reference: the server's `/llms.txt`.
@MainActor
public final class RexConnection {
    public static let apiRevision = 14

    public struct Identity {
        public var kind = "other"
        public var platform = "macos"
        public var name = "rex-push-relay"
        public var version = "0.1.0"
        public var label = "rex-push-relay"
        public init() {}
    }

    public let baseURL: URL
    public let identity: Identity
    public private(set) var isConnected = false
    public private(set) var clientID: String?

    /// Called after each welcome. Run setup calls (bootstrap etc.) here; a throw drops the connection.
    public var onConnected: (() async throws -> Void)?
    /// Called with the event's inner object: `{"type": ..., "payload": ...}`.
    public var onEvent: ((JSONObject) -> Void)?
    public var onDisconnected: ((String) -> Void)?

    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private var pending: [String: CheckedContinuation<Any, Error>] = [:]
    private var nextID = 0
    private var reconnectToken: String?
    private var running = false
    private var loop: Task<Void, Never>?

    public init(baseURL: URL, identity: Identity = Identity()) {
        self.baseURL = baseURL
        self.identity = identity
        let cfg = URLSessionConfiguration.ephemeral
        cfg.waitsForConnectivity = false
        cfg.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: cfg)
    }

    var controlURL: URL {
        var c = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        if c.scheme == "https" { c.scheme = "wss" } else if c.scheme == "http" { c.scheme = "ws" }
        c.path = "/api/control"
        c.query = nil
        return c.url!
    }

    public func start() {
        guard !running else { return }
        running = true
        loop = Task { await self.runForever() }
    }

    public func stop() {
        running = false
        task?.cancel(with: .normalClosure, reason: nil)
        loop?.cancel()
    }

    // MARK: Connection loop

    private func runForever() async {
        var delay: Double = 1
        while running && !Task.isCancelled {
            let began = Date()
            var reason = "closed"
            do {
                let t = try await open()
                let receiver = Task { await self.receiveLoop(t) }
                let pinger = Task { await self.pingLoop(t) }
                do {
                    try await onConnected?()
                } catch {
                    Log.info("[\(host)] setup failed: \(error.localizedDescription)")
                    t.cancel(with: .goingAway, reason: nil)
                }
                reason = await receiver.value
                pinger.cancel()
            } catch {
                reason = error.localizedDescription
            }
            task = nil
            let wasConnected = isConnected
            isConnected = false
            failAll(RexError.local("connection lost"))
            if wasConnected { onDisconnected?(reason) }
            guard running else { break }
            // A connection that stayed up a while starts the backoff over.
            if Date().timeIntervalSince(began) > 60 { delay = 1 }
            let wait = delay * Double.random(in: 0.8...1.2)
            Log.info("[\(host)] disconnected (\(reason)); retrying in \(Int(wait.rounded()))s")
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            delay = min(delay * 2, 60)
        }
    }

    var host: String { baseURL.host ?? baseURL.absoluteString }

    private func open() async throws -> URLSessionWebSocketTask {
        let t = session.webSocketTask(with: controlURL, protocols: ["rex.control.v1"])
        t.maximumMessageSize = 16 * 1024 * 1024
        task = t
        t.resume()

        var client: JSONObject = [
            "kind": identity.kind, "platform": identity.platform,
            "name": identity.name, "version": identity.version, "label": identity.label,
        ]
        client = client.filter { !(($0.value as? String) ?? "x").isEmpty }
        var hello: JSONObject = ["type": "hello", "api_revision": Self.apiRevision, "client": client]
        if let tok = reconnectToken { hello["reconnect_token"] = tok }
        try await t.send(.string(JSONCodec.encode(hello)))

        // The welcome is always the first message. Give up after 8 s.
        let timeout = Task {
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            if !Task.isCancelled { t.cancel(with: .goingAway, reason: nil) }
        }
        defer { timeout.cancel() }
        let first = try await t.receive()
        guard let m = Self.decode(first), m.str("type") == "welcome" else {
            t.cancel(with: .protocolError, reason: nil)
            throw RexError.local("expected welcome")
        }
        if let c = m.obj("client") {
            clientID = c.str("id")
            reconnectToken = c.str("reconnect_token")
        }
        isConnected = true
        let resumed = m.obj("client")?.bool("resumed") ?? false
        Log.info("[\(host)] connected as \(clientID ?? "?")\(resumed ? " (resumed)" : "")")
        return t
    }

    private static func decode(_ msg: URLSessionWebSocketTask.Message) -> JSONObject? {
        switch msg {
        case .string(let s): return JSONCodec.decode(s)
        case .data(let d): return JSONCodec.decode(d)
        @unknown default: return nil
        }
    }

    private func receiveLoop(_ t: URLSessionWebSocketTask) async -> String {
        while true {
            do {
                let msg = try await t.receive()
                guard let m = Self.decode(msg) else { continue }
                handle(m)
            } catch {
                if t.closeCode != .invalid { return "closed \(t.closeCode.rawValue)" }
                return error.localizedDescription
            }
        }
    }

    /// The server pings every 120 s; we ping too so we notice a dead server.
    private func pingLoop(_ t: URLSessionWebSocketTask) async {
        final class Flag: @unchecked Sendable { var ok = false }
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 45_000_000_000)
            guard !Task.isCancelled else { return }
            let flag = Flag()
            t.sendPing { err in if err == nil { flag.ok = true } }
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard !Task.isCancelled else { return }
            if !flag.ok {
                Log.info("[\(host)] ping timed out")
                t.cancel(with: .goingAway, reason: nil)
                return
            }
        }
    }

    private func handle(_ m: JSONObject) {
        switch m.str("type") {
        case "response":
            guard let id = m.str("id"), let c = pending.removeValue(forKey: id) else { return }
            if let e = m.obj("error") {
                c.resume(throwing: RexError(code: e.str("code") ?? "internal", message: e.str("message") ?? "error"))
            } else {
                c.resume(returning: m["payload"] ?? NSNull())
            }
        case "event":
            if let inner = m.obj("payload") { onEvent?(inner) }
        default:
            break
        }
    }

    private func failAll(_ err: Error) {
        let p = pending
        pending.removeAll()
        for (_, c) in p { c.resume(throwing: err) }
    }

    // MARK: Calls

    @discardableResult
    public func call(_ method: String, _ payload: JSONObject? = nil, timeout: Double = 20) async throws -> JSONObject {
        try await callAny(method, payload, timeout: timeout) as? JSONObject ?? [:]
    }

    public func callAny(_ method: String, _ payload: JSONObject? = nil, timeout: Double = 20) async throws -> Any {
        guard let t = task, isConnected else { throw RexError.local("not connected") }
        nextID += 1
        let id = "r\(nextID)"
        var req: JSONObject = ["type": "request", "id": id, "method": method]
        if let payload { req["payload"] = payload }
        let text = JSONCodec.encode(req)
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<Any, Error>) in
            pending[id] = c
            t.send(.string(text)) { err in
                guard let err else { return }
                Task { @MainActor in self.pending.removeValue(forKey: id)?.resume(throwing: err) }
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self.pending.removeValue(forKey: id)?.resume(throwing: RexError.local("\(method) timed out"))
            }
        }
    }
}
