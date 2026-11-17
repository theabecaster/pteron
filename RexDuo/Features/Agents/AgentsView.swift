import SwiftUI
import RexKit

/// Every agent running in any pane on any connected server, most urgent first.
struct AgentsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    @Environment(Prefs.self) private var prefs
    @Environment(\.dismiss) private var dismiss
    var onOpen: (Selection) -> Void
    /// The state pill's glyph follows its text's Dynamic Type size.
    @ScaledMetric(relativeTo: .caption2) private var pillGlyph: CGFloat = 10

    var body: some View {
        let theme = prefs.theme(for: scheme)
        NavigationStack {
            List {
                if model.push.offersPrompt {
                    Section {
                        NotificationPromptCard(theme: theme)
                            .padding(.vertical, 6)
                            .listRowBackground(theme.chrome.sidebar)
                    }
                }
                ForEach(model.servers) { server in
                    let rows = server.agents
                    if !rows.isEmpty {
                        Section(server.config.name) {
                            ForEach(rows) { row in
                                Button {
                                    open(server, row)
                                } label: {
                                    agentRow(row, theme)
                                        .frame(minHeight: 44)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .listRowBackground(theme.chrome.sidebar)
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
                            }
                        }
                    }
                }
                if model.servers.allSatisfy({ $0.agents.isEmpty }) {
                    Text("No agents are running. Agents such as Claude Code and Codex show up here, with whether they're working or waiting for you.")
                        .font(.footnote)
                        .foregroundStyle(theme.chrome.secondary)
                        .listRowBackground(Color.clear)
                }
            }
            .scrollContentBackground(.hidden)
            .background(theme.chrome.canvas)
            .navigationTitle("Agents")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .foregroundStyle(theme.fg)
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
        onOpen(sel)
    }

    private func agentRow(_ row: ServerConnection.AgentRow, _ theme: TermTheme) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: row.kind?.symbol ?? "cpu")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(row.kind == .claude ? Color(hex: "#d97757") : theme.accent)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    // The name keeps its width while the state can shrink to its glyph; only then
                    // does the name truncate.
                    Text(row.kind?.displayName ?? row.status?.app ?? "Program").font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .layoutPriority(1)
                    Spacer(minLength: 0)
                    stateLabel(row.status, theme)
                }
                Text(WindowTitle.condense(row.title)).font(.caption).lineLimit(2).foregroundStyle(theme.chrome.secondary)
                if let t = row.status?.text, !t.isEmpty {
                    Text(t).font(.caption).lineLimit(2).foregroundStyle(theme.fg.opacity(0.8))
                }
                Text(row.place).font(.caption2).foregroundStyle(theme.chrome.tertiary)
            }
        }
        .padding(.vertical, 3)
    }

    /// The state in words, or, where they don't fit, the row glyph (and progress) in the same pill.
    private func stateLabel(_ s: ProgramStatus?, _ theme: TermTheme) -> some View {
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
