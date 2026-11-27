import SwiftUI

/// Phone-only view state that outlives any one WindowScreen. None of it is sent to the server,
/// so the Mac's layout never changes because of it.
@MainActor
@Observable
final class PhoneState {
    static let shared = PhoneState()

    /// Tabs (window IDs) zoomed on the phone: shown one pane at a time instead of splits or two pages.
    var zoomed: Set<String> = []

    /// Narrow tabs' float sheets (window IDs): the size each keeps and the tiled pane shown under
    /// it (`FloatSheet.Phone`).
    var sheets: [String: FloatSheet.Phone] = [:]

    /// When each blocked pane started waiting, as first seen by the app. "Jump" goes to the oldest.
    @ObservationIgnored var waitingSince: [String: Date] = [:]
    @ObservationIgnored private var handled: UUID?

    /// True for the first handler that sees this request, so a command never runs twice
    /// (RootView and a WindowScreen both listen, and screens can overlap during a transition).
    func claim(_ r: CommandRequest) -> Bool {
        guard handled != r.id else { return false }
        handled = r.id
        return true
    }
}

/// Runs `handle` for every new `AppModel.lastCommand`. It reads the command in its own body,
/// so a command never re-renders the screen that owns it.
struct CommandListener: View {
    @Environment(AppModel.self) private var model
    let handle: (CommandRequest) -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onChange(of: model.lastCommand) { _, r in
                if let r { handle(r) }
            }
    }
}

extension RexCommand {
    /// Commands that act on the tab on screen. The visible WindowScreen runs these; RootView runs the rest.
    var isWindowCommand: Bool {
        switch self {
        case .newSession, .toggleSidebar, .toggleAgents, .jumpToWaiting, .fontBigger, .fontSmaller, .fontReset, .settings,
             .nextSession, .previousSession, .renameSession, .closeSession, .closeOtherTabs, .addComputer,
             .navigateBack, .navigateForward: return false
        default: return true
        }
    }
}

// MARK: - Tabs

@MainActor
enum TabNav {
    /// The tab `by` steps from `windowID` within its session, or nil past either end (no wrap).
    /// Like Safari's tab bar swipe, it never leaves the session: other sessions are other work.
    /// The terminal's swipe wraps instead (`wrapped`), and stays in the session as well.
    static func neighbor(_ server: ServerConnection, _ sessionID: String, _ windowID: String, by d: Int) -> Selection? {
        let ws = server.views[sessionID]?.windows ?? []
        guard let i = ws.firstIndex(where: { $0.id == windowID }), ws.indices.contains(i + d) else { return nil }
        return Selection(serverID: server.id, sessionID: sessionID, windowID: ws[i + d].id)
    }

    /// What a sideways swipe on the terminal does next.
    enum SwipeStep: Equatable {
        /// Shows this pane of the tab.
        case pane(String)
        /// Goes on to the next or previous tab (`wrapped`).
        case tab
    }

    /// A swipe `by` steps from `block` among the panes a tab pages through: the next or previous
    /// pane, and past either end the tab beside it. A tab that doesn't page its panes (one pane,
    /// splits) passes none, so every swipe goes on to the tab beside it.
    nonisolated static func step(pages: [String], from block: String, by d: Int) -> SwipeStep {
        guard let i = pages.firstIndex(of: block), pages.indices.contains(i + d) else { return .tab }
        return .pane(pages[i + d])
    }

    /// The tab a terminal swipe goes to from `windowID`: `by` steps in the session's order, round
    /// from the last tab to the first and back. Nil with no other tab, or when `windowID` isn't in
    /// `order` any more (it closed). The title bar's swipe and the tab commands don't wrap (`neighbor`).
    nonisolated static func wrapped(_ order: [String], from windowID: String, by d: Int) -> String? {
        guard order.count > 1, let i = order.firstIndex(of: windowID) else { return nil }
        let n = order.count
        return order[((i + d) % n + n) % n]
    }

    /// The pane a swipe into a tab that pages its panes shows, so the panes run on from the tab
    /// left: going forward its first, going back its last.
    nonisolated static func landing(pages: [String], forward: Bool) -> String? {
        forward ? pages.first : pages.last
    }

    /// The first tab on a server, in sidebar order.
    static func first(_ server: ServerConnection) -> Selection? {
        for s in server.sessions {
            if let w = server.views[s.id]?.windows.first { return Selection(serverID: server.id, sessionID: s.id, windowID: w.id) }
        }
        return nil
    }
}

/// Next Session and Previous Session (`session.next`, `session.previous`): the session beside
/// the one on screen, in the sidebar's order across the computers, with its active tab.
enum SessionNav {
    /// A session by its computer and ID.
    struct Place: Equatable {
        var serverID: UUID
        var sessionID: String
    }

    /// The place `by` steps from `current` in `order`, or nil past either end (no wrap, as the
    /// tabs' steps) or when `current` isn't in it.
    static func step(_ order: [Place], from current: Place, by d: Int) -> Place? {
        guard let i = order.firstIndex(of: current), order.indices.contains(i + d) else { return nil }
        return order[i + d]
    }

    /// Every session the sidebar lists that has a tab to show, in its order: the computers in
    /// their order, each one's sessions as the sidebar orders them, without the hidden ones.
    @MainActor
    static func order(_ servers: [ServerConnection]) -> [Place] {
        servers.flatMap { s in
            let hidden = s.hiddenSessions()
            return s.orderedSessions.filter { !hidden.contains($0.id) && s.views[$0.id]?.activeWindow != nil }
                .map { Place(serverID: s.id, sessionID: $0.id) }
        }
    }

    /// The tab to show for the session `by` steps from the one in `sel`.
    @MainActor
    static func neighbor(_ servers: [ServerConnection], from sel: Selection, by d: Int) -> Selection? {
        guard let p = step(order(servers), from: Place(serverID: sel.serverID, sessionID: sel.sessionID), by: d),
              let s = servers.first(where: { $0.id == p.serverID }), let w = s.views[p.sessionID]?.activeWindow else { return nil }
        return Selection(serverID: p.serverID, sessionID: p.sessionID, windowID: w.id)
    }
}

@MainActor
enum Poll {
    /// Checks `f` every 50 ms until it returns a value or `timeout` passes. Used to follow a new
    /// pane or tab once the server's event for it has arrived.
    static func until<T>(timeout: Double = 3, _ f: @MainActor () -> T?) async -> T? {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if let v = f() { return v }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return nil
    }
}

// MARK: - Waiting agents

@MainActor
enum Waiting {
    struct Item: Identifiable {
        var id: String { key.blockID }
        let server: ServerConnection
        let key: AgentKey
    }

    /// Every agent waiting for the user, oldest first. Reads only each server's `agentKeys`, so a
    /// view that calls it re-renders when an agent starts or stops waiting, not when a title,
    /// directory or status line changes in some pane.
    static func all(_ servers: [ServerConnection]) -> [Item] {
        let since = PhoneState.shared.waitingSince
        return servers.flatMap { s in
            s.agentKeys.filter { $0.state == "blocked" }.map { Item(server: s, key: $0) }
        }
        .sorted { (since[$0.id] ?? .distantFuture) < (since[$1.id] ?? .distantFuture) }
    }

    /// Points the app at that agent's pane and returns the tab to open. A pane in a minimized
    /// floating window shows it again first, where the server can.
    static func prepare(_ model: AppModel, _ item: Item) -> Selection {
        let k = item.key
        model.focusedPane[k.windowID] = k.blockID
        // A float's agent: a narrow tab shows it in its sheet, at full size.
        if item.server.views[k.sessionID]?.window(k.windowID)?.floatingLayer(of: k.blockID) != nil {
            PhoneState.shared.sheets[k.windowID, default: FloatSheet.Phone()].detent = .large
        }
        let server = item.server
        if let w = server.views[k.sessionID]?.window(k.windowID), let layer = w.floatingLayer(of: k.blockID), layer.minimized,
           server.capabilities.paneSupport.has(.restore) {
            let id = layer.id, several = layer.blocks.count > 1
            Task { await server.raiseFloat(k.sessionID, id, focus: several ? k.blockID : nil) }
        } else {
            Task { await server.focus(k.sessionID, block: k.blockID) }
        }
        return Selection(serverID: server.id, sessionID: k.sessionID, windowID: k.windowID)
    }
}

/// Notes when each agent starts waiting, so "jump" can pick the oldest. Lives once, in RootView.
struct WaitingWatcher: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let ids = model.waitingAgentIDs
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onChange(of: ids, initial: true) { _, now in
                let st = PhoneState.shared
                let date = Date()
                for id in now where st.waitingSince[id] == nil { st.waitingSince[id] = date }
                for id in st.waitingSince.keys where !now.contains(id) { st.waitingSince[id] = nil }
            }
    }
}

/// Header pill shown while an agent the user can't see is waiting. Tap jumps to the oldest;
/// touch and hold lists every waiting agent. It reads only the agent index (`Waiting.all`), so it
/// re-renders when an agent starts or stops waiting; each menu label reads the rest itself.
struct WaitingPill: View {
    @Environment(AppModel.self) private var model
    /// Panes on screen right now; agents waiting there are already in view.
    let visible: Set<String>
    let theme: TermTheme
    /// The hit height: the bar's.
    var height: CGFloat = 44
    let onJump: (Waiting.Item) -> Void

    var body: some View {
        let items = Waiting.all(model.servers).filter { !visible.contains($0.id) }
        if let first = items.first {
            Menu {
                Section("Waiting for You") {
                    ForEach(items) { it in
                        Button { onJump(it) } label: { WaitingMenuLabel(item: it) }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "hand.raised.fill").font(.system(size: 11, weight: .semibold))
                    Text("\(items.count)").font(.caption.weight(.bold)).monospacedDigit()
                }
                .lineLimit(1)
                .foregroundStyle(theme.chrome.blocked)
                .padding(.horizontal, 9)
                .frame(minHeight: 26)
                .background(Capsule().fill(theme.chrome.blocked.opacity(0.18)))
                .fixedSize()
                .frame(minWidth: 44, minHeight: height)
                .contentShape(Rectangle())
                // The title bar keeps its height, so the count stops growing where it would clip.
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            } primaryAction: {
                Haptic.selection()
                onJump(first)
            }
            .accessibilityLabel(items.count == 1 ? "1 agent waiting" : "\(items.count) agents waiting")
            .accessibilityHint("Jumps to the one waiting longest. Touch and hold to pick one.")
            .transition(.scale.combined(with: .opacity))
        }
    }
}

/// One waiting agent in the pill's menu: what it is and where. Reads the pane's metadata and the
/// session's layout in its own body, so the pill doesn't.
private struct WaitingMenuLabel: View {
    let item: Waiting.Item

    var body: some View {
        let k = item.key, server = item.server
        let meta = server.meta[k.blockID]
        let view = server.views[k.sessionID]
        let window = view?.window(k.windowID)
        let place = [view?.label ?? "", window?.label ?? ""].filter { !$0.isEmpty }.joined(separator: " › ")
        Text(k.kind?.displayName ?? meta?.topStatus?.app ?? "Program")
        Text(place.isEmpty ? WindowTitle.condense(meta?.title ?? window?.block(k.blockID)?.label ?? "") : place)
    }
}
