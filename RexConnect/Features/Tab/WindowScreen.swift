import SwiftUI
import RexKit
import UIKit

/// One Rex tab (window), as the Mac app shows it: a thin title bar and the tab's terminal panes.
/// The terminal is the input: tap it and type, with the key bar above the keyboard.
struct WindowScreen: View {
    /// How the tab is placed on screen. Either way, splits show while every pane stays legible;
    /// otherwise one pane at a time, a swipe away from the next.
    enum Mode: Equatable {
        /// Narrow (folded Duo, iPhone portrait): the full window, the sidebar a drawer over it.
        case narrow
        /// Wide, beside the inline sidebar. Partly folded with a horizontal crease (tabletop), the
        /// title bar and panes stay above the crease and the keyboard comes up below it.
        case wide(tabletop: Arrangement.Tabletop? = nil)
    }

    /// A close that needs a second tap because an agent would stop.
    enum Confirm: Identifiable {
        case pane(String), tab
        var id: String { if case .pane(let b) = self { return b } else { return "tab" } }
    }

    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    @Environment(Prefs.self) private var prefs
    @Environment(\.verticalSizeClass) private var vSize
    /// Where the system's vertical bar is, if any: the tab's actions go there as toolbar items.
    @Environment(\.verticalBarEdge) private var barEdge

    let server: ServerConnection
    let sessionID: String
    let windowID: String
    let mode: Mode
    @Binding var sidebarVisible: Bool
    /// Opens another tab (tab overview, title menu, tab swipes, waiting pill).
    var onOpen: (Selection) -> Void = { _ in }

    @State private var renaming = false
    @State private var renameText = ""
    /// Direction of the last pane switch, for the slide transition.
    @State private var forward = true
    @State private var keyboardUp = false
    @State private var showOverview = false
    @State private var confirm: Confirm?
    /// The panes' area with the keyboard down, for the folded legibility check: typing must not
    /// flip splits to one pane.
    @State private var canvasSize: CGSize = .zero

    private var view: SessionView? { server.views[sessionID] }
    private var window: WindowInfo? { view?.window(windowID) }
    /// Zoomed on the phone only (see `PhoneState.zoomed`).
    private var zoomedHere: Bool { PhoneState.shared.zoomed.contains(windowID) }

    var body: some View {
        let theme = prefs.theme(for: scheme)
        VStack(spacing: 0) {
            if let w = window {
                if case .wide(let t?) = mode {
                    // Tabletop: title bar and panes above the crease, read at a distance; the keyboard
                    // comes up below it. The top region gives way only if the keyboard needs it.
                    VStack(spacing: 0) {
                        if showsHeader { header(w, theme) }
                        panes(w, theme)
                    }
                    .frame(maxHeight: t.top)
                    .layoutPriority(1)
                    Color.clear.frame(height: t.gap)
                    Spacer(minLength: 0)
                } else {
                    if showsHeader { header(w, theme) }
                    panes(w, theme)
                }
            } else {
                header(nil, theme)
                VStack(spacing: 10) {
                    Image(systemName: "rectangle.dashed").font(.system(size: 34, weight: .light))
                    Text("This tab closed.").font(.subheadline)
                }
                .foregroundStyle(theme.chrome.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(theme.bg)
            }
        }
        // Edge to edge, under the status bar and the Duo's vertical bar, so system UI sits on the
        // app's chrome. The panes themselves stay inside the safe area.
        .background(theme.chrome.canvas.ignoresSafeArea())
        .toolbar { barItems(theme) }
        .background(CommandListener { handle($0) })
        .alert("Rename Tab", isPresented: $renaming) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { Task { await server.renameWindow(sessionID, windowID, renameText) } }
        }
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                            titleVisibility: .visible, presenting: confirm) { c in
            switch c {
            case .pane(let b):
                Button("Close Pane", role: .destructive) { Task { await server.closeBlock(sessionID, b) } }
            case .tab:
                Button("Close Tab", role: .destructive) { closeTab() }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The agent running there stops, on the Mac too.")
        }
        .fullScreenCover(isPresented: $showOverview) {
            TabOverview(server: server, currentSessionID: sessionID, currentWindowID: windowID) { sel in
                showOverview = false
                onOpen(sel)
            }
            .environment(model)
        }
        // Every frame change, not only "will show": a keyboard can grow from the key bar alone to its
        // full height without showing again, and the panes' layout must not follow it.
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { n in
            let f = (n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect) ?? .zero
            // How much of the screen the keyboard covers: a split or floating keyboard (the unfolded
            // Duo) has another height and place. The key bar alone (hardware keyboard) is shorter.
            let covered = (n.object as? UIScreen).map { f.intersection($0.bounds).height } ?? f.height
            let up = covered > 150
            if up != keyboardUp { keyboardUp = up }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            if keyboardUp { keyboardUp = false }
        }
    }

    private func panes(_ w: WindowInfo, _ theme: TermTheme) -> some View {
        canvas(w, theme)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .onGeometryChange(for: CGSize.self) { $0.size } action: { s in
                if !keyboardUp, s != canvasSize { canvasSize = s }
            }
    }

    /// Under compact height (landscape iPhone, folded Duo on its side) the title bar steps aside while
    /// the keyboard is up, so the terminal keeps its rows. The edge swipe still goes back.
    private var showsHeader: Bool { !(vSize == .compact && keyboardUp) }

    private var confirmTitle: String {
        if case .tab = confirm { return "Close this tab?" }
        return "Close this pane?"
    }

    // MARK: State helpers

    /// Splits as the Mac lays them out would show, zoom aside. Wide (unfolded), always; folded, only
    /// while every pane keeps a legible grid.
    private func splitsFit(_ w: WindowInfo) -> Bool {
        guard let layout = w.layout, w.orderedBlockIDs.count > 1 else { return false }
        guard w.zoomedBlockID == nil else { return false }
        return SplitGeometry.legible(layout.leaves.map(\.rect), canvas: canvasSize, fontSize: prefs.fontSize)
    }

    private func useSplits(_ w: WindowInfo) -> Bool { splitsFit(w) && !zoomedHere }

    /// Zoom means something only while more than one pane is on screen.
    private func canZoom(_ w: WindowInfo) -> Bool { zoomedHere || splitsFit(w) }

    private func activeBlock(_ w: WindowInfo) -> String? {
        if let f = model.focusedPane[w.id], w.allBlocks.contains(where: { $0.id == f }) { return f }
        if let z = w.zoomedBlockID { return z }
        return w.focusedBlockID ?? w.orderedBlockIDs.first
    }

    /// Shows pane `id` with a slide in the direction of travel.
    private func pick(_ w: WindowInfo, _ id: String, forward fw: Bool? = nil) {
        let ids = w.orderedBlockIDs
        guard let cur = activeBlock(w), id != cur else { return }
        forward = fw ?? ((ids.firstIndex(of: id) ?? 0) > (ids.firstIndex(of: cur) ?? 0))
        Haptic.selection()
        withAnimation(.snappy(duration: 0.24)) { model.focusedPane[w.id] = id }
        Task { await server.focus(sessionID, block: id) }
    }

    /// Terminal swipe or pane command: +1 next pane, -1 previous pane. No wrap: at either end, a bump.
    private func switchPane(_ w: WindowInfo, by dir: Int) {
        let ids = w.orderedBlockIDs
        guard let cur = activeBlock(w), let i = ids.firstIndex(of: cur) else { return }
        guard ids.indices.contains(i + dir) else { Haptic.bump(); return }
        pick(w, ids[i + dir], forward: dir > 0)
    }

    private var slide: AnyTransition {
        .asymmetric(insertion: .move(edge: forward ? .trailing : .leading),
                    removal: .move(edge: forward ? .leading : .trailing))
    }

    // MARK: Actions

    private func openOverview() {
        Haptic.tap()
        showOverview = true
    }

    private func rename() {
        renameText = window?.label ?? ""
        renaming = true
    }

    /// Phone-only zoom: show the active pane alone, or go back to splits.
    private func toggleZoom() {
        guard let w = window, canZoom(w) else { Haptic.bump(); return }
        let st = PhoneState.shared
        Haptic.zoom()
        withAnimation(.snappy(duration: 0.25)) {
            if st.zoomed.contains(windowID) {
                st.zoomed.remove(windowID)
            } else {
                if let b = activeBlock(w) { model.focusedPane[w.id] = b }
                st.zoomed.insert(windowID)
            }
        }
    }

    /// Splits `anchor` (default: the active pane), then shows the new pane.
    private func split(vertical: Bool, anchor a: String? = nil) {
        guard let w = window, let anchor = a ?? activeBlock(w) else { return }
        let before = Set(w.orderedBlockIDs)
        let server = server, sid = sessionID, wid = windowID
        Haptic.tap()
        Task {
            await server.split(sid, anchor: anchor, vertical: vertical)
            guard let new = await Poll.until({ server.views[sid]?.window(wid)?.orderedBlockIDs.first { !before.contains($0) } }),
                  let w = window else { return }
            pick(w, new, forward: true)
        }
    }

    /// Opens a tab in this session and shows it once it exists.
    private func newTab() {
        let before = Set(view?.windows.map(\.id) ?? [])
        let server = server, sid = sessionID, open = onOpen
        Haptic.tap()
        Task {
            await server.newWindow(sid)
            if let wid = await Poll.until({ server.views[sid]?.windows.first { !before.contains($0.id) }?.id }) {
                open(Selection(serverID: server.id, sessionID: sid, windowID: wid))
            }
        }
    }

    /// Closing stops whatever runs there; ask first when that's an agent.
    private func requestClose(_ b: String) {
        if server.meta[b]?.agentKind != nil { confirm = .pane(b); return }
        Task { await server.closeBlock(sessionID, b) }
    }

    private func requestCloseTab() {
        if let w = window, server.windowAgent(w) != nil { confirm = .tab; return }
        closeTab()
    }

    /// Closes this tab and shows its neighbor in the session (next, else previous), like Safari.
    private func closeTab() {
        let next = TabNav.neighbor(server, sessionID, windowID, by: 1) ?? TabNav.neighbor(server, sessionID, windowID, by: -1)
        let server = server, sid = sessionID, wid = windowID, open = onOpen
        Task {
            await server.closeWindow(sid, wid)
            if let next, server.views[sid]?.window(next.windowID) != nil { open(next) }
        }
    }

    /// Previous / next tab in this session. No wrap.
    private func switchTab(by d: Int, haptic: Bool = true) {
        guard let sel = TabNav.neighbor(server, sessionID, windowID, by: d) else { Haptic.bump(); return }
        if haptic { Haptic.selection() }
        onOpen(sel)
    }

    /// `goToTab(n)`: the n-th tab of this session, counting from 1; 9 or a negative index (Rex's keymap uses -1) is the last tab.
    private func goToTab(_ n: Int) {
        let ws = view?.windows ?? []
        let i = (n == 9 || n < 0) ? ws.count - 1 : n - 1
        guard ws.indices.contains(i) else { Haptic.bump(); return }
        guard ws[i].id != windowID else { return }
        Haptic.selection()
        onOpen(Selection(serverID: server.id, sessionID: sessionID, windowID: ws[i].id))
    }

    private func jump(_ item: Waiting.Item) {
        onOpen(Waiting.prepare(model, item))
    }

    /// Runs the tab-scoped `RexCommand`s; RootView runs the app-wide ones.
    private func handle(_ r: CommandRequest) {
        guard r.command.isWindowCommand, PhoneState.shared.claim(r) else { return }
        guard let w = window else { return }
        switch r.command {
        case .newTab: newTab()
        case .splitRight: split(vertical: false)
        case .splitDown: split(vertical: true)
        case .closePane: if let b = activeBlock(w) { requestClose(b) }
        case .closeTab: requestCloseTab()
        case .renameTab: rename()
        case .nextTab: switchTab(by: 1)
        case .previousTab: switchTab(by: -1)
        case .goToTab(let n): goToTab(n)
        case .nextPane: switchPane(w, by: 1)
        case .previousPane: switchPane(w, by: -1)
        case .toggleZoom: toggleZoom()
        case .clear: if let b = activeBlock(w) { Task { await server.clear(sessionID, b) } }
        case .tabOverview: openOverview()
        case .newSession, .toggleSidebar, .jumpToWaiting, .fontBigger, .fontSmaller, .fontReset, .settings: break
        }
    }

    // MARK: Title bar

    /// Where the system has a vertical bar, the sidebar toggle and the tab's actions are toolbar items
    /// there (Apple: navigation at the top, then actions, each with a title and a symbol). The title
    /// and status stay in the title bar: text and custom views stay off the vertical axis.
    @ToolbarContentBuilder
    private func barItems(_ theme: TermTheme) -> some ToolbarContent {
        if barEdge != nil, let w = window, let b = activeBlock(w) {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if zoomedHere {
                    Button { toggleZoom() } label: { Label("Unzoom", systemImage: "arrow.down.right.and.arrow.up.left") }
                }
                Button { openOverview() } label: { Label("All Tabs", systemImage: "square.on.square") }
                paneMenu(w, block: b)
            }
        }
    }

    /// Thin, like the Mac's title bar: the sidebar toggle, the tab's title with the shown pane's
    /// status beside it, then the page dots and the pane menu. Where the system has a vertical bar, the buttons are there instead and this keeps the
    /// title and status. Under a short window (landscape iPhone) it is thinner, to leave rows for the
    /// panes.
    private func header(_ w: WindowInfo?, _ theme: TermTheme) -> some View {
        let bar = barEdge != nil
        let short = vSize == .compact
        let height: CGFloat = short ? 34 : 44
        return HStack(spacing: 0) {
            if !bar {
                IconButton(symbol: "sidebar.left", label: sidebarVisible ? "Hide Sidebar" : "Show Sidebar",
                           height: height) { sidebarVisible.toggle() }
            }
            if let w {
                titleBar(w, theme, subtitle: !short)
            } else {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(theme.chrome.tertiary)
                    .padding(.leading, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let w, let b = activeBlock(w) {
                let single = !useSplits(w)
                WaitingPill(visible: single ? [b] : Set(w.orderedBlockIDs), theme: theme, onJump: jump)
                if single, w.orderedBlockIDs.count > 1 {
                    PaneDots(ids: w.orderedBlockIDs, current: b, theme: theme) { switchPane(w, by: $0) }
                }
                if !bar {
                    if zoomedHere { unzoomButton(theme, height: height) }
                    paneMenu(w, block: b)
                        .labelStyle(.iconOnly)
                        .frame(width: 44, height: height)
                        .contentShape(Rectangle())
                }
            }
        }
        .font(.system(size: 17))
        .foregroundStyle(theme.fg)
        .frame(height: height)
        .padding(.leading, bar ? 12 : 4)
        .padding(.trailing, 4)
        .background(theme.chrome.canvas)
        .animation(.snappy(duration: 0.2), value: zoomedHere)
    }

    private func titleBar(_ w: WindowInfo, _ theme: TermTheme, subtitle showsSubtitle: Bool) -> some View {
        TabTitleBar(server: server, sessionID: sessionID, window: w, block: activeBlock(w), subtitle: subtitle, showsSubtitle: showsSubtitle,
                    theme: theme,
                    onSwipe: { switchTab(by: $0, haptic: false) },
                    onPick: { Haptic.selection(); onOpen($0) },
                    onOverview: { openOverview() },
                    onNewTab: { newTab() },
                    onRename: { rename() })
    }

    /// Session name, plus the server's name when more than one server is set up.
    private var subtitle: String {
        let session = view?.label.isEmpty == false ? view!.label : "session"
        return model.servers.count > 1 ? "\(server.config.name) · \(session)" : session
    }

    private func unzoomButton(_ theme: TermTheme, height: CGFloat) -> some View {
        IconButton(symbol: "arrow.down.right.and.arrow.up.left", label: "Unzoom", height: height) { toggleZoom() }
            .foregroundStyle(theme.accent)
            .transition(.scale.combined(with: .opacity))
    }

    private func paneMenu(_ w: WindowInfo, block: String) -> some View {
        Menu {
            Section {
                Button { split(vertical: false) } label: { Label("Split Right", systemImage: "rectangle.split.2x1") }
                Button { split(vertical: true) } label: { Label("Split Down", systemImage: "rectangle.split.1x2") }
                Button { newTab() } label: { Label("New Tab", systemImage: "plus.square") }
                Button { openOverview() } label: { Label("All Tabs", systemImage: "square.on.square") }
            }
            Section {
                if canZoom(w) {
                    Button { toggleZoom() } label: {
                        Label(zoomedHere ? "Unzoom" : "Zoom Pane",
                              systemImage: zoomedHere ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        Text("or tap with two fingers")
                    }
                }
                Button { Task { await server.clear(sessionID, block) } } label: { Label("Clear", systemImage: "eraser") }
                Button { rename() } label: { Label("Rename Tab…", systemImage: "pencil") }
            }
            Section {
                Button(role: .destructive) { requestClose(block) } label: { Label("Close Pane", systemImage: "xmark.square") }
                Button(role: .destructive) { requestCloseTab() } label: { Label("Close Tab", systemImage: "xmark") }
            }
        } label: {
            // Not an ellipsis: Apple keeps that symbol for the system's overflow menu.
            Label("Pane Actions", systemImage: "square.split.2x2")
        }
        .accessibilityLabel("Pane Actions")
    }

    // MARK: Panes

    @ViewBuilder
    private func canvas(_ w: WindowInfo, _ theme: TermTheme) -> some View {
        if !useSplits(w) {
            if let b = activeBlock(w) {
                let rounded = mode != .narrow
                ZStack {
                    PaneView(server: server, sessionID: sessionID, blockID: b, active: true, onFocus: {},
                             onSwipe: { dir in switchPane(w, by: dir) })
                        .id(b)
                        .transition(slide)
                }
                .clipShape(RoundedRectangle(cornerRadius: rounded ? 10 : 0))
                .padding(rounded ? 6 : 0)
            }
        } else if let layout = w.layout {
            let active = activeBlock(w)
            GeometryReader { geo in
                let size = geo.size
                ZStack(alignment: .topLeading) {
                    ForEach(layout.leaves, id: \.id) { leaf in
                        let r = leaf.rect
                        let frame = CGRect(x: r.minX * size.width, y: r.minY * size.height,
                                           width: r.width * size.width, height: r.height * size.height)
                            .insetBy(dx: 3, dy: 3)
                        PaneView(server: server, sessionID: sessionID, blockID: leaf.id, active: leaf.id == active) {
                            model.focusedPane[w.id] = leaf.id
                            Task { await server.focus(sessionID, block: leaf.id) }
                        }
                        .id(leaf.id)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8)
                            .stroke(leaf.id == active ? theme.chrome.activeBorder : theme.chrome.divider, lineWidth: leaf.id == active ? 1.5 : 1))
                        .frame(width: max(frame.width, 10), height: max(frame.height, 10))
                        .offset(x: frame.minX, y: frame.minY)
                    }
                    ForEach(layout.splits, id: \.id) { sp in
                        SplitHandle(split: sp, canvas: size, theme: theme) { ratio in
                            Task { await server.resizePane(sessionID, direction: sp.direction, before: sp.beforeFirst, after: sp.afterFirst, ratio: ratio) }
                        }
                    }
                }
            }
            .padding(3)
        }
    }
}

// MARK: - Observation-scoped pieces

/// The tab's title. Reads block metadata in its own body so title changes don't re-render the screen.
struct TabTitle: View {
    let server: ServerConnection
    let window: WindowInfo
    var body: some View {
        let title = WindowTitle.of(window, server: server)
        Text(title)
            .font(.subheadline.weight(.semibold))
            // One line, like the Mac's title bar. A path keeps both ends; a name keeps its start.
            .lineLimit(1)
            .truncationMode(title.contains("/") ? .middle : .tail)
    }
}

/// A block's status badge, observing only that block. The same glyphs as the sidebar's rows.
struct BlockBadge: View {
    let server: ServerConnection
    let block: String
    let theme: TermTheme
    var body: some View {
        let status = server.meta[block]?.topStatus
        StatusBadge(status: status, theme: theme)
            .accessibilityLabel(Self.spoken(status?.state))
    }

    /// The status as VoiceOver reads it beside the title.
    static func spoken(_ state: String?) -> String {
        switch state {
        case "working": "Working"
        case "blocked": "Waiting for you"
        case "done": "Done"
        case "error": "Error"
        default: ""
        }
    }
}

/// Where the shown pane sits among the tab's panes, when one shows at a time (folded, splits too
/// narrow). A page control, not a status: neutral, in the theme's text colors, the shown pane a
/// short bar. Status lives beside the title, and the waiting pill covers panes out of view.
/// Swipe the terminal to move between them.
struct PaneDots: View {
    let ids: [String]
    let current: String
    let theme: TermTheme
    let onStep: (Int) -> Void

    var body: some View {
        let idx = ids.firstIndex(of: current) ?? 0
        Group {
            if ids.count <= 6 {
                HStack(spacing: 3) {
                    ForEach(ids, id: \.self) { bid in
                        let on = bid == current
                        Capsule()
                            .fill(on ? theme.fg : theme.chrome.tertiary)
                            .frame(width: on ? 9 : 4, height: 4)
                    }
                }
                .animation(.snappy(duration: 0.2), value: idx)
            } else {
                Text("\(idx + 1)/\(ids.count)").font(.caption2.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(theme.chrome.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Pane \(idx + 1) of \(ids.count)")
        .accessibilityHint("Swipe the terminal sideways to change pane.")
        .accessibilityAdjustableAction { d in onStep(d == .increment ? 1 : -1) }
    }
}

// MARK: - Tab overview

/// Every tab on the server as cards with a live text preview, like Safari's tab overview.
struct TabOverview: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(Prefs.self) private var prefs
    @Environment(\.dismiss) private var dismiss
    @Environment(\.division) private var division

    let server: ServerConnection
    let currentSessionID: String
    let currentWindowID: String
    let onOpen: (Selection) -> Void

    var body: some View {
        let theme = prefs.theme(for: scheme)
        let order = server.sessions.filter { $0.id == currentSessionID } + server.sessions.filter { $0.id != currentSessionID }
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18, pinnedViews: []) {
                    ForEach(order) { s in
                        if let v = server.views[s.id] {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(s.label.isEmpty ? "session" : s.label)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(theme.chrome.secondary)
                                    .lineLimit(2)
                                    .padding(.leading, 4)
                                    .padding(.top, 8)
                                LazyVGrid(columns: columns, spacing: 12) {
                                    ForEach(v.windows) { w in
                                        TabCard(server: server, sessionID: s.id, window: w,
                                                selected: w.id == currentWindowID, theme: theme) {
                                            onOpen(Selection(serverID: server.id, sessionID: s.id, windowID: w.id))
                                        }
                                    }
                                    NewTabCard(theme: theme) { newTab(in: s.id) }
                                }
                            }
                        }
                    }
                }
                .padding(14)
            }
            .background(theme.chrome.canvas.ignoresSafeArea())
            .navigationTitle("Tabs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .foregroundStyle(theme.fg)
    }

    /// Across a vertical crease, an even number of columns, so the crease falls between two cards.
    private var columns: [GridItem] {
        guard let d = division, d.isVertical else { return [GridItem(.adaptive(minimum: 150), spacing: 12)] }
        let gap = max(12, d.frame.width + 8)
        return [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: gap),
                GridItem(.flexible(), spacing: 12), GridItem(.flexible())]
    }

    /// Opens a tab in that session and goes straight to it.
    private func newTab(in sid: String) {
        Haptic.tap()
        let before = Set(server.views[sid]?.windows.map(\.id) ?? [])
        let server = server, open = onOpen
        Task {
            await server.newWindow(sid)
            if let wid = await Poll.until({ server.views[sid]?.windows.first { !before.contains($0.id) }?.id }) {
                open(Selection(serverID: server.id, sessionID: sid, windowID: wid))
            }
        }
    }
}

/// The last card of each session in the tab overview, like Safari's.
struct NewTabCard: View {
    let theme: TermTheme
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: "plus").font(.system(size: 26, weight: .light))
                Text("New Tab").font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(theme.accent)
            .frame(maxWidth: .infinity)
            .frame(height: 190)
            .background(RoundedRectangle(cornerRadius: 14).fill(theme.fg.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(theme.chrome.divider, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(PressScale())
        .accessibilityLabel("New Tab")
    }
}

struct TabCard: View {
    let server: ServerConnection
    let sessionID: String
    let window: WindowInfo
    let selected: Bool
    let theme: TermTheme
    let onOpen: () -> Void

    @State private var preview: String?

    private var block: String? { window.focusedBlockID ?? window.orderedBlockIDs.first }

    var body: some View {
        Button(action: onOpen) {
            VStack(spacing: 0) {
                Text(preview ?? " ")
                    .font(.system(size: 7, design: .monospaced))
                    .foregroundStyle(theme.fg.opacity(0.85))
                    .lineLimit(18)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(6)
                    .background(theme.bg)
                    .clipped()
                HStack(spacing: 6) {
                    TabTitle(server: server, window: window)
                    Spacer(minLength: 2)
                    if window.allBlocks.count > 1 {
                        Text("\(window.allBlocks.count)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(theme.chrome.tertiary)
                    }
                    WindowBadge(server: server, window: window, theme: theme)
                }
                .padding(.horizontal, 10)
                .frame(minHeight: 36)
                .background(theme.chrome.sidebar)
            }
            .frame(height: 190)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14)
                .stroke(selected ? theme.accent : theme.chrome.divider, lineWidth: selected ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(PressScale())
        .contextMenu {
            Button(role: .destructive) { Task { await server.closeWindow(sessionID, window.id) } } label: {
                Label("Close Tab", systemImage: "xmark")
            }
        }
        .task(id: block) {
            guard let b = block else { return }
            preview = await server.preview(sessionID, b)
        }
    }
}

/// A tab's combined status, observing only that tab's blocks.
struct WindowBadge: View {
    let server: ServerConnection
    let window: WindowInfo
    let theme: TermTheme
    var body: some View {
        StatusBadge(status: server.windowStatus(window), theme: theme)
    }
}

// MARK: - Small pieces

/// A 44 pt wide icon button for headers and bars, 44 pt tall unless a thin bar asks for less.
struct IconButton: View {
    let symbol: String
    let label: String
    var height: CGFloat = 44
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 44, height: height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(.snappy(duration: 0.12), value: configuration.isPressed)
    }
}

/// System haptics, each used for its documented meaning. iOS mutes them when System Haptics is off.
@MainActor
enum Haptic {
    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let medium = UIImpactFeedbackGenerator(style: .medium)
    private static let rigid = UIImpactFeedbackGenerator(style: .rigid)
    private static let select = UISelectionFeedbackGenerator()
    private static var lastBump = Date.distantPast

    /// A button press.
    static func tap() { light.impactOccurred() }
    /// Something the person set out to do worked: a pairing code read, a server added.
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    /// A value changed: pane, tab, font size, split detent.
    static func selection() { select.selectionChanged() }
    /// A gesture crossed its commit point. Played once, at the threshold.
    static func threshold() { medium.impactOccurred() }
    /// Zoom toggled: the layout snapping into place.
    static func zoom() { medium.impactOccurred() }
    /// Interrupt sent.
    static func interrupt() { rigid.impactOccurred() }
    /// Nothing there (end of panes or tabs). At most once a second.
    static func bump() {
        guard Date().timeIntervalSince(lastBump) > 1 else { return }
        lastBump = Date()
        light.impactOccurred(intensity: 0.6)
    }
}

/// The draggable border between two sides of a split.
struct SplitHandle: View {
    let split: (id: String, direction: String, ratio: Double, rect: CGRect, beforeFirst: String, afterFirst: String)
    let canvas: CGSize
    let theme: TermTheme
    let onCommit: (Double) -> Void
    @State private var drag: CGFloat = 0
    @State private var inDetent = false

    var body: some View {
        let g = SplitGeometry(rect: split.rect, ratio: split.ratio, direction: split.direction, canvas: canvas)
        let horizontal = g.sideBySide
        let len = g.length
        Capsule()
            .fill(drag != 0 ? theme.accent : Color.clear)
            .frame(width: horizontal ? 4 : len * 0.9, height: horizontal ? len * 0.9 : 4)
            .contentShape(Rectangle().inset(by: -20))
            .position(x: g.origin.x + (horizontal ? drag : len / 2), y: g.origin.y + (horizontal ? len / 2 : drag))
            .gesture(DragGesture(minimumDistance: 4)
                .onChanged { v in
                    // A detent at 50%: the split snaps there with a tick, so an even split is easy to hit.
                    let d = g.detent(horizontal ? v.translation.width : v.translation.height)
                    if d.snapped != inDetent {
                        inDetent = d.snapped
                        if d.snapped { Haptic.selection() }
                    }
                    drag = d.offset
                }
                .onEnded { _ in
                    let ratio = g.ratio(after: drag)
                    drag = 0
                    inDetent = false
                    onCommit(ratio)
                })
    }
}
