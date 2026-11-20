import SwiftUI
import RexKit

/// Agents mode, like the Rex Mac app's activity sidebar: every agent on every machine, grouped by
/// machine, the ones waiting for you first. Machines don't fold here, so a waiting agent never hides.
///
/// The list reads only `agentKeys`, which change when an agent comes, goes or changes state. Each
/// row is equatable and its label reads its own block's box, so a title or status line change in
/// one pane re-renders that row alone, and nothing re-sorts.
struct AgentsList: View {
    @Environment(AppModel.self) private var model
    let theme: TermTheme
    var onSelect: (Selection) -> Void
    @State private var actions = SidebarActions()
    @ScaledMetric(relativeTo: .headline) private var machineGapScaled: CGFloat = 18
    private var machineGap: CGFloat { min(machineGapScaled, 30) }

    var body: some View {
        actions.onSelect = onSelect
        let since = PhoneState.shared.waitingSince
        let groups = model.servers.map { s in
            (server: s, keys: AgentOrder.sorted(s.agentKeys, state: \.state, id: \.blockID, since: since))
        }
        .filter { !$0.keys.isEmpty }
        let selection = model.selection
        return List {
            ForEach(Array(groups.enumerated()), id: \.element.server.id) { i, g in
                MachineHeader(server: g.server, windows: [], sessionCount: g.server.sessions.count, collapsed: false, foldable: false, theme: theme) {}
                    .padding(.top, i == 0 ? 4 : machineGap)
                    .modifier(SidebarRowStyle(theme: theme))
                ForEach(g.keys) { key in
                    let selected = selection == Selection(serverID: g.server.id, sessionID: key.sessionID, windowID: key.windowID)
                        && (model.focusedPane[key.windowID].map { $0 == key.blockID } ?? true)
                    AgentRow(server: g.server, key: key, dim: g.server.phase.problem != nil, theme: theme, actions: actions)
                        .equatable()
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if key.state == "blocked" || key.state == "working" {
                                Button { AgentRow.send(g.server, key, "\u{1b}", interrupt: true) } label: {
                                    Label("Interrupt", systemImage: "escape")
                                }
                                .tint(theme.chrome.error)
                            }
                            if key.state == "blocked" {
                                Button { AgentRow.send(g.server, key, "\r") } label: { Label("Enter", systemImage: "return") }
                                    .tint(theme.chrome.blocked)
                            }
                            Button { AgentRow.open(g.server, key, model, actions) } label: {
                                Label("Jump", systemImage: "arrow.up.forward.square")
                            }
                            .tint(theme.accent)
                        }
                        .accessibilityAddTraits(selected ? .isSelected : [])
                        .modifier(SidebarRowStyle(theme: theme, selected: selected,
                                                  selectionLeading: SidebarMetrics.sessionLeading - 10))
                }
            }
            if groups.isEmpty {
                Text("No agents are running. Agents such as Claude Code and Codex show up here, with whether they're working or waiting for you.")
                    .font(.footnote)
                    .foregroundStyle(theme.chrome.secondary)
                    .padding(.horizontal, SidebarMetrics.pad)
                    .padding(.vertical, 12)
                    .modifier(SidebarRowStyle(theme: theme))
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 30)
        .refreshable { await model.refresh() }
    }
}

/// One agent. Tap, or Return on a focused row, opens its tab with its pane in view.
struct AgentRow: View, Equatable {
    let server: ServerConnection
    let key: AgentKey
    let dim: Bool
    let theme: TermTheme
    let actions: SidebarActions
    @Environment(AppModel.self) private var model

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.server === b.server && a.key == b.key && a.dim == b.dim && a.theme.id == b.theme.id && a.actions === b.actions
    }

    var body: some View {
        Button { Self.open(server, key, model, actions) } label: {
            AgentRowLabel(server: server, key: key, theme: theme)
                .padding(.leading, SidebarMetrics.sessionLeading - SidebarMetrics.pad)
                .padding(.horizontal, SidebarMetrics.pad)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onKeyPress(.return) {
            Self.open(server, key, model, actions)
            return .handled
        }
        .opacity(dim ? 0.45 : 1)
    }

    /// Opens the agent's tab with its pane in view.
    static func open(_ server: ServerConnection, _ key: AgentKey, _ model: AppModel, _ actions: SidebarActions) {
        model.select(server, session: key.sessionID, window: key.windowID, block: key.blockID)
        Task { await server.focus(key.sessionID, block: key.blockID) }
        actions.onSelect(Selection(serverID: server.id, sessionID: key.sessionID, windowID: key.windowID))
    }

    /// Types into the agent's pane: Esc stops its turn, Return answers.
    static func send(_ server: ServerConnection, _ key: AgentKey, _ text: String, interrupt: Bool = false) {
        if interrupt { Haptic.interrupt() } else { Haptic.tap() }
        Task { await server.write(key.sessionID, key.blockID, text) }
    }
}

/// One agent: its tile, name and state, then the pane's title, its status line and where it runs.
/// Reads its own block's box, like `TabRowLabel`.
struct AgentRowLabel: View {
    let server: ServerConnection
    let key: AgentKey
    let theme: TermTheme
    /// The state pill's glyph follows its text's Dynamic Type size.
    @ScaledMetric(relativeTo: .caption2) private var pillGlyph: CGFloat = 10

    var body: some View {
        let meta = server.meta[key.blockID]
        let status = meta?.topStatus
        let kind = meta?.agentKind ?? key.kind
        HStack(alignment: .top, spacing: 9) {
            ZStack {
                TabRowLabel.tile(kind).fill(TabRowLabel.tint(kind, theme).opacity(0.9))
                Image(systemName: kind?.symbol ?? "cpu")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(theme.bg)
            }
            .frame(width: 18, height: 18)
            .padding(.top, 1)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    // The name keeps its width while the state can shrink to its glyph; only then
                    // does the name truncate.
                    Text(kind?.displayName ?? status?.app ?? "Program")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .layoutPriority(1)
                    Spacer(minLength: 0)
                    stateLabel(status)
                }
                Text(WindowTitle.condense(meta?.title ?? "shell"))
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(theme.chrome.secondary)
                if let t = status?.text, !t.isEmpty {
                    Text(t).font(.caption).lineLimit(2).foregroundStyle(theme.fg.opacity(0.8))
                }
                if !place.isEmpty {
                    Text(place).font(.caption2).lineLimit(1).foregroundStyle(theme.chrome.tertiary)
                }
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    /// Where it runs, as the sidebar names the tab: "session › tab".
    private var place: String {
        guard let v = server.views[key.sessionID] else { return "" }
        return [v.label, v.window(key.windowID).map { WindowTitle.of($0, server: server) } ?? ""]
            .filter { !$0.isEmpty }.joined(separator: " › ")
    }

    /// An agent's state in words. The agent board says it the same way.
    nonisolated static func stateText(_ s: ProgramStatus?) -> String {
        switch s?.state ?? "idle" {
        case "working": return "Working" + (s?.progress.map { " \($0)%" } ?? "")
        case "blocked":
            switch s?.waitingFor {
            case "permission": return "Needs permission"
            case "question": return "Has a question"
            case "auth": return "Needs password"
            default: return "Waiting for you"
            }
        case "done": return "Done"
        case "error": return "Error"
        default: return "Idle"
        }
    }

    /// The state in words, or, where they don't fit, the row glyph (and progress) in the same pill.
    private func stateLabel(_ s: ProgramStatus?) -> some View {
        let state = s?.state ?? "idle"
        let progress = s?.progress.map { "\($0)%" }
        let text = Self.stateText(s)
        let color: Color = {
            switch state {
            case "working": return theme.chrome.working
            case "blocked": return theme.chrome.blocked
            case "done": return theme.chrome.done
            case "error": return theme.chrome.error
            default: return theme.chrome.tertiary
            }
        }()
        // Idle has no glyph, so it keeps its one short word.
        let glyph = state == "working" || state == "blocked" || state == "done" || state == "error"
        return ViewThatFits(in: .horizontal) {
            statePill(Text(text).monospacedDigit(), color)
            if glyph {
                statePill(HStack(spacing: 3) {
                    StatusBadge(state: state, theme: theme, size: pillGlyph)
                    if let progress { Text(progress).monospacedDigit() }
                }, color)
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }

    private func statePill(_ content: some View, _ color: Color) -> some View {
        content
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundStyle(color)
            .fixedSize()
    }
}
