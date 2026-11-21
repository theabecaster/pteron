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
        case .newSession, .toggleSidebar, .toggleAgents, .jumpToWaiting, .fontBigger, .fontSmaller, .fontReset, .settings: return false
        default: return true
        }
    }
}

// MARK: - Tabs

@MainActor
enum TabNav {
    /// The tab `by` steps from `windowID` within its session, or nil past either end (no wrap).
    /// Like Safari's tab bar swipe, it never leaves the session: other sessions are other work.
    static func neighbor(_ server: ServerConnection, _ sessionID: String, _ windowID: String, by d: Int) -> Selection? {
        let ws = server.views[sessionID]?.windows ?? []
        guard let i = ws.firstIndex(where: { $0.id == windowID }), ws.indices.contains(i + d) else { return nil }
        return Selection(serverID: server.id, sessionID: sessionID, windowID: ws[i + d].id)
    }

    /// The first tab on a server, in sidebar order.
    static func first(_ server: ServerConnection) -> Selection? {
        for s in server.sessions {
            if let w = server.views[s.id]?.windows.first { return Selection(serverID: server.id, sessionID: s.id, windowID: w.id) }
        }
        return nil
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
    let onJump: (Waiting.Item) -> Void

    var body: some View {
        let items = Waiting.all(model.servers).filter { !visible.contains($0.id) }
        if let first = items.first {
            Menu {
                Section("Waiting for you") {
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
                .frame(minWidth: 44, minHeight: 44)
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
