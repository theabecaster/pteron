import SwiftUI
import RexKit

/// Sessions mode: each machine, its sessions and their tabs, with machines and sessions folding.
/// One flat `ForEach` over `SidebarOutline.rows`, so a fold animates only the rows it removes.
/// Each row is its own equatable view that holds no closures, so a fold or a selection re-renders
/// only the rows whose inputs changed.
struct SessionsList: View {
    @Environment(AppModel.self) private var model
    @Environment(Prefs.self) private var prefs
    let theme: TermTheme
    var onSelect: (Selection) -> Void

    @State private var actions = SidebarActions()
    /// Space above each machine after the first, and above each session after the first in its
    /// machine. Tighter within a group, looser between groups, and both follow Dynamic Type.
    @ScaledMetric(relativeTo: .headline) private var machineGapScaled: CGFloat = 18
    @ScaledMetric(relativeTo: .subheadline) private var sessionGapScaled: CGFloat = 6
    private var machineGap: CGFloat { min(machineGapScaled, 30) }
    private var sessionGap: CGFloat { min(sessionGapScaled, 10) }

    var body: some View {
        // The root's callback changes with the posture (a drawer closes on select, inline stays).
        actions.onSelect = onSelect
        let servers = Dictionary(model.servers.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let collapsed = prefs.sidebarCollapsed
        let rows = SidebarOutline.rows(model.servers.map { s in
            SidebarOutline.Machine(id: s.id, sessions: s.sessions.map { e in
                SidebarOutline.Session(id: e.id, windowIDs: s.views[e.id]?.windows.map(\.id) ?? [])
            })
        }, collapsed: collapsed)
        let notAdded = NotAddedHosts.list(model)
        let selection = model.selection
        return List {
            ForEach(rows) { row in
                if let server = servers[row.kind.serverID] {
                    self.row(row, server, collapsed, selection)
                }
            }
            if !notAdded.isEmpty {
                Text("Not added")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(theme.chrome.tertiary)
                    .padding(.horizontal, SidebarMetrics.pad)
                    .padding(.top, machineGap)
                    .frame(maxWidth: .infinity, minHeight: 28, alignment: .bottomLeading)
                    .accessibilityAddTraits(.isHeader)
                    .modifier(SidebarRowStyle(theme: theme))
                ForEach(notAdded) { h in
                    NotAddedRow(host: h, theme: theme) { NotAddedHosts.add(h, model: model) }
                        .modifier(SidebarRowStyle(theme: theme))
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 30)
        .refreshable { await model.refresh() }
        .onChange(of: PruneKey(model.servers)) { _, _ in prune() }
        #if DEBUG
        .modifier(SidebarFoldBench())
        #endif
        .modifier(SidebarDialogs(actions: actions))
    }

    @ViewBuilder
    private func row(_ row: SidebarOutline.Row, _ server: ServerConnection, _ collapsed: Set<String>,
                     _ selection: Selection?) -> some View {
        // A down server's last known sessions stay listed, dimmed: they open read-only.
        let dim = server.phase.problem != nil
        // List-row traits (insets, background, swipe actions) go outside `.equatable()`: inside an
        // equatable view's body they don't reach the list.
        switch row.kind {
        case .machine(let id):
            MachineRow(server: server, collapsed: collapsed.contains(SidebarCollapse.machine(id)),
                       topGap: row.first ? 4 : machineGap, theme: theme)
                .equatable()
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    Button { Task { await server.createSession(label: nil) } } label: { Label("New Session", systemImage: "plus") }
                        .tint(theme.accent)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button { server.reconnect() } label: { Label("Reconnect", systemImage: "arrow.clockwise") }
                        .tint(theme.chrome.working)
                }
                .modifier(SidebarRowStyle(theme: theme))
        case .session(let id, let sid):
            if let entry = server.sessions.first(where: { $0.id == sid }) {
                let target = SidebarActions.Target(server: server, sessionID: sid, label: entry.label)
                SessionRow(server: server, session: entry, windows: server.views[sid]?.windows ?? [],
                           collapsed: collapsed.contains(SidebarCollapse.session(id, sid)),
                           topGap: server.sessions.first?.id == sid ? 0 : sessionGap, dim: dim,
                           theme: theme, actions: actions)
                    .equatable()
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button { actions.closing = target } label: { Label("Close", systemImage: "xmark") }
                            .tint(theme.chrome.error)
                        Button { actions.rename(target, current: entry.label) } label: { Label("Rename", systemImage: "pencil") }
                            .tint(theme.chrome.secondary)
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button { Task { await server.newWindow(sid) } } label: { Label("New Tab", systemImage: "plus.square") }
                            .tint(theme.accent)
                    }
                    .modifier(SidebarRowStyle(theme: theme))
            }
        case .tab(_, let sid, let wid):
            if let w = server.views[sid]?.window(wid) {
                let selected = selection == Selection(serverID: server.id, sessionID: sid, windowID: wid)
                let target = SidebarActions.Target(server: server, sessionID: sid, windowID: wid, label: w.label)
                TabRow(server: server, sessionID: sid, window: w, last: row.last, selected: selected,
                       dim: dim, theme: theme, actions: actions)
                    .equatable()
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button { actions.closeTab(target, hasAgent: server.windowAgent(w) != nil) } label: {
                            Label("Close", systemImage: "xmark")
                        }
                        .tint(theme.chrome.error)
                        Button { actions.rename(target, current: w.label) } label: { Label("Rename", systemImage: "pencil") }
                            .tint(theme.chrome.secondary)
                    }
                    .modifier(SidebarRowStyle(theme: theme, selected: selected, selectionLeading: SidebarMetrics.tabLeading))
            }
        }
    }

    // MARK: Fold state

    /// Drops fold state for sessions and servers that are gone.
    private func prune() {
        let live = Dictionary(model.servers.filter { $0.phase == .online && $0.synced }.map { ($0.id, $0.sessions.map(\.id)) },
                              uniquingKeysWith: { a, _ in a })
        let kept = SidebarCollapse.pruned(prefs.sidebarCollapsed, servers: model.servers.map(\.id), live: live)
        if kept != prefs.sidebarCollapsed { prefs.sidebarCollapsed = kept }
    }

    /// What pruning depends on: the servers, and the sessions of each connected, synced one.
    private struct PruneKey: Equatable {
        var ids: [UUID]
        var live: [[String]]

        @MainActor init(_ servers: [ServerConnection]) {
            ids = servers.map(\.id)
            live = servers.map { $0.phase == .online && $0.synced ? $0.sessions.map(\.id) : [] }
        }
    }
}

/// What rows ask the list to do: open a tab, or ask before renaming or closing. One object for the
/// list's life, so rows compare equal while it stays the same.
@MainActor
@Observable
final class SidebarActions {
    struct Target: Identifiable {
        var id: String { (windowID ?? "") + sessionID }
        var server: ServerConnection
        var sessionID: String
        var windowID: String?
        var label: String = ""
    }

    @ObservationIgnored var onSelect: (Selection) -> Void = { _ in }
    var renaming: Target?
    var renameText = ""
    var closing: Target?
    /// A tab with an agent in it: closing asks first.
    var closingTab: Target?

    func rename(_ t: Target, current: String) {
        renameText = current
        renaming = t
    }

    /// Destructive: a confirmation when an agent would stop.
    func closeTab(_ t: Target, hasAgent: Bool) {
        guard let w = t.windowID else { return }
        if hasAgent { closingTab = t } else { Task { await t.server.closeWindow(t.sessionID, w) } }
    }
}

/// The rename alert and the close confirmations, driven by `SidebarActions`.
private struct SidebarDialogs: ViewModifier {
    @Bindable var actions: SidebarActions

    func body(content: Content) -> some View {
        content
            .alert("Rename", isPresented: Binding(get: { actions.renaming != nil }, set: { if !$0 { actions.renaming = nil } })) {
                TextField("Name", text: $actions.renameText)
                Button("Cancel", role: .cancel) { actions.renaming = nil }
                Button("Rename") {
                    if let r = actions.renaming {
                        let text = actions.renameText
                        Task {
                            if let w = r.windowID { await r.server.renameWindow(r.sessionID, w, text) }
                            else { await r.server.renameSession(r.sessionID, text) }
                        }
                    }
                    actions.renaming = nil
                }
            }
            .confirmationDialog(actions.closing.map { "Close session “\($0.label.isEmpty ? "session" : $0.label)”?" } ?? "",
                                isPresented: Binding(get: { actions.closing != nil }, set: { if !$0 { actions.closing = nil } }),
                                titleVisibility: .visible) {
                Button("Close Session", role: .destructive) {
                    if let c = actions.closing { Task { await c.server.destroySession(c.sessionID) } }
                    actions.closing = nil
                }
                Button("Cancel", role: .cancel) { actions.closing = nil }
            } message: {
                Text("Every tab in it closes and its programs stop, on the Mac too.")
            }
            .confirmationDialog("Close this tab?",
                                isPresented: Binding(get: { actions.closingTab != nil }, set: { if !$0 { actions.closingTab = nil } }),
                                titleVisibility: .visible) {
                Button("Close Tab", role: .destructive) {
                    if let c = actions.closingTab, let w = c.windowID { Task { await c.server.closeWindow(c.sessionID, w) } }
                    actions.closingTab = nil
                }
                Button("Cancel", role: .cancel) { actions.closingTab = nil }
            } message: {
                Text("The agent running there stops, on the Mac too.")
            }
    }
}

// MARK: - Rows

/// Folds or opens a group, animated, and saves it.
@MainActor
func toggleFold(_ key: String, _ prefs: Prefs) {
    Haptic.selection()
    withAnimation(.snappy(duration: 0.25)) {
        if prefs.sidebarCollapsed.contains(key) { prefs.sidebarCollapsed.remove(key) }
        else { prefs.sidebarCollapsed.insert(key) }
    }
}

struct MachineRow: View, Equatable {
    let server: ServerConnection
    let collapsed: Bool
    let topGap: CGFloat
    let theme: TermTheme
    @Environment(Prefs.self) private var prefs

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.server === b.server && a.collapsed == b.collapsed && a.topGap == b.topGap && a.theme.id == b.theme.id
    }

    var body: some View {
        let server = server
        MachineHeader(server: server, collapsed: collapsed, theme: theme) {
            toggleFold(SidebarCollapse.machine(server.id), prefs)
        }
        .contextMenu {
            Button { Task { await server.createSession(label: nil) } } label: { Label("New Session", systemImage: "plus") }
            Button { server.reconnect() } label: { Label("Reconnect", systemImage: "arrow.clockwise") }
        }
        .padding(.top, topGap)
    }
}

struct SessionRow: View, Equatable {
    let server: ServerConnection
    let session: SessionEntry
    let windows: [WindowInfo]
    let collapsed: Bool
    let topGap: CGFloat
    let dim: Bool
    let theme: TermTheme
    let actions: SidebarActions
    @Environment(Prefs.self) private var prefs

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.server === b.server && a.session == b.session && a.collapsed == b.collapsed && a.topGap == b.topGap
            && a.dim == b.dim && a.theme.id == b.theme.id && a.actions === b.actions
            && a.windows.map(\.id) == b.windows.map(\.id)
            && a.windows.flatMap(\.allBlocks).map(\.id) == b.windows.flatMap(\.allBlocks).map(\.id)
    }

    var body: some View {
        let server = server, s = session, actions = actions
        let target = SidebarActions.Target(server: server, sessionID: s.id, label: s.label)
        let newTab = { Task { await server.newWindow(s.id) } }
        SessionHeader(server: server, session: s, collapsed: collapsed, theme: theme,
                      toggle: { toggleFold(SidebarCollapse.session(server.id, s.id), prefs) },
                      newTab: { _ = newTab() })
            .contextMenu {
                Button { _ = newTab() } label: { Label("New Tab", systemImage: "plus.square") }
                Button { actions.rename(target, current: s.label) } label: { Label("Rename Session", systemImage: "pencil") }
                Button(role: .destructive) { actions.closing = target } label: { Label("Close Session…", systemImage: "xmark") }
            }
            .padding(.top, topGap)
            .opacity(dim ? 0.45 : 1)
    }
}

struct TabRow: View, Equatable {
    let server: ServerConnection
    let sessionID: String
    let window: WindowInfo
    let last: Bool
    let selected: Bool
    let dim: Bool
    let theme: TermTheme
    let actions: SidebarActions
    @Environment(AppModel.self) private var model

    /// What the row shows of its tab; the status comes from the block boxes the label observes.
    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.server === b.server && a.sessionID == b.sessionID && a.last == b.last && a.selected == b.selected
            && a.dim == b.dim && a.theme.id == b.theme.id && a.actions === b.actions
            && a.window.id == b.window.id && a.window.label == b.window.label
            && a.window.focusedBlockID == b.window.focusedBlockID
            && a.window.allBlocks.map(\.id) == b.window.allBlocks.map(\.id)
    }

    var body: some View {
        let server = server, w = window, sid = sessionID, actions = actions
        let target = SidebarActions.Target(server: server, sessionID: sid, windowID: w.id, label: w.label)
        let close = { actions.closeTab(target, hasAgent: server.windowAgent(w) != nil) }
        let rename = { actions.rename(target, current: w.label) }
        Button {
            model.select(server, session: sid, window: w.id)
            actions.onSelect(Selection(serverID: server.id, sessionID: sid, windowID: w.id))
        } label: {
            TabRowLabel(server: server, window: w, textColor: selected ? theme.fg : theme.fg.opacity(0.8),
                        minHeight: 36, theme: theme)
                .padding(.vertical, 2)
                .padding(.leading, SidebarMetrics.tabLeading)
                .background(alignment: .leading) {
                    IndentGuide(last: last, theme: theme)
                        .padding(.leading, SidebarMetrics.guideX)
                }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .contextMenu {
            Button(action: rename) { Label("Rename Tab", systemImage: "pencil") }
            Button { Task { await server.newWindow(sid) } } label: { Label("New Tab", systemImage: "plus.square") }
            Button(role: .destructive, action: close) { Label("Close Tab", systemImage: "xmark") }
        }
        .opacity(dim ? 0.45 : 1)
    }
}

/// Rex's compact row on a plain list: no separators, a rounded selection that can start at an indent.
struct SidebarRowStyle: ViewModifier {
    let theme: TermTheme
    var selected = false
    var selectionLeading: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
            .listRowSeparator(.hidden)
            // Only the selected row draws a shape; the rest stay a plain clear color, cheap to
            // set up when a fold inserts many rows at once.
            .listRowBackground(selected ? AnyView(
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.chrome.rowSelected)
                    .padding(.leading, 6 + selectionLeading)
                    .padding(.trailing, 6)
                    .padding(.vertical, 1)
            ) : AnyView(Color.clear))
    }
}

extension SidebarOutline.Row.Kind {
    var serverID: UUID {
        switch self {
        case .machine(let id), .session(let id, _), .tab(let id, _, _): id
        }
    }
}
