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
        /// Nil for a job that shows no progress (`tryBeginJob`).
        var fraction: Double?
        /// Nil for a job that can't be cancelled from here.
        var cancel: Action?
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
            job?.cancel?.run()
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

    /// Takes the lane for a short job with no progress and no button (an action running on the
    /// server), shown at once while the slot is empty. Nil, and nothing waits, while another job
    /// holds the lane: such a job is long, and this one says only that something runs.
    func tryBeginJob(text: String) -> JobID? {
        guard job == nil else { return nil }
        nextJob += 1
        let id = JobID(raw: nextJob)
        job = Job(id: id, text: text, fraction: nil, cancel: nil, shown: true)
        if case .empty = slot { render() }
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
    /// Minimizes the active pane's floating window, or every one the tab can spare
    /// (`pane.minimize_floating`, `pane.minimize_all_floating`).
    case minimizeFloat, minimizeAllFloats
    /// Moves the tab one place forward (+1) or back (-1) in its session (`client.tab.move.*`).
    case moveTab(Int)
    /// Opens the palette (`pane.go_to`, `session.switch`, `client.palette.toggle`).
    case goTo(GoToScope)
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

    var servers: [ServerConnection] = [] {
        didSet {
            for s in servers where s.viewsChanged == nil {
                s.viewsChanged = { [weak self] s, old in self?.viewsChanged(on: s, old: old) }
            }
        }
    }
    /// The tab on screen. Remembered, so the next launch opens it again; not in a test launch
    /// (`-autoOpen`), whose throwaway session must not replace the tab the owner had open.
    var selection: Selection? {
        didSet {
            guard let selection, selection != oldValue else { return }
            recentTabs = TabHistory.visiting(selection, recentTabs)
            guard !Self.isTestLaunch else { return }
            prefs.lastSelection = selection
            prefs.recentTabs = recentTabs
        }
    }
    /// The tabs viewed, newest first, for what to show when the one on screen closes. Saved
    /// across launches, except in a test launch, which starts empty and keeps only what it opened.
    @ObservationIgnored private(set) var recentTabs: [Selection] = []
    private static let isTestLaunch = UserDefaults.standard.string(forKey: "autoOpen") != nil
    /// The pane shown when only one pane fits (compact width), per window.
    var focusedPane: [String: String] = [:]
    var showSettings = false
    /// The Agents sheet is up (`AgentsSheet`): the sidebar's Agents list, for a layout without
    /// the sidebar. Open it with `showAgents()`.
    var agentsShown = false

    /// Shows every agent in a sheet: the same list, order and actions as the sidebar's Agents
    /// mode. For callers with no sidebar to show it in (tab mode's session menu, ⌘., the board's
    /// "+K more"); the sidebar keeps its own Agents mode. Does nothing while Settings or the
    /// scanner is up, which would hold the one sheet the root can show.
    func showAgents() {
        guard !showSettings, !showPairing else { return }
        agentsShown = true
    }

    /// The machine whose ports are up in a sheet (`PortsSheet`), for tab mode, where no sidebar
    /// header holds them. Open it with `showPorts(_:)`.
    var portsShown: UUID?

    /// Shows a machine's ports in a sheet: the list its sidebar header opens. Does nothing while
    /// another sheet or the scanner is up, which would hold the one sheet the root can show.
    func showPorts(_ id: UUID) {
        guard !showSettings, !showPairing, !agentsShown, server(id) != nil else { return }
        portsShown = id
    }

    /// The agent board covers the tab (`TentBoard`). Toasts stay away meanwhile.
    var boardShown = false
    /// The palette while it is open (Go to Anything, Change Session, the commands); nil closed.
    var goTo: GoToModel?
    /// Opens, runs and closes the palette, and keeps what outlives it: the runs a server's
    /// question may belong to, the questions waiting their turn, the keyboard hold.
    @ObservationIgnored private(set) lazy var palette = GoToCenter(model: self)
    /// The "Pair via QR Code" scanner, opened from the screen shown when there are no servers.
    var showPairing = false
    /// The setup guide while it covers the app (`OnboardingCover`), and where it starts: the
    /// welcome on a first run, the checklist from Setup Guide. Nil the rest of the time.
    var guide: OnboardingStart?

    /// Setup Guide (the empty state, Settings → About): the checklist, over the app.
    func openGuide() {
        showSettings = false
        guide = .checklist
    }

    /// Not Now, or a computer was added: the guide goes, and the first run is over for good.
    func closeGuide() {
        guide = nil
        if !prefs.onboardingDone { prefs.onboardingDone = true }
    }
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

    /// The same flow for an address typed in Settings → Add Computer, whose own pairing sheet
    /// presents it there (Settings is up, so the root's can't). Typed, so it may be http, and
    /// it is never `guessed`: a failed check keeps its offers. A blank name comes from the address.
    func preparePairing(typed url: URL, name: String) {
        let typed = name.trimmingCharacters(in: .whitespaces)
        pairingStart = PairingStart(candidate: PairingCode.Candidate(url: url, guessed: false),
                                    name: typed.isEmpty ? ServerConfig.name(for: url) : typed)
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
    /// What happened to the connections, kept across launches. Nil in tests and the test host.
    @ObservationIgnored let connectionLog: ConnectionLog?
    /// What the servers share when they reconnect: the budget of attempts for servers that are
    /// down, and the breaker that tries one server when several stop answering together.
    @ObservationIgnored let reconnect = ReconnectGovernor()
    /// Tells a real change of route from the path's other reports, once it has settled.
    @ObservationIgnored let route = RouteWatch()
    /// Writes the snapshot the widgets read. It does nothing in tests, the test host and test
    /// launches (`GlanceWriter.Mode`).
    @ObservationIgnored let glance: GlanceWriter
    /// Sends each written snapshot on to the watch. It only sends, and knows nothing of this model.
    @ObservationIgnored let bridge: GlanceBridge
    /// Answers an action from the watch: Enter or Interrupt for one waiting agent.
    @ObservationIgnored let actions = GlanceActions()
    /// Opens computers' dev servers on the phone, one browser at a time.
    @ObservationIgnored let forward = PortForward()
    /// What a row of each machine's ports list does: open, copy its link, show its pane, stop.
    @ObservationIgnored private(set) lazy var ports = PortActions(model: self)

    /// `connect: false` builds no servers (unit tests and the test host). With `connect`, the
    /// servers are built here and none is started: `sceneVisible()` starts them. `glance`: the
    /// snapshot's writer; without one, a writer that is on only in the app's own launches.
    /// `log`: the connection log (`ConnectionDiagnostics`); nil records nothing.
    init(prefs: Prefs, connect: Bool = true, glance: GlanceWriter? = nil, log: ConnectionLog? = nil) {
        self.prefs = prefs
        recentTabs = Self.isTestLaunch ? [] : prefs.recentTabs
        connectionLog = log
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
        network = connect ? NetworkWatch(log: log) : nil
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
        helperSetup.sheetIsUp = { [weak self] in
            self?.showSettings == true || self?.showPairing == true || self?.agentsShown == true
                || self?.portsShown != nil
        }
        helperSetup.shownSession = { [weak self] server in
            guard let self else { return nil }
            if let sel = self.selection, sel.serverID == server.id { return sel.sessionID }
            return server.sessions.first?.id
        }
        network?.onChange = { [weak self] _ in self?.networkChanged() }
        // The path the app started on: where route changes are counted from, and what gives
        // the connections their deadlines (Wi-Fi or cellular) before any change of path.
        network?.onStart = { [weak self] snap in
            self?.route.report(snap.facts)
            for s in self?.servers ?? [] { s.pathStarted() }
        }
        route.onChange = { [weak self] in
            for s in self?.servers ?? [] { s.routeChanged() }
        }
        reconnect.onBreaker = { [weak self] open in
            log?.record(.breaker(open: open))
            self?.checkTunnel()
            if open { self?.probeTunnel() }
        }
        connectTidy()
        self.glance.source = { [weak self] in
            guard let self else { return [] }
            var only: String?
            if case .live(let label) = self.glance.mode { only = label }
            return GlanceSource.machines(self.servers, since: self.firstSeenWaiting(), only: only)
        }
        self.glance.palette = { [weak self] in self.map { GlanceSource.palette($0.prefs) } ?? .standard }
        self.glance.anyLive = { [weak self] in self?.servers.contains { GlanceSource.link($0) == .live } ?? false }
        connectActions(mode)
        if connect { rebuildServers() }
        if connect, prefs.navigation == .sidebar {
            launchHold = Self.launchHasTab(last: prefs.lastSelection, servers: servers.map(\.id), autoOpen: Self.isTestLaunch)
        }
        // Read once, here: an existing user pays one saved flag at launch.
        if connect { guide = FirstRun.start(done: prefs.onboardingDone, servers: servers.count) }
        #if DEBUG
        // `-settings <page>` (testing): open Settings at launch, at that page.
        if connect, SettingsPage.debugLaunch != nil { showSettings = true }
        #endif
    }

    /// Pull to refresh: re-bootstrap every server that is up. Of those that are down, one is
    /// tried now (`ReconnectGovernor.refreshTarget`: the selected one, else the one the breaker
    /// tries, else the likeliest to answer); the others keep their schedules, and follow its
    /// welcome if the breaker held them.
    func refresh() async {
        let target = reconnect.refreshTarget()
        await withTaskGroup(of: Void.self) { g in
            for s in servers {
                let retry = s.control === target
                g.addTask { await s.refresh(retry: retry) }
            }
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
        for id in old.keys where !configs.contains(where: { $0.id == id }) {
            push.serverRemoved(id)
            if let s = old[id] { forward.serverRemoved(s) }
        }
        servers = configs.map { cfg in
            if let s = old[cfg.id], s.config == cfg { return s }
            old[cfg.id]?.stop()
            let s = ServerConnection(config: cfg, prefs: prefs, notifier: notifier, push: push, network: network,
                                     deviceID: push.deviceID, log: connectionLog, governor: reconnect)
            helperSetup.attach(s)
            s.agentsKnown = { [weak self] in self?.tidy.request() }
            s.tunnelShows = { [weak self] in self?.tunnel.shows ?? false }
            s.linkChanged = { [weak self, weak s] in
                self?.checkTunnel()
                if let s { self?.leadReported(s.id, synced: s.synced, failed: s.control.failedNow, dormant: s.control.dormant) }
            }
            s.firstSynced = { [weak self, weak s] in
                if let s { self?.leadReported(s.id, synced: true, failed: false, dormant: false) }
            }
            s.forward = forward
            palette.attach(s)
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
        // The list changed while the app runs: nobody waits a turn (that is for a launch).
        staggered?.cancel()
        leadWait?.cancel()
        lead = nil
        laterTurns = []
        waitingToStart = []
        for s in servers { startServer(s) }
    }

    // MARK: Connecting only once a scene shows

    /// True from the first scene phase that shows the app. Until then no server is started.
    @ObservationIgnored private(set) var mayConnect = false
    /// Starts a server's connection. Tests record the calls instead.
    @ObservationIgnored var startServer: @MainActor (ServerConnection) -> Void = { $0.start() }

    /// The servers whose turn to start has not come (`StartStagger`), and the one wait for them.
    @ObservationIgnored private(set) var waitingToStart: Set<UUID> = []
    @ObservationIgnored private var staggered: Task<Void, Never>?
    /// The wait before a turn, in seconds. Tests end it by hand.
    @ObservationIgnored var staggerSleep: @MainActor (Double) async -> Void = {
        try? await Task.sleep(for: .milliseconds(Int(($0 * 1000).rounded())))
    }

    /// The computer the others wait for, until it has settled or a second has passed.
    @ObservationIgnored private var lead: UUID?
    /// The others, in the order they start, once the first has settled.
    @ObservationIgnored private var laterTurns: [StartStagger.Turn] = []
    /// The one wait for the first computer: `StartStagger.lead` at most.
    @ObservationIgnored private var leadWait: Task<Void, Never>?

    /// The launch's starts: the computer of the tab it opens at once, the others when it has
    /// settled or after a second, whichever comes first, one at a time.
    private func startInTurns() {
        let plan = StartStagger.plan(servers: servers.map(\.id), first: (selection ?? prefs.lastSelection)?.serverID,
                                     unit: { Double.random(in: 0...1) })
        waitingToStart = Set(plan.later.map(\.id))
        laterTurns = plan.later
        lead = plan.later.isEmpty ? nil : plan.now.first
        // In this same turn, with nothing before it.
        for id in plan.now { if let s = server(id) { startServer(s) } }
        guard lead != nil else { return }
        let sleep = staggerSleep
        leadWait = Task { [weak self] in
            await sleep(StartStagger.lead)
            guard !Task.isCancelled else { return }
            self?.startTheOthers()
        }
    }

    /// The first computer reports where it is. Once it has settled the others start.
    func leadReported(_ id: UUID, synced: Bool, failed: Bool, dormant: Bool) {
        guard id == lead, StartStagger.settled(synced: synced, failed: failed, dormant: dormant) else { return }
        startTheOthers()
    }

    /// The others start now, one at a time: the first has settled, or its second is over.
    private func startTheOthers() {
        guard lead != nil else { return }
        lead = nil
        leadWait?.cancel()
        leadWait = nil
        let turns = laterTurns, sleep = staggerSleep
        laterTurns = []
        staggered = Task { [weak self] in
            for t in turns {
                if t.pause > 0 { await sleep(t.pause) }
                guard !Task.isCancelled, let self else { return }
                // Nothing starts in the background: the return starts whoever still waits.
                if self.inBackground { continue }
                self.startNow(t.id)
            }
        }
    }

    /// Starts a server that waits its turn, now: its turn came, the user opened it, or the app
    /// is back from the background. Nothing for a server that is not waiting.
    func startNow(_ id: UUID) {
        guard waitingToStart.remove(id) != nil, let s = server(id) else { return }
        startServer(s)
    }

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
        startInTurns()
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
    /// The setup guide, if it is up, goes: the new computer's tab is what comes next.
    @discardableResult
    func addServer(_ config: ServerConfig) -> Bool {
        if let url = ServerConfig.url(from: config.url), PairingCode.existing(url, in: prefs.servers) != nil { return false }
        prefs.servers.append(config)
        rebuildServers()
        closeGuide()
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
        if let snap = network?.snapshot { route.report(snap.facts) }
        for s in servers { s.networkChanged() }
        push.networkChanged()
        checkTunnel()
    }

    // MARK: The tunnel's message

    /// When the app says that the way to the computers, not a computer, is down: the rule and
    /// its ten seconds in front are `TunnelSuspicion`'s; this only asks it and tells the servers.
    @ObservationIgnored private var tunnel = TunnelSuspicion()
    /// Ends the wait `TunnelSuspicion.update` asked for.
    @ObservationIgnored private var tunnelTask: Task<Void, Never>?

    /// Something `TunnelSuspicion` reads may have changed: the breaker, a server's connection,
    /// the network, the app in front or not. The one place that reads the governor for it:
    /// `breakerOpen` and `tunnelHosts`. A connection's facts are as they are after a change by
    /// the time it is told (`RexControl.handleDrop`), so the answer is right in that turn.
    private func checkTunnel() {
        tunnelTask?.cancel()
        tunnelTask = nil
        let was = tunnel.shows
        let suspected = TunnelSuspicion.suspected(breakerOpen: reconnect.breakerOpen,
                                                  pathSatisfied: network?.snapshot.reachable ?? true,
                                                  hosts: reconnect.tunnelHosts)
        let left = tunnel.update(suspected: suspected, foreground: mayConnect && !inBackground,
                                 now: ProcessInfo.processInfo.systemUptime)
        // Each server words its own screen; one that is not offline does nothing.
        if was != tunnel.shows { for s in servers { s.tunnelNoticeChanged() } }
        guard let left else { return }
        tunnelTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((left + 0.05) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.checkTunnel()
        }
    }

    /// The breaker opened: ask Tailscale's own service on this phone whether it answers, and
    /// write the answer in the connection log. For the log only (`TunnelProbe`): nothing on
    /// screen and nothing about reconnecting depends on it. Only with the app in front and a
    /// tailnet address on the phone, where that address is Tailscale's.
    private func probeTunnel() {
        guard let log = connectionLog, !inBackground, network?.snapshot.onPrivateNetwork == true else { return }
        Task.detached(priority: .utility) { await TunnelProbe.record(into: log) }
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

    /// `byUser`: the user chose this tab. False when the app moves by itself (the tab on screen
    /// closed and the next one shows): that is no tap, and asks no connection for an attempt.
    func select(_ server: ServerConnection, session: String, window: String, block: String? = nil,
                byUser: Bool = true) {
        let tap = Self.isTap(from: selection?.serverID, to: server.id, byUser: byUser)
        selection = Selection(serverID: server.id, sessionID: session, windowID: window)
        if let block { focusedPane[window] = block }
        reconnect.select(server.control)
        // A computer the user opens does not wait its turn.
        startNow(server.id)
        if tap { server.opened() }
        Task { await server.focusWindow(session, window) }
    }

    /// A server's views changed. When that took away the tab on screen (its last pane closed, it
    /// was closed, its session ended), shows the next one `CloseNext` picks, in this same turn,
    /// so the empty state never draws in between. Changes elsewhere move nothing.
    private func viewsChanged(on server: ServerConnection, old: [String: SessionView]) {
        guard let sel = selection, sel.serverID == server.id else { return }
        let now = server.views[sel.sessionID]
        guard now?.window(sel.windowID) == nil, let gone = old[sel.sessionID]?.window(sel.windowID) else { return }
        // A sync that couldn't read a session that is still listed: its view comes back.
        if now == nil, server.sessions.contains(where: { $0.id == sel.sessionID }) { return }
        let moved = gone.allBlocks.lazy.compactMap { now?.windowContaining(block: $0.id)?.id }.first
        moveOff(sel, on: server, order: old[sel.sessionID]?.windows.map(\.id) ?? [], movedTo: moved)
    }

    /// The phone's own Close Tab on the tab on screen: once the server has closed it, the next tab
    /// shows without waiting for the session's view to be read again.
    func closedTab(_ sel: Selection) {
        guard selection == sel, let server = server(sel.serverID),
              let order = server.views[sel.sessionID]?.windows.map(\.id), order.contains(sel.windowID) else { return }
        moveOff(sel, on: server, order: order, movedTo: nil)
    }

    private func moveOff(_ sel: Selection, on server: ServerConnection, order: [String], movedTo: String?) {
        let rule = CloseNext(
            closed: sel, order: order, movedTo: movedTo,
            machines: servers.map { s in
                CloseNext.Machine(id: s.id, online: s === server || s.phase == .online, sessions: s.sessions.compactMap { e in
                    s.views[e.id].map { v in
                        let tabs = v.windows.map(\.id)
                        return CloseNext.Session(id: e.id, windows: s === server && e.id == sel.sessionID ? tabs.filter { $0 != sel.windowID } : tabs,
                                                 active: v.activeWindowID)
                    }
                })
            },
            recent: recentTabs, anySession: !Self.isTestLaunch)
        guard let next = rule.next(), let s = self.server(next.serverID) else { return }
        // The app moves on by itself: not a tap.
        select(s, session: next.sessionID, window: next.windowID, byUser: false)
    }

    /// Whether a selection is a tap for reconnecting (`ServerConnection.opened`): the user
    /// moved to another server. A tab or a pane of the server already selected is not, and
    /// neither is a move the app made itself.
    nonisolated static func isTap(from old: UUID?, to new: UUID, byUser: Bool) -> Bool {
        byUser && old != new
    }

    /// Back in the foreground: reconnect where needed and resync every server with its real state.
    func foregroundResumed() {
        let fromBackground = inBackground
        inBackground = false
        // The selected server is first in every order the governor keeps.
        reconnect.select(selection.flatMap { sel in servers.first { $0.id == sel.serverID } }?.control)
        // Back from the background: whoever still waited a turn starts now. At a launch they
        // keep their turns: `resume` would start them all at once.
        if fromBackground {
            leadWait?.cancel()
            lead = nil
            laterTurns = []
            for id in Array(waitingToStart) { startNow(id) }
        }
        for s in servers where !waitingToStart.contains(s.id) { s.resume(fromBackground: fromBackground) }
        forward.becameActive()
        push.becameActive()
        glance.becameActive()
        tidy.becameActive()
        checkTunnel()
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

    /// Hands the watch's actions to `actions` and tells it how to reach a pane. Only a launch
    /// that writes the real snapshot takes any (`GlanceWriter.Mode.live`): the session with the
    /// watch is opened now, so a message that woke the app in the background is delivered.
    private func connectActions(_ mode: GlanceWriter.Mode) {
        guard case .live(let label) = mode else { return }
        actions.enabled = { true }
        actions.only = { label }
        actions.channel = { [weak self] in self?.actionChannel($0) }
        bridge.answer = { [actions] data in
            // The app may be in the background: the system gives the time to answer.
            let task = BackgroundTask(name: "watch_action") {}
            defer { task.end() }
            return await actions.answer(data)
        }
        // After `init`, off the launch path.
        Task { [bridge] in bridge.listen() }
    }

    /// The way to the pane an action from the watch names. Nil: the server is not one of the
    /// app's. It starts nothing: with the app in front and the server's connection up, that
    /// connection; otherwise (the system woke the app for this) one short connection, labelled
    /// without the device id, as the one that reads who a computer is.
    func actionChannel(_ action: WatchAction) -> ActionChannel? {
        guard let server = servers.first(where: { $0.id.uuidString == action.target.server }) else { return nil }
        if mayConnect, !inBackground, server.control.state == .connected { return LiveActionChannel(server) }
        // A computer that has stopped answering, or a tunnel that looks down: no socket is
        // opened for the action, and it is answered as one that couldn't reach the computer.
        if server.control.dormant || reconnect.breakerOpen { return UnreachableActionChannel() }
        return OneShotActionChannel(address: server.config.url, client: ClientInfo(
            name: Brand.appName,
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
            label: PushIdentity.previewLabel(deviceName: UIDevice.current.name)))
    }

    /// Set from the background until the app is active again, so a return from Control Center or
    /// the app switcher's peek isn't taken for a wake.
    @ObservationIgnored private var inBackground = false

    /// The app went to the background: a connection that drops from now on is waking up when the
    /// app returns, not a problem (`ForegroundWake`).
    func enteredBackground() {
        // First: its background task must begin before anything else is queued.
        forward.enteredBackground()
        inBackground = true
        tidy.enteredBackground()
        for s in servers { s.enteredBackground() }
        // The seconds in front don't run on through the background.
        checkTunnel()
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
            guard !showSettings, !showPairing, !agentsShown, portsShown == nil, helperSetup.active == nil else { return }
            pairingStart = nil
            showPairing = true
            // Straight to pairing: the guide steps aside for this run (a cancel lands on the
            // empty state), and adding the computer ends the first run (`Prefs.servers`).
            guide = nil
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
        // The tab viewed last, else the top tab nearest it (`LaunchTab`).
        guard case .show(let sel) = launchTab.pick() else { return }
        autoSelected = sel
        selection = sel
    }

    /// What `autoSelect()` decides from: the tab viewed last and what each server has synced.
    var launchTab: LaunchTab {
        LaunchTab(last: prefs.lastSelection, machines: servers.map { s in
            LaunchTab.Machine(id: s.id, state: s.synced ? .synced : s.showsOffline ? .down : .waiting,
                              sessions: s.sessions.compactMap { e in
                                  s.views[e.id].map { CloseNext.Session(id: e.id, windows: $0.windows.map(\.id), active: $0.activeWindowID) }
                              })
        })
    }

    /// What the root watches to run `autoSelect()` again: each server's tabs and, until a tab is
    /// on screen, whether it has synced or is down. With a tab on screen it reads no phase.
    var autoSelectInputs: [AutoSelectInput] {
        let launching = selection == nil
        return servers.map { s in
            AutoSelectInput(views: s.views.count, synced: launching && s.synced, down: launching && s.showsOffline)
        }
    }

    struct AutoSelectInput: Equatable {
        var views: Int
        var synced: Bool
        var down: Bool
    }

    /// A cold launch with a tab to show, in sidebar mode: the first root starts with a narrow
    /// window's drawer closed (`SidebarState.launchHold`). Decided once, from saved state, when
    /// the model is made, before anything is drawn; the first root takes it (`launchHoldTaken`),
    /// so a window made later, a scene the system rebuilt, starts as before.
    @ObservationIgnored var launchHold = false

    func launchHoldTaken() { launchHold = false }

    /// Whether a launch has a tab to show: the `-autoOpen` session's with a server, else the tab
    /// viewed last, on a computer still added. With nothing (no computers, the first run), no.
    static func launchHasTab(last: Selection?, servers: [UUID], autoOpen: Bool) -> Bool {
        if autoOpen { return !servers.isEmpty }
        guard let last else { return false }
        return servers.contains(last.serverID)
    }
}
