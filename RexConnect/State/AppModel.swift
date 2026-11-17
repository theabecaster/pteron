import CryptoKit
import SwiftUI
import RexKit

struct Selection: Hashable, Codable {
    var serverID: UUID
    var sessionID: String
    var windowID: String
}

/// What the device reports about its fold (iPhone Duo). Nil in `AppModel.hinge` means no hinge info.
struct HingeInfo: Equatable {
    enum Status: String { case unknown, closed, partial, full }
    var status: Status
    /// Radians, as UIKit reports it.
    var angle: Double

    var isOpen: Bool { status == .partial || status == .full }
}

/// A short, unobtrusive notice (e.g. an action the server refused). One at a time; fades on its own.
@MainActor
@Observable
final class Notice {
    static let shared = Notice()
    private(set) var message: String?
    @ObservationIgnored private var hide: Task<Void, Never>?

    func show(_ text: String) {
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
    case toggleZoom, clear, toggleSidebar, tabOverview, jumpToWaiting
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
    @ObservationIgnored let prefs: Prefs
    @ObservationIgnored let notifier = AgentNotifier()
    /// Push registration with each server's Rex Connect Helper.
    @ObservationIgnored let push: PushRegistrar
    /// Latest request to show a tab; RootView observes it.
    var openRequest: OpenRequest?

    /// Live hinge state from `UIHingeInteraction` (iOS 27.1+). Nil when the device or OS gives none.
    var hinge: HingeInfo?

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

    /// `-hinge closed|partial|full` launch argument (testing): pretend the hinge reports this.
    static var hingeOverride: HingeInfo? {
        guard let raw = UserDefaults.standard.string(forKey: "hinge"), let st = HingeInfo.Status(rawValue: raw) else { return nil }
        let angle: Double = st == .closed ? 0 : st == .partial ? 1.9 : .pi
        return HingeInfo(status: st, angle: angle)
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
