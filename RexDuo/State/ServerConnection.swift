import SwiftUI
import RexKit

struct SessionEntry: Identifiable, Equatable {
    var id: String
    var label: String
}

/// One block's metadata, observed on its own.
@MainActor
@Observable
final class BlockMetaBox {
    var value: BlockMeta?
}

/// `server.meta[blockID]` reads and writes a block's metadata through its own observable box.
@MainActor
struct MetaTable {
    let server: ServerConnection

    subscript(id: String) -> BlockMeta? {
        get { server.metaBox(id).value }
        nonmutating set {
            let box = server.metaBox(id)
            guard box.value != newValue else { return }
            let old = box.value
            box.value = newValue
            if old?.agentKind != newValue?.agentKind || old?.topStatus?.state != newValue?.topStatus?.state {
                server.agentsMayHaveChanged()
            }
        }
    }
}

struct HostEntry: Identifiable, Equatable {
    var id: String
    var label: String
    var endpoints: [String]
}

/// Where an agent runs and what it is doing, without the details that change all the time.
struct AgentKey: Equatable, Identifiable {
    var id: String { blockID }
    var sessionID: String
    var windowID: String
    var blockID: String
    var kind: AgentKind?
    var state: String?
}

/// A computer from a server's host list that isn't saved in the app, for the sidebar.
struct KnownHost: Identifiable, Equatable {
    var id: String
    var label: String
    /// Its address, when it can be told (`PairingCode.candidate`).
    var candidate: PairingCode.Candidate?

    /// Every listed host that isn't a saved server, by name or by address, once each.
    static func unsaved(_ servers: [(config: ServerConfig, hosts: [HostEntry])]) -> [KnownHost] {
        let configs = servers.map(\.config)
        let names = Set(configs.map { $0.name.lowercased() })
        var seen = Set<String>()
        var out: [KnownHost] = []
        for (config, hosts) in servers {
            for h in hosts {
                let key = h.label.lowercased()
                guard !names.contains(key), !seen.contains(key) else { continue }
                let candidate = ServerConfig.url(from: config.url).flatMap {
                    PairingCode.candidate(label: h.label, endpoints: h.endpoints, listedBy: $0)
                }
                if let candidate, PairingCode.existing(candidate.url, in: configs) != nil { continue }
                seen.insert(key)
                out.append(KnownHost(id: h.id.isEmpty ? key : h.id, label: h.label, candidate: candidate))
            }
        }
        return out
    }
}

/// Everything known about one Rex server: its sessions, their layouts, and live block metadata.
///
/// Sync rules, kept simple:
/// - The server is the truth. A full resync (sessions, views, meta) replaces local state on first
///   connect, on every reconnect, on return to the foreground and when an event `seq` gap shows we
///   missed something. Every action ends by re-reading the server's view of the session.
/// - The UI stays calm: per-block events are coalesced into one update per ~150 ms, a status is held
///   on screen for at least a second (a new "blocked" shows at once), and connection drops only show
///   once they last more than a second.
/// - Offline holds still. `RexControl` retries in the background, but a retry never shows as
///   "connecting" once the server is offline; only a real connection leaves `.offline`. The problem
///   shown changes only through `ProblemGate`, so alternating errors don't swap the message.
/// - Waking up isn't a problem. A drop around a trip to the background is held for a few seconds
///   after the return (`ForegroundWake`) while the connection is made again: `phase` stays
///   `.online`, `waking` is set, and the offline screen shows only if the hold runs out.
@MainActor
@Observable
final class ServerConnection: Identifiable {
    enum Phase: Equatable {
        case idle
        /// The first attempt since start. Retries after a failure stay `.offline`.
        case connecting
        case online
        case offline(ConnectionProblem)

        var problem: ConnectionProblem? {
            if case .offline(let p) = self { return p }
            return nil
        }
    }

    let config: ServerConfig
    nonisolated var id: UUID { config.id }
    let control: RexControl
    /// What each hardware key does: Rex's defaults under the user's init.lua (`client.keymap`).
    @ObservationIgnored let keymap: KeymapStore
    /// In-app agent alerts and haptics; shared by every server.
    @ObservationIgnored let notifier: AgentNotifier
    /// Push registration with this server's Rex DUO Helper.
    @ObservationIgnored private weak var push: PushRegistrar?
    @ObservationIgnored let prefs: Prefs
    /// Counts successful connections, so per-connection work (push registration) can tell a new
    /// connection from a resync.
    @ObservationIgnored private(set) var connectionSerial = 0
    /// Whether this server takes files (`upload_begin`, `download_begin`), asked once per
    /// connection by the first pane that needs it (`PaneFiles.checkSupport`).
    @ObservationIgnored var fileSupport: (serial: Int, supported: Bool)?

    /// Connection state for the UI. A drop from online shows only after it lasts `phaseGrace`.
    var phase: Phase = .idle
    var sessions: [SessionEntry] = [] { didSet { agentsMayHaveChanged() } }
    var views: [String: SessionView] = [:] { didSet { agentsMayHaveChanged() } }
    /// Every agent's place, kind and state, in sidebar order. It changes only when an agent comes,
    /// goes, moves or changes kind or state, so the Agents list and the waiting count don't
    /// re-render for a title, directory or progress change in some pane.
    private(set) var agentKeys: [AgentKey] = []
    @ObservationIgnored private var agentKeysPending = false
    /// Live per-block metadata. Each block has its own observable box, so a status change in one pane
    /// only re-renders the views that read that pane (not every view that touches the server).
    var meta: MetaTable { MetaTable(server: self) }
    var hosts: [HostEntry] = []
    var hostName: String?
    /// What the server was built for (`server.version`), such as darwin_arm64: the sidebar's OS glyph.
    var platform: String?
    /// Who the server belongs to and which login it took this iPhone for (`server.status`,
    /// `server.whoami`). Decides whether to offer installing the helper there.
    var identity: ServerIdentity?
    var lastError: String?
    /// The user asked to try again and that attempt hasn't finished: the offline screen's feedback.
    var retrying = false
    /// The first full sync since the latest connect has finished, so sessions are loaded. The offline
    /// screen stays up until then, instead of flashing an empty sidebar.
    var synced = false
    /// Offline was shown and the sessions haven't reloaded since. The offline screen stays up for
    /// this, saying the signal is back, so it hands over to the app in one step.
    var recovering = false
    /// The offline screen is up for this server.
    var showsOffline: Bool { phase.problem != nil || recovering }
    /// The connection dropped around a trip to the background and is being made again, while
    /// `phase` stays `.online` (`ForegroundWake`). The title bar's Rexie breathes meanwhile.
    var waking = false

    /// What an install of the helper on this server listens for. Set by `HelperSetupCenter`.
    @ObservationIgnored var setupSignals: ((SetupSignal) -> Void)?
    /// Sessions this app opened to install the helper. They are the installer's, not the user's
    /// work, so they are left out of `sessions` and `views`.
    @ObservationIgnored var hiddenSessions: () -> Set<String> = { [] }

    /// What reaches a helper install from the server.
    enum SetupSignal {
        /// A block event in any session, hidden ones included.
        case block(session: String, block: String, name: String, payload: JSONObject)
        /// The control connection dropped.
        case disconnected
        /// A sync finished: on first connect, on every reconnect and on return to the foreground.
        case ready
    }

    @ObservationIgnored fileprivate var metaBoxes: [String: BlockMetaBox] = [:]
    /// The phone's network, to classify failures and retry when it changes. Nil in tests.
    @ObservationIgnored private let network: NetworkWatch?
    @ObservationIgnored private var gate = ProblemGate()
    /// A drop from online waits out `phaseGrace` before it shows.
    @ObservationIgnored private var graceTask: Task<Void, Never>?
    @ObservationIgnored private var pendingProblem: ConnectionProblem?
    /// Holds drops around a trip to the background.
    @ObservationIgnored private var wake = ForegroundWake()
    /// Ends the hold when its grace has passed.
    @ObservationIgnored private var wakeTask: Task<Void, Never>?
    @ObservationIgnored private var retryStarted = Date.distantPast
    @ObservationIgnored private var retryEnd: Task<Void, Never>?
    #if DEBUG
    /// `-simulateOffline`: shown instead of connecting.
    @ObservationIgnored private var simulated: ConnectionProblem.Kind?
    #endif
    @ObservationIgnored private var refreshScheduled: Set<String> = []
    @ObservationIgnored private var started = false
    // Resync bookkeeping.
    @ObservationIgnored private var lastSeq = 0
    @ObservationIgnored private var resyncTask: Task<Void, Never>?
    @ObservationIgnored private var syncing = false
    @ObservationIgnored private var syncAgain = false
    @ObservationIgnored private var touchedBlocks: Set<String> = []
    @ObservationIgnored private var touchedSessions: Set<String> = []
    // Coalescing and status hold.
    @ObservationIgnored private var pendingMeta: [String: BlockMeta] = [:]
    @ObservationIgnored private var statusShownAt: [String: Date] = [:]
    @ObservationIgnored private var flushTask: Task<Void, Never>?

    static let phaseGrace: Double = 1.0
    /// "Trying…" stays up at least this long, so a fast failure still reads as an attempt.
    static let minRetryShow: Double = 0.9
    static let coalesce: Double = 0.15
    static let minStatusHold: Double = 1.0

    /// Recomputes `agentKeys` once, after the changes of this turn of the main actor.
    fileprivate func agentsMayHaveChanged() {
        guard !agentKeysPending else { return }
        agentKeysPending = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.agentKeysPending = false
            let keys = self.currentAgentKeys()
            if keys != self.agentKeys { self.agentKeys = keys }
        }
    }

    /// The same agents as `agents`, without their titles and status lines.
    func currentAgentKeys() -> [AgentKey] {
        var keys: [AgentKey] = []
        for s in sessions {
            guard let v = views[s.id] else { continue }
            for w in v.windows {
                for b in w.allBlocks where b.isTerminal {
                    let m = metaBoxes[b.id]?.value ?? BlockMeta()
                    guard m.agentKind != nil || m.topStatus != nil else { continue }
                    keys.append(AgentKey(sessionID: s.id, windowID: w.id, blockID: b.id, kind: m.agentKind,
                                         state: m.topStatus?.state))
                }
            }
        }
        return keys
    }

    fileprivate func metaBox(_ id: String) -> BlockMetaBox {
        if let b = metaBoxes[id] { return b }
        let b = BlockMetaBox()
        metaBoxes[id] = b
        return b
    }

    /// `deviceID` ends the client label (` #<id>`), which is how the helper recognizes this phone.
    init(config: ServerConfig, prefs: Prefs, notifier: AgentNotifier, push: PushRegistrar? = nil,
         network: NetworkWatch? = nil, deviceID: String) {
        self.prefs = prefs
        self.config = config
        self.notifier = notifier
        self.push = push
        self.network = network
        control = RexControl(address: config.url, client: ClientInfo(
            name: "Rex DUO",
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
            label: PushIdentity.clientLabel(deviceName: UIDevice.current.name, deviceID: deviceID)))
        keymap = KeymapStore(control: control)
        control.onEvent = { [weak self] seq, ev in self?.receive(seq: seq, event: ev) }
        control.onStateChange = { [weak self] st in self?.controlChanged(st) }
        control.onReconnected = { [weak self] _ in
            // Events that happened while disconnected are lost: start over from the server's state.
            self?.scheduleResync(after: 0)
        }
    }

    // MARK: Connection

    /// Turns the socket's state into the phase on screen. Called for every attempt, so it must stay
    /// cheap and must not change `phase` unless the screen should change.
    private func controlChanged(_ st: RexControl.State) {
        switch st {
        case .connected:
            connectionSerial += 1
            show(.online)
            endRetry()
        case .connecting:
            // Only the first attempt shows. A retry while offline keeps the offline screen as it is.
            if phase == .idle { show(.connecting) }
        case .failed(let f):
            let snap = network?.snapshot ?? .unknown
            let p = ConnectionProblem.classify(f, network: snap)
            setupSignals?(.disconnected)
            if phase == .online,
               wake.failure(p.kind, answered: Self.answered(f), network: snap, now: Self.now()) == .hold {
                // Waking up: the tab stays as it was. The problem shows only if the hold runs out.
                pendingProblem = p
                // In the background nobody sees it; the mark's delay starts at the return (`beginWake`).
                if wake.state != .background, !waking { waking = true }
            } else if phase == .online {
                pendingProblem = p
                waitOutDrop()
            } else if graceTask == nil {
                show(.offline(gate.observe(p)))
            } else {
                pendingProblem = p
            }
            endRetry()
        case .idle:
            show(.idle)
        }
    }

    private func show(_ p: Phase) {
        if p == .online || p == .idle {
            graceTask?.cancel()
            graceTask = nil
            pendingProblem = nil
            gate.reset()
            wake.connected()
            wakeTask?.cancel()
            wakeTask = nil
        }
        if waking { waking = false }
        if p != .online { synced = false }
        if p.problem != nil, !recovering { recovering = true }
        if p == .idle, recovering { recovering = false }
        if phase != p { phase = p }
    }

    /// A drop from online shows only if it outlasts `phaseGrace`, so a blip that reconnects at once
    /// never reaches the screen.
    private func waitOutDrop() {
        guard graceTask == nil else { return }
        graceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.phaseGrace * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.graceTask = nil
            guard self.control.state != .connected, !self.wake.holds, let p = self.pendingProblem else { return }
            self.show(.offline(self.gate.observe(p)))
        }
    }

    /// The server answered and turned the connection away (an HTTP status, or a refused port):
    /// waiting won't change that.
    private static func answered(_ f: ConnectionFailure) -> Bool {
        f.httpStatus != nil || f.posixCode == Int(ECONNREFUSED)
    }

    private static func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// The app went to the background: a drop from here on is held until the return.
    func enteredBackground() {
        wake.enteredBackground(online: phase == .online && control.state == .connected)
        #if DEBUG
        // `-wakeTest drop|unreachable` (testing): lose the connection as the app goes, as iOS does.
        if let t = UserDefaults.standard.string(forKey: "wakeTest") {
            control.dropForTesting(unreachable: t == "unreachable")
        }
        #endif
    }

    /// The app is back: hold drops for `ForegroundWake.grace` while the connections are checked.
    private func beginWake() {
        guard wake.enteredForeground(now: Self.now()), let until = wake.deadline else { return }
        // A drop held while in the background shows now if it was a clear one.
        if let p = pendingProblem, ForegroundWake.isClear(p.kind, answered: false, network: network?.snapshot ?? .unknown) {
            endWake()
            return
        }
        if control.state != .connected, !waking { waking = true }
        wakeTask?.cancel()
        wakeTask = Task { [weak self] in
            let left = until - Self.now()
            if left > 0 { try? await Task.sleep(nanoseconds: UInt64(left * 1_000_000_000)) }
            guard !Task.isCancelled, let self else { return }
            self.wakeTask = nil
            if self.wake.expire(now: Self.now()) { self.endWake() }
        }
    }

    /// The hold is over: a drop that is still unresolved shows as any other does.
    private func endWake() {
        wakeTask?.cancel()
        wakeTask = nil
        guard control.state != .connected, let p = pendingProblem else { return }
        show(.offline(gate.observe(p)))
    }

    func start() {
        #if DEBUG
        if simulated != nil { return }
        #endif
        guard !started else { control.kick(); return }
        guard control.wsBase != nil else {
            // A typo in Settings: say so, and don't retry an address that can't work.
            let f = ConnectionFailure.invalidAddress(config.url)
            show(.offline(gate.observe(ConnectionProblem.classify(f, network: .unknown))))
            lastError = f.message
            return
        }
        started = true
        Task {
            do {
                try await control.connect()
                lastSeq = 0
                await bootstrap()
            } catch {
                // RexControl keeps retrying with backoff; a later connect resyncs via `onReconnected`.
                lastError = ConnectionFailure(error).message
            }
        }
    }

    func stop() {
        control.disconnect()
        started = false
        show(.idle)
    }

    /// Back in the foreground: reconnect if needed (which resyncs), or resync the live connection.
    /// From the background, the connection is also pinged (`RexControl.wake`): it may have died
    /// while the app was suspended, and a dead one is made again at once. Drops meanwhile are
    /// held (`beginWake`).
    func resume(fromBackground: Bool = false) {
        guard fromBackground, started else {
            start()
            if control.state == .connected { scheduleResync(after: 0) }
            return
        }
        #if DEBUG
        if simulated != nil { return }
        #endif
        beginWake()
        let wasConnected = control.state == .connected
        control.wake()
        // A connection that answers is resynced; one that drops resyncs when it is back.
        if wasConnected { scheduleResync(after: 0) }
    }

    /// The phone's network changed: whatever failed may work now, so try at once.
    func networkChanged() {
        if let snap = network?.snapshot, wake.networkChanged(snap) {
            // No network: waking up can't finish, so say so now.
            if let p = pendingProblem {
                pendingProblem = ConnectionProblem(kind: .noInternet, detail: p.detail)
            }
            endWake()
        }
        gate.networkChanged()
        guard started, control.state != .connected else { return }
        control.kick()
    }

    /// Try Again: retry now, with `retrying` set until the attempt ends.
    func retryNow() {
        guard phase != .online else { return }
        retrying = true
        retryStarted = Date()
        retryEnd?.cancel()
        #if DEBUG
        if simulated != nil {
            retryEnd = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_400_000_000)
                guard !Task.isCancelled else { return }
                self?.retrying = false
            }
            return
        }
        #endif
        if started { control.kick() } else { start() }
    }

    /// Reconnect from the sidebar: a fresh connection when online, else a retry that keeps the
    /// offline screen steady.
    func reconnect() {
        if control.state == .connected {
            stop()
            start()
        } else {
            retryNow()
        }
    }

    private func endRetry() {
        guard retrying else { return }
        let left = Self.minRetryShow - Date().timeIntervalSince(retryStarted)
        retryEnd?.cancel()
        retryEnd = Task { [weak self] in
            if left > 0 { try? await Task.sleep(nanoseconds: UInt64(left * 1_000_000_000)) }
            guard !Task.isCancelled else { return }
            self?.retrying = false
        }
    }

    #if DEBUG
    /// `-simulateOffline <kind>`: show that problem and never connect.
    func simulate(_ kind: ConnectionProblem.Kind) {
        simulated = kind
        show(.offline(ConnectionProblem(kind: kind, detail: "Simulated: -simulateOffline \(kind.rawValue)")))
    }
    #endif

    /// Pull to refresh: reload everything when online, otherwise try again.
    func refresh() async {
        if control.state == .connected {
            await bootstrap()
        } else {
            retryNow()
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
    }

    // MARK: Full sync

    func scheduleResync(after delay: Double = 0.25) {
        resyncTask?.cancel()
        resyncTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard !Task.isCancelled, let self else { return }
            await self.bootstrap()
        }
    }

    /// Reads the whole server state and replaces the local copy with it.
    func bootstrap() async {
        if syncing { syncAgain = true; return }
        syncing = true
        touchedBlocks = []
        touchedSessions = []
        defer {
            syncing = false
            if syncAgain { syncAgain = false; scheduleResync(after: 0.1) }
        }
        do {
            let r = try await control.call("session.bootstrap", ["event_scope": "all", "attach_session_ids": [String]()])
            if let st = r.obj("server_status"), let ts = st.obj("tailscale") {
                hostName = ts.str("dns_name")
            }
            let hidden = hiddenSessions()
            let list = (r.obj("attach_all")?.arr("sessions") ?? []).map {
                SessionEntry(id: $0.str("session_id") ?? "", label: $0.str("label") ?? "")
            }.filter { !hidden.contains($0.id) }
            var fresh: [String: SessionView] = [:]
            await withTaskGroup(of: SessionView?.self) { g in
                for s in list { g.addTask { await self.fetchView(s.id) } }
                for await v in g { if let v { fresh[v.sessionID] = v } }
            }
            // Replace, don't merge. Sessions changed by events during the sync get one more read.
            sessions = list.map { e in SessionEntry(id: e.id, label: fresh[e.id]?.label ?? e.label) }
            views = fresh
            // Sessions and tabs are in: the app can show them while metadata loads.
            if !synced, control.state == .connected {
                synced = true
                recovering = false
            }
            for sid in touchedSessions { refreshView(sid) }
            let blocks = fresh.values.flatMap { v in
                v.windows.flatMap(\.allBlocks).filter(\.isTerminal).map { (v.sessionID, $0.id) }
            }
            await loadMeta(blocks)
            await loadHosts()
            if platform == nil, let v = try? await control.call("server.version") { platform = v.str("platform") }
            if identity == nil, let who = try? await control.call("server.whoami") {
                identity = ServerIdentity(status: r.obj("server_status"), version: nil, whoami: who, sessions: nil, clients: nil)
            }
            await keymap.load()
            lastError = nil
            push?.serverReady(self)
            setupSignals?(.ready)
        } catch {
            lastError = error.localizedDescription
            // Connected but the server refused the sync: show the app with what it has rather than
            // holding the "back in range" card forever.
            if control.state == .connected { recovering = false }
        }
    }

    private func fetchView(_ sessionID: String) async -> SessionView? {
        guard let r = try? await control.call("session.attach", ["session_id": sessionID]), let v = r.obj("view") else { return nil }
        return SessionView(v)
    }

    func loadHosts() async {
        if let r = try? await control.call("hosts.list") {
            hosts = r.arr("hosts").map { HostEntry(id: $0.str("id") ?? "", label: $0.str("label") ?? "host",
                                                   endpoints: ($0["endpoints"] as? [String]) ?? []) }
        }
    }

    /// Drops sessions that became hidden after they were listed: the server announces a new
    /// session before the call that made it returns.
    func dropHiddenSessions() {
        let hidden = hiddenSessions()
        guard sessions.contains(where: { hidden.contains($0.id) }) || views.keys.contains(where: hidden.contains) else { return }
        sessions.removeAll { hidden.contains($0.id) }
        for id in hidden { views[id] = nil }
    }

    /// Attaches one new session (for `session_created`).
    func attach(_ sessionID: String) async {
        guard !hiddenSessions().contains(sessionID) else { return }
        guard let v = await fetchView(sessionID) else { return }
        apply(view: v)
        await loadMeta(v.windows.flatMap(\.allBlocks).filter(\.isTerminal).map { (sessionID, $0.id) })
    }

    private func apply(view: SessionView) {
        guard !hiddenSessions().contains(view.sessionID) else { return }
        if let old = views[view.sessionID], old.revision > view.revision { return }
        views[view.sessionID] = view
        if let i = sessions.firstIndex(where: { $0.id == view.sessionID }) {
            if sessions[i].label != view.label { sessions[i].label = view.label }
        } else {
            sessions.append(SessionEntry(id: view.sessionID, label: view.label))
        }
    }

    /// Re-reads a session's layout from the server. Bursts of calls collapse into one read.
    func refreshView(_ sessionID: String) {
        guard !refreshScheduled.contains(sessionID) else { return }
        refreshScheduled.insert(sessionID)
        Task {
            try? await Task.sleep(nanoseconds: 80_000_000)
            refreshScheduled.remove(sessionID)
            if let r = try? await control.call("session.view", ["session_id": sessionID]) {
                let v = r.obj("view") ?? r
                apply(view: SessionView(v))
            }
        }
    }

    /// One block's status, title and process, read in parallel. Each read parses its reply on the
    /// main actor and hands back plain values. Outer nil: the call failed, keep what we had.
    /// Inner nil: the server has none.
    private func readMeta(_ sid: String, _ bid: String) async -> (String, BlockMeta?, String??, String??) {
        async let st = readStatuses(sid, bid)
        async let ti = readTitle(sid, bid)
        async let pr = readProcess(sid, bid)
        return (bid, await st, await ti, await pr)
    }

    private func readStatuses(_ sid: String, _ bid: String) async -> BlockMeta? {
        guard let r = try? await control.blockCall("com.superlogical.terminal.program_status", session: sid, block: bid) else { return nil }
        var m = BlockMeta()
        for rec in r.arr("records") { m.statuses[rec.str("id") ?? ""] = ProgramStatus(rec) }
        return m
    }

    private func readTitle(_ sid: String, _ bid: String) async -> String?? {
        guard let r = try? await control.blockCall("com.superlogical.terminal.title", session: sid, block: bid) else { return nil }
        return .some(r.str("title"))
    }

    private func readProcess(_ sid: String, _ bid: String) async -> String?? {
        guard let r = try? await control.blockCall("com.superlogical.terminal.process", session: sid, block: bid) else { return nil }
        return .some(r.obj("foreground").map(Self.processLabel))
    }

    /// Reads status, title and process for the blocks and replaces what we had for them.
    private func loadMeta(_ blocks: [(session: String, block: String)]) async {
        await withTaskGroup(of: (String, BlockMeta?, String??, String??).self) { g in
            for (sid, bid) in blocks {
                g.addTask { await self.readMeta(sid, bid) }
            }
            for await (bid, statuses, title, fg) in g where !touchedBlocks.contains(bid) {
                var cur = pendingMeta[bid] ?? meta[bid] ?? BlockMeta()
                if let statuses { cur.statuses = statuses.statuses }
                if let title { cur.title = title }
                if let fg { cur.foreground = fg }
                pendingMeta[bid] = nil
                statusShownAt[bid] = Date()
                meta[bid] = cur
            }
        }
    }

    nonisolated static func processLabel(_ fg: JSONObject) -> String {
        if let s = fg.str("script"), !s.isEmpty { return (s as NSString).lastPathComponent }
        if let a = fg.str("invoked_path") ?? fg.str("argv0"), !a.isEmpty {
            return (a.trimmingCharacters(in: CharacterSet(charactersIn: "-")) as NSString).lastPathComponent
        }
        return fg.str("name") ?? ""
    }

    // MARK: Events

    private func receive(seq: Int, event: JSONObject) {
        if seq > 0 {
            // seq counts events on this connection from 1, with no gaps. A jump means we missed some.
            if seq > 1, lastSeq > 0, seq > lastSeq + 1 { scheduleResync() }
            lastSeq = seq
        }
        handle(event: event)
    }

    private func handle(event: JSONObject) {
        let type = event.str("type") ?? ""
        let p = event.obj("payload") ?? [:]
        switch type {
        case "session_created":
            if let s = p.obj("session"), let id = s.str("session_id"), !hiddenSessions().contains(id) {
                if !sessions.contains(where: { $0.id == id }) { sessions.append(SessionEntry(id: id, label: s.str("label") ?? "")) }
                touchedSessions.insert(id)
                Task { await attach(id) }
            }
        case "session_destroyed":
            let id = p.str("session_id") ?? p.obj("session")?.str("session_id") ?? ""
            sessions.removeAll { $0.id == id }
            views[id] = nil
        case "session_moved":
            Task {
                if let r = try? await control.call("session.list") {
                    let order = r.arr("sessions").compactMap { $0.str("session_id") }
                    sessions.sort { (order.firstIndex(of: $0.id) ?? 0) < (order.firstIndex(of: $1.id) ?? 0) }
                }
            }
        case "hosts_changed":
            Task { await loadHosts() }
        case "keymap_changed":
            keymap.configChanged(hash: p.str("hash"))
        case "client_joined":
            if p.obj("client")?.obj("info")?.str("name") == RelayLookup.clientName { push?.relayChanged(self) }
        case "client_left":
            if let id = p.str("client_id"), push?.isRelay(id, on: self) == true { push?.relayChanged(self) }
        case "session_event":
            guard let sid = p.str("session_id"), let ev = p.obj("event") else { return }
            handle(sessionID: sid, event: ev)
        default:
            break
        }
    }

    private func handle(sessionID sid: String, event ev: JSONObject) {
        let type = ev.str("type") ?? ""
        let p = ev.obj("payload") ?? [:]
        if type == "block_event", let bid = p.str("block_id") {
            setupSignals?(.block(session: sid, block: bid, name: p.str("name") ?? "", payload: p.obj("payload") ?? [:]))
        }
        // The installer's session has no row, no badge and no toast.
        guard !hiddenSessions().contains(sid) else { return }
        switch type {
        case "session_view_changed":
            let rev = p.int("revision") ?? Int.max
            if rev > (views[sid]?.revision ?? -1) { touchedSessions.insert(sid); refreshView(sid) }
        case "session_label_changed":
            if let l = p.str("label") {
                views[sid]?.label = l
                if let i = sessions.firstIndex(where: { $0.id == sid }) { sessions[i].label = l }
            }
        case "block_created":
            touchedSessions.insert(sid)
            refreshView(sid)
            if let bid = p.str("block_id") {
                Task { try? await Task.sleep(nanoseconds: 300_000_000); await loadMeta([(sid, bid)]) }
            }
        case "block_event":
            handleBlockEvent(sessionID: sid, p)
        case "window_created", "window_closed", "window_label_changed", "active_window_changed", "block_closed", "block_owner_changed":
            touchedSessions.insert(sid)
            refreshView(sid)
        default:
            break
        }
    }

    private func handleBlockEvent(sessionID sid: String, _ p: JSONObject) {
        guard let bid = p.str("block_id") else { return }
        let name = p.str("name") ?? ""
        let e = p.obj("payload") ?? [:]
        var m = pendingMeta[bid] ?? meta[bid] ?? BlockMeta()
        switch name {
        case "title_changed":
            m.title = e.str("title")
        case "pwd_changed":
            m.pwd = e.str("pwd")
        case "process_changed":
            if let fg = e.obj("foreground") { m.foreground = Self.processLabel(fg) } else { m.foreground = nil }
        case "program_status_changed":
            let id = e.str("id") ?? ""
            let prev = m.statuses[id]?.state
            if let rec = e.obj("record") {
                let st = ProgramStatus(rec)
                m.statuses[id] = st
                if st.state == "blocked", prev != "blocked" { notifyBlocked(sid, bid, st, m) }
            }
        case "program_status_removed":
            for id in (e["ids"] as? [String]) ?? [] { m.statuses[id] = nil }
        case "bell":
            m.bellAt = Date()
        case "child_exited":
            m.exited = true
        case "desktop_notification":
            // No banner in the app; the helper pushes these while the app is in the background.
            return
        default:
            return
        }
        if syncing { touchedBlocks.insert(bid) }
        pendingMeta[bid] = m
        scheduleFlush(after: Self.coalesce)
    }

    // MARK: Coalescing

    private func scheduleFlush(after delay: Double) {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(delay, 0.01) * 1_000_000_000))
            self?.flush()
        }
    }

    /// Applies the buffered block updates in one go. A status that changed less than `minStatusHold`
    /// ago stays on screen a little longer, so badges don't flicker; a new "blocked" shows at once.
    private func flush() {
        flushTask = nil
        let now = Date()
        var wait: Double?
        for (bid, m) in pendingMeta {
            let old = meta[bid]?.topStatus?.state
            let new = m.topStatus?.state
            if old != new {
                let age = now.timeIntervalSince(statusShownAt[bid] ?? .distantPast)
                if new != "blocked", age < Self.minStatusHold {
                    let rest = Self.minStatusHold - age
                    wait = min(wait ?? rest, rest)
                    continue
                }
                statusShownAt[bid] = now
            }
            meta[bid] = m
            pendingMeta[bid] = nil
        }
        if let wait { scheduleFlush(after: wait) }
    }

    private func notifyBlocked(_ sid: String, _ bid: String, _ st: ProgramStatus, _ m: BlockMeta) {
        let who = m.agentKind?.displayName ?? st.app ?? "A program"
        let why: String
        switch st.waitingFor {
        case "permission": why = "needs permission"
        case "question": why = "has a question"
        case "auth": why = "needs a password"
        default: why = "is waiting for you"
        }
        let place = label(for: sid, block: bid)
        notifier.post(AgentAlert(serverID: id, sessionID: sid, windowID: views[sid]?.windowContaining(block: bid)?.id,
                                 blockID: bid, title: "\(who) \(why)",
                                 body: [place.isEmpty ? nil : place, st.text].compactMap { $0 }.joined(separator: " — "),
                                 date: Date()))
        notifier.waitingHaptic()
    }

    func label(for sid: String, block bid: String) -> String {
        let s = views[sid]
        let w = s?.windowContaining(block: bid)
        return [s?.label, w?.label].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " › ")
    }

    // MARK: Actions
    //
    // Each action asks the server, then re-reads the server's view of the session. Nothing guesses a
    // layout locally. A failure shows a short notice and the view is re-read, so the screen matches
    // the server either way.

    @discardableResult
    private func act(_ what: String, session sid: String?, _ body: () async throws -> JSONObject) async -> JSONObject? {
        do {
            let r = try await body()
            if let sid { refreshView(sid) }
            return r
        } catch {
            Notice.shared.show("Couldn't \(what). \(Self.short(error))")
            if let sid { refreshView(sid) }
            return nil
        }
    }

    private static func short(_ error: Error) -> String {
        let s = (error as? RexError).map { $0.message } ?? error.localizedDescription
        return s.count > 80 ? String(s.prefix(80)) : s
    }

    @discardableResult
    func createSession(label: String?) async -> String? {
        var p: JSONObject = ["initial_windows": [["layout": ["block": ["flavor": "com.superlogical.terminal.shell"]]]]]
        if let label, !label.isEmpty { p["label"] = label }
        guard let r = await act("create the session", session: nil, { try await self.control.call("session.create", p) }),
              let id = r.str("session_id") else { return nil }
        if !sessions.contains(where: { $0.id == id }) { sessions.append(SessionEntry(id: id, label: label ?? "")) }
        await attach(id)
        return id
    }

    func newWindow(_ sid: String, label: String? = nil) async {
        var p: JSONObject = ["session_id": sid, "layout": ["block": ["flavor": "com.superlogical.terminal.shell"]], "focus": true]
        if let label, !label.isEmpty { p["window_label"] = label }
        await act("open a tab", session: sid) { try await self.control.call("session.new_window", p) }
    }

    func split(_ sid: String, anchor: String, vertical: Bool) async {
        await act("split the pane", session: sid) {
            try await self.control.call("session.new_split", [
                "session_id": sid, "anchor_id": anchor, "direction": vertical ? "vertical" : "horizontal",
                "side": "after", "ratio": 0.5, "focus": true,
                "layout": ["block": ["flavor": "com.superlogical.terminal.shell"]],
            ])
        }
    }

    func closeBlock(_ sid: String, _ bid: String) async {
        await act("close the pane", session: sid) { try await self.control.call("block.close", ["session_id": sid, "block_id": bid]) }
    }

    func closeWindow(_ sid: String, _ wid: String) async {
        await act("close the tab", session: sid) { try await self.control.call("session.close_window", ["session_id": sid, "window_id": wid]) }
    }

    func destroySession(_ sid: String) async {
        // Only drop it locally once the server agrees.
        guard await act("close the session", session: nil, { try await self.control.call("session.destroy", ["session_id": sid]) }) != nil else { return }
        sessions.removeAll { $0.id == sid }
        views[sid] = nil
    }

    func renameSession(_ sid: String, _ label: String) async {
        await act("rename the session", session: sid) { try await self.control.call("session.set_label", ["session_id": sid, "label": label]) }
    }

    func renameWindow(_ sid: String, _ wid: String, _ label: String) async {
        await act("rename the tab", session: sid) {
            try await self.control.call("session.set_window_label", ["session_id": sid, "window_id": wid, "label": label])
        }
    }

    func focus(_ sid: String, block: String) async {
        _ = try? await control.call("session.focus_block", ["session_id": sid, "block_id": block])
    }

    func focusWindow(_ sid: String, _ wid: String) async {
        _ = try? await control.call("session.focus_window", ["session_id": sid, "window_id": wid])
    }

    func zoom(_ sid: String, block: String, on: Bool?) async {
        var p: JSONObject = ["session_id": sid, "block_id": block]
        if let on { p["zoom"] = on }
        await act("zoom the pane", session: sid) { try await self.control.call("session.zoom_block", p) }
    }

    func resizePane(_ sid: String, direction: String, before: String, after: String, ratio: Double) async {
        await act("resize the pane", session: sid) {
            try await self.control.call("session.resize_pane", [
                "session_id": sid, "direction": direction, "before_block_id": before, "after_block_id": after,
                "ratio": min(max(ratio, 0.05), 0.95),
            ])
        }
    }

    /// Types text into a pane. Escape sequences work: "\u{1b}" is Esc, "\r" is Enter.
    func write(_ sid: String, _ bid: String, _ text: String) async {
        await act("send to the pane", session: nil) {
            try await self.control.blockCall("com.superlogical.terminal.write", session: sid, block: bid, args: ["data": text])
        }
    }

    /// The last lines of a pane as plain text (tab overview cards).
    func preview(_ sid: String, _ bid: String, lines: Int = 16) async -> String? {
        let window = 6000
        guard let r = try? await control.blockCall("com.superlogical.terminal.format", session: sid, block: bid,
                                                   args: ["format": "text", "trim": true, "max_bytes": window]) else { return nil }
        var text = r.str("content") ?? ""
        if let id = r.int("id"), let total = r.int("total"), total > window,
           let tail = try? await control.blockCall("com.superlogical.terminal.blob_read", session: sid, block: bid,
                                                   args: ["id": id, "offset": total - window, "max_bytes": window]) {
            text = tail.str("data") ?? text
        }
        let rows = text.split(separator: "\n", omittingEmptySubsequences: false)
        var trimmed = rows[...]
        while let last = trimmed.last, last.trimmingCharacters(in: .whitespaces).isEmpty { trimmed = trimmed.dropLast() }
        return trimmed.suffix(lines).joined(separator: "\n")
    }

    func clear(_ sid: String, _ bid: String) async {
        await act("clear the pane", session: nil) {
            try await self.control.blockCall("com.superlogical.terminal.clear", session: sid, block: bid)
        }
    }

    // MARK: Derived

    struct AgentRow: Identifiable {
        var id: String { blockID }
        var sessionID: String
        var windowID: String
        var blockID: String
        var kind: AgentKind?
        var status: ProgramStatus?
        var title: String
        var place: String
    }

    var agents: [AgentRow] {
        var rows: [AgentRow] = []
        for s in sessions {
            guard let v = views[s.id] else { continue }
            for w in v.windows {
                for b in w.allBlocks where b.isTerminal {
                    let m = meta[b.id] ?? BlockMeta()
                    guard m.agentKind != nil || m.topStatus != nil else { continue }
                    rows.append(AgentRow(sessionID: s.id, windowID: w.id, blockID: b.id, kind: m.agentKind,
                                         status: m.topStatus, title: m.title ?? b.label,
                                         place: [v.label, w.label].filter { !$0.isEmpty }.joined(separator: " › ")))
                }
            }
        }
        let rank = ["blocked": 0, "error": 1, "working": 2, "done": 3, "idle": 4]
        return rows.sorted { (rank[$0.status?.state ?? "idle"] ?? 5) < (rank[$1.status?.state ?? "idle"] ?? 5) }
    }

    func windowStatus(_ w: WindowInfo) -> ProgramStatus? {
        let rank = ["blocked": 5, "error": 4, "working": 3, "done": 2, "idle": 1]
        return w.allBlocks.compactMap { meta[$0.id]?.topStatus }.max { (rank[$0.state] ?? 0) < (rank[$1.state] ?? 0) }
    }

    func windowAgent(_ w: WindowInfo) -> AgentKind? {
        w.allBlocks.lazy.compactMap { self.meta[$0.id]?.agentKind }.first
    }
}
