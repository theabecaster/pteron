import SwiftUI
import RexKit

/// Agents mode, like the Rex Mac app's activity sidebar: every agent on every machine, grouped by
/// machine, the ones waiting for you first. Machines don't fold here, so a waiting agent never hides.
/// Its own view: it reads every block's status only while it shows.
struct AgentsList: View {
    @Environment(AppModel.self) private var model
    let theme: TermTheme
    var onSelect: (Selection) -> Void
    @ScaledMetric(relativeTo: .headline) private var machineGapScaled: CGFloat = 18
    private var machineGap: CGFloat { min(machineGapScaled, 30) }

    var body: some View {
        let since = PhoneState.shared.waitingSince
        let groups = model.servers.map { s in
            (server: s, rows: AgentOrder.sorted(s.agents, state: { $0.status?.state }, id: \.blockID, since: since))
        }
        .filter { !$0.rows.isEmpty }
        List {
            if model.push.offersPrompt {
                NotificationPromptCard(theme: theme)
                    .padding(.vertical, 6)
                    .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
            ForEach(Array(groups.enumerated()), id: \.element.server.id) { i, g in
                MachineHeader(server: g.server, collapsed: false, foldable: false, theme: theme) {}
                    .padding(.top, i == 0 ? 4 : machineGap)
                    .modifier(SidebarRowStyle(theme: theme))
                ForEach(g.rows) { row in
                    agentRow(g.server, row)
                        .opacity(g.server.phase.problem != nil ? 0.45 : 1)
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

    private func agentRow(_ server: ServerConnection, _ row: ServerConnection.AgentRow) -> some View {
        let selected = model.selection == Selection(serverID: server.id, sessionID: row.sessionID, windowID: row.windowID)
            && model.focusedPane[row.windowID].map { $0 == row.blockID } ?? true
        // Where it runs, as the sidebar names the tab: "session › tab".
        let place = server.views[row.sessionID].map { v in
            [v.label, v.window(row.windowID).map { WindowTitle.of($0, server: server) } ?? ""]
                .filter { !$0.isEmpty }.joined(separator: " › ")
        } ?? row.place
        return Button { open(server, row) } label: {
            AgentRowLabel(row: row, place: place, theme: theme)
                .padding(.leading, SidebarMetrics.sessionLeading - SidebarMetrics.pad)
                .padding(.horizontal, SidebarMetrics.pad)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            let state = row.status?.state
            if state == "blocked" || state == "working" {
                Button { interrupt(server, row) } label: { Label("Interrupt", systemImage: "escape") }
                    .tint(theme.chrome.error)
            }
            if state == "blocked" {
                Button { send(server, row, "\r") } label: { Label("Enter", systemImage: "return") }
                    .tint(theme.chrome.blocked)
            }
            Button { open(server, row) } label: { Label("Jump", systemImage: "arrow.up.forward.square") }
                .tint(theme.accent)
        }
        .modifier(SidebarRowStyle(theme: theme, selected: selected, selectionLeading: SidebarMetrics.sessionLeading - 10))
    }

    private func send(_ server: ServerConnection, _ row: ServerConnection.AgentRow, _ text: String) {
        Haptic.tap()
        Task { await server.write(row.sessionID, row.blockID, text) }
    }

    /// Esc stops an agent's current turn.
    private func interrupt(_ server: ServerConnection, _ row: ServerConnection.AgentRow) {
        Haptic.interrupt()
        Task { await server.write(row.sessionID, row.blockID, "\u{1b}") }
    }

    /// Opens the agent's tab with its pane in view.
    private func open(_ server: ServerConnection, _ row: ServerConnection.AgentRow) {
        let sel = Waiting.prepare(model, Waiting.Item(server: server, row: row))
        model.select(server, session: sel.sessionID, window: sel.windowID)
        onSelect(sel)
    }
}

/// One agent: its tile, name and state, then the pane's title, its status line and where it runs.
struct AgentRowLabel: View {
    let row: ServerConnection.AgentRow
    let place: String
    let theme: TermTheme
    /// The state pill's glyph follows its text's Dynamic Type size.
    @ScaledMetric(relativeTo: .caption2) private var pillGlyph: CGFloat = 10

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 5).fill(TabRowLabel.tint(row.kind, theme).opacity(0.9))
                Image(systemName: row.kind?.symbol ?? "cpu")
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
                    Text(row.kind?.displayName ?? row.status?.app ?? "Program")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .layoutPriority(1)
                    Spacer(minLength: 0)
                    stateLabel(row.status)
                }
                Text(WindowTitle.condense(row.title))
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(theme.chrome.secondary)
                if let t = row.status?.text, !t.isEmpty {
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

    /// The state in words, or, where they don't fit, the row glyph (and progress) in the same pill.
    private func stateLabel(_ s: ProgramStatus?) -> some View {
        let state = s?.state ?? "idle"
        let progress = s?.progress.map { "\($0)%" }
        let (text, color): (String, Color) = {
            switch state {
            case "working": return ("Working" + (progress.map { " \($0)" } ?? ""), theme.chrome.working)
            case "blocked":
                switch s?.waitingFor {
                case "permission": return ("Needs permission", theme.chrome.blocked)
                case "question": return ("Has a question", theme.chrome.blocked)
                case "auth": return ("Needs password", theme.chrome.blocked)
                default: return ("Waiting for you", theme.chrome.blocked)
                }
            case "done": return ("Done", theme.chrome.done)
            case "error": return ("Error", theme.chrome.error)
            default: return ("Idle", theme.chrome.tertiary)
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
