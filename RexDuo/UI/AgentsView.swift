import SwiftUI

/// Every agent running in any pane on any connected server, most urgent first.
struct AgentsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
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
                                    model.select(server, session: row.sessionID, window: row.windowID, block: row.blockID)
                                    onOpen(Selection(serverID: server.id, sessionID: row.sessionID, windowID: row.windowID))
                                } label: {
                                    agentRow(row, theme)
                                }
                                .listRowBackground(theme.chrome.sidebar)
                            }
                        }
                    }
                }
                if model.servers.allSatisfy({ $0.agents.isEmpty }) {
                    Text("No agents are running. Agents such as Claude Code and Codex show up here, with whether they're working or waiting for you.")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.chrome.secondary)
                        .listRowBackground(Color.clear)
                }
            }
            .scrollContentBackground(.hidden)
            .background(theme.chrome.canvas)
            .navigationTitle("Agents")
            .navigationBarTitleDisplayMode(.inline)
        }
        .foregroundStyle(theme.fg)
    }

    private func agentRow(_ row: ServerConnection.AgentRow, _ theme: TermTheme) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: row.kind?.symbol ?? "cpu")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(row.kind == .claude ? Color(hex: "#d97757") : theme.accent)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(row.kind?.displayName ?? row.status?.app ?? "Program").font(.system(size: 14, weight: .semibold))
                    Spacer()
                    stateLabel(row.status, theme)
                }
                Text(row.title).font(.system(size: 12)).lineLimit(1).foregroundStyle(theme.chrome.secondary)
                if let t = row.status?.text, !t.isEmpty {
                    Text(t).font(.system(size: 12)).lineLimit(2).foregroundStyle(theme.fg.opacity(0.8))
                }
                Text(row.place).font(.system(size: 11)).foregroundStyle(theme.chrome.tertiary)
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
        return Text(text).font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundStyle(color)
    }
}
