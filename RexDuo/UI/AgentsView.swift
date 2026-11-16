import SwiftUI

/// Every agent running in any pane on any connected server, most urgent first.
struct AgentsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    var onOpen: (Selection) -> Void

    var body: some View {
        let theme = ThemeStore.current(scheme)
        NavigationStack {
            List {
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
                    Text(row.kind?.displayName ?? row.status?.app ?? "Program").font(.subheadline.weight(.semibold))
                    Spacer()
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

    private func stateLabel(_ s: ProgramStatus?, _ theme: TermTheme) -> some View {
        let state = s?.state ?? "idle"
        let (text, color): (String, Color) = {
            switch state {
            case "working": return ("Working" + (s?.progress.map { " \($0)%" } ?? ""), theme.chrome.working)
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
        return Text(text).font(.caption2.weight(.semibold))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundStyle(color)
    }
}
