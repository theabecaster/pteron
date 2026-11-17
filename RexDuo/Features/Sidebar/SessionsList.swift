import SwiftUI
import RexKit

/// Sessions mode: each machine, its sessions and their tabs, with machines and sessions folding.
/// One flat `ForEach` over `SidebarOutline.rows` in a `LazyVStack`, so a fold inserts or removes
/// only its rows and builds only the ones that come into view. Not a `List`: on the device a
/// `List` sizes every visible cell again on each fold, 25 to 40 ms a fold (docs/sidebar.md,
/// Performance). Each row is its own equatable view that holds no closures, so a fold or a
/// selection re-renders only the rows whose inputs changed.
struct SessionsList: View {
    @Environment(AppModel.self) private var model
    @Environment(Prefs.self) private var prefs
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let theme: TermTheme
    /// Where the list was scrolled to, kept by the sidebar across mode switches.
    @Binding var scrollY: CGFloat
    var onSelect: (Selection) -> Void

    @State private var actions = SidebarActions()
    @State private var reveal = SidebarReveal()
    @State private var swipe = SwipeState()
    @State private var position = ScrollPosition(edge: .top)
    @State private var restored = false

    private struct ScrollSpot: Equatable {
        var y: CGFloat
        var room: CGFloat
    }
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
        let target = SidebarOutline.rows(model.servers.map { s in
            SidebarOutline.Machine(id: s.id, sessions: s.sessions.map { e in
                SidebarOutline.Session(id: e.id, windowIDs: s.views[e.id]?.windows.map(\.id) ?? [])
            }, empty: s.phase == .online && s.synced && s.sessions.isEmpty)
        }, collapsed: collapsed)
        let rows = reveal.rows(target, collapsed: collapsed)
        let selection = model.selection
        return ScrollView {
            LazyVStack(spacing: 0) {
                if model.servers.isEmpty {
                    NoServersRow(theme: theme)
                        .modifier(SidebarStackRow(theme: theme))
                }
                ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                    if let server = servers[row.kind.serverID] {
                        self.row(row, server, collapsed, selection)
                            .transition(SidebarMotion.transition(row, reduceMotion: reduceMotion))
                            // Each row is opaque and drawn over the ones above it, so the rows below
                            // a group slide over its rows as they come and go instead of through them.
                            .zIndex(Double(i))
                    }
                }
                // Its own view: the host lists are read there, not on every change to this list.
                NotAddedSection(theme: theme, gap: machineGap)
                    .zIndex(Double(rows.count))
            }
            .padding(.bottom, 8)
        }
        .scrollPosition($position)
        .onScrollGeometryChange(for: ScrollSpot.self) { g in
            ScrollSpot(y: g.contentOffset.y + g.contentInsets.top, room: g.contentSize.height - g.containerSize.height)
        } action: { _, spot in
            // Back from Agents mode: go where the list was once its rows are tall enough, then follow.
            guard restored else {
                guard spot.room >= scrollY else { return }
                restored = true
                if scrollY > 0 { position.scrollTo(y: scrollY) }
                return
            }
            scrollY = spot.y
        }
        .refreshable { await model.refresh() }
        .onChange(of: PruneKey(model.servers), initial: true) { _, _ in prune() }
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
        // Row style and swipe actions go outside `.equatable()`, so a swipe or a selection change
        // doesn't re-render the row's contents.
        switch row.kind {
        case .machine(let id):
            MachineRow(server: server, sessionCount: server.sessions.count,
                       windows: server.sessions.flatMap { server.views[$0.id]?.windows ?? [] },
                       collapsed: collapsed.contains(SidebarCollapse.machine(id)),
                       topGap: row.first ? 4 : machineGap, theme: theme)
                .equatable()
                .modifier(SidebarStackRow(theme: theme))
                .modifier(SidebarSwipe(id: row.id, leading: [
                    SwipeAction(title: "New Session", symbol: "plus", tint: theme.accent) {
                        Task { await server.createSession(label: nil) }
                    },
                ], trailing: [
                    SwipeAction(title: "Reconnect", symbol: "arrow.clockwise", tint: theme.chrome.working) { server.reconnect() },
                ], fullLeading: true, state: swipe))
        case .session(let id, let sid):
            if let entry = server.sessions.first(where: { $0.id == sid }) {
                let target = SidebarActions.Target(server: server, sessionID: sid, label: entry.label)
                SessionRow(server: server, session: entry, windows: server.views[sid]?.windows ?? [],
                           collapsed: collapsed.contains(SidebarCollapse.session(id, sid)),
                           topGap: server.sessions.first?.id == sid ? 0 : sessionGap, dim: dim,
                           theme: theme, actions: actions)
                    .equatable()
                    .modifier(SidebarStackRow(theme: theme))
                    .modifier(SidebarSwipe(id: row.id, leading: [
                        SwipeAction(title: "New Tab", symbol: "plus.square", tint: theme.accent) {
                            Task { await server.newWindow(sid) }
                        },
                    ], trailing: [
                        SwipeAction(title: "Close", symbol: "xmark", tint: theme.chrome.error) { actions.closing = target },
                        SwipeAction(title: "Rename", symbol: "pencil", tint: theme.chrome.secondary) {
                            actions.rename(target, current: entry.label)
                        },
                    ], fullLeading: true, state: swipe))
            }
        case .tab(_, let sid, let wid):
            if let w = server.views[sid]?.window(wid) {
                let selected = selection == Selection(serverID: server.id, sessionID: sid, windowID: wid)
                let target = SidebarActions.Target(server: server, sessionID: sid, windowID: wid, label: w.label)
                TabRow(server: server, sessionID: sid, window: w, selected: selected, dim: dim, theme: theme,
                       actions: actions)
                    .equatable()
                    .modifier(SidebarStackRow(theme: theme, selected: selected, selectionLeading: SidebarMetrics.tabLeading))
                    .modifier(SidebarSwipe(id: row.id, trailing: [
                        SwipeAction(title: "Close", symbol: "xmark", tint: theme.chrome.error) {
                            actions.closeTab(target, hasAgent: server.windowAgent(w) != nil)
                        },
                        SwipeAction(title: "Rename", symbol: "pencil", tint: theme.chrome.secondary) {
                            actions.rename(target, current: w.label)
                        },
                    ], state: swipe))
            }
        case .empty:
            NoSessionsRow(server: server, theme: theme)
                .modifier(SidebarStackRow(theme: theme))
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
    struct PruneKey: Equatable {
        var ids: [UUID]
        var live: [[String]]

        @MainActor init(_ servers: [ServerConnection]) {
            ids = servers.map(\.id)
            live = servers.map { $0.phase == .online && $0.synced ? $0.sessions.map(\.id) : [] }
        }
    }
}

/// Opens a big group a few rows per frame, top first: each frame builds only the rows it adds, and
/// the rows unfurl as a short cascade. After `maxSteps` the rest come at once; by then they are
/// below the screen, so nothing builds them.
@MainActor
@Observable
final class SidebarReveal {
    private var tick = 0
    @ObservationIgnored private var shown: Set<String>?
    @ObservationIgnored private var collapsed: Set<String> = []
    @ObservationIgnored private var steps = 0
    /// A reveal is under way: rows of the target are still held back.
    @ObservationIgnored private var stepping = false
    @ObservationIgnored private var scheduled = false

    /// The rows to show now for `target`. Steps only when the fold state changed, so a server's
    /// first load or a new tab shows at once.
    func rows(_ target: [SidebarOutline.Row], collapsed now: Set<String>) -> [SidebarOutline.Row] {
        _ = tick
        let folding = now != collapsed
        collapsed = now
        if folding { steps = 0 }
        guard let shown, folding || stepping, steps < SidebarMotion.maxSteps else {
            shown = Set(target.map(\.id))
            stepping = false
            return target
        }
        let out = SidebarOutline.stepped(target, shown: shown, adding: SidebarMotion.rowsPerStep)
        self.shown = Set(out.map(\.id))
        steps += 1
        stepping = out.count < target.count
        if stepping, !scheduled {
            scheduled = true
            Task { @MainActor [weak self] in
                // The next frame (one refresh at 120 Hz).
                try? await Task.sleep(nanoseconds: 8_000_000)
                guard let self else { return }
                self.scheduled = false
                withAnimation(SidebarCollapse.animation) { self.tick += 1 }
            }
        }
        return out
    }
}

/// How rows come and go when a group folds: transforms and opacity only, so the GPU does the work.
enum SidebarMotion {
    /// Rows a reveal adds per frame, and how many frames it steps before adding the rest.
    static let rowsPerStep = 3
    static let maxSteps = 10

    /// A header's folded summary and its `+` share a spot: the one leaving fades in 80 ms, the one
    /// coming fades in after it, so they never show over each other.
    static var handoff: AnyTransition {
        .asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.18).delay(0.08)),
                    removal: .opacity.animation(.easeOut(duration: 0.08)))
    }

    /// Opening: a child row slides down a few points from under its header, grows from 97% and fades
    /// in, on the fold's spring. Folding: the reverse, quicker, the lower rows first. Reduce Motion:
    /// a plain fade.
    static func transition(_ row: SidebarOutline.Row, reduceMotion: Bool) -> AnyTransition {
        if reduceMotion { return .opacity }
        if case .machine = row.kind { return .opacity }
        let away = AnyTransition.opacity
            .combined(with: .offset(y: -6))
            .combined(with: .scale(scale: 0.97, anchor: .top))
        // The top rows leave last, 4 ms apart, capped at 32 ms.
        let delay = Double(max(0, 8 - row.index)) * 0.004
        return .asymmetric(insertion: away, removal: away.animation(.snappy(duration: 0.18).delay(delay)))
    }
}

/// A row's insets and selection in the sidebar's stack: 8 pt each side, the sidebar's color behind
/// it (rows cover each other while a group folds), and a rounded highlight that can start at an indent.
struct SidebarStackRow: ViewModifier {
    let theme: TermTheme
    var selected = false
    var selectionLeading: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 8)
            .background {
                ZStack {
                    theme.chrome.sidebar
                    if selected {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(theme.chrome.rowSelected)
                            .padding(.leading, 6 + selectionLeading)
                            .padding(.trailing, 6)
                            .padding(.vertical, 1)
                    }
                }
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
    withAnimation(SidebarCollapse.animation) {
        prefs.sidebarCollapsed = SidebarCollapse.toggled(prefs.sidebarCollapsed, key)
    }
}

struct MachineRow: View, Equatable {
    let server: ServerConnection
    let sessionCount: Int
    let windows: [WindowInfo]
    let collapsed: Bool
    let topGap: CGFloat
    let theme: TermTheme
    @Environment(Prefs.self) private var prefs

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.server === b.server && a.sessionCount == b.sessionCount && a.collapsed == b.collapsed
            && a.topGap == b.topGap && a.theme.id == b.theme.id
            && SidebarRowKeys.windows(a.windows) == SidebarRowKeys.windows(b.windows)
    }

    var body: some View {
        let server = server
        MachineHeader(server: server, windows: windows, sessionCount: sessionCount, collapsed: collapsed, theme: theme) {
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
            && SidebarRowKeys.windows(a.windows) == SidebarRowKeys.windows(b.windows)
    }

    var body: some View {
        let server = server, s = session, actions = actions
        let target = SidebarActions.Target(server: server, sessionID: s.id, label: s.label)
        let newTab = { Task { await server.newWindow(s.id) } }
        SessionHeader(server: server, session: s, windows: windows, collapsed: collapsed, theme: theme,
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
    let selected: Bool
    let dim: Bool
    let theme: TermTheme
    let actions: SidebarActions
    @Environment(AppModel.self) private var model

    /// What the row shows of its tab; the status comes from the block boxes the label observes.
    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.server === b.server && a.sessionID == b.sessionID && a.selected == b.selected
            && a.dim == b.dim && a.theme.id == b.theme.id && a.actions === b.actions
            && SidebarRowKeys.windows([a.window]) == SidebarRowKeys.windows([b.window])
    }

    var body: some View {
        let server = server, w = window, sid = sessionID, actions = actions
        let target = SidebarActions.Target(server: server, sessionID: sid, windowID: w.id, label: w.label)
        let close = { actions.closeTab(target, hasAgent: server.windowAgent(w) != nil) }
        let rename = { actions.rename(target, current: w.label) }
        let open = {
            model.select(server, session: sid, window: w.id)
            actions.onSelect(Selection(serverID: server.id, sessionID: sid, windowID: w.id))
        }
        Button(action: open) {
            TabRowLabel(server: server, window: w, textColor: selected ? theme.fg : theme.fg.opacity(0.8),
                        minHeight: 36, theme: theme)
                .padding(.vertical, 2)
                .padding(.leading, SidebarMetrics.tabLeading)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        // Keyboard: Tab and the arrows move between rows, Return or Space opens the tab.
        .focusable(interactions: .activate)
        .onKeyPress(.return) {
            open()
            return .handled
        }
        .contextMenu {
            Button(action: rename) { Label("Rename Tab", systemImage: "pencil") }
            Button { Task { await server.newWindow(sid) } } label: { Label("New Tab", systemImage: "plus.square") }
            Button(role: .destructive, action: close) { Label("Close Tab", systemImage: "xmark") }
        }
        .opacity(dim ? 0.45 : 1)
    }
}

/// What a row shows of its tabs, for the rows' `==`: ids, names, the focused pane and the panes.
/// Statuses aren't in it: the labels read those from the block boxes themselves.
enum SidebarRowKeys {
    struct Window: Equatable {
        var id: String
        var label: String
        var focused: String?
        var blocks: [String]
    }

    static func windows(_ ws: [WindowInfo]) -> [Window] {
        ws.map { Window(id: $0.id, label: $0.label, focused: $0.focusedBlockID, blocks: $0.allBlocks.map(\.id)) }
    }
}

/// A connected machine without sessions: says so, with New Session.
struct NoSessionsRow: View {
    let server: ServerConnection
    let theme: TermTheme

    var body: some View {
        HStack(spacing: 6) {
            Text("No sessions")
                .font(.subheadline)
                .foregroundStyle(theme.chrome.tertiary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Button { Task { await server.createSession(label: nil) } } label: {
                Text("New Session")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(theme.accent.opacity(0.16)))
                    .foregroundStyle(theme.accent)
                    .frame(minHeight: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("New Session on \(server.config.name)")
        }
        .padding(.leading, SidebarMetrics.sessionLeading)
        .padding(.trailing, SidebarMetrics.pad)
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
    }
}

/// No servers yet: how to add one, in the sidebar too.
struct NoServersRow: View {
    let theme: TermTheme
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("No computers yet. On your computer, run `rex server tailscale pair`, then scan the code it shows.")
                .font(.footnote)
                .foregroundStyle(theme.chrome.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button { model.showPairing = true } label: {
                Label("Pair via QR Code", systemImage: "qrcode.viewfinder")
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, SidebarMetrics.pad)
        .padding(.vertical, 12)
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
        case .machine(let id), .session(let id, _), .tab(let id, _, _), .empty(let id): id
        }
    }
}

