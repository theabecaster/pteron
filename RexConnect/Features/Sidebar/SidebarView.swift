import SwiftUI
import RexKit

/// Rex's vertical-tab sidebar: hosts, then sessions, then each session's tabs.
/// A plain `List` styled like Rex: swipe actions on rows, pull to refresh, 44 pt rows.
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    @Environment(Prefs.self) private var prefs
    var onSelect: (Selection) -> Void

    @State private var renaming: RenameTarget?
    @State private var renameText = ""
    @State private var closing: RenameTarget?
    /// A tab with an agent in it: closing asks first.
    @State private var closingTab: RenameTarget?
    @State private var showAgents = false

    struct RenameTarget: Identifiable {
        var id: String { (windowID ?? "") + sessionID }
        var server: ServerConnection
        var sessionID: String
        var windowID: String?
        var label: String = ""
    }

    var body: some View {
        let theme = prefs.theme(for: scheme)
        let p = prefs
        VStack(spacing: 0) {
            List {
                agentsSummary(theme)
                ForEach(model.servers) { server in
                    hostHeader(server, theme)
                    ForEach(server.sessions) { s in
                        sessionHeader(server, s, theme)
                        if let v = server.views[s.id] {
                            ForEach(v.windows) { w in
                                windowRow(server, v, w, theme, textSize: p.sidebarTextSize)
                            }
                        }
                    }
                }
                remoteHosts(theme)
            }
            .listStyle(.plain)
            .confirmationDialog("Close this tab?",
                                isPresented: Binding(get: { closingTab != nil }, set: { if !$0 { closingTab = nil } }),
                                titleVisibility: .visible) {
                Button("Close Tab", role: .destructive) {
                    if let c = closingTab, let w = c.windowID { Task { await c.server.closeWindow(c.sessionID, w) } }
                    closingTab = nil
                }
                Button("Cancel", role: .cancel) { closingTab = nil }
            } message: {
                Text("The agent running there stops, on the Mac too.")
            }
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 44)
            .refreshable { await model.refresh() }
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
        .confirmationDialog(closing.map { "Close session “\($0.label.isEmpty ? "session" : $0.label)”?" } ?? "",
                            isPresented: Binding(get: { closing != nil }, set: { if !$0 { closing = nil } }),
                            titleVisibility: .visible) {
            Button("Close Session", role: .destructive) {
                if let c = closing { Task { await c.server.destroySession(c.sessionID) } }
                closing = nil
            }
            Button("Cancel", role: .cancel) { closing = nil }
        } message: {
            Text("Every tab in it closes and its programs stop, on the Mac too.")
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

    /// Shared row styling: Rex's compact look on a plain list.
    private func styled<V: View>(_ v: V, selected: Bool = false, _ theme: TermTheme) -> some View {
        v.listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
            .listRowSeparator(.hidden)
            .listRowBackground(
                RoundedRectangle(cornerRadius: 8)
                    .fill(selected ? theme.chrome.rowSelected : .clear)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
            )
    }

    @ViewBuilder
    private func agentsSummary(_ theme: TermTheme) -> some View {
        if prefs.showAgentStatus {
            styled(
                Button { showAgents = true } label: {
                    AgentsSummaryLabel(servers: model.servers, theme: theme)
                }
                .buttonStyle(.plain)
                .padding(.top, 6).padding(.bottom, 4),
                theme)
        }
    }

    private func hostHeader(_ server: ServerConnection, _ theme: TermTheme) -> some View {
        styled(
            HStack(spacing: 8) {
                Image(systemName: server.config.name == "This Mac" ? "laptopcomputer" : "globe")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.chrome.secondary)
                Text(server.config.name)
                    .font(.footnote.weight(.medium))
                Spacer()
                phaseDot(server.phase, theme)
            }
            .padding(.horizontal, 8)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .contextMenu {
                Button { Task { await server.createSession(label: nil) } } label: { Label("New Session", systemImage: "plus") }
                Button { server.stop(); server.start() } label: { Label("Reconnect", systemImage: "arrow.clockwise") }
            }
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                Button { Task { await server.createSession(label: nil) } } label: { Label("New Session", systemImage: "plus") }
                    .tint(theme.accent)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button { server.stop(); server.start() } label: { Label("Reconnect", systemImage: "arrow.clockwise") }
                    .tint(theme.chrome.working)
            },
            theme)
    }

    @ViewBuilder
    private func phaseDot(_ phase: ServerConnection.Phase, _ theme: TermTheme) -> some View {
        switch phase {
        case .online: Circle().fill(theme.chrome.done).frame(width: 7, height: 7)
        case .connecting, .idle: ProgressView().controlSize(.mini)
        case .offline: Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(theme.chrome.blocked)
        }
    }

    private func sessionHeader(_ server: ServerConnection, _ s: SessionEntry, _ theme: TermTheme) -> some View {
        let target = RenameTarget(server: server, sessionID: s.id, label: s.label)
        let name = s.label.isEmpty ? "session" : s.label
        return styled(
            HStack(spacing: 4) {
                Text(name)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(theme.chrome.tertiary)
                    .lineLimit(2)
                Spacer(minLength: 4)
                Button { Task { await server.newWindow(s.id) } } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.chrome.tertiary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("New Tab in \(name)")
            }
            .padding(.leading, 10)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .contextMenu {
                Button { Task { await server.newWindow(s.id) } } label: { Label("New Tab", systemImage: "plus.square") }
                Button { renameText = s.label; renaming = target } label: { Label("Rename Session", systemImage: "pencil") }
                Button(role: .destructive) { closing = target } label: { Label("Close Session…", systemImage: "xmark") }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button { closing = target } label: { Label("Close", systemImage: "xmark") }
                    .tint(theme.chrome.error)
                Button { renameText = s.label; renaming = target } label: { Label("Rename", systemImage: "pencil") }
                    .tint(theme.chrome.secondary)
            }
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                Button { Task { await server.newWindow(s.id) } } label: { Label("New Tab", systemImage: "plus.square") }
                    .tint(theme.accent)
            },
            theme)
    }

    private func windowRow(_ server: ServerConnection, _ v: SessionView, _ w: WindowInfo, _ theme: TermTheme, textSize: Double) -> some View {
        let selected = model.selection == Selection(serverID: server.id, sessionID: v.sessionID, windowID: w.id)
        let rename = { renameText = w.label; renaming = RenameTarget(server: server, sessionID: v.sessionID, windowID: w.id) }
        // Destructive: never a full swipe, and a confirmation when an agent would stop.
        let close = {
            if server.windowAgent(w) != nil {
                closingTab = RenameTarget(server: server, sessionID: v.sessionID, windowID: w.id, label: w.label)
            } else {
                Task { await server.closeWindow(v.sessionID, w.id) }
            }
        }
        return styled(
            Button {
                let sel = Selection(serverID: server.id, sessionID: v.sessionID, windowID: w.id)
                if !selected { GestureTips.donate(TabSwipeTip.switchedTabs) }
                model.select(server, session: v.sessionID, window: w.id)
                onSelect(sel)
            } label: {
                TabRowLabel(server: server, window: w, textSize: textSize, theme: theme)
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button(action: rename) { Label("Rename Tab", systemImage: "pencil") }
                Button { Task { await server.newWindow(v.sessionID) } } label: { Label("New Tab", systemImage: "plus.square") }
                Button(role: .destructive, action: close) { Label("Close Tab", systemImage: "xmark") }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(action: close) { Label("Close", systemImage: "xmark") }
                    .tint(theme.chrome.error)
                Button(action: rename) { Label("Rename", systemImage: "pencil") }
                    .tint(theme.chrome.secondary)
            },
            selected: selected, theme)
    }

    @ViewBuilder
    private func remoteHosts(_ theme: TermTheme) -> some View {
        let known = Set(model.servers.map(\.config.name))
        let hosts = model.servers.flatMap(\.hosts).filter { !known.contains($0.label) }
        ForEach(hosts) { h in
            styled(
                Button { model.showSettings = true } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Image(systemName: "globe").font(.system(size: 13)).foregroundStyle(theme.chrome.secondary)
                            Text(h.label).font(.footnote.weight(.medium))
                            Spacer()
                        }
                        Text("Reachable from the Mac over SSH only. Turn on Rex's Tailscale there (rex server tailscale enable), then add its address in Settings.")
                            .font(.caption2)
                            .foregroundStyle(theme.chrome.tertiary)
                            .padding(.leading, 2)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain),
                theme)
        }
    }

    private func bottomBar(_ theme: TermTheme) -> some View {
        HStack(spacing: 4) {
            IconButton(symbol: "gearshape", label: "Settings") { model.showSettings = true }
            IconButton(symbol: "sparkles", label: "Agents") { showAgents = true }
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
            } label: {
                Image(systemName: "plus")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("New Session")
        }
        .font(.system(size: 17))
        .foregroundStyle(theme.chrome.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
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

/// The "working" dot. A symbol effect, not a SwiftUI repeat-forever animation, so many rows stay cheap.
struct PulsingDot: View {
    var color: Color
    var body: some View {
        Image(systemName: "circle.fill")
            .font(.system(size: 7))
            .foregroundStyle(color)
            .symbolEffect(.pulse, options: .repeating)
    }
}

/// The agents count row. Reads every block's status, so it lives in its own view.
struct AgentsSummaryLabel: View {
    let servers: [ServerConnection]
    let theme: TermTheme

    var body: some View {
        let rows = servers.flatMap(\.agents)
        let blocked = rows.filter { $0.status?.state == "blocked" }.count
        let working = rows.filter { $0.status?.state == "working" }.count
        HStack(spacing: 8) {
            Image(systemName: "sparkles").foregroundStyle(theme.accent)
            Text("Agents").font(.footnote.weight(.semibold))
            Spacer()
            if blocked > 0 { pill("\(blocked) waiting", theme.chrome.blocked) }
            if working > 0 { pill("\(working) working", theme.chrome.working) }
            if blocked == 0 && working == 0 { pill(rows.isEmpty ? "none" : "\(rows.count) idle", theme.chrome.tertiary) }
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 44)
        .background(RoundedRectangle(cornerRadius: 10).fill(theme.fg.opacity(0.06)))
        .contentShape(Rectangle())
    }

    private func pill(_ t: String, _ c: Color) -> some View {
        Text(t).font(.caption2.weight(.semibold))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(c.opacity(0.2)))
            .foregroundStyle(c)
    }
}

/// One tab row's contents. It reads block metadata in its own body, so a status change in one tab
/// re-renders only that row, not the whole sidebar.
struct TabRowLabel: View {
    let server: ServerConnection
    let window: WindowInfo
    let textSize: Double
    let theme: TermTheme
    /// Scales the user's sidebar text size with Dynamic Type.
    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

    var body: some View {
        let agent = server.windowAgent(window)
        HStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 5).fill(Self.tint(agent, theme).opacity(0.9))
                Image(systemName: agent?.symbol ?? "terminal")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(theme.bg)
            }
            .frame(width: 18, height: 18)
            Text(WindowTitle.of(window, server: server))
                .font(.system(size: textSize * scale))
                .lineLimit(2)
            Spacer(minLength: 4)
            if window.allBlocks.count > 1 {
                Text("\(window.allBlocks.count)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(theme.chrome.tertiary)
            }
            StatusBadge(status: server.windowStatus(window), theme: theme)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
    }

    static func tint(_ a: AgentKind?, _ theme: TermTheme) -> Color {
        switch a {
        case .claude: return Color(hex: "#d97757")
        case .codex: return theme.fg
        case .gemini: return theme.ansiColor(4)
        case .some: return theme.ansiColor(5)
        case nil: return theme.chrome.secondary
        }
    }
}

enum WindowTitle {
    @MainActor
    static func of(_ w: WindowInfo, server: ServerConnection) -> String {
        let generic = w.label.isEmpty || w.label.hasPrefix("Window ")
        if !generic { return w.label }
        if let f = w.focusedBlockID ?? w.orderedBlockIDs.first, let t = server.meta[f]?.title, !t.isEmpty { return condense(t) }
        return w.block(w.focusedBlockID ?? "")?.label ?? "shell"
    }

    /// Shell titles like "user@host:~/code/project" become "project": the part that tells tabs apart.
    static func condense(_ t: String) -> String {
        let s = t.trimmingCharacters(in: .whitespaces)
        guard let at = s.firstIndex(of: "@"), let colon = s[at...].firstIndex(of: ":"),
              !s[..<at].contains(" ") else { return s }
        let path = s[s.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        if path.isEmpty { return s }
        if path == "~" || path == "/" { return path }
        return path.split(separator: "/").last.map(String.init) ?? path
    }
}
