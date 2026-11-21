import GlanceModel
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

/// The parts of a block's metadata that both a read and a live event can set.
struct MetaFields: OptionSet {
    let rawValue: Int
    static let statuses = MetaFields(rawValue: 1)
    static let title = MetaFields(rawValue: 2)
    static let foreground = MetaFields(rawValue: 4)

    /// What a block event of this name sets.
    static func set(byBlockEvent name: String) -> MetaFields {
        switch name {
        case "title_changed": return .title
        case "process_changed": return .foreground
        case "program_status_changed", "program_status_removed": return .statuses
        default: return []
        }
    }
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
            server.paneNames.set(id, PaneNameParts(newValue))
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
///   once they last more than five seconds (`phaseGrace`).
/// - Offline holds still. `RexControl` retries in the background, but a retry never shows as
///   "connecting" once the server is offline; only a real connection leaves `.offline`. The problem
///   shown changes only through `ProblemGate`, so alternating errors don't swap the message.
///   While every computer is silent together, a silent server says that instead of its own
///   problem (`ConnectionProblem.under`, `tunnelNoticeChanged`).
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
    /// Push registration with this server's Beacon.
    @ObservationIgnored weak var push: PushRegistrar?
    @ObservationIgnored let prefs: Prefs
    /// Counts successful connections, so per-connection work (push registration) can tell a new
    /// connection from a resync.
    @ObservationIgnored private(set) var connectionSerial = 0
    /// What this server can do: its API revision, its creators, and what probes found.
    @ObservationIgnored let capabilities = ServerCapabilities()
    /// What to read again when the server drops an oversized event (`recover(dropped:)`).
    @ObservationIgnored let router = EventRouter()
    /// Who answers the server's questions; by default nobody, and each is declined.
    @ObservationIgnored let prompts = PromptHook()

    /// Connection state for the UI. A drop from online shows only after it lasts `phaseGrace`.
    var phase: Phase = .idle
    var sessions: [SessionEntry] = [] {
        didSet {
            agentsMayHaveChanged()
            if pendingOrder.sessions != nil { releaseSessionHold() }
        }
    }
    var views: [String: SessionView] = [:] {
        didSet {
            agentsMayHaveChanged()
            if !pendingOrder.tabs.isEmpty { releaseTabHolds() }
            viewsChanged?(self, oldValue)
        }
    }
    /// Told of every change to `views`, with the views before it, in the same turn: the app moves
    /// off a tab that closed before anything draws the empty state (`CloseNext`).
    @ObservationIgnored var viewsChanged: (@MainActor (ServerConnection, [String: SessionView]) -> Void)?
    /// A sidebar drag's new order, shown until the server's lists agree (`PendingOrder`).
    var pendingOrder = PendingOrder()
    /// Each pane's agent and program, for its name in menus: a title change writes nothing here.
    @ObservationIgnored let paneNames = BlockBoxTable<PaneNameParts>()
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
    /// Every agent's state has been read since the latest thing that could have made it stale: a
    /// connect, a resync that was asked for, a trip to the background. `synced` comes earlier, when
    /// the tabs are in and the states are not. Until this is true, "no agent is waiting here" is
    /// not known. Read by `AppModel.openWaiting`, which polls it; no view observes it.
    @ObservationIgnored private(set) var agentsCurrent = false
    /// Every agent's state has just been read, or one changed while they were all known.
    /// AppModel sets it, to clear notifications that no longer hold (`NotificationTidier`).
    @ObservationIgnored var agentsKnown: (@MainActor () -> Void)?
    /// Counts what makes the agent states stale, so a sync that began before the latest one
    /// doesn't call them current.
    @ObservationIgnored private var agentsStale = 0
    /// Offline was shown and the sessions haven't reloaded since. The offline screen stays up for
    /// this, saying the signal is back, so it hands over to the app in one step.
    var recovering = false
    /// The offline screen is up for this server.
    var showsOffline: Bool { phase.problem != nil || recovering }
    /// Whether the app says that the way to the computers is down (`TunnelSuspicion`). Set by
    /// `AppModel`; alone, a server never says it.
    @ObservationIgnored var tunnelShows: @MainActor () -> Bool = { false }
    /// Called when the control connection's state changed: what `TunnelSuspicion` reads may
    /// have changed with it. Set by `AppModel`.
    @ObservationIgnored var linkChanged: (@MainActor () -> Void)?
    /// The user asked something of this computer (Try Again, Reconnect, a pull to refresh, a
    /// new session, opening it): at a launch it starts now instead of waiting its turn.
    @ObservationIgnored var wanted: (@MainActor () -> Void)?
    /// Called when a sync has the sessions and tabs in for the first time on a connection.
    @ObservationIgnored var firstSynced: (@MainActor () -> Void)?
    /// The connection dropped around a trip to the background and is being made again, while
    /// `phase` stays `.online` (`ForegroundWake`). The title bar's Glide breathes meanwhile.
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
    @ObservationIgnored var lastSeq = 0
    @ObservationIgnored private var resyncTask: Task<Void, Never>?
    @ObservationIgnored var syncing = false
    @ObservationIgnored private var syncAgain = false
    @ObservationIgnored var touchedBlocks: Set<String> = []
    @ObservationIgnored var touchedSessions: Set<String> = []
    @ObservationIgnored var creatorsTask: Task<Void, Never>?
    /// Counts creator reads, so only the newest one's answer is used.
    @ObservationIgnored private var creatorsRead = 0
    /// Blocks whose dropped event waits for one metadata read (`recover(dropped:)`), with their session.
    @ObservationIgnored var droppedBlocks: [String: String] = [:]
    @ObservationIgnored var droppedBlocksTask: Task<Void, Never>?
    /// What live events changed in each block while a metadata read is out, per read, so the
    /// read's older answer doesn't replace it.
    @ObservationIgnored var metaReads: [Int: [String: MetaFields]] = [:]
    @ObservationIgnored private var nextMetaRead = 0
    /// On cellular or a hotspot at most four of a sync's reads are under way at once
    /// (`CallGate`): one call for each session, three for each pane and one for each pane's
    /// ports don't go out in one turn there. On Wi-Fi nothing goes through it: a sync is as it
    /// always was. What the user does never waits here.
    @ObservationIgnored let syncCalls = CallGate()
    /// Whether reads that start now go through `syncCalls`: the path is cellular or a hotspot,
    /// by the same word the cellular deadlines go by. Asked once where a batch of reads starts,
    /// so a change of path in the middle leaves the batch as it began.
    var gatesSync: Bool { control.onExpensivePath }
    /// The session of the tab on screen, when it is on this computer: a sync reads it first.
    @ObservationIgnored var shownSession: (@MainActor () -> String?)?

    /// `items` with those of the session on screen first, the rest in their order.
    nonisolated static func shownFirst<T>(_ items: [T], shown: String?, session: (T) -> String) -> [T] {
        guard let shown else { return items }
        return items.filter { session($0) == shown } + items.filter { session($0) != shown }
    }
    @ObservationIgnored var sessionListTask: Task<Void, Never>?
    /// Counts what makes a session list read out of date: a session event, or a full sync. Only a
    /// read that saw no change after it began is applied, so an older list never lands last.
    @ObservationIgnored var sessionListGeneration = 0
    /// Another read is owed: an event came while one was out.
    @ObservationIgnored var sessionListAgain = false
    /// The latest session drag's call, which the next one waits for (`session.move` isn't ordered).
    @ObservationIgnored var sessionMoveTask: Task<Void, Never>?
    /// Counts the drags whose order is held, so only the newest one's answer sets the release.
    @ObservationIgnored var nextOrderToken = 0
    // Coalescing and status hold.
    @ObservationIgnored var pendingMeta: [String: BlockMeta] = [:]
    @ObservationIgnored var statusShownAt: [String: Date] = [:]
    @ObservationIgnored var flushTask: Task<Void, Never>?
    /// Each pane's progress bar (OSC 9;4). Its own table and flush, never `meta`: a report
    /// re-renders only the rings that read the pane, and the meta flush keeps its pace.
    @ObservationIgnored let progress = BlockBoxTable<TermProgress>()
    /// Reports since the last progress flush, newest per block; `.value` nil is a removal.
    @ObservationIgnored var pendingProgress: [String: PendingProgress] = [:]
    /// When each block last reported progress, equal reports included. A bar with no report for
    /// `progressStale` goes, as Ghostty's does.
    @ObservationIgnored var progressSeen: [String: ContinuousClock.Instant] = [:]
    @ObservationIgnored var progressFlushTask: Task<Void, Never>?
    @ObservationIgnored var progressSweepTask: Task<Void, Never>?
    /// When each block last lost an OSC 7501 record: its notices count as an agent's a while longer.
    @ObservationIgnored var statusRemovedAt: [String: ContinuousClock.Instant] = [:]
    /// Each block's latest notice text and when it came, so a repeat is dropped before it waits.
    @ObservationIgnored var noticeTexts: [String: NoticeText] = [:]
    /// How many of each block's notices wait out `noticeWait` now.
    @ObservationIgnored var noticesInWait: [String: Int] = [:]
    /// Each local terminal's listening ports (`ServerConnection+Ports.swift`). Its own table, so a
    /// change re-renders only the views that read that pane's list.
    @ObservationIgnored let ports = BlockBoxTable<PortList>()
    /// `ports_changed` lists since the last flush, newest per block.
    @ObservationIgnored var pendingPorts: [String: PortList] = [:]
    /// Panes on screen: their ports are read first.
    @ObservationIgnored var portWatch: [String: PortWatch] = [:]
    /// The connection each pane's ports were last read on (or an event gave them on).
    @ObservationIgnored var portsRead: [String: Int] = [:]
    /// The ports list's rows, in sidebar order: set only when they change, so the sidebar and
    /// the palette read ports here and never walk the lists.
    var portRows: [PortRow] = []
    /// The rows' ids alone, set only when a row comes or goes: what a machine's ports button and
    /// its list read, so a port that changes hands re-renders its own row and nothing else.
    var portRowIDs: [String] = []
    /// Whether there is any row: all a machine's ports button reads while it has none.
    var hasPortRows = false
    /// Where each row's port is, for a row to read its own pane's list.
    @ObservationIgnored var portRowPlaces: [String: PortRow] = [:]
    /// When `block_created` named each block that hasn't reached a view yet.
    @ObservationIgnored var createdAt: [String: Date] = [:]
    /// The app's forwards to dev servers; set by `AppModel`.
    @ObservationIgnored weak var forward: PortForward?

    /// A drop from online shows nothing for this long: most end sooner.
    static let phaseGrace: Double = 5.0
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
            guard keys != self.agentKeys else { return }
            self.agentKeys = keys
            if self.agentsCurrent { self.agentsKnown?() }
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

    /// A block's newest metadata, buffered or applied, without making it a box.
    func currentMeta(_ id: String) -> BlockMeta? {
        pendingMeta[id] ?? metaBoxes[id]?.value
    }

    fileprivate func metaBox(_ id: String) -> BlockMetaBox {
        if let b = metaBoxes[id] { return b }
        let b = BlockMetaBox()
        metaBoxes[id] = b
        return b
    }

    /// `deviceID` ends the client label (` #<id>`), which is how the helper recognizes this phone.
    /// `log`: the connection log, which gets this connection's state changes and retries.
    /// `governor`: what the app's servers share when they reconnect (the budget, the breaker).
    init(config: ServerConfig, prefs: Prefs, notifier: AgentNotifier, push: PushRegistrar? = nil,
         network: NetworkWatch? = nil, deviceID: String, log: ConnectionLog? = nil,
         governor: ReconnectGovernor? = nil) {
        self.prefs = prefs
        self.config = config
        self.notifier = notifier
        self.push = push
        self.network = network
        control = RexControl(address: config.url, client: ClientInfo(
            name: Brand.appName,
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
            label: PushIdentity.clientLabel(deviceName: UIDevice.current.name, deviceID: deviceID)),
            governor: governor)
        keymap = KeymapStore(control: control)
        #if DEBUG || BENCH
        // `-netDelay <ms>` (testing): a simulated round-trip time on this server's calls and
        // terminal streams (docs/debug-args.md).
        let delay = UserDefaults.standard.integer(forKey: "netDelay")
        if delay > 0 { control.linkDelay = LinkDelay(roundTrip: .milliseconds(delay)) }
        #endif
        control.onEvent = { [weak self] seq, ev in self?.receive(seq: seq, event: ev) }
        // The log knows the server by its id alone: no name and no address.
        let reporter = log.map { ConnectionReporter(log: $0, server: ConnectionDiagnostics.key(config)) }
        control.onStateChange = { [weak self] st in
            reporter?.changed(st)
            self?.controlChanged(st)
        }
        control.onRetryScheduled = { reporter?.retryScheduled(after: $0) }
        control.onAttempt = { reporter?.attempt($0) }
        control.onDormant = { reporter?.wentDormant() }
        control.onReconnected = { [weak self] _ in
            // Events that happened while disconnected are lost: start over from the server's state.
            self?.scheduleResync(after: 0)
        }
        // No method reads a progress bar back: a dropped report clears it until the next one.
        router.on(blockEvent: "progress_report") { [weak self] _, bid in self?.dropProgress(bid) }
        // The list is read back.
        router.on(blockEvent: "ports_changed") { [weak self] sid, bid in self?.portsDropped(session: sid, bid) }
    }

    // MARK: Connection

    /// Turns the socket's state into the phase on screen. Called for every attempt, so it must stay
    /// cheap and must not change `phase` unless the screen should change.
    private func controlChanged(_ st: RexControl.State) {
        switch st {
        case .connected:
            connectionSerial += 1
            // Nothing reads the bars back, and reports from before may be stale.
            resetProgress()
            resetPorts()
            capabilities.connected(serial: connectionSerial, revision: control.negotiatedRevision,
                                   serverRevision: control.serverRevision, features: control.features)
            // The bootstrap's lists win over a drag's order from before.
            if !pendingOrder.isEmpty { pendingOrder = PendingOrder() }
            panesSupportChanged()
            prompts.onConnected?(connectionSerial)
            #if DEBUG
            // To check on a device or simulator which revision a server gave this connection.
            NSLog("CONTROL_API negotiated=%d server=%d", control.negotiatedRevision, control.serverRevision)
            #endif
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
                show(.offline(worded(gate.observe(p))))
            } else {
                pendingProblem = p
            }
            endRetry()
        case .idle:
            show(.idle)
        }
        linkChanged?()
    }

    /// The problem as shown: the server's own, or the tunnel's while that shows and this server
    /// is silent.
    private func worded(_ own: ConnectionProblem) -> ConnectionProblem {
        own.under(tunnel: tunnelShows(), host: control.tunnelFact,
                  tailnetAddress: TailscaleApp.isTailnetAddress(config.url))
    }

    /// The tunnel's message came or went: an offline
    /// server says the tunnel's problem or its own again, at once. `ProblemGate` keeps the
    /// server's own problem all along, so nothing has to fail again first.
    func tunnelNoticeChanged() {
        guard case .offline(let shown) = phase, let own = gate.shown else { return }
        let p = worded(own)
        if p != shown { show(.offline(p)) }
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
        if p != .online {
            synced = false
            agentsWentStale()
        }
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
            self.show(.offline(self.worded(self.gate.observe(p))))
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
        // Nothing is retried in the background, and no wait for a retry stays armed.
        control.enteredBackground()
        wake.enteredBackground(online: phase == .online && control.state == .connected)
        // No events arrive while the app is suspended.
        agentsWentStale()
        #if DEBUG
        // `-wakeTest drop|unreachable` (testing): lose the connection as the app goes, as iOS does.
        if let t = UserDefaults.standard.string(forKey: "wakeTest") {
            control.dropForTesting(unreachable: t == "unreachable")
        }
        #endif
    }

    /// The app is back: hold drops for `ForegroundWake.grace` while the connections are checked.
    private func beginWake() {
        guard wake.enteredForeground(now: Self.now(), expensive: network?.snapshot.expensive ?? false),
              let until = wake.deadline else { return }
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
        show(.offline(worded(gate.observe(p))))
    }

    func start() {
        #if DEBUG
        if simulated != nil { return }
        #endif
        guard !started else { control.kick(.foreground); return }
        guard control.wsBase != nil else {
            // A typo in Settings: say so, and don't retry an address that can't work.
            let f = ConnectionFailure.invalidAddress(config.url)
            show(.offline(gate.observe(ConnectionProblem.classify(f, network: .unknown))))
            lastError = f.message
            return
        }
        started = true
        // The path as it is now, so the deadlines fit Wi-Fi or cellular from the first attempt.
        tellPath(interfaceChanged: false)
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
        guard started else { return }
        // Not every report is a new route: with no path nothing is tried, and with one again a
        // wait that had stopped goes on. `routeChanged()` says when the route really changed.
        tellPath(interfaceChanged: false)
    }

    /// The path monitor's first report: the path the app started on, which `start()` may have
    /// been too early to read. No change, so nothing is asked.
    func pathStarted() {
        guard started else { return }
        tellPath(interfaceChanged: false)
    }

    /// The route really changed and has settled (`RouteWatch`): another kind of interface, other
    /// tunnel addresses, or a path after none. The connection decides by its policy: a socket
    /// that is up is pinged and never torn down, and a server that is down gets one attempt only
    /// past the floor.
    func routeChanged() {
        guard started else { return }
        tellPath(interfaceChanged: true)
    }

    /// Passes the phone's network path on to the control connection.
    private func tellPath(interfaceChanged: Bool) {
        let snap = network?.snapshot ?? .unknown
        control.pathChanged(satisfied: snap.reachable, expensive: snap.expensive, interfaceChanged: interfaceChanged)
    }

    /// The user moved to this server from another one: a tap. A server that is down gets one
    /// attempt now (none while one is under way); a connected one needs nothing. Moving between
    /// the tabs and panes of one server is not a tap and asks for nothing.
    func opened() {
        guard started, control.state != .connected else { return }
        control.kick(.user)
    }

    /// Try Again: retry now, with `retrying` set until the attempt ends.
    func retryNow() {
        wanted?()
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
        if started { control.kick(.user) } else { start() }
    }

    /// Reconnect from the sidebar: a fresh connection when online, else a retry that keeps the
    /// offline screen steady.
    func reconnect() {
        wanted?()
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

    /// Pull to refresh: reload everything when online. A server that is down is tried again
    /// only when `retry` says so: a pull tries one server that is down, not all of them
    /// (`AppModel.refresh`).
    func refresh(retry: Bool = true) async {
        if retry { wanted?() }
        if control.state == .connected {
            await bootstrap()
        } else {
            if retry { retryNow() }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
    }

    // MARK: Full sync

    func scheduleResync(after delay: Double = 0.25) {
        agentsWentStale()
        resyncTask?.cancel()
        resyncTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard !Task.isCancelled, let self else { return }
            await self.bootstrap()
        }
    }

    /// The agent states may be out of date until the next full read ends.
    func agentsWentStale() {
        agentsStale += 1
        agentsCurrent = false
    }

    /// Every agent's state has been read. `agentKeys` is brought up to date now, not a turn
    /// later, so whoever sees `agentsCurrent` can read it at once instead of walking the tabs.
    func agentsWereRead() {
        let keys = currentAgentKeys()
        if keys != agentKeys { agentKeys = keys }
        agentsCurrent = true
        agentsKnown?()
    }

    /// Reads the whole server state and replaces the local copy with it.
    func bootstrap() async {
        if syncing { syncAgain = true; return }
        syncing = true
        let stale = agentsStale
        // Bars reported from here on are as new as anything this sync reads.
        let progressMark = ContinuousClock.now
        touchedBlocks = []
        touchedSessions = []
        // A session list read that began before this sync is older than it.
        sessionListGeneration += 1
        defer {
            syncing = false
            if syncAgain { syncAgain = false; scheduleResync(after: 0.1) }
        }
        do {
            let r = try await control.call("session.bootstrap", ["event_scope": "all", "attach_session_ids": [String]()])
            if let st = r.obj("server_status"), let ts = st.obj("tailscale") {
                hostName = ts.str("dns_name")
            }
            capabilities.status(instance: r.obj("server_status")?.str("instance_id"),
                                hostID: r.obj("server_status")?.str("host_id"))
            // Once per server process and revision, not on every sync: the list is about 70 KB.
            // Not awaited: what the sync shows doesn't wait for a list only entry points read.
            let readsCreators = capabilities.needsCreatorRead
            if readsCreators { loadCreators() }
            #if DEBUG
            // One line per sync, to count syncs and creator reads on a device or simulator.
            NSLog("CONTROL_SYNC creators=%@", readsCreators ? "read" : "kept")
            #endif
            let hidden = hiddenSessions()
            let list = (r.obj("attach_all")?.arr("sessions") ?? []).map {
                SessionEntry(id: $0.str("session_id") ?? "", label: $0.str("label") ?? "")
            }.filter { !hidden.contains($0.id) }
            // The session on screen first. On cellular four at a time; on Wi-Fi all at once.
            let shown = shownSession?()
            let ids = Self.shownFirst(list.map(\.id), shown: shown) { $0 }
            var fresh: [String: SessionView] = [:]
            if gatesSync {
                let read = ViewReads()
                let serial = connectionSerial
                await syncCalls.each(ids) { [weak self] id in
                    // Not on a later connection: its own sync reads the sessions again.
                    guard let self, serial == self.connectionSerial, self.control.state == .connected else { return }
                    if let v = await self.fetchView(id) { read.views[v.sessionID] = v }
                }
                fresh = read.views
            } else {
                await withTaskGroup(of: SessionView?.self) { g in
                    for id in ids { g.addTask { await self.fetchView(id) } }
                    for await v in g { if let v { fresh[v.sessionID] = v } }
                }
            }
            // Replace, don't merge. Sessions changed by events during the sync get one more read.
            sessions = list.map { e in SessionEntry(id: e.id, label: fresh[e.id]?.label ?? e.label) }
            views = fresh
            let live = Set(fresh.values.flatMap { $0.windows.flatMap(\.allBlocks).map(\.id) })
            paneNames.removeAll { !live.contains($0) }
            // A sync means events may have been missed, a bar's removal among them: bars with
            // no report since the sync began go. A bar reported during the sync is live and stays.
            clearProgressBoxes(notSeenSince: progressMark)
            portsSynced()
            // Sessions and tabs are in: the app can show them while metadata loads.
            if !synced, control.state == .connected {
                synced = true
                firstSynced?()
                recovering = false
            }
            for sid in touchedSessions { refreshView(sid) }
            let blocks = fresh.values.flatMap { v in
                v.windows.flatMap(\.allBlocks).filter(\.isTerminal).map { (v.sessionID, $0.id) }
            }
            await loadMeta(Self.shownFirst(blocks, shown: shown) { $0.0 })
            if stale == agentsStale, !syncAgain, control.state == .connected { agentsWereRead() }
            await loadHosts()
            if platform == nil, let v = try? await control.call("server.version") { platform = v.str("platform") }
            if identity == nil, let who = try? await control.call("server.whoami") {
                identity = ServerIdentity(status: r.obj("server_status"), version: nil, whoami: who, sessions: nil, clients: nil)
            }
            await keymap.load()
            lastError = nil
            push?.serverReady(self)
            forward?.serverSynced(self)
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

    /// Reads `block_creator.list` into `capabilities`: on the first sync with a server process at
    /// a revision, and when the server says the creators or the hosts changed. Of a burst of
    /// calls only the newest one's answer is used.
    func loadCreators() {
        let serial = connectionSerial
        creatorsRead += 1
        let read = creatorsRead
        creatorsTask = Task { [weak self] in
            guard let self else { return }
            let r = self.gatesSync ? try? await self.syncCalls.run { try await self.control.call("block_creator.list") }
                : try? await self.control.call("block_creator.list")
            guard read == self.creatorsRead else { return }
            self.creatorsTask = nil
            // A read the connection dropped under says nothing about the server: what is known
            // stays, and the next sync asks again.
            guard serial == self.connectionSerial, self.control.state == .connected else {
                self.capabilities.creatorReadLost()
                return
            }
            self.capabilities.creatorsLoaded(r, serial: serial)
            // The panes' ports are read once the server is known to list them.
            self.refreshPortRows()
            self.fillAllPorts()
        }
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

    func apply(view: SessionView) {
        guard !hiddenSessions().contains(view.sessionID) else { return }
        let old = views[view.sessionID]
        if let old, old.revision > view.revision { return }
        views[view.sessionID] = view
        createdBlocksShown(view, old: old)
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

    private func readProcess(_ sid: String, _ bid: String) async -> (name: String?, pid: Int?)? {
        guard let r = try? await control.blockCall("com.superlogical.terminal.process", session: sid, block: bid) else { return nil }
        let fg = r.obj("foreground")
        return (fg.map(ProcessNames.label), fg?.int("pid"))
    }

    /// One of a block's three reads.
    private struct MetaRead: Sendable {
        enum Part: Sendable { case statuses, title, process }
        var session: String
        var block: String
        var part: Part
    }

    /// A block's answers as they come. Outer nil: the call failed, keep what we had. Inner nil:
    /// the server has none.
    private struct MetaAnswer {
        var statuses: BlockMeta?
        var title: String??
        var process: (name: String?, pid: Int?)?
        var left = 3
    }

    /// The answers of one `loadMeta`, by block, until each block has its three.
    @MainActor private final class MetaAnswers {
        var blocks: [String: MetaAnswer] = [:]
    }

    /// The views of one sync, as they are read.
    @MainActor private final class ViewReads {
        var views: [String: SessionView] = [:]
    }

    /// Reads status, title and process for the blocks, in their order, and replaces what we had
    /// for them: three calls for each block, each block applied when its three have answered.
    /// On Wi-Fi every call goes out in one turn; on cellular four are under way at a time
    /// (`syncCalls`). What a live event changed while the read was out is newer than the read's
    /// answer and is kept.
    func loadMeta(_ blocks: [(session: String, block: String)]) async {
        nextMetaRead += 1
        let read = nextMetaRead
        metaReads[read] = [:]
        defer { metaReads[read] = nil }
        guard gatesSync else {
            await withTaskGroup(of: (String, MetaAnswer).self) { g in
                for (sid, bid) in blocks {
                    g.addTask {
                        async let st = self.readStatuses(sid, bid)
                        async let ti = self.readTitle(sid, bid)
                        async let pr = self.readProcess(sid, bid)
                        return (bid, MetaAnswer(statuses: await st, title: await ti, process: await pr, left: 0))
                    }
                }
                for await (bid, answer) in g { applyMeta(bid, answer, read: read) }
            }
            return
        }
        let answers = MetaAnswers()
        let reads = blocks.flatMap { b in
            [MetaRead.Part.statuses, .title, .process].map { MetaRead(session: b.session, block: b.block, part: $0) }
        }
        let serial = connectionSerial
        await syncCalls.each(reads) { [weak self] r in
            guard let self else { return }
            var a = MetaAnswer()
            // A read whose turn comes after its connection is gone is not sent on the next one:
            // it counts as failed, and the reads of that connection's own sync don't wait behind it.
            if serial == self.connectionSerial, self.control.state == .connected {
                switch r.part {
                case .statuses: a.statuses = await self.readStatuses(r.session, r.block)
                case .title: a.title = await self.readTitle(r.session, r.block)
                case .process: a.process = await self.readProcess(r.session, r.block)
                }
            }
            // The block's other reads may have answered meanwhile: only this part is taken.
            var now = answers.blocks[r.block] ?? MetaAnswer()
            switch r.part {
            case .statuses: now.statuses = a.statuses
            case .title: now.title = a.title
            case .process: now.process = a.process
            }
            now.left -= 1
            answers.blocks[r.block] = now
            guard now.left == 0 else { return }
            answers.blocks[r.block] = nil
            self.applyMeta(r.block, now, read: read)
        }
    }

    private func applyMeta(_ bid: String, _ a: MetaAnswer, read: Int) {
        guard !touchedBlocks.contains(bid) else { return }
        let live = metaReads[read]?[bid] ?? []
        var cur = pendingMeta[bid] ?? meta[bid] ?? BlockMeta()
        if let statuses = a.statuses, !live.contains(.statuses) { cur.statuses = statuses.statuses }
        if let title = a.title, !live.contains(.title) { cur.title = title }
        if let fg = a.process, !live.contains(.foreground) {
            cur.foreground = fg.name
            cur.foregroundPID = fg.pid
        }
        pendingMeta[bid] = nil
        statusShownAt[bid] = Date()
        meta[bid] = cur
    }

    // MARK: Actions
    //
    // Each action asks the server, then re-reads the server's view of the session. Nothing guesses a
    // layout locally. A failure shows a short notice and the view is re-read, so the screen matches
    // the server either way.

    @discardableResult
    func act(_ what: String, session sid: String?, _ body: () async throws -> JSONObject) async -> JSONObject? {
        do {
            let r = try await body()
            if let sid { refreshView(sid) }
            return r
        } catch {
            Notice.shared.show(Messages.couldNot(what, error, computer: config.name))
            if let sid { refreshView(sid) }
            return nil
        }
    }

    /// Why a call failed, in words (`Messages.reason`): never the server's own text.
    func reason(_ error: Error) -> String { Messages.reason(error, computer: config.name) }

    @discardableResult
    func createSession(label: String?) async -> String? {
        wanted?()
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

    /// True when the server closed it.
    @discardableResult
    func closeWindow(_ sid: String, _ wid: String) async -> Bool {
        await act("close the tab", session: sid) { try await self.control.call("session.close_window", ["session_id": sid, "window_id": wid]) } != nil
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

    /// Reads a pane's whole output for a share (`OutputReader`): before each request it waits
    /// while any pane on this server has typed input on its way, and it stops on a new
    /// `connectionSerial`. `source` stands in for this connection in tests.
    func formatChunks(_ sid: String, _ bid: String, form: OutputForm, reader: OutputReader,
                      from source: OutputSource? = nil) async throws(OutputReadFailure) {
        try await reader.read(form, session: sid, block: bid, from: source ?? self)
    }

    func clear(_ sid: String, _ bid: String) async {
        await act("clear the pane", session: nil) {
            try await self.control.blockCall("com.superlogical.terminal.clear", session: sid, block: bid)
        }
    }

    /// Runs a configuration-file action with no pane (`client.action` without `session_id`),
    /// picked from the palette with no tab on screen. Without a connection it fails at once and
    /// is never sent later. Returns the client actions the server asks this client to perform.
    func runAction(name: String, args: JSONObject?) async throws -> [JSONObject] {
        guard control.state == .connected else { throw RexError.unsent("not connected") }
        var p: JSONObject = ["action": name, "origin": TerminalStream.ActionOrigin.palette.rawValue]
        if let args, !args.isEmpty { p["args"] = args }
        return try await control.call("client.action", p).arr("client_actions")
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

extension ServerConnection: OutputSource {
    func outputCall(_ method: String, session: String, block: String, args: JSONObject) async throws -> JSONObject {
        try await control.blockCall(method, session: session, block: block, args: args)
    }

    var outputConnected: Bool { control.state == .connected }

    func inputIdle() async { await control.inputActivity.idle() }
}
