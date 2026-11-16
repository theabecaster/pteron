import Foundation
import RexKit

/// A minimal Rex control-API client (`/api/control`, subprotocol `rex.control.v1`).
/// It finds the server, connects, and reconnects forever with backoff.
/// Protocol reference: the server's `/llms.txt`.
///
/// It's event driven: while connected, nothing runs until the server sends something. The
/// server pings every 120 s and `WebSocket` answers; a local server that goes away closes the
/// socket, and a remote one is caught by TCP keepalive.
@MainActor
public final class RexConnection {
    public static let apiRevision = 14

    public struct Identity {
        public var kind = "other"
        public var platform = "macos"
        /// Rex Connect finds the relay by this name in `client.list`. Don't change it.
        public var name = "rex-push-relay"
        public var version = "0.1.0"
        public var label = "rex-push-relay"
        public init() {}
    }

    /// Finds the server's address; called before every connection attempt. Nil means "no server".
    public typealias Resolver = @MainActor () async -> RexEndpoint?

    public let identity: Identity
    public private(set) var endpoint: RexEndpoint?
    public private(set) var isConnected = false
    public private(set) var clientID: String?

    /// Called after each welcome. Run setup calls (bootstrap etc.) here; a throw drops the connection.
    public var onConnected: (() async throws -> Void)?
    /// Called with the event's inner object: `{"type": ..., "payload": ...}`.
    public var onEvent: ((JSONObject) -> Void)?
    public var onDisconnected: ((String) -> Void)?

    private let resolve: Resolver
    private var socket: WebSocket?
    private var pending: [String: CheckedContinuation<Any, Error>] = [:]
    private var timeouts: [String: Task<Void, Never>] = [:]
    private var nextID = 0
    private var reconnectToken: String?
    private var running = false
    private var loop: Task<Void, Never>?

    public init(resolve: @escaping Resolver, identity: Identity = Identity()) {
        self.resolve = resolve
        self.identity = identity
    }

    public convenience init(endpoint: RexEndpoint, identity: Identity = Identity()) {
        self.init(resolve: { endpoint }, identity: identity)
    }

    /// Short name for log lines.
    public var host: String {
        switch endpoint {
        case .unix?: return "local"
        case .url(let u)?: return u.host ?? u.absoluteString
        case nil: return "rex"
        }
    }

    public func start() {
        guard !running else { return }
        running = true
        loop = Task { await self.runForever() }
    }

    /// Closes the connection with a close frame, so Rex drops this client at once.
    public func stop() {
        running = false
        socket?.close(code: 1000)
        loop?.cancel()
    }

    // MARK: Connection loop

    private func runForever() async {
        var delay: Double = 1
        var lastReason = ""
        while running && !Task.isCancelled {
            let began = Date()
            var reason = "closed"
            if let ep = await resolve() {
                endpoint = ep
                do {
                    let ws = try await open(ep)
                    let receiver = Task { await self.receiveLoop(ws) }
                    do {
                        try await onConnected?()
                    } catch {
                        Log.info("[\(host)] setup failed: \(error.localizedDescription)")
                        ws.close(code: 1001)
                    }
                    reason = await receiver.value
                } catch {
                    reason = error.localizedDescription
                }
            } else {
                reason = "no Rex server found"
            }
            socket?.cancel()
            socket = nil
            let wasConnected = isConnected
            isConnected = false
            failAll(RexError.local("connection lost"))
            if wasConnected { onDisconnected?(reason) }
            guard running else { break }
            // A connection that stayed up a while starts the backoff over.
            if Date().timeIntervalSince(began) > 60 { delay = 1 }
            let wait = delay * Double.random(in: 0.8...1.2)
            // While Rex is down this repeats every minute; say it once.
            if reason != lastReason || wasConnected {
                Log.info("[\(host)] disconnected (\(reason)); retrying with backoff up to 60s")
            }
            lastReason = reason
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            delay = min(delay * 2, 60)
        }
    }

    private func open(_ ep: RexEndpoint) async throws -> WebSocket {
        let ws = WebSocket(endpoint: ep)
        socket = ws
        // Connect, upgrade, hello and welcome must all finish within 8 s.
        let timeout = Task {
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            if !Task.isCancelled { ws.cancel() }
        }
        defer { timeout.cancel() }
        try await ws.open(path: "/api/control", subprotocol: "rex.control.v1")

        var client: JSONObject = [
            "kind": identity.kind, "platform": identity.platform,
            "name": identity.name, "version": identity.version, "label": identity.label,
        ]
        client = client.filter { !(($0.value as? String) ?? "x").isEmpty }
        var hello: JSONObject = ["type": "hello", "api_revision": Self.apiRevision, "client": client]
        if let tok = reconnectToken { hello["reconnect_token"] = tok }
        try await ws.send(text: JSONCodec.encode(hello))

        // The welcome is always the first message.
        guard let m = JSONCodec.decode(try await ws.receive()), m.str("type") == "welcome" else {
            ws.close(code: 1002)
            throw RexError.local("expected welcome")
        }
        if let c = m.obj("client") {
            clientID = c.str("id")
            reconnectToken = c.str("reconnect_token")
        }
        isConnected = true
        let resumed = m.obj("client")?.bool("resumed") ?? false
        Log.info("[\(host)] connected to \(ep) as \(clientID ?? "?")\(resumed ? " (resumed)" : "")")
        return ws
    }

    private func receiveLoop(_ ws: WebSocket) async -> String {
        while true {
            do {
                guard let m = JSONCodec.decode(try await ws.receive()) else { continue }
                handle(m)
            } catch {
                return error.localizedDescription
            }
        }
    }

    private func handle(_ m: JSONObject) {
        switch m.str("type") {
        case "response":
            guard let id = m.str("id"), let c = pending.removeValue(forKey: id) else { return }
            timeouts.removeValue(forKey: id)?.cancel()
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
        for t in timeouts.values { t.cancel() }
        timeouts.removeAll()
        for (_, c) in p { c.resume(throwing: err) }
    }

    // MARK: Calls

    @discardableResult
    public func call(_ method: String, _ payload: JSONObject? = nil, timeout: Double = 20) async throws -> JSONObject {
        try await callAny(method, payload, timeout: timeout) as? JSONObject ?? [:]
    }

    public func callAny(_ method: String, _ payload: JSONObject? = nil, timeout: Double = 20) async throws -> Any {
        guard let ws = socket, isConnected else { throw RexError.local("not connected") }
        nextID += 1
        let id = "r\(nextID)"
        var req: JSONObject = ["type": "request", "id": id, "method": method]
        if let payload { req["payload"] = payload }
        let text = JSONCodec.encode(req)
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<Any, Error>) in
            pending[id] = c
            Task { @MainActor in
                do { try await ws.send(text: text) } catch { self.pending.removeValue(forKey: id)?.resume(throwing: error) }
            }
            timeouts[id] = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self.timeouts[id] = nil
                self.pending.removeValue(forKey: id)?.resume(throwing: RexError.local("\(method) timed out"))
            }
        }
    }
}
