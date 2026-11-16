import Foundation

/// The relay: watches the Rex server (found automatically, or the ones in the config), turns
/// agent and notification events into pushes, and serves the `register_push` /
/// `unregister_push` / `push_presence` client actions.
@MainActor
public final class Relay {
    nonisolated public static let version = "0.1.0"

    /// Actions the relay offers to other Rex clients (declared with `client.keymap`).
    /// The server checks `client.perform` args against these schemas.
    public static let actions: [JSONObject] = [
        [
            "name": "register_push", "kind": "client", "category": "Rex Connect",
            "title": "Register for Rex Connect Pushes",
            "description": "Send push notifications for this server's agents to an iPhone.",
            "args": [
                "type": "object",
                "properties": [
                    "token": ["type": "string", "description": "APNs device token, hex."],
                    "environment": ["type": "string", "enum": ["sandbox", "production"]],
                    "device_name": ["type": "string"],
                    "device_id": ["type": "string", "description": "Short id the app also puts in its client label as \"#<id>\"."],
                ] as JSONObject,
                "required": ["token", "environment"],
            ] as JSONObject,
        ],
        [
            "name": "unregister_push", "kind": "client", "category": "Rex Connect",
            "title": "Unregister from Rex Connect Pushes",
            "description": "Stop sending pushes to an iPhone.",
            "args": [
                "type": "object",
                "properties": ["token": ["type": "string"]] as JSONObject,
                "required": ["token"],
            ] as JSONObject,
        ],
        [
            "name": "push_presence", "kind": "client", "category": "Rex Connect",
            "title": "Rex Connect Presence",
            "description": "Tell the relay whether the calling Rex Connect app is in the foreground.",
            "args": [
                "type": "object",
                "properties": ["active": ["type": "boolean"]] as JSONObject,
                "required": ["active"],
            ] as JSONObject,
        ],
    ]

    final class Server {
        let conn: RexConnection
        /// The server's address as the app knows it (its Tailscale HTTPS URL), sent in payloads.
        var name = ""
        /// Set up and watching events.
        var ready = false
        var sessions: [String: String] = [:]
        var views: [String: SessionView] = [:]
        var latestRevision: [String: Int] = [:]
        /// App clients that said they went to the background (`push_presence {active: false}`).
        var backgrounded: Set<String> = []
        init(conn: RexConnection) { self.conn = conn }
    }

    struct SessionView {
        var revision: Int
        var blocks: [String: BlockContext]
    }

    public let store: DeviceStore
    private let sender: PushSender?
    private let dryRun: Bool
    private var servers: [Server] = []
    private var policy: PushPolicy
    private var limiter: RateLimiter
    private var dueTimer: Task<Void, Never>?

    /// Called when the relay starts or stops watching a server (for the app's window).
    public var onWatchingChanged: ((Bool) -> Void)?
    public var isWatching: Bool { servers.contains(where: \.ready) }

    /// `resolvers` find each server before every connection attempt. Nil uses the servers in
    /// `config`, or discovers the local one when it lists none.
    public init(config: RelayConfig, store: DeviceStore, sender: PushSender?, dryRun: Bool,
                resolvers: [RexConnection.Resolver]? = nil) {
        self.store = store
        self.sender = sender
        self.dryRun = dryRun
        self.policy = PushPolicy(debounce: config.debounceSeconds ?? 30)
        self.limiter = RateLimiter(capacity: config.rateLimitBurst ?? 10, perMinute: config.rateLimitPerMinute ?? 10)
        var ident = RexConnection.Identity()
        ident.version = Self.version
        if let l = config.label, !l.isEmpty { ident.label = l }
        let finders: [RexConnection.Resolver] = resolvers
            ?? config.endpoints.map { eps in eps.map { ep in { ep } } }
            ?? [{ await Discovery.find() }]
        for find in finders {
            let s = Server(conn: RexConnection(resolve: find, identity: ident))
            s.conn.onConnected = { [unowned self, unowned s] in
                try await self.setUp(s)
                s.ready = true
                self.onWatchingChanged?(self.isWatching)
            }
            s.conn.onDisconnected = { [unowned self, unowned s] _ in
                s.ready = false
                self.onWatchingChanged?(self.isWatching)
            }
            s.conn.onEvent = { [unowned self, unowned s] ev in self.handle(s, ev) }
            servers.append(s)
        }
    }

    public func start() {
        Log.info("Rex Connect Helper \(Self.version) starting; \(store.devices.count) registered device(s); "
                 + (dryRun ? "dry run, no pushes are sent" : (sender == nil ? "pushes disabled (no APNs key)" : "APNs on")))
        for s in servers { s.conn.start() }
    }

    public func stop() {
        for s in servers { s.conn.stop() }
    }

    // MARK: Setup

    private func setUp(_ s: Server) async throws {
        let boot = try await s.conn.call("session.bootstrap", ["event_scope": "all", "attach_session_ids": [String]()])
        // Payloads name the server by its Tailscale URL, which is how Rex Connect knows it.
        let url = boot.obj("server_status")?.obj("tailscale")?.obj("https")?.text("url")
            ?? s.conn.endpoint?.description ?? ""
        s.name = url.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        s.sessions = [:]
        for sess in boot.obj("attach_all")?.arr("sessions") ?? [] {
            if let id = sess.str("session_id") { s.sessions[id] = sess.str("label") ?? "" }
        }
        s.views = [:]
        s.latestRevision = [:]
        _ = try await s.conn.call("client.keymap", ["actions": Self.actions, "server_actions": "none"])
        let live = Set(try await appClients(s).map(\.clientID))
        s.backgrounded.formIntersection(live)
        Log.info("[\(s.conn.host)] watching \(s.sessions.count) session(s) as \(s.name); offering register_push")
    }

    // MARK: Events

    private func handle(_ s: Server, _ ev: JSONObject) {
        let p = ev.obj("payload") ?? [:]
        switch ev.str("type") {
        case "session_created":
            if let sess = p.obj("session"), let id = sess.str("session_id") {
                s.sessions[id] = sess.str("label") ?? ""
                Log.debug("[\(s.conn.host)] session created: \(sess.str("label") ?? id)")
            }
        case "session_destroyed":
            if let id = p.str("session_id") {
                s.sessions[id] = nil
                s.views[id] = nil
                s.latestRevision[id] = nil
            }
        case "client_left":
            if let id = p.str("client_id") { s.backgrounded.remove(id) }
        case "client_perform_requested":
            Task { await self.perform(s, p) }
        case "session_event":
            guard let sid = p.str("session_id"), let inner = p.obj("event") else { return }
            handleSessionEvent(s, sid, inner)
        default:
            break
        }
    }

    private func handleSessionEvent(_ s: Server, _ sid: String, _ ev: JSONObject) {
        let p = ev.obj("payload") ?? [:]
        switch ev.str("type") {
        case "session_view_changed":
            if let r = p.int("revision") { s.latestRevision[sid] = max(s.latestRevision[sid] ?? 0, r) }
        case "session_label_changed":
            if let l = p.str("label") { s.sessions[sid] = l }
        case "block_closed":
            if let b = p.str("block_id") {
                apply(policy.decide(.blockClosed(BlockRef(server: s.name, sessionID: sid, blockID: b)), now: Date()), s)
            }
        case "block_event":
            guard let b = p.str("block_id"), let name = p.str("name") else { return }
            let ref = BlockRef(server: s.name, sessionID: sid, blockID: b)
            let e = p.obj("payload") ?? [:]
            switch name {
            case "program_status_changed":
                guard let rep = StatusReport(event: e) else { return }
                let line = "[\(s.conn.host)] status \(short(b)) \(rep.recordID.isEmpty ? "" : rep.recordID + " ")→ \(rep.state)"
                    + (rep.app.map { " (\($0))" } ?? "") + (rep.msg.map { ": \($0)" } ?? "")
                if ["blocked", "done", "error"].contains(rep.state) { Log.info(line) } else { Log.debug(line) }
                apply(policy.decide(.status(ref, rep), now: Date()), s)
            case "program_status_removed":
                let ids = (e["ids"] as? [String]) ?? []
                apply(policy.decide(.statusRemoved(ref, ids: ids), now: Date()), s)
            case "desktop_notification":
                let body = e.str("body") ?? ""
                Log.info("[\(s.conn.host)] notification \(short(b)): \(e.text("title") ?? "") \(body)")
                apply(policy.decide(.notification(ref, title: e.text("title"), body: body), now: Date()), s)
            default:
                break
            }
        default:
            break
        }
    }

    private func short(_ id: String) -> String { String(id.suffix(6)) }

    private func apply(_ d: Decision, _ s: Server) {
        switch d {
        case .push(let i):
            Task { await self.dispatch(i) }
        case .deferred(let until):
            Log.info("blocked again within the debounce window; holding until \(until.formatted(date: .omitted, time: .standard))")
            scheduleDue()
        case .drop(let why):
            Log.debug("no push: \(why)")
        }
    }

    private func scheduleDue() {
        dueTimer?.cancel()
        guard let next = policy.nextDue else { return }
        dueTimer = Task {
            let wait = max(0, next.timeIntervalSinceNow) + 0.05
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard !Task.isCancelled else { return }
            for i in self.policy.due(now: Date()) { await self.dispatch(i) }
            self.scheduleDue()
        }
    }

    // MARK: Sending

    private func dispatch(_ intent: PushIntent) async {
        guard let s = servers.first(where: { $0.name == intent.ref.server }) else { return }
        let msg = PushMessage.compose(intent, context: await context(s, intent.ref))
        Log.info("push \(msg.category.rawValue) [\(msg.interruptionLevel)] \"\(msg.title)\": \(msg.body)")
        guard let sender else { return }
        let devices = store.devices
        if devices.isEmpty {
            if dryRun { Log.info("DRY-RUN push → (no registered devices) \(DryRunSender.describe(msg, topic: (sender as? DryRunSender)?.topic ?? ""))") }
            return
        }
        let (clients, background) = await presenceSnapshot()
        let now = Date()
        for d in devices {
            let who = d.deviceName ?? String(d.token.prefix(8))
            if Presence.isAppOpen(d, clients: clients, backgrounded: background) {
                Log.info("skip \(who): Rex Connect is open")
                continue
            }
            guard limiter.allow(d.token, now: now) else {
                Log.info("skip \(who): rate limited")
                continue
            }
            switch await sender.send(msg, to: d) {
            case .sent(let id):
                if !dryRun { Log.info("sent to \(who)\(id.map { " (apns-id \($0))" } ?? "")") }
            case .dropDevice(let why):
                Log.info("APNs rejected \(who) (\(why)); unregistering it")
                store.remove(token: d.token)
            case .failed(let why):
                Log.info("send to \(who) failed: \(why)")
            }
        }
    }

    private func appClients(_ s: Server) async throws -> [ClientSnapshot] {
        let r = try await s.conn.call("client.list", ["kinds": ["app"]])
        return r.arr("clients").compactMap(ClientSnapshot.init)
    }

    /// Asks every connected server who's connected right now. Pushes are rare, so this stays exact.
    private func presenceSnapshot() async -> ([ClientSnapshot], Set<String>) {
        var clients: [ClientSnapshot] = []
        var background = Set<String>()
        for s in servers where s.conn.isConnected {
            if let c = try? await appClients(s) { clients += c }
            background.formUnion(s.backgrounded)
        }
        return (clients, background)
    }

    private func context(_ s: Server, _ ref: BlockRef) async -> BlockContext {
        let sid = ref.sessionID
        if s.views[sid] == nil || (s.views[sid]!.revision < (s.latestRevision[sid] ?? 0)),
           let v = try? await s.conn.call("session.view", ["session_id": sid]) {
            s.views[sid] = Self.parseView(v)
            if let l = v.str("label") { s.sessions[sid] = l }
        }
        var c = s.views[sid]?.blocks[ref.blockID] ?? BlockContext()
        c.sessionLabel = s.sessions[sid].flatMap { $0.isEmpty ? nil : $0 }
        return c
    }

    static func parseView(_ v: JSONObject) -> SessionView {
        var blocks: [String: BlockContext] = [:]
        for w in v.arr("windows") {
            for layer in w.arr("layers") {
                for b in layer.arr("blocks") {
                    guard let id = b.str("block_id") else { continue }
                    blocks[id] = BlockContext(windowID: w.str("window_id"), tabLabel: w.text("label"), blockLabel: b.text("label"))
                }
            }
        }
        return SessionView(revision: v.int("revision") ?? 0, blocks: blocks)
    }

    // MARK: Client actions

    private func perform(_ s: Server, _ p: JSONObject) async {
        guard let callID = p.str("call_id") else { return }
        let args = p.obj("args") ?? [:]
        let requester = p.obj("requester") ?? [:]
        let who = requester.obj("info")?.str("label") ?? requester.str("client_id") ?? "?"
        var reply: JSONObject = ["call_id": callID]
        switch p.str("action") {
        case "register_push":
            let token = (args.str("token") ?? "").lowercased()
            let env = args.str("environment") ?? ""
            let devID = args.text("device_id")?.lowercased()
            if !Device.isValidToken(token) {
                reply["error"] = ["code": "bad_request", "message": "token must be the APNs device token in hex"]
            } else if env != "sandbox" && env != "production" {
                reply["error"] = ["code": "bad_request", "message": "environment must be sandbox or production"]
            } else if let devID, !Device.isValidDeviceID(devID) {
                reply["error"] = ["code": "bad_request", "message": "device_id must be 4-16 letters or digits"]
            } else {
                let pr = requester.obj("principal") ?? [:]
                let d = store.register(Device(
                    token: token, environment: env, deviceName: args.text("device_name"), deviceID: devID,
                    tailscaleNode: pr.str("kind") == "tailscale" ? pr.text("node") : nil))
                Log.info("registered \(d.deviceName ?? "device") [\(env)] token \(token.prefix(8))… from \(who)")
                reply["result"] = [
                    "registered": true, "devices": store.devices.count,
                    "push_enabled": sender != nil && !dryRun, "relay_version": Self.version,
                ] as JSONObject
            }
        case "unregister_push":
            let removed = store.remove(token: args.str("token") ?? "")
            Log.info("unregister from \(who): \(removed ? "removed" : "not found")")
            reply["result"] = ["removed": removed]
        case "push_presence":
            if let cid = requester.str("client_id") {
                if args.bool("active") == false { s.backgrounded.insert(cid) } else { s.backgrounded.remove(cid) }
                Log.info("presence from \(who): \(args.bool("active") == false ? "background" : "foreground")")
            }
            reply["result"] = [String: Any]()
        default:
            reply["error"] = ["code": "not_supported", "message": "unknown action \(p.str("action") ?? "")"]
        }
        do {
            try await s.conn.call("client.reply", reply)
        } catch {
            Log.info("client.reply failed: \(error.localizedDescription)")
        }
    }
}
