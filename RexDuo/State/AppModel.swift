import SwiftUI

struct Selection: Hashable {
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

@MainActor
@Observable
final class AppModel {
    var servers: [ServerConnection] = []
    var selection: Selection?
    /// The pane shown when only one pane fits (compact width), per window.
    var focusedPane: [String: String] = [:]
    var showSettings = false
    var showAgents = false

    /// Live hinge state from `UIHingeInteraction` (iOS 27.1+). Nil when the device or OS gives none.
    var hinge: HingeInfo?
    /// Unfolded Duo: show two panes of the tab, one per page, instead of sidebar + tab.
    var dualPages: Bool { didSet { UserDefaults.standard.set(dualPages, forKey: "dualPages") } }
    /// Dual pages: which pane sits on each page, per window.
    var dualPair: [String: [String]] = [:]
    /// Quick-reply bars the user dismissed, keyed by block, holding the status they dismissed.
    var dismissedReplies: [String: String] = [:]
    /// Composer drafts, per pane. Kept outside the observed state so typing doesn't re-render the screen.
    @ObservationIgnored var drafts: [String: String] = [:]

    init() {
        dualPages = UserDefaults.standard.bool(forKey: "dualPages")
        rebuildServers()
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
        let configs = Prefs.shared.servers + Prefs.shared.hostURLs.compactMap { label, url in
            url.isEmpty ? nil : ServerConfig(id: Self.stableID(label), name: label, url: url)
        }
        let old = Dictionary(uniqueKeysWithValues: servers.map { ($0.config.id, $0) })
        servers = configs.map { cfg in
            if let s = old[cfg.id], s.config == cfg { return s }
            old[cfg.id]?.stop()
            return ServerConnection(config: cfg)
        }
        for s in servers { s.start() }
    }

    static func stableID(_ label: String) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        for (i, b) in Array(("host:" + label).utf8).enumerated() { bytes[i % 16] = bytes[i % 16] &+ b &* UInt8((i % 7) + 1) }
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
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
