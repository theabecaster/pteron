import SwiftUI

/// Rex's vertical-tab sidebar: hosts, then sessions, then each session's tabs.
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    var onSelect: (Selection) -> Void

    @State private var renaming: RenameTarget?
    @State private var renameText = ""
    @State private var showAgents = false

    struct RenameTarget: Identifiable {
        var id: String { (windowID ?? "") + sessionID }
        var server: ServerConnection
        var sessionID: String
        var windowID: String?
    }

    var body: some View {
        let theme = ThemeStore.current(scheme)
        let p = Prefs.shared
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    agentsSummary(theme)
                    ForEach(model.servers) { server in
                        hostHeader(server, theme)
                        ForEach(server.sessions) { s in
                            sessionBlock(server, s, theme, textSize: p.sidebarTextSize)
                        }
                    }
                    remoteHosts(theme)
                }
                .padding(.horizontal, 8)
                .padding(.top, 6)
                .padding(.bottom, 20)
            }
            bottomBar(theme)
        }
        .foregroundStyle(theme.fg)
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Rename") {
                if let r = renaming {
                    Task {
                        if let w = r.windowID { await r.server.renameWindow(r.sessionID, w, renameText) }
                        else { await r.server.renameSession(r.sessionID, renameText) }
                    }
                }
                renaming = nil
            }
        }
        .sheet(isPresented: $showAgents) {
            AgentsView(onOpen: { sel in
                showAgents = false
                onSelect(sel)
            })
            .environment(model)
            .presentationDetents([.medium, .large])
        }
    }

    // MARK: Pieces

    @ViewBuilder
    private func agentsSummary(_ theme: TermTheme) -> some View {
        let rows = model.servers.flatMap(\.agents)
        if Prefs.shared.showAgentStatus, !rows.isEmpty {
            let blocked = rows.filter { $0.status?.state == "blocked" }.count
            let working = rows.filter { $0.status?.state == "working" }.count
            Button { showAgents = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles").foregroundStyle(theme.accent)
                    Text("Agents").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if blocked > 0 { pill("\(blocked) waiting", theme.chrome.blocked) }
                    if working > 0 { pill("\(working) working", theme.chrome.working) }
                    if blocked == 0 && working == 0 { pill("\(rows.count) idle", theme.chrome.tertiary) }
                }
                .padding(.horizontal, 10).padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 10).fill(theme.fg.opacity(0.06)))
            }
            .buttonStyle(.plain)
            .padding(.bottom, 6)
        }
    }

    private func pill(_ t: String, _ c: Color) -> some View {
        Text(t).font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(c.opacity(0.2)))
            .foregroundStyle(c)
    }

    private func hostHeader(_ server: ServerConnection, _ theme: TermTheme) -> some View {
        HStack(spacing: 8) {
            Image(systemName: server.config.name == "This Mac" ? "laptopcomputer" : "globe")
                .font(.system(size: 13))
                .foregroundStyle(theme.chrome.secondary)
            Text(server.config.name)
                .font(.system(size: 13, weight: .medium))
            Spacer()
            phaseDot(server.phase, theme)
        }
        .padding(.horizontal, 8)
        .padding(.top, 10).padding(.bottom, 4)
        .contextMenu {
            Button { Task { await server.createSession(label: nil) } } label: { Label("New Session", systemImage: "plus") }
            Button { server.stop(); server.start() } label: { Label("Reconnect", systemImage: "arrow.clockwise") }
        }
    }

    @ViewBuilder
    private func phaseDot(_ phase: ServerConnection.Phase, _ theme: TermTheme) -> some View {
        switch phase {
        case .online: Circle().fill(theme.chrome.done).frame(width: 7, height: 7)
        case .connecting, .idle: ProgressView().controlSize(.mini)
        case .offline: Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(theme.chrome.blocked)
        }
    }

    @ViewBuilder
    private func sessionBlock(_ server: ServerConnection, _ s: SessionEntry, _ theme: TermTheme, textSize: Double) -> some View {
        Text(s.label.isEmpty ? "session" : s.label)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(theme.chrome.tertiary)
            .padding(.horizontal, 10)
            .padding(.top, 8).padding(.bottom, 2)
            .contextMenu {
                Button { Task { await server.newWindow(s.id) } } label: { Label("New Tab", systemImage: "plus.square") }
                Button { renameText = s.label; renaming = RenameTarget(server: server, sessionID: s.id) } label: { Label("Rename Session", systemImage: "pencil") }
                Button(role: .destructive) { Task { await server.destroySession(s.id) } } label: { Label("Close Session", systemImage: "xmark") }
            }
        if let v = server.views[s.id] {
            ForEach(v.windows) { w in
                windowRow(server, v, w, theme, textSize: textSize)
            }
        }
    }

    private func windowRow(_ server: ServerConnection, _ v: SessionView, _ w: WindowInfo, _ theme: TermTheme, textSize: Double) -> some View {
        let selected = model.selection == Selection(serverID: server.id, sessionID: v.sessionID, windowID: w.id)
        let status = server.windowStatus(w)
        let agent = server.windowAgent(w)
        return Button {
            let sel = Selection(serverID: server.id, sessionID: v.sessionID, windowID: w.id)
            model.select(server, session: v.sessionID, window: w.id)
            onSelect(sel)
        } label: {
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5).fill(iconTint(agent, theme).opacity(0.9))
                    Image(systemName: agent?.symbol ?? "terminal")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(theme.bg)
                }
                .frame(width: 18, height: 18)
                Text(WindowTitle.of(w, server: server))
                    .font(.system(size: textSize))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if w.allBlocks.count > 1 {
                    Text("\(w.allBlocks.count)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(theme.chrome.tertiary)
                }
                StatusBadge(status: status, theme: theme)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? theme.chrome.rowSelected : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { renameText = w.label; renaming = RenameTarget(server: server, sessionID: v.sessionID, windowID: w.id) } label: { Label("Rename Tab", systemImage: "pencil") }
            Button { Task { await server.newWindow(v.sessionID) } } label: { Label("New Tab", systemImage: "plus.square") }
            Button(role: .destructive) { Task { await server.closeWindow(v.sessionID, w.id) } } label: { Label("Close Tab", systemImage: "xmark") }
        }
    }

    private func iconTint(_ a: AgentKind?, _ theme: TermTheme) -> Color {
        switch a {
        case .claude: return Color(hex: "#d97757")
        case .codex: return theme.fg
        case .gemini: return theme.ansiColor(4)
        case .some: return theme.ansiColor(5)
        case nil: return theme.chrome.secondary
        }
    }

    @ViewBuilder
    private func remoteHosts(_ theme: TermTheme) -> some View {
        let known = Set(model.servers.map(\.config.name))
        let hosts = model.servers.flatMap(\.hosts).filter { !known.contains($0.label) }
        if !hosts.isEmpty {
            ForEach(hosts) { h in
                HStack(spacing: 8) {
                    Image(systemName: "globe").font(.system(size: 13)).foregroundStyle(theme.chrome.secondary)
                    Text(h.label).font(.system(size: 13, weight: .medium))
                    Spacer()
                }
                .padding(.horizontal, 8).padding(.top, 12)
                Text("Reachable from the Mac over SSH only. Turn on Rex's Tailscale there (rex server tailscale enable), then add its address in Settings.")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.chrome.tertiary)
                    .padding(.horizontal, 10)
                    .onTapGesture { model.showSettings = true }
            }
        }
    }

    private func bottomBar(_ theme: TermTheme) -> some View {
        HStack(spacing: 18) {
            Button { model.showSettings = true } label: { Image(systemName: "gearshape") }
            Button { showAgents = true } label: { Image(systemName: "sparkles") }
            Spacer()
            Menu {
                ForEach(model.servers) { s in
                    Button("New Session on \(s.config.name)") {
                        Task {
                            if let id = await s.createSession(label: nil), let w = s.views[id]?.windows.first {
                                model.select(s, session: id, window: w.id)
                                onSelect(Selection(serverID: s.id, sessionID: id, windowID: w.id))
                            }
                        }
                    }
                }
            } label: { Image(systemName: "plus") }
        }
        .font(.system(size: 16))
        .foregroundStyle(theme.chrome.secondary)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(theme.chrome.sidebar)
        .overlay(alignment: .top) { Rectangle().fill(theme.chrome.divider).frame(height: 1) }
    }
}

struct StatusBadge: View {
    var status: ProgramStatus?
    var theme: TermTheme

    var body: some View {
        switch status?.state {
        case "working":
            PulsingDot(color: theme.chrome.working)
        case "blocked":
            Image(systemName: "hand.raised.fill").font(.system(size: 10)).foregroundStyle(theme.chrome.blocked)
        case "done":
            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(theme.chrome.done)
        case "error":
            Image(systemName: "exclamationmark").font(.system(size: 10, weight: .bold)).foregroundStyle(theme.chrome.error)
        default:
            EmptyView()
        }
    }
}

struct PulsingDot: View {
    var color: Color
    @State private var on = false
    var body: some View {
        Circle().fill(color).frame(width: 7, height: 7)
            .opacity(on ? 1 : 0.35)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
    }
}

enum WindowTitle {
    @MainActor
    static func of(_ w: WindowInfo, server: ServerConnection) -> String {
        let generic = w.label.isEmpty || w.label.hasPrefix("Window ")
        if !generic { return w.label }
        if let f = w.focusedBlockID ?? w.orderedBlockIDs.first, let t = server.meta[f]?.title, !t.isEmpty { return t }
        return w.block(w.focusedBlockID ?? "")?.label ?? "shell"
    }
}
