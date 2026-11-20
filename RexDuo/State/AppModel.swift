import CryptoKit
import GlanceModel
import SwiftUI
import RexKit

struct Selection: Hashable, Codable {
    var serverID: UUID
    var sessionID: String
    var windowID: String
}

/// A short, unobtrusive notice (e.g. an action the server refused). One at a time; fades on its own.
/// A notice can carry one button (Retry), and a running job's notice shows its progress with
/// Cancel.
///
/// Two places feed it:
/// - **The slot**: plain notices (`show`), and a transfer's progress (`showProgress`). A plain
///   notice shows its full time: progress that comes meanwhile waits and shows when it hides.
/// - **The job lane**: one long job at a time (a share of a pane's whole output). Its progress
///   shows whenever the slot is empty, so a plain notice over it shows its full time and the job's
///   progress and Cancel come back after. A second job waits until the first ends.
@MainActor
@Observable
final class Notice {
    static let shared = Notice()
    /// An error (an action the server refused) or plain news.
    enum Style { case error, neutral }

    struct Action {
        var title: String
        var run: @MainActor () -> Void
    }

    /// A job in the lane (`beginJob`).
    struct JobID: Hashable {
        fileprivate let raw: Int
    }

    private(set) var message: String?
    private(set) var style = Style.error
    /// 0...1 while a job runs; nil for a plain notice.
    private(set) var progress: Double?
    /// The notice's button: its title is observed, the action is not.
    private(set) var actionTitle: String?
    @ObservationIgnored private var action: Action?
    @ObservationIgnored private var hide: Task<Void, Never>?
    /// How long a plain notice shows, without and with a button. Tests shorten them.
    @ObservationIgnored var plainSeconds = 3.5
    @ObservationIgnored var actionSeconds = 6.0

    /// What the slot holds.
    private enum Slot {
        case empty
        case plain(String, Style, Action?)
        case progress(String, Double, Action)
    }
    @ObservationIgnored private var slot = Slot.empty
    /// Progress that came while a plain notice was up; it shows when that notice hides.
    @ObservationIgnored private var heldProgress: (text: String, fraction: Double, cancel: Action)?

    private struct Job {
        var id: JobID
        var text: String
        var fraction: Double
        var cancel: Action
        /// A job shows from its first `progress`, so one that ends at once never shows.
        var shown: Bool
    }
    @ObservationIgnored private var job: Job?
    @ObservationIgnored private var nextJob = 0
    /// Jobs waiting for the lane, oldest first.
    @ObservationIgnored private var laneWaiters: [(id: Int, resume: CheckedContinuation<Bool, Never>)] = []

    func show(_ text: String, style: Style = .error, action: Action? = nil) {
        slot = .plain(text, style, action)
        heldProgress = nil
        hide?.cancel()
        // Long enough to reach a button.
        let wait = action == nil ? plainSeconds : actionSeconds
        hide = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            self?.plainHid()
        }
        render()
    }

    /// A transfer's progress: `text` with its progress and a Cancel button. It stays until the next
    /// `show` or `dismiss`. A plain notice that is up stays up: this shows when it hides.
    func showProgress(_ text: String, fraction: Double, cancel: @escaping @MainActor () -> Void) {
        let a = Action(title: "Cancel", run: cancel)
        if case .plain = slot {
            heldProgress = (text, fraction, a)
            return
        }
        hide?.cancel()
        slot = .progress(text, fraction, a)
        render()
    }

    /// Puts the slot away. A job in the lane shows again.
    func dismiss() {
        hide?.cancel()
        slot = .empty
        heldProgress = nil
        render()
    }

    /// Puts the notice away and runs its button's action. A job's Cancel leaves its progress up
    /// until the job ends.
    func runAction() {
        if case .empty = slot {
            job?.cancel.run()
            return
        }
        let a = action
        dismiss()
        a?.run()
    }

    private func plainHid() {
        hide = nil
        if let p = heldProgress {
            heldProgress = nil
            slot = .progress(p.text, p.fraction, p.cancel)
        } else {
            slot = .empty
        }
        render()
    }

    // MARK: Job lane

    /// Takes the lane for a job, waiting while another job holds it. Nil when the waiting task is
    /// cancelled first. The job shows from its first `progress`, with `text` and Cancel.
    func beginJob(text: String, cancel: @escaping @MainActor () -> Void) async -> JobID? {
        nextJob += 1
        let raw = nextJob
        if job != nil {
            let got = await withTaskCancellationHandler {
                await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
                    if Task.isCancelled { c.resume(returning: false) } else { laneWaiters.append((raw, c)) }
                }
            } onCancel: {
                Task { @MainActor [weak self] in self?.dropWaiter(raw) }
            }
            guard got, !Task.isCancelled else {
                if got { passLane() }
                return nil
            }
        }
        let id = JobID(raw: raw)
        job = Job(id: id, text: text, fraction: 0, cancel: Action(title: "Cancel", run: cancel), shown: false)
        return id
    }

    /// The job's progress, 0...1, and optionally new text. It shows when the slot is empty.
    func progress(_ id: JobID, fraction: Double, text: String? = nil) {
        guard var j = job, j.id == id else { return }
        j.fraction = fraction
        if let text { j.text = text }
        j.shown = true
        job = j
        if case .empty = slot { render() }
    }

    /// The job is over: its progress goes, and the next job waiting gets the lane.
    func endJob(_ id: JobID) {
        guard job?.id == id else { return }
        job = nil
        render()
        passLane()
    }

    /// True while a job holds the lane.
    var jobRunning: Bool { job != nil }

    private func passLane() {
        guard job == nil, !laneWaiters.isEmpty else { return }
        laneWaiters.removeFirst().resume.resume(returning: true)
    }

    private func dropWaiter(_ raw: Int) {
        guard let i = laneWaiters.firstIndex(where: { $0.id == raw }) else { return }
        laneWaiters.remove(at: i).resume.resume(returning: false)
    }

    // MARK: What shows

    private func render() {
        var next: (String, Style, Double?, Action?)?
        switch slot {
        case .plain(let text, let style, let a): next = (text, style, nil, a)
        case .progress(let text, let f, let a): next = (text, .neutral, f, a)
        case .empty:
            if let j = job, j.shown { next = (j.text, .neutral, j.fraction, j.cancel) }
        }
        guard let next else {
            if message != nil { message = nil }
            if progress != nil { progress = nil }
            action = nil
            if actionTitle != nil { actionTitle = nil }
            return
        }
        if style != next.1 { style = next.1 }
        if message != next.0 { message = next.0 }
        if progress != next.2 { progress = next.2 }
        action = next.3
        if actionTitle != next.3?.title { actionTitle = next.3?.title }
    }
}

/// App-wide actions triggered by keyboard shortcuts, gestures and menus.
/// Senders call `AppModel.perform(_:)`; the visible WindowScreen/RootView executes them.
enum RexCommand: Equatable {
    case newTab, newSession, splitRight, splitDown, closePane, closeTab, renameTab
    case nextTab, previousTab, goToTab(Int), nextPane, previousPane
    case toggleZoom, clear, toggleSidebar, toggleAgents, tabOverview, jumpToWaiting
    case fontBigger, fontSmaller, fontReset, settings
    /// Find in the active pane's history (`client.find.*`).
    case find(FindStep)
    /// The pane commands of Arrange (`pane.balance`, `pane.close_others`, `pane.move_to_*`).
    case balanceSplits, closeOtherPanes, moveToTab, moveToNewTab
    /// Moves the tab one place forward (+1) or back (-1) in its session (`client.tab.move.*`).
    case moveTab(Int)
}

/// What a find key asks for.
enum FindStep: Equatable {
    /// Open find (or, while its field edits, select the field's text).
    case open
    /// The next match, toward older output. With find closed it does nothing.
    case next
    /// The previous match, toward newer output.
    case previous
}

struct CommandRequest: Equatable {
    let id = UUID()
    let command: RexCommand
}

/// A request to put a tab on screen (a tapped push or toast). RootView shows it.
struct OpenRequest: Equatable {
    let id = UUID()
    let selection: Selection
}

@MainActor
@Observable
final class AppModel {
    /// Latest requested command; observe with `.onChange(of: model.lastCommand)`.
    var lastCommand: CommandRequest?
    func perform(_ command: RexCommand) { lastCommand = CommandRequest(command: command) }

    var servers: [ServerConnection] = []
    /// The tab on screen. Remembered, so the next launch opens it again; not in a test launch
    /// (`-autoOpen`), whose throwaway session must not replace the tab the owner had open.
    var selection: Selection? {
        didSet {
            guard let selection, selection != oldValue, !Self.isTestLaunch else { return }
            prefs.lastSelection = selection
        }
    }
    private static let isTestLaunch = UserDefaults.standard.string(forKey: "autoOpen") != nil
    /// The pane shown when only one pane fits (compact width), per window.
    var focusedPane: [String: String] = [:]
    var showSettings = false
    /// The agent board covers the tab (`TentBoard`). Toasts stay away meanwhile.
    var boardShown = false
    /// The "Pair via QR Code" scanner, opened from the screen shown when there are no servers.
    var showPairing = false
    @ObservationIgnored private var landing: Task<Void, Never>?
    /// A computer picked from the sidebar's known hosts: the scanner opens straight at its check.
    var pairingStart: PairingStart?

    struct PairingStart: Equatable {
        var candidate: PairingCode.Candidate
        var name: String
    }

    /// Opens the pairing flow at an address, as if its code had been scanned: the check, the
    /// identity card, Add & Open. `name` is the card's starting name (the host's label); without one
    /// it comes from the address. Does nothing for an address that isn't an https server address.
    /// `guessed`: the address was worked out (`PairingCode.candidate`), so a failed check says to
    /// pair with a code and never offers to add it.
    func startPairing(prefilled address: URL, name: String? = nil, guessed: Bool = false) {
        guard let url = PairingCode.address(from: address.absoluteString) else { return }
        pairingStart = PairingStart(candidate: PairingCode.Candidate(url: url, guessed: guessed),
                                    name: name ?? ServerConfig.name(for: url))
        showPairing = true
    }
    /// The page Settings opens at next; Settings clears it.
    var settingsStart: SettingsPage?
    @ObservationIgnored let prefs: Prefs
    @ObservationIgnored let notifier = AgentNotifier()
    /// Clears delivered notifications about agents that no longer wait. Tests put a stand-in's.
    @ObservationIgnored var tidy = NotificationTidier() {
        didSet { connectTidy() }
    }
    /// Push registration with each server's Beacon.
    @ObservationIgnored let push: PushRegistrar
    /// Installing Beacon on a server from here.
    @ObservationIgnored let helperSetup: HelperSetupCenter
    /// Latest request to show a tab; RootView observes it.
    var openRequest: OpenRequest?

    /// The phone's network. Nil in tests and the test host.
    @ObservationIgnored let network: NetworkWatch?
    /// Writes the snapshot the widgets read. It does nothing in tests, the test host and test
    /// launches (`GlanceWriter.Mode`).
    @ObservationIgnored let glance: GlanceWriter
    /// Sends each written snapshot on to the watch. It only sends, and knows nothing of this model.
    @ObservationIgnored let bridge: GlanceBridge

    /// `connect: false` builds no servers (unit tests and the test host). With `connect`, the
    /// servers are built here and none is started: `sceneVisible()` starts them. `glance`: the
    /// snapshot's writer; without one, a writer that is on only in the app's own launches.
    init(prefs: Prefs, connect: Bool = true, glance: GlanceWriter? = nil) {
        self.prefs = prefs
        let mode = connect ? GlanceWriter.Mode.current() : .off
        // The App Group's container is looked up at the writer's first read or write, off the
        // main thread, not here on the launch path.
        // The session with the watch is made at the first written snapshot, not here.
        let bridge = GlanceBridge { WCSessionLink() }
        self.bridge = bridge
        var parts = GlanceWriter.Parts(reload: GlanceReload.all, wrote: bridge.wrote)
        #if DEBUG
        parts.wroteDemo = bridge.wroteDemo
        #endif
        self.glance = glance ?? GlanceWriter(mode: mode, parts: parts) { GlanceStore.shared() }
        // One fetcher for the release list: the installs use it, and so does the one check that
        // tells every computer's row which Beacon version is the latest.
        let fetcher = HelperReleaseFetcher.standard()
        push = PushRegistrar(prefs: prefs, deviceID: PushIdentity.deviceID(vendorID: UIDevice.current.identifierForVendor),
                             release: ReleaseCheck(fetcher: fetcher))
        helperSetup = HelperSetupCenter(push: push, prefs: prefs, fetcher: fetcher)
        network = connect ? NetworkWatch() : nil
        push.servers = { [weak self] in self?.servers ?? [] }
        push.setup = helperSetup
        // An install's sheet takes the screen once Settings has closed.
        push.presentSetup = { [weak self] id, kind in
            self?.helperSetup.request(id, kind: kind)
            self?.showSettings = false
        }
        push.showSetup = { [weak self] id, details in
            self?.helperSetup.show(id, details: details)
            self?.showSettings = false
        }
        helperSetup.servers = { [weak self] in self?.servers ?? [] }
        helperSetup.sheetIsUp = { [weak self] in self?.showSettings == true || self?.showPairing == true }
        helperSetup.shownSession = { [weak self] server in
            guard let self else { return nil }
            if let sel = self.selection, sel.serverID == server.id { return sel.sessionID }
            return server.sessions.first?.id
        }
        network?.onChange = { [weak self] _ in self?.networkChanged() }
        connectTidy()
        self.glance.source = { [weak self] in
            guard let self else { return [] }
            var only: String?
            if case .live(let label) = self.glance.mode { only = label }
            return GlanceSource.machines(self.servers, since: self.firstSeenWaiting(), only: only)
        }
        self.glance.palette = { [weak self] in self.map { GlanceSource.palette($0.prefs) } ?? .standard }
        self.glance.anyLive = { [weak self] in self?.servers.contains { GlanceSource.link($0) == .live } ?? false }
        if connect { rebuildServers() }
        #if DEBUG
        // `-settings <page>` (testing): open Settings at launch, at that page.
        if connect, SettingsPage.debugLaunch != nil { showSettings = true }
        #endif
    }

    /// Pull to refresh: re-bootstrap every server (reconnect the ones that are down).
    func refresh() async {
        await withTaskGroup(of: Void.self) { g in
            for s in servers { g.addTask { await s.refresh() } }
        }
    }

    func rebuildServers() {
        #if DEBUG
        // `-boardDemo` shows made-up agents: no server is used, so no real pane is opened.
        let configs = BoardDemo.scenario != nil ? [] : Self.debugServers ?? prefs.servers
        #else
        let configs = prefs.servers
        #endif
        let old = Dictionary(uniqueKeysWithValues: servers.map { ($0.config.id, $0) })
        // A server that is gone from the list: its helper's secret must stop working.
        for id in old.keys where !configs.contains(where: { $0.id == id }) { push.serverRemoved(id) }
        servers = configs.map { cfg in
            if let s = old[cfg.id], s.config == cfg { return s }
            old[cfg.id]?.stop()
            let s = ServerConnection(config: cfg, prefs: prefs, notifier: notifier, push: push, network: network,
                                     deviceID: push.deviceID)
            helperSetup.attach(s)
            s.agentsKnown = { [weak self] in self?.tidy.request() }
            return s
        }
        #if DEBUG
        if let kind = Self.simulatedProblem {
            // `-simulateRetrying YES`: hold the Try Again button in its "Trying…" state.
            let trying = UserDefaults.standard.bool(forKey: "simulateRetrying")
            for s in servers {
                s.simulate(kind)
                if trying { s.retrying = true }
            }
            return
        }
        #endif
        // Before the first scene shows, nothing connects (`sceneVisible`).
        guard mayConnect else { return }
        for s in servers { startServer(s) }
    }

    // MARK: Connecting only once a scene shows

    /// True from the first scene phase that shows the app. Until then no server is started.
    @ObservationIgnored private(set) var mayConnect = false
    /// Starts a server's connection. Tests record the calls instead.
    @ObservationIgnored var startServer: @MainActor (ServerConnection) -> Void = { $0.start() }

    /// The app's scene is on its way to the screen (its first `.inactive` or `.active` phase):
    /// start every server, once. A launch iOS makes in the background, to prewarm the app or
    /// later to hand it a message, has no scene and so never gets here: it opens no connection
    /// to any server, which would otherwise tell each Beacon that the phone is in use.
    func sceneVisible() {
        guard !mayConnect else { return }
        mayConnect = true
        #if DEBUG
        // To check on a simulator when the servers were started: `eventMessage CONTAINS "SCENE_VISIBLE"`.
        NSLog("SCENE_VISIBLE servers=%d", servers.count)
        #endif
        for s in servers { startServer(s) }
        #if DEBUG
        // `-glanceDemo <scenario>`: a made-up snapshot for the widgets, written once.
        Task { await glance.writeDemo() }
        #endif
    }

    func openSettings(at page: SettingsPage) {
        settingsStart = page
        showSettings = true
    }

    // MARK: Adding a server

    /// Saves a server, unless one at the same address is already saved. True when it was saved.
    @discardableResult
    func addServer(_ config: ServerConfig) -> Bool {
        if let url = ServerConfig.url(from: config.url), PairingCode.existing(url, in: prefs.servers) != nil { return false }
        prefs.servers.append(config)
        rebuildServers()
        return true
    }

    /// Checks a scanned address before it is saved. First a plain request that only that address
    /// can answer (`ServerProbe`), then one short control connection that reads who the computer is
    /// (`ServerPreview`). That connection attaches to nothing and carries no device id in its label,
    /// so the server drops it on close and the helper doesn't take it for this iPhone being open.
    func check(_ url: URL) async -> PairingCheck {
        #if DEBUG
        if let kind = Self.simulatedProblem { return .problem(ConnectionProblem(kind: kind, detail: "simulated")) }
        if let fake = Self.simulatedIdentity { return .reachable(fake) }
        #endif
        if let failure = await ServerProbe.check(address: url.absoluteString) {
            return .problem(ConnectionProblem.classify(failure, network: network?.snapshot ?? .unknown))
        }
        let client = ClientInfo(
            name: Brand.appName,
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
            label: PushIdentity.previewLabel(deviceName: UIDevice.current.name))
        return .reachable(await ServerPreview.fetch(address: url.absoluteString, client: client))
    }

    #if DEBUG
    /// `-simulateIdentity 'os=linux,account=sam,owner=sam@x.com,viewer=me@x.com,sessions=api|web,count=5,helper=no'`
    /// (testing): a scanned code gets this identity card, with no network.
    static var simulatedIdentity: ServerIdentity? {
        guard let raw = UserDefaults.standard.string(forKey: "simulateIdentity") else { return nil }
        var f: [String: String] = [:]
        for part in raw.split(separator: ",") {
            let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { f[kv[0]] = kv[1] }
        }
        let sessions = f["sessions"]?.split(separator: "|").map(String.init) ?? []
        return ServerIdentity(platform: ServerIdentity.Platform(rawValue: f["os"] ?? "") ?? .other, account: f["account"],
                              owner: f["owner"], viewer: f["viewer"], sessionCount: f["count"].flatMap(Int.init) ?? sessions.count,
                              sessions: sessions, hasHelper: f["helper"] != "no")
    }
    #endif

    /// A server was just added: land on its active tab once it has connected and its sessions
    /// are in. One landing at a time; a new one replaces it.
    func land(on config: ServerConfig) {
        landing?.cancel()
        landing = Task { [weak self] in await self?.openWhenReady(config) }
    }

    /// Waits for `config`'s server to be online with a tab to show, then shows it. Ends without
    /// showing anything after `timeout`, when its task is cancelled, or as soon as the person has
    /// opened something themselves. True when it showed the tab.
    @discardableResult
    func openWhenReady(_ config: ServerConfig, timeout: Double = 15, poll: Double = 0.2) async -> Bool {
        let before = selection
        let end = Date().addingTimeInterval(timeout)
        while Date() < end, selection == before, !Task.isCancelled {
            if let s = server(config.id), s.phase == .online, show(config) { return true }
            try? await Task.sleep(nanoseconds: UInt64(poll * 1_000_000_000))
        }
        return false
    }

    /// Shows a server's active tab: a saved server that was scanned again, or one just added. A
    /// server that is down is tried now instead. True when a tab was shown.
    @discardableResult
    func show(_ config: ServerConfig) -> Bool {
        guard let s = server(config.id) else { return false }
        guard s.phase == .online else { s.reconnect(); return false }
        for e in s.sessions {
            if let w = s.views[e.id]?.activeWindow {
                openRequest = OpenRequest(selection: Selection(serverID: s.id, sessionID: e.id, windowID: w.id))
                return true
            }
        }
        return false
    }

    /// A new network path is when a down server can come back: retry those now.
    private func networkChanged() {
        for s in servers { s.networkChanged() }
        push.networkChanged()
    }

    #if DEBUG
    /// `-servers 'Name=https://…,Other=https://…'` (testing): use these servers for this run only,
    /// instead of the saved ones.
    static var debugServers: [ServerConfig]? {
        guard let raw = UserDefaults.standard.string(forKey: "servers"), !raw.isEmpty else { return nil }
        return raw.split(separator: ",").compactMap { part in
            let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { return nil }
            return ServerConfig(id: stableID("debug:" + kv[0]), name: kv[0], url: kv[1])
        }
    }

    /// `-simulateOffline <kind>` (testing): every server shows that problem and none connects.
    static var simulatedProblem: ConnectionProblem.Kind? {
        UserDefaults.standard.string(forKey: "simulateOffline").flatMap(ConnectionProblem.Kind.init(rawValue:))
    }
    #endif

    /// The same id for the same host label on every launch: the first 16 bytes of its SHA-256.
    static func stableID(_ label: String) -> UUID {
        let b = Array(SHA256.hash(data: Data(("host:" + label).utf8)))
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                           b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    func server(_ id: UUID?) -> ServerConnection? { servers.first { $0.id == id } }

    /// The block of every agent waiting for the user, on every server. Reads only `agentKeys`, so a
    /// view that shows it re-renders when an agent starts or stops waiting, not on other metadata.
    var waitingAgentIDs: Set<String> {
        Set(servers.flatMap { $0.agentKeys.filter { $0.state == "blocked" }.map(\.blockID) })
    }

    var current: (server: ServerConnection, view: SessionView, window: WindowInfo)? {
        guard let sel = selection, let s = server(sel.serverID), let v = s.views[sel.sessionID],
              let w = v.window(sel.windowID) else { return nil }
        return (s, v, w)
    }

    func select(_ server: ServerConnection, session: String, window: String, block: String? = nil) {
        selection = Selection(serverID: server.id, sessionID: session, windowID: window)
        if let block { focusedPane[window] = block }
        Task { await server.focusWindow(session, window) }
    }

    /// Back in the foreground: reconnect where needed and resync every server with its real state.
    func foregroundResumed() {
        let fromBackground = inBackground
        inBackground = false
        for s in servers { s.resume(fromBackground: fromBackground) }
        push.becameActive()
        glance.becameActive()
        tidy.becameActive()
    }

    /// What the tidier reads of the servers: where each is, and which of its agents wait, once
    /// every agent's state has been read on a live connection.
    private func connectTidy() {
        tidy.servers = { [weak self] in
            (self?.servers ?? []).map { s in
                let known = s.agentsCurrent && s.control.state == .connected
                return NotificationTidy.Server(url: s.config.url, hostName: s.hostName,
                                               waiting: known ? Set(s.agentKeys.filter { $0.state == "blocked" }.map(\.blockID)) : nil)
            }
        }
    }

    /// Set from the background until the app is active again, so a return from Control Center or
    /// the app switcher's peek isn't taken for a wake.
    @ObservationIgnored private var inBackground = false

    /// The app went to the background: a connection that drops from now on is waking up when the
    /// app returns, not a problem (`ForegroundWake`).
    func enteredBackground() {
        inBackground = true
        tidy.enteredBackground()
        for s in servers { s.enteredBackground() }
        // The widgets get what is known now. iOS suspends the app right after, so the write
        // runs inside a background task, and through the same writer as every other write.
        // With the writer off there is nothing to write and no task is taken.
        let task = glance.mode == .off ? nil : BackgroundTask(name: "glance_snapshot") {}
        Task {
            await glance.flush()
            task?.end()
        }
    }

    // MARK: Opening a pane from a push or toast

    /// Opens the pane a push points at. After a cold launch the server may still be connecting, so
    /// this waits up to `timeout` for the session to load. False if it never did.
    @discardableResult
    func open(_ route: PushRoute, timeout: Double = 30) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while true {
            if let s = servers.first(where: { route.matches(serverURL: $0.config.url, hostName: $0.hostName) }),
               openPane(s, session: route.sessionID, window: route.windowID, block: route.blockID) {
                return true
            }
            guard Date() < end else { return false }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    /// Puts a pane on screen: its tab, with the pane shown when only one fits. With no window given,
    /// the tab holding the block. False while the session or tab isn't loaded.
    @discardableResult
    func openPane(_ s: ServerConnection, session sid: String, window wid: String?, block bid: String?) -> Bool {
        guard let v = s.views[sid] else { return false }
        let w = v.window(wid) ?? bid.flatMap { v.windowContaining(block: $0) } ?? (wid == nil && bid == nil ? v.activeWindow : nil)
        guard let w else { return false }
        if let bid, w.allBlocks.contains(where: { $0.id == bid }) {
            focusedPane[w.id] = bid
            Task { await s.focus(sid, block: bid) }
        }
        openRequest = OpenRequest(selection: Selection(serverID: s.id, sessionID: sid, windowID: w.id))
        return true
    }

    // MARK: Links (controls)

    /// A `rexduo:` link from a control or a widget: `DeepLink` lists them, and `PaneLink` is the
    /// one that names a pane. Links only navigate, and a URL of another scheme does nothing. A
    /// link that arrives before the app's first screen is up waits for `releaseLinks()`, as a
    /// tapped push waits in `AppDelegate`.
    func openLink(_ url: URL) {
        let link: Link
        if let pane = PaneLink(url) {
            link = .pane(pane)
        } else if let plain = DeepLink(url) {
            link = .plain(plain)
        } else {
            return
        }
        #if DEBUG
        // To check on a simulator that a link reached the app: `eventMessage CONTAINS "OPEN_LINK"`.
        NSLog("OPEN_LINK %@ %@", link.name, linksReleased ? "run" : "queued")
        #endif
        guard linksReleased else {
            // `open` asks for nothing, so it never replaces a link that is waiting.
            if link != .plain(.open) { pendingLink = link }
            return
        }
        run(link)
    }

    /// A link the app takes.
    enum Link: Equatable {
        case plain(DeepLink)
        case pane(PaneLink)

        var name: String {
            switch self {
            case .plain(let l): l.rawValue
            case .pane: PaneLink.host
            }
        }
    }

    /// The app's first screen is up (`AppDelegate.attach`): run the link that waited, if any.
    func releaseLinks() {
        linksReleased = true
        guard let link = pendingLink else { return }
        pendingLink = nil
        run(link)
    }

    private func run(_ link: Link) {
        switch link {
        case .plain(.open):
            // The app is in front, which is all it asks. The tab, a sheet and the agent board stay.
            break
        case .plain(.pair):
            // Only onto the bare app: a sheet or a cover that is up stays, and the link is dropped.
            guard !showSettings, !showPairing, helperSetup.active == nil else { return }
            pairingStart = nil
            showPairing = true
        case .pane(let pane):
            // One link at a time; a new one replaces it.
            jump?.cancel()
            jump = Task { [weak self] in
                guard let self else { return }
                let step = await self.openPane(link: pane)
                #if DEBUG
                NSLog("OPEN_PANE %@", String(describing: step))
                #else
                _ = step
                #endif
            }
        case .plain(.waiting):
            // One jump at a time; a new one replaces it.
            jump?.cancel()
            jump = Task { [weak self] in
                guard let self else { return }
                let step = await self.openWaiting()
                #if DEBUG
                NSLog("OPEN_WAITING %@", String(describing: step))
                #else
                _ = step
                #endif
            }
        }
    }

    @ObservationIgnored private var linksReleased = false
    @ObservationIgnored private var pendingLink: Link?
    @ObservationIgnored private var jump: Task<Void, Never>?
    /// The tab `autoSelect()` last put on screen, and how many times it has put one there. A
    /// wait that gives up when the person opens something tells the two apart by them: only a
    /// landing made after the link arrived excuses a changed tab. An older one doesn't, or a tap
    /// on that same tab during the wait would pass for the launch's own move.
    @ObservationIgnored private(set) var autoSelected: Selection? {
        didSet { autoSelects += 1 }
    }
    @ObservationIgnored private var autoSelects = 0
    /// When the phone first saw each waiting agent, by block. Tests pass their own.
    @ObservationIgnored var firstSeenWaiting: @MainActor () -> [String: Date] = { PhoneState.shared.waitingSince }

    /// Opens the agent that has waited longest, on any server, as a tapped push for it would: its
    /// pane is focused on the server and its tab is requested, which puts sheets and the agent
    /// board away. After a cold launch the servers are still syncing, so this waits for them;
    /// `OpenWaiting` holds the rules. With nobody waiting, no servers, or the wait run out, it
    /// does nothing at all: no notice and no haptic, unlike the pill and the shortcut.
    /// Returns the step that ended the wait.
    @discardableResult
    func openWaiting(clock: OpenWaiting.Clock = .system, poll: TimeInterval = 0.1) async -> OpenWaiting.Step {
        var wait = OpenWaiting(began: clock.now(), arrived: Date(), before: selection)
        let landings = autoSelects
        while true {
            let since = firstSeenWaiting()
            // `agentKeys` is exact when a server turns current (`agentsWereRead`) and follows
            // the states a turn behind after that, as it does for the waiting pill.
            let waiting = servers.map { s in
                s.agentsCurrent ? s.agentKeys.filter { $0.state == "blocked" && Self.mayJump(to: $0, on: s) } : []
            }
            let states = servers.indices.map { i in
                OpenWaiting.Server(known: servers[i].agentsCurrent, problem: servers[i].phase.problem != nil,
                                   waiting: waiting[i].map { OpenWaiting.Waiter(block: $0.blockID, since: since[$0.blockID]) })
            }
            let step = wait.step(servers: states, now: clock.now(), selection: selection,
                                 autoSelected: autoSelects > landings ? autoSelected : nil)
            switch step {
            case .wait:
                await clock.sleep(poll)
                if Task.isCancelled { return .nothing(.replaced) }
            case .open(let target):
                // No suspension since the lists were read, so the target is still in them.
                guard let key = waiting[target.server].first(where: { $0.blockID == target.block }) else {
                    return .nothing(.noneWaiting)
                }
                openRequest = OpenRequest(selection: Waiting.prepare(self, Waiting.Item(server: servers[target.server], key: key)))
                return step
            case .nothing:
                return step
            }
        }
    }

    /// In a test launch (`-autoOpen <label>`) a link jumps only to agents in the session with that
    /// label, so a test never opens, focuses or resizes a pane in anyone's real session.
    private static func mayJump(to key: AgentKey, on server: ServerConnection) -> Bool {
        mayOpen(session: key.sessionID, on: server)
    }

    private static func mayOpen(session: String, on server: ServerConnection) -> Bool {
        guard let label = UserDefaults.standard.string(forKey: "autoOpen") else { return true }
        return server.sessions.contains { $0.id == session && $0.label == label }
    }

    /// Opens the pane a widget's row names, as a tapped push for it would: its pane is focused
    /// on the server and its tab is requested, which puts sheets and the agent board away.
    /// `OpenPaneLink` holds the rules: the server must be one of the app's, by id, and the pane
    /// one the app has loaded or one the snapshot lists as waiting, for which this waits until
    /// its session has loaded. Anything else does nothing. Returns the step that ended it.
    @discardableResult
    func openPane(link: PaneLink, clock: OpenWaiting.Clock = .system, poll: TimeInterval = 0.1) async -> OpenPaneLink.Step {
        let wait = OpenPaneLink(began: clock.now(), before: selection)
        let landings = autoSelects
        // Read once: what the widget showed when it was tapped.
        let listed = await glance.current()?.machines.first { $0.id == link.server }?.waiting
            .contains { $0.block == link.block && $0.session == link.session } ?? false
        while true {
            let server = servers.first { $0.id.uuidString == link.server }
            let view = server?.views[link.session]
            let loaded = server.map { s in
                Self.mayOpen(session: link.session, on: s) && view?.windowContaining(block: link.block) != nil
            } ?? false
            let step = wait.step(OpenPaneLink.World(serverKnown: server != nil, loaded: loaded, inSnapshot: listed),
                                 now: clock.now(), selection: selection, autoSelected: autoSelects > landings ? autoSelected : nil)
            switch step {
            case .wait:
                await clock.sleep(poll)
                if Task.isCancelled { return .nothing(.replaced) }
            case .open:
                // The tab that holds the pane now, whatever tab the link named.
                guard let server, openPane(server, session: link.session, window: nil, block: link.block) else {
                    return .nothing(.unknownPane)
                }
                return step
            case .nothing:
                return step
            }
        }
    }

    /// `-autoOpen <session label>` launch argument (testing): open that session's first tab.
    func autoOpenTarget() -> Selection? {
        guard let label = UserDefaults.standard.string(forKey: "autoOpen") else { return nil }
        for s in servers {
            for e in s.sessions where e.label == label {
                if let w = s.views[e.id]?.windows.first {
                    return Selection(serverID: s.id, sessionID: e.id, windowID: w.id)
                }
            }
        }
        return nil
    }

    /// Picks something to show on launch.
    func autoSelect() {
        if let t = autoOpenTarget() {
            autoSelected = t
            if selection != t { selection = t }
            return
        }
        guard UserDefaults.standard.string(forKey: "autoOpen") == nil else { return }
        guard selection == nil else { return }
        // The tab open when the app last ran, while it still exists.
        if let last = prefs.lastSelection, server(last.serverID)?.views[last.sessionID]?.window(last.windowID) != nil {
            autoSelected = last
            selection = last
            return
        }
        for s in servers {
            for e in s.sessions {
                if let v = s.views[e.id], let w = v.activeWindow {
                    let first = Selection(serverID: s.id, sessionID: e.id, windowID: w.id)
                    autoSelected = first
                    selection = first
                    return
                }
            }
        }
    }
}
