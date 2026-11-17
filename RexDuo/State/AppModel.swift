import CryptoKit
import SwiftUI
import RexKit

struct Selection: Hashable, Codable {
    var serverID: UUID
    var sessionID: String
    var windowID: String
}

/// A short, unobtrusive notice (e.g. an action the server refused). One at a time; fades on its own.
@MainActor
@Observable
final class Notice {
    static let shared = Notice()
    /// An error (an action the server refused) or plain news.
    enum Style { case error, neutral }

    private(set) var message: String?
    private(set) var style = Style.error
    @ObservationIgnored private var hide: Task<Void, Never>?

    func show(_ text: String, style: Style = .error) {
        self.style = style
        message = text
        hide?.cancel()
        hide = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard !Task.isCancelled else { return }
            self?.message = nil
        }
    }

    func dismiss() { hide?.cancel(); message = nil }
}

/// App-wide actions triggered by keyboard shortcuts, gestures and menus.
/// Senders call `AppModel.perform(_:)`; the visible WindowScreen/RootView executes them.
enum RexCommand: Equatable {
    case newTab, newSession, splitRight, splitDown, closePane, closeTab, renameTab
    case nextTab, previousTab, goToTab(Int), nextPane, previousPane
    case toggleZoom, clear, toggleSidebar, toggleAgents, tabOverview, jumpToWaiting
    case fontBigger, fontSmaller, fontReset, settings
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
    /// Push registration with each server's Rex DUO Helper.
    @ObservationIgnored let push: PushRegistrar
    /// Latest request to show a tab; RootView observes it.
    var openRequest: OpenRequest?

    /// The phone's network. Nil in tests and the test host.
    @ObservationIgnored let network: NetworkWatch?

    /// `connect: false` builds no servers (unit tests and the test host).
    init(prefs: Prefs, connect: Bool = true) {
        self.prefs = prefs
        push = PushRegistrar(prefs: prefs, deviceID: PushIdentity.deviceID(vendorID: UIDevice.current.identifierForVendor))
        network = connect ? NetworkWatch() : nil
        push.servers = { [weak self] in self?.servers ?? [] }
        network?.onChange = { [weak self] _ in self?.networkChanged() }
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
        let configs = Self.debugServers ?? prefs.servers
        #else
        let configs = prefs.servers
        #endif
        let old = Dictionary(uniqueKeysWithValues: servers.map { ($0.config.id, $0) })
        servers = configs.map { cfg in
            if let s = old[cfg.id], s.config == cfg { return s }
            old[cfg.id]?.stop()
            return ServerConnection(config: cfg, prefs: prefs, notifier: notifier, push: push, network: network,
                                    deviceID: push.deviceID)
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
        for s in servers { s.start() }
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
            name: "Rex DUO",
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
        for s in servers { s.resume() }
        push.becameActive()
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
            if selection != t { selection = t }
            return
        }
        guard UserDefaults.standard.string(forKey: "autoOpen") == nil else { return }
        guard selection == nil else { return }
        // The tab open when the app last ran, while it still exists.
        if let last = prefs.lastSelection, server(last.serverID)?.views[last.sessionID]?.window(last.windowID) != nil {
            selection = last
            return
        }
        for s in servers {
            for e in s.sessions {
                if let v = s.views[e.id], let w = v.activeWindow {
                    selection = Selection(serverID: s.id, sessionID: e.id, windowID: w.id)
                    return
                }
            }
        }
    }
}
