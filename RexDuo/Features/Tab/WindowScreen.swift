import SwiftUI
import RexKit
import UIKit
import TipKit

/// One Rex tab (window): a header, its panes, and a dock with a message composer, pane pager and
/// agent quick replies.
struct WindowScreen: View {
    /// How the tab is placed on screen.
    enum Mode: Equatable {
        /// Folded / regular iPhone: one pane at a time, full-bleed, back button.
        case compact
        /// Beside the sidebar (one page of the unfolded Duo).
        case page
        /// The whole width (sidebar hidden) or the top half in laptop posture.
        case full
        /// Two panes, one per page. `split` is the first page's width (or height when `vertical`).
        case dual(split: CGFloat, vertical: Bool)
    }

    /// A close that needs a second tap because an agent would stop.
    enum Confirm: Identifiable {
        case pane(String), tab
        var id: String { if case .pane(let b) = self { return b } else { return "tab" } }
    }

    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss

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

    private let zoomTip = ZoomGestureTip()

    private var view: SessionView? { server.views[sessionID] }
    private var window: WindowInfo? { view?.window(windowID) }
    /// Zoomed on the phone only (see `PhoneState.zoomed`).
    private var zoomedHere: Bool { PhoneState.shared.zoomed.contains(windowID) }

    var body: some View {
        let theme = ThemeStore.current(scheme)
        VStack(spacing: 0) {
            if let w = window {
                if case .dual(let split, let vertical) = mode, dualShown(w) {
                    dualPages(w, theme, split: split, vertical: vertical)
                } else {
                    header(w, theme)
                    canvas(w, theme)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                    if let b = activeBlock(w) {
                        PaneDock(server: server, sessionID: sessionID, window: w, block: b, keyboardUp: keyboardUp,
                                 actions: actions(w, block: b), splitDownByDefault: mode == .compact, stepIDs: w.orderedBlockIDs,
                                 onPick: { pick(w, $0) }, onStep: { switchPane(w, by: $0) })
                    }
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
        .background(theme.chrome.canvas.ignoresSafeArea(edges: .bottom))
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
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { n in
            let f = (n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect) ?? .zero
            keyboardUp = f.height > 150  // the key bar alone (hardware keyboard) is shorter
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardUp = false
        }
    }

    private var confirmTitle: String {
        if case .tab = confirm { return "Close this tab?" }
        return "Close this pane?"
    }

    // MARK: State helpers

    private var isDual: Bool { if case .dual = mode { return true } else { return false } }

    /// Two panes, one per page, are on screen (not zoomed).
    private func dualShown(_ w: WindowInfo) -> Bool {
        isDual && w.orderedBlockIDs.count >= 2 && !zoomedHere
    }

    /// Splits as the Mac lays them out would show, zoom aside.
    private func splitsFit(_ w: WindowInfo) -> Bool {
        guard w.layout != nil, w.orderedBlockIDs.count > 1 else { return false }
        switch mode {
        case .compact, .dual: return false
        case .page, .full: break
        }
        switch Prefs.shared.wideLayout {
        case .single: return false
        case .splits: return true
        // A single Duo page is too narrow for splits; show them once the tab has the whole width.
        case .auto: return w.zoomedBlockID == nil && mode == .full
        }
    }

    private func useSplits(_ w: WindowInfo) -> Bool { splitsFit(w) && !zoomedHere }

    /// Zoom means something only while more than one pane is on screen.
    private func canZoom(_ w: WindowInfo) -> Bool {
        zoomedHere || (w.orderedBlockIDs.count >= 2 && (isDual || splitsFit(w)))
    }

    private func activeBlock(_ w: WindowInfo) -> String? {
        if let f = model.focusedPane[w.id], w.allBlocks.contains(where: { $0.id == f }) { return f }
        if let z = w.zoomedBlockID { return z }
        return w.focusedBlockID ?? w.orderedBlockIDs.first
    }

    /// The pane commands act on: the active pane, or in two pages the active page's pane.
    private func currentBlock(_ w: WindowInfo) -> String? {
        guard dualShown(w) else { return activeBlock(w) }
        let pair = dualPair(w)
        return activeBlock(w).flatMap { pair.contains($0) ? $0 : nil } ?? pair[0]
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

    /// Terminal or dock swipe: +1 next pane, -1 previous pane. No wrap: at either end, a bump.
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

    private func actions(_ w: WindowInfo, block b: String, page: Int? = nil) -> PaneActions {
        PaneActions(
            split: { split(vertical: $0, anchor: b) },
            newTab: { newTab() },
            zoom: canZoom(w) ? { toggleZoom() } : nil,
            zoomed: zoomedHere,
            swapPages: page.map { p in { if let w = window { setDual(w, page: 1 - p, b) } } },
            clear: { Task { await server.clear(sessionID, b) } },
            renameTab: { rename() },
            close: { requestClose(b) },
            overview: { openOverview() })
    }

    private func openOverview() {
        Haptic.tap()
        showOverview = true
    }

    private func rename() {
        renameText = window?.label ?? ""
        renaming = true
    }

    /// Phone-only zoom: show the active pane alone, or go back to splits / two pages.
    private func toggleZoom() {
        guard let w = window, canZoom(w) else { Haptic.bump(); return }
        let st = PhoneState.shared
        Haptic.zoom()
        withAnimation(.snappy(duration: 0.25)) {
            if st.zoomed.contains(windowID) {
                st.zoomed.remove(windowID)
            } else {
                if let b = currentBlock(w) { model.focusedPane[w.id] = b }
                st.zoomed.insert(windowID)
            }
        }
    }

    /// Splits `anchor` (default: the pane commands act on), then shows the new pane
    /// (on the other page with two pages).
    private func split(vertical: Bool, anchor a: String? = nil) {
        guard let w = window, let anchor = a ?? currentBlock(w) else { return }
        let before = Set(w.orderedBlockIDs)
        let page = dualShown(w) ? dualPair(w).firstIndex(of: anchor) : nil
        let server = server, sid = sessionID, wid = windowID
        Haptic.tap()
        Task {
            await server.split(sid, anchor: anchor, vertical: vertical)
            guard let new = await Poll.until({ server.views[sid]?.window(wid)?.orderedBlockIDs.first { !before.contains($0) } }),
                  let w = window else { return }
            if let page, dualShown(w) { setDual(w, page: 1 - page, new) } else { pick(w, new, forward: true) }
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

    private func stepPane(_ d: Int) {
        guard let w = window else { return }
        if dualShown(w), let b = currentBlock(w), let page = dualPair(w).firstIndex(of: b) {
            cycleDual(w, page: page, by: d)
        } else {
            switchPane(w, by: d)
        }
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
        case .closePane: if let b = currentBlock(w) { requestClose(b) }
        case .closeTab: requestCloseTab()
        case .renameTab: rename()
        case .nextTab: switchTab(by: 1)
        case .previousTab: switchTab(by: -1)
        case .goToTab(let n): goToTab(n)
        case .nextPane: stepPane(1)
        case .previousPane: stepPane(-1)
        case .toggleZoom: toggleZoom()
        case .clear: if let b = currentBlock(w) { Task { await server.clear(sessionID, b) } }
        case .tabOverview: openOverview()
        case .newSession, .toggleSidebar, .jumpToWaiting, .fontBigger, .fontSmaller, .fontReset, .settings: break
        }
    }

    // MARK: Header

    private func header(_ w: WindowInfo?, _ theme: TermTheme) -> some View {
        HStack(spacing: 0) {
            leadingButton()
            if let w {
                titleBar(w, theme)
            } else {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(theme.chrome.tertiary)
                    .padding(.leading, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let w, let b = activeBlock(w) {
                WaitingPill(visible: [b], theme: theme, onJump: jump)
                BlockBadge(server: server, block: b, theme: theme)
                    .padding(.horizontal, 6)
                if zoomedHere { unzoomButton(theme) }
                if mode != .compact, w.orderedBlockIDs.count >= 2 { dualToggle(theme) }
                // Beside the sidebar every tab is already listed; the title menu and a swipe up on
                // the pager still open the overview. Leaves the title room on a 334 pt Duo page.
                if mode != .page { overviewButton }
                paneMenu(w, block: b)
            }
        }
        .font(.system(size: 17))
        .foregroundStyle(theme.fg)
        .frame(minHeight: 44)
        .padding(.horizontal, 4)
        .background(theme.chrome.canvas)
        .animation(.snappy(duration: 0.2), value: zoomedHere)
    }

    private func titleBar(_ w: WindowInfo, _ theme: TermTheme) -> some View {
        TabTitleBar(server: server, sessionID: sessionID, window: w, subtitle: subtitle, theme: theme,
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

    private var overviewButton: some View {
        IconButton(symbol: "square.on.square", label: "All Tabs") { openOverview() }
    }

    private func unzoomButton(_ theme: TermTheme) -> some View {
        IconButton(symbol: "arrow.down.right.and.arrow.up.left", label: "Unzoom") { toggleZoom() }
            .foregroundStyle(theme.accent)
            .transition(.scale.combined(with: .opacity))
    }

    @ViewBuilder
    private func leadingButton() -> some View {
        switch mode {
        case .compact:
            IconButton(symbol: "chevron.left", label: "Back") { dismiss() }
                .fontWeight(.semibold)
        case .dual:
            IconButton(symbol: "sidebar.left", label: "Show Sidebar") {
                withAnimation(.snappy(duration: 0.25)) {
                    model.dualPages = false
                    sidebarVisible = true
                }
            }
        case .page, .full:
            IconButton(symbol: "sidebar.left", label: sidebarVisible ? "Hide Sidebar" : "Show Sidebar") {
                sidebarVisible.toggle()
            }
        }
    }

    private func dualToggle(_ theme: TermTheme) -> some View {
        let on = isDual
        let vertical: Bool = { if case .dual(_, let v) = mode { return v } else { return false } }()
        return IconButton(symbol: vertical ? "rectangle.split.1x2" : "rectangle.split.2x1",
                          label: on ? "One Pane" : "Two Panes, One per Page") {
            Haptic.tap()
            withAnimation(.snappy(duration: 0.25)) { model.dualPages.toggle() }
        }
        .foregroundStyle(on ? theme.accent : theme.fg)
    }

    private func paneMenu(_ w: WindowInfo, block: String) -> some View {
        Menu {
            Section {
                Button { GestureTips.donate(PlusMenuTip.splitFromMenu); split(vertical: false) } label: { Label("Split Right", systemImage: "rectangle.split.2x1") }
                Button { GestureTips.donate(PlusMenuTip.splitFromMenu); split(vertical: true) } label: { Label("Split Down", systemImage: "rectangle.split.1x2") }
                Button { newTab() } label: { Label("New Tab", systemImage: "plus.square") }
            }
            Section {
                if canZoom(w) {
                    Button {
                        if !zoomedHere { GestureTips.donate(ZoomGestureTip.zoomedFromMenu) }
                        toggleZoom()
                    } label: {
                        Label(zoomedHere ? "Unzoom" : "Zoom Pane",
                              systemImage: zoomedHere ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        Text("or tap with two fingers")
                    }
                }
                Button { Task { await server.clear(sessionID, block) } } label: { Label("Clear", systemImage: "eraser") }
                Button {
                    let p = Prefs.shared
                    p.sizing = p.sizing == .fit ? .mirror : .fit
                } label: {
                    Label(Prefs.shared.sizing == .fit ? "Mirror Mac Size" : "Fit to Phone", systemImage: "arrow.up.and.down.and.arrow.left.and.right")
                }
                Button { rename() } label: { Label("Rename Tab…", systemImage: "pencil") }
            }
            Section {
                Button(role: .destructive) { requestClose(block) } label: { Label("Close Pane", systemImage: "xmark.square") }
                Button(role: .destructive) { requestCloseTab() } label: { Label("Close Tab", systemImage: "xmark") }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Pane Actions")
        .popoverTip(zoomTip, arrowEdge: .top)
    }

    // MARK: Canvas

    @ViewBuilder
    private func canvas(_ w: WindowInfo, _ theme: TermTheme) -> some View {
        if !useSplits(w) {
            if let b = activeBlock(w) {
                let rounded = mode != .compact
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

    // MARK: Dual pages (one pane per page)

    private func dualPair(_ w: WindowInfo) -> [String] {
        let ids = w.orderedBlockIDs
        if let p = model.dualPair[w.id], p.count == 2, p[0] != p[1], ids.contains(p[0]), ids.contains(p[1]) { return p }
        let a = activeBlock(w) ?? ids[0]
        let i = ids.firstIndex(of: a) ?? 0
        return i + 1 < ids.count ? [a, ids[i + 1]] : [ids[i - 1], a]
    }

    /// Puts pane `id` on page `page`; picking the pane shown on the other page swaps them.
    private func setDual(_ w: WindowInfo, page: Int, _ id: String, forward fw: Bool = true) {
        var p = dualPair(w)
        guard p[page] != id else { return }
        if p[1 - page] == id { p.swapAt(0, 1) } else { p[page] = id }
        forward = fw
        Haptic.selection()
        withAnimation(.snappy(duration: 0.24)) {
            model.dualPair[w.id] = p
            model.focusedPane[w.id] = id
        }
        Task { await server.focus(sessionID, block: id) }
    }

    /// Swipe on a page: step that page through the panes the other page isn't showing. No wrap.
    private func cycleDual(_ w: WindowInfo, page: Int, by dir: Int) {
        let p = dualPair(w)
        let pool = w.orderedBlockIDs.filter { $0 != p[1 - page] }
        guard let i = pool.firstIndex(of: p[page]) else { return }
        guard pool.indices.contains(i + dir) else { Haptic.bump(); return }
        setDual(w, page: page, pool[i + dir], forward: dir > 0)
    }

    private func dualPages(_ w: WindowInfo, _ theme: TermTheme, split: CGFloat, vertical: Bool) -> some View {
        let pair = dualPair(w)
        let active = activeBlock(w).flatMap { pair.contains($0) ? $0 : nil } ?? pair[0]
        let stack = vertical ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
        return stack {
            dualPage(w, theme, pair: pair, page: 0, active: active)
                .frame(width: vertical ? nil : split, height: vertical ? split : nil)
                .overlay(alignment: vertical ? .bottom : .trailing) {
                    Rectangle().fill(theme.chrome.divider)
                        .frame(width: vertical ? nil : 1, height: vertical ? 1 : nil)
                }
            dualPage(w, theme, pair: pair, page: 1, active: active)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func dualPage(_ w: WindowInfo, _ theme: TermTheme, pair: [String], page: Int, active: String) -> some View {
        let b = pair[page]
        let isActive = b == active
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                if page == 0 { leadingButton() }
                VStack(alignment: .leading, spacing: 1) {
                    PaneName(server: server, window: w, block: b)
                        .font(.subheadline.weight(.semibold))
                    Text(page == 0
                         ? [w.label.isEmpty ? nil : w.label, view?.label].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                         : "Pane \((w.orderedBlockIDs.firstIndex(of: b) ?? 0) + 1) of \(w.orderedBlockIDs.count)")
                        .font(.caption2)
                        .foregroundStyle(theme.chrome.tertiary)
                        .lineLimit(1)
                }
                .padding(.leading, page == 0 ? 2 : 12)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
                .contextMenu { PaneMenuItems(actions: actions(w, block: b, page: page)) }
                if page == 0 { WaitingPill(visible: Set(pair), theme: theme, onJump: jump) }
                BlockBadge(server: server, block: b, theme: theme)
                    .padding(.horizontal, 6)
                if page == 1 {
                    dualToggle(theme)
                    overviewButton
                    paneMenu(w, block: active)
                }
            }
            .font(.system(size: 17))
            .foregroundStyle(theme.fg)
            .frame(minHeight: 44)
            .padding(.horizontal, 4)

            ZStack {
                PaneView(server: server, sessionID: sessionID, blockID: b, active: isActive,
                         onFocus: {
                             guard model.focusedPane[w.id] != b else { return }
                             model.focusedPane[w.id] = b
                             Task { await server.focus(sessionID, block: b) }
                         },
                         onSwipe: { dir in cycleDual(w, page: page, by: dir) })
                    .id(b)
                    .transition(slide)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(isActive ? theme.chrome.activeBorder : theme.chrome.divider, lineWidth: isActive ? 1.5 : 1))
            .padding(4)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            PaneDock(server: server, sessionID: sessionID, window: w, block: b, keyboardUp: keyboardUp,
                     actions: actions(w, block: b, page: page), splitDownByDefault: false,
                     stepIDs: w.orderedBlockIDs.filter { $0 != pair[1 - page] },
                     onPick: { setDual(w, page: page, $0) }, onStep: { cycleDual(w, page: page, by: $0) })
        }
    }
}

// MARK: - Observation-scoped pieces

/// The tab's title. Reads block metadata in its own body so title changes don't re-render the screen.
struct TabTitle: View {
    let server: ServerConnection
    let window: WindowInfo
    var body: some View {
        Text(WindowTitle.of(window, server: server))
            .font(.subheadline.weight(.semibold))
            .lineLimit(2)
    }
}

struct PaneName: View {
    let server: ServerConnection
    let window: WindowInfo
    let block: String
    var body: some View {
        Text(PaneDock.title(server, window, block)).lineLimit(2)
    }
}

/// A block's status badge, observing only that block.
struct BlockBadge: View {
    let server: ServerConnection
    let block: String
    let theme: TermTheme
    var body: some View {
        StatusBadge(status: server.meta[block]?.topStatus, theme: theme)
    }
}

// MARK: - Dock

/// The thumb-reach dock under a pane, like a chat app's input area:
/// - an accessory row: quick replies while the agent is blocked, key chips while composing,
///   otherwise a pager (‹ dots ›, swipe it to change pane) with an interrupt button while an agent works;
/// - a composer that types a message and presses Enter, with a per-pane draft.
/// While the terminal's own keyboard is up, the dock steps aside (except for quick replies).
struct PaneDock: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme

    let server: ServerConnection
    let sessionID: String
    let window: WindowInfo
    let block: String
    let keyboardUp: Bool
    let actions: PaneActions
    /// "+" splits down when folded (one narrow pane), right when unfolded.
    let splitDownByDefault: Bool
    /// The panes the pager steps through.
    let stepIDs: [String]
    let onPick: (String) -> Void
    let onStep: (Int) -> Void

    @State private var text = ""
    @FocusState private var composing: Bool
    private let plusTip = PlusMenuTip()

    static let rowHeight: CGFloat = 48

    var body: some View {
        let theme = ThemeStore.current(scheme)
        let st = server.meta[block]?.topStatus
        let sig = Self.signature(st)
        let dismissed = sig != nil && model.dismissedReplies[block] == sig
        let blocked = st?.state == "blocked" && !dismissed
        let rawKeyboard = keyboardUp && !composing
        VStack(spacing: 0) {
            if blocked || !rawKeyboard {
                Group {
                    if let st, blocked {
                        ViewThatFits(in: .horizontal) {
                            replies(st, theme, caption: true, wideEnter: true)
                            replies(st, theme, caption: false, wideEnter: true)
                            replies(st, theme, caption: false, wideEnter: false)
                        }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    } else if composing {
                        keyChips(theme).transition(.opacity)
                    } else {
                        pager(theme, working: st?.state == "working" && !dismissed, sig: sig).transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: Self.rowHeight)
            }
            if !rawKeyboard { composer(theme) }
        }
        .background(theme.chrome.canvas)
        .overlay(alignment: .top) { Rectangle().fill(theme.chrome.divider).frame(height: 1) }
        .animation(.snappy(duration: 0.2), value: sig)
        .animation(.snappy(duration: 0.2), value: dismissed)
        .animation(.snappy(duration: 0.2), value: composing)
        .onAppear { text = model.drafts[block] ?? "" }
        .onChange(of: block) { old, new in
            model.drafts[old] = text
            text = model.drafts[new] ?? ""
        }
    }

    /// A pane's name: a label the user gave it, else the agent, else the terminal title.
    @MainActor
    static func title(_ server: ServerConnection, _ w: WindowInfo, _ b: String) -> String {
        let l = w.block(b)?.label ?? ""
        if !l.isEmpty, l != "shell" { return l }
        let m = server.meta[b]
        if let a = m?.agentKind { return a.displayName }
        if let t = m?.title, !t.isEmpty { return WindowTitle.condense(t) }
        return l.isEmpty ? "pane" : l
    }

    static func signature(_ st: ProgramStatus?) -> String? {
        guard let st else { return nil }
        return [st.state, st.waitingFor ?? "", st.text ?? "", st.label ?? ""].joined(separator: "|")
    }

    private func send(_ bytes: String) {
        Haptic.tap()
        Task { await server.write(sessionID, block, bytes) }
    }

    /// Stop: a hard, distinct haptic so the user feels it.
    private func interrupt(_ bytes: String) {
        Haptic.interrupt()
        Task { await server.write(sessionID, block, bytes) }
    }

    private func dismiss(_ sig: String?) {
        Haptic.tap()
        model.dismissedReplies[block] = sig
    }

    // MARK: Composer

    private func submit() {
        let t = text
        text = ""
        model.drafts[block] = ""
        Haptic.tap()
        Task { await server.submit(sessionID, block, t) }
    }

    private func composer(_ theme: TermTheme) -> some View {
        let isAgent = server.meta[block]?.agentKind != nil
        return HStack(alignment: .bottom, spacing: 6) {
            TextField(isAgent ? "Message \(Self.title(server, window, block))" : "Command", text: $text, axis: .vertical)
                .font(.body)
                .lineLimit(1...5)
                .textInputAutocapitalization(isAgent ? .sentences : .never)
                .autocorrectionDisabled(!isAgent)
                .focused($composing)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(minHeight: 38)
                .background(RoundedRectangle(cornerRadius: 19).fill(theme.fg.opacity(0.07)))
                .overlay(RoundedRectangle(cornerRadius: 19).stroke(composing ? theme.accent.opacity(0.5) : theme.chrome.divider, lineWidth: 1))
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                .onTapGesture { composing = true }
                .onChange(of: text) { _, new in
                    // Return sends, like a terminal prompt. Pasted multi-line text stays as is.
                    if new.hasSuffix("\n"), !new.dropLast().contains("\n") {
                        text = String(new.dropLast())
                        submit()
                    } else {
                        model.drafts[block] = new
                    }
                }
            Button(action: submit) {
                Image(systemName: text.isEmpty ? "return" : "arrow.up")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(text.isEmpty ? theme.fg : theme.bg)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(text.isEmpty ? theme.fg.opacity(0.1) : theme.accent))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressScale())
            .accessibilityLabel(text.isEmpty ? "Press Enter" : "Send")
        }
        .padding(.leading, 8)
        .padding(.trailing, 2)
        .padding(.vertical, 3)
    }

    private func keyChips(_ theme: TermTheme) -> some View {
        let keys: [(String, String, String)] = [
            ("esc", "\u{1b}", "Escape"), ("tab", "\t", "Tab"), ("↑", "\u{1b}[A", "Up"), ("↓", "\u{1b}[B", "Down"),
            ("^C", "\u{3}", "Control C"), ("⏎", "\r", "Enter"),
        ]
        return HStack(spacing: 6) {
            ForEach(keys, id: \.0) { k in
                key(k.0, theme, tint: theme.accent, small: true) { send(k.1) }
                    .accessibilityLabel("Send \(k.2)")
            }
            Spacer(minLength: 0)
            Button { composing = false } label: {
                Image(systemName: "keyboard.chevron.compact.down")
                    .foregroundStyle(theme.chrome.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Hide Keyboard")
        }
        .padding(.horizontal, 8)
    }

    // MARK: Pager

    private func pager(_ theme: TermTheme, working: Bool, sig: String?) -> some View {
        let step = stepIDs.firstIndex(of: block) ?? 0
        let many = window.orderedBlockIDs.count > 1
        return HStack(spacing: 0) {
            if many {
                chevron("chevron.left", "Previous Pane", enabled: step > 0, theme) { onStep(-1) }
            }
            PagerCenter(server: server, window: window, block: block, stepIDs: stepIDs, theme: theme, actions: actions,
                        onPick: onPick, onStep: onStep, onNewPane: { actions.split(splitDownByDefault) })
            if many {
                chevron("chevron.right", "Next Pane", enabled: step < stepIDs.count - 1, theme) { onStep(1) }
            }
            if working {
                interrupt(theme, sig: sig).transition(.opacity)
            } else {
                newMenu(theme)
            }
        }
        .padding(.horizontal, 2)
    }

    /// Pane arrows dim at either end: paging doesn't wrap.
    private func chevron(_ symbol: String, _ label: String, enabled: Bool, _ theme: TermTheme,
                         action: @escaping () -> Void) -> some View {
        IconButton(symbol: symbol, label: label, action: action)
            .foregroundStyle(enabled ? theme.chrome.secondary : theme.chrome.tertiary.opacity(0.4))
            .disabled(!enabled)
    }

    /// Stop. Tap sends Esc to an agent (Ctrl-C to a shell); touch and hold for the other ways to stop.
    private func interrupt(_ theme: TermTheme, sig: String?) -> some View {
        let agent = server.meta[block]?.agentKind != nil
        return HStack(spacing: 0) {
            Menu {
                Button { interrupt("\u{1b}") } label: { Label("Esc", systemImage: "escape"); Text("Interrupt the agent") }
                Button { interrupt("\u{3}") } label: { Label("Ctrl-C", systemImage: "control") }
                Button(role: .destructive) { interrupt("\u{3}\u{3}") } label: { Label("Ctrl-C Twice", systemImage: "xmark.octagon"); Text("Exits most agents") }
            } label: {
                Text(agent ? "Esc · interrupt" : "^C · interrupt")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.chrome.working)
                    .padding(.leading, 12).padding(.trailing, 4)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            } primaryAction: {
                interrupt(agent ? "\u{1b}" : "\u{3}")
            }
            .accessibilityLabel(agent ? "Interrupt: send Escape" : "Interrupt: send Control C")
            .accessibilityHint("Touch and hold for more ways to stop.")
            Button { dismiss(sig) } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                    .frame(width: 30, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Hide Interrupt")
        }
        .foregroundStyle(theme.chrome.working)
        .background(Capsule().fill(theme.chrome.working.opacity(0.16)).frame(height: 32))
        .fixedSize()
        .padding(.trailing, 4)
    }

    /// "+": tap splits (down when folded, right when unfolded); touch and hold for the menu.
    private func newMenu(_ theme: TermTheme) -> some View {
        Menu {
            Button { actions.split(false) } label: { Label("Split Right", systemImage: "rectangle.split.2x1") }
            Button { actions.split(true) } label: { Label("Split Down", systemImage: "rectangle.split.1x2") }
            Button { actions.newTab() } label: { Label("New Tab", systemImage: "plus.square") }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(theme.chrome.secondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        } primaryAction: {
            actions.split(splitDownByDefault)
        }
        .accessibilityLabel(splitDownByDefault ? "Split Down" : "Split Right")
        .accessibilityHint("Touch and hold for more.")
        .popoverTip(plusTip, arrowEdge: .bottom)
    }

    // MARK: Quick replies

    private func replies(_ st: ProgramStatus, _ theme: TermTheme, caption: Bool, wideEnter: Bool) -> some View {
        let numbers = st.waitingFor == "auth" ? [] : ["1", "2", "3"]
        return HStack(spacing: 6) {
            if caption {
                HStack(spacing: 5) {
                    Image(systemName: "hand.raised.fill").font(.system(size: 12))
                    Text(Self.why(st)).font(.caption.weight(.semibold)).lineLimit(1)
                }
                .foregroundStyle(theme.chrome.blocked)
                .fixedSize()
                .padding(.trailing, 2)
            }
            ForEach(numbers, id: \.self) { n in
                key(n, theme, tint: theme.chrome.blocked) { send(n) }.accessibilityLabel("Send \(n)")
            }
            key(wideEnter ? "⏎ Enter" : "⏎", theme, tint: theme.chrome.blocked, prominent: true) { send("\r") }
                .accessibilityLabel("Send Enter")
            key("Esc", theme, tint: theme.chrome.blocked) { send("\u{1b}") }.accessibilityLabel("Send Escape")
            Button { dismiss(Self.signature(st)) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.chrome.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Hide Quick Replies")
        }
        .padding(.horizontal, 8)
        .fixedSize(horizontal: true, vertical: false)
    }

    private func key(_ title: String, _ theme: TermTheme, tint: Color, prominent: Bool = false, small: Bool = false,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(small ? .subheadline : .callout, design: .monospaced, weight: .semibold))
                .foregroundStyle(theme.fg)
                .padding(.horizontal, small ? 6 : 10)
                .frame(minWidth: 44, minHeight: small ? 36 : 44)
                .background(RoundedRectangle(cornerRadius: 9)
                    .fill(prominent ? tint.opacity(0.22) : theme.fg.opacity(0.08)))
                .overlay(RoundedRectangle(cornerRadius: 9)
                    .stroke(tint.opacity(prominent ? 0.6 : 0.25), lineWidth: 1))
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
    }

    static func why(_ st: ProgramStatus) -> String {
        switch st.waitingFor {
        case "permission": return "Permission"
        case "question": return "Question"
        case "auth": return "Password"
        default: return "Waiting"
        }
    }
}

/// One pager dot. Blocked panes show in the "waiting" color so you can see where to go.
struct PagerDot: View {
    let server: ServerConnection
    let block: String
    let selected: Bool
    let theme: TermTheme
    var body: some View {
        let state = server.meta[block]?.topStatus?.state
        Circle()
            .fill(state == "blocked" ? theme.chrome.blocked : selected ? theme.accent : theme.chrome.tertiary)
            .frame(width: selected ? 7 : 6, height: selected ? 7 : 6)
            .padding(.vertical, 2)
    }
}

// MARK: - Tab overview

/// Every tab on the server as cards with a live text preview, like Safari's tab overview.
struct TabOverview: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss

    let server: ServerConnection
    let currentSessionID: String
    let currentWindowID: String
    let onOpen: (Selection) -> Void

    var body: some View {
        let theme = ThemeStore.current(scheme)
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
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
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

/// A 44 × 44 pt icon button for headers and bars.
struct IconButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 44, height: 44)
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

/// System haptics, each used for its documented meaning. All behind the Haptics setting.
@MainActor
enum Haptic {
    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let medium = UIImpactFeedbackGenerator(style: .medium)
    private static let rigid = UIImpactFeedbackGenerator(style: .rigid)
    private static let select = UISelectionFeedbackGenerator()
    private static var lastBump = Date.distantPast

    private static var on: Bool { Prefs.shared.haptics }

    /// A button press.
    static func tap() { if on { light.impactOccurred() } }
    /// A value changed: pane, tab, font size, split detent.
    static func selection() { if on { select.selectionChanged() } }
    /// A gesture crossed its commit point. Played once, at the threshold.
    static func threshold() { if on { medium.impactOccurred() } }
    /// Zoom toggled: the layout snapping into place.
    static func zoom() { if on { medium.impactOccurred() } }
    /// Interrupt sent.
    static func interrupt() { if on { rigid.impactOccurred() } }
    /// Nothing there (end of panes or tabs). At most once a second.
    static func bump() {
        guard on, Date().timeIntervalSince(lastBump) > 1 else { return }
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
        let r = split.rect
        let horizontal = split.direction != "vertical"  // side by side
        let x = (r.minX + (horizontal ? r.width * split.ratio : 0)) * canvas.width
        let y = (r.minY + (horizontal ? 0 : r.height * split.ratio)) * canvas.height
        let len = (horizontal ? r.height * canvas.height : r.width * canvas.width)
        Capsule()
            .fill(drag != 0 ? theme.accent : Color.clear)
            .frame(width: horizontal ? 4 : len * 0.9, height: horizontal ? len * 0.9 : 4)
            .contentShape(Rectangle().inset(by: -20))
            .position(x: x + (horizontal ? drag : len / 2), y: y + (horizontal ? len / 2 : drag))
            .gesture(DragGesture(minimumDistance: 4)
                .onChanged { v in
                    // A detent at 50%: the split snaps there with a tick, so an even split is easy to hit.
                    let total = max(horizontal ? r.width * canvas.width : r.height * canvas.height, 1)
                    var t = horizontal ? v.translation.width : v.translation.height
                    let snap = abs(split.ratio + t / total - 0.5) < 0.025
                    if snap { t = (0.5 - split.ratio) * total }
                    if snap != inDetent {
                        inDetent = snap
                        if snap { Haptic.selection() }
                    }
                    drag = t
                }
                .onEnded { _ in
                    let total = max(horizontal ? r.width * canvas.width : r.height * canvas.height, 1)
                    let ratio = split.ratio + drag / total
                    drag = 0
                    inDetent = false
                    onCommit(ratio)
                })
    }
}
