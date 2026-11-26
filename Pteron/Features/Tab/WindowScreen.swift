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

    /// A close that needs a second tap because an agent would stop, or that closes several panes.
    enum Confirm: Identifiable {
        case pane(String), tab(CloseTabAsk)
        /// Close Other Panes: exactly these blocks, as the tab held them at the tap.
        case others([String], agent: Bool)
        var id: String {
            switch self {
            case .pane(let b): b
            case .tab: "tab"
            case .others: "others"
            }
        }
    }

    /// A tab Move Pane to Tab… can move the pane to, named as the tab was at the key press.
    struct MoveChoice: Identifiable {
        var id: String
        var name: String
    }

    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    @Environment(Prefs.self) private var prefs
    @Environment(\.verticalSizeClass) private var vSize
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Where the system's vertical bar is, if any: the tab's actions go there as toolbar items.
    @Environment(\.verticalBarEdge) private var barEdge
    /// That bar's column in screen coordinates, for the room it has above the keyboard.
    @Environment(\.verticalBarColumn) private var barColumn
    @Environment(\.division) private var division
    @Environment(\.rootOrigin) private var rootOrigin
    @Environment(\.bookCrease) private var bookCrease
    /// The room the keyboard takes from the root's bottom, for the panes' size with it down.
    @Environment(\.keyboardRoom) private var keyboardRoom
    /// The window's bottom inset, side insets and corners, which say how far the panes run on
    /// past the safe area with the keyboard down (`PaneBottom`).
    @Environment(\.windowBottom) private var windowBottom
    @Environment(TerminalHostPool.self) private var pool: TerminalHostPool?

    let server: ServerConnection
    let sessionID: String
    let windowID: String
    let mode: Mode
    @Binding var sidebarVisible: Bool
    /// Opens another tab (tab overview, title menu, tab swipes, waiting pill).
    var onOpen: (Selection) -> Void = { _ in }
    /// Whether this tab would be in book mode with the sidebar collapsed (`bookFits`).
    var onBookFits: (Bool?) -> Void = { _ in }
    /// Tab mode: what the strip's chips and its session popover ask for (`StripRoutes`).
    var strip: StripRoutes?

    @State private var renaming = false
    @State private var renameText = ""
    /// Direction of the last pane switch, for the slide transition.
    @State private var forward = true
    /// Counts the tab changes a terminal swipe made: each one slides the panes' area out and the
    /// new tab's in (`panes`). Any other tab change leaves it, and cuts as before.
    @State private var tabSlides = 0
    /// The tab change a terminal swipe asked for, until the update after (`crossTab`).
    @State private var tabStep: TabStep?
    @State private var keyboardUp = false
    /// Whether the keyboard is up now, also while the palette holds `keyboardUp`. Not drawn.
    @State private var liveKeyboard = LiveKeyboard()
    @State private var showOverview = false
    @State private var confirm: Confirm?
    /// The confirmation shows from the pane menu in the tab strip, not from the tab (`ask`).
    @State private var confirmInStrip = false
    /// The tab strip holds the pane menu now: tab mode, no vertical bar, and the strip on screen
    /// with room for it.
    @State private var stripMenuShown = false
    /// Move Pane to Tab… from its key: the tabs to pick from.
    @State private var moveChoices: [MoveChoice]?
    /// The panes' area with the keyboard down. For the folded legibility check: typing must not
    /// flip splits to one pane. And for each pane's grid, which stays the one that fits it with
    /// the keyboard down while the keyboard covers it (`PaneLayout`). Worked out each time the
    /// area is measured, from the area and the keyboard's room of that same layout, never kept
    /// from an earlier one: a fold or a rotation with the keyboard up gives the new posture's
    /// panes at once (`PaneLayout.restCanvas`).
    @State private var canvasSize: CGSize = .zero
    /// How far `canvasSize` runs past the safe area, under the home indicator (`PaneBottom.restReach`):
    /// what the floating windows' rest sizes leave out. Measured with it.
    @State private var restReach: CGFloat = 0
    /// Where the panes' area ends, in global coordinates. The sidebar doesn't move it.
    @State private var canvasMaxX: CGFloat?
    /// A floating window a tap raised, drawn in front until the server's view puts it there, for
    /// at most `FloatRaise.hold`, and only on the connection that sent the raise.
    @State private var raised: FloatRaise?

    struct TabStep: Equatable {
        var session: String
        var from: String
        var to: String
        var forward: Bool
        /// Two swipes to the same tab are two steps.
        var token = UUID()
    }

    struct FloatRaise: Equatable {
        static let hold: UInt64 = 1_000_000_000
        var layer: String
        var serial: Int
        var token = UUID()
    }

    private var view: SessionView? { server.views[sessionID] }
    private var window: WindowInfo? { view?.window(windowID) }
    /// Zoomed on the phone only (see `PhoneState.zoomed`).
    private var zoomedHere: Bool { PhoneState.shared.zoomed.contains(windowID) }

    var body: some View {
        #if DEBUG
        let _ = RenderCount.bump(.windowScreens)
        #endif
        let theme = prefs.theme(for: scheme)
        // Nil for every tab without a floating window on screen: those run the code below as before.
        let p = window.flatMap { presentation($0) }
        VStack(spacing: 0) {
            if let w = window {
                if case .wide(let t?) = mode {
                    // Tabletop: title bar and panes above the crease, read at a distance; the keyboard
                    // comes up below it. The top region gives way only if the keyboard needs it.
                    VStack(spacing: 0) {
                        if showsHeader { header(w, theme, p) }
                        panes(w, theme, p)
                    }
                    .frame(maxHeight: t.top)
                    .layoutPriority(1)
                    Color.clear.frame(height: t.gap)
                    Spacer(minLength: 0)
                } else {
                    if showsHeader { header(w, theme, p) }
                    panes(w, theme, p)
                }
            } else {
                header(nil, theme, nil)
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
        // app's chrome. The panes themselves stay inside the safe area, but for its bottom, which
        // they run on into with the keyboard down (`PaneBottom`).
        .background(theme.chrome.canvas.ignoresSafeArea())
        .toolbar { barItems(theme, p) }
        .background(CommandListener { handle($0) })
        .alert("Rename Tab", isPresented: $renaming) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { Task { await server.renameWindow(sessionID, windowID, renameText) } }
        }
        // Tab mode's pane menu in the strip shows it by itself (`confirmInStrip`).
        .confirmationDialog(confirmTitle, isPresented: confirmShown(!confirmInStrip), titleVisibility: .visible,
                            presenting: confirm) { confirmButtons($0) } message: { confirmMessage($0) }
        .confirmationDialog("Move Pane to Tab", isPresented: Binding(get: { moveChoices != nil }, set: { if !$0 { moveChoices = nil } }),
                            titleVisibility: .visible, presenting: moveChoices) { choices in
            ForEach(choices) { c in Button(c.name) { moveToTab(c.id) } }
            Button("Cancel", role: .cancel) {}
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
            liveKeyboard.up = up
            // The palette keeps the tab as it was while it is open (`PadHold`).
            if model.palette.padHold.active { return }
            if up != keyboardUp { keyboardUp = up }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            liveKeyboard.up = false
            if model.palette.padHold.active { return }
            if keyboardUp { keyboardUp = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: PadHold.ended)) { _ in
            if keyboardUp != liveKeyboard.up { keyboardUp = liveKeyboard.up }
        }
        .onChange(of: bookFits, initial: true) { _, fits in onBookFits(fits) }
        .onChange(of: window.flatMap { activeBlock($0) }, initial: true) { _, b in noteTiled(b) }
        // The server's view put the raised float in front: its order holds from here.
        .onChange(of: window?.visibleFloating.last?.id) { _, front in
            if let r = raised, r.layer == front { raised = nil }
        }
        // After the update that gave the slide its direction, so the tab left slides out that way.
        .onChange(of: tabStep) { _, s in if let s { finishTab(s) } }
        #if DEBUG || BENCH
        // `-perfSwitch <n>` (testing): the probe switches panes as a swipe does.
        .onAppear { PerfProbe.active?.setSwitcher { dir in if let w = window { switchPane(w, by: dir) } } }
        // `-echoTest` with `-echoWalk YES` (testing): so does the key-to-echo probe.
        .onAppear { EchoDriver.active?.setSwitcher { dir in if let w = window { switchPane(w, by: dir) } } }
        #endif
        #if DEBUG
        .onAppear { PanesTest.run(panesTestActions) }
        .onAppear { GoToDebug.launch(model) }
        #endif
    }

    private func panes(_ w: WindowInfo, _ theme: TermTheme, _ p: TabPresentation?) -> some View {
        // With the keyboard down the panes' area ignores the bottom safe area and runs on past it
        // as far as the window's corners allow, to the edge where they allow it; with it up it
        // keeps to the safe area and ends at the keyboard's top as before (`PaneBottom`).
        let look = canvasLook(w, p)
        let bottom = PaneBottom(window: windowBottom, keyboardRoom: keyboardRoom,
                                padding: PaneLayout.bottomPadding(splits: look.splits, rounded: mode != .narrow),
                                tolerance: PaneBottom.tolerance(fontSize: prefs.fontSize), reaches: reachesBottom)
        return ZStack {
            canvas(w, theme, p, bottom: bottom)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // The floating windows sit above the tiled panes, a sibling of them, so one coming or
                // going never rebuilds the panes below. Empty in a tab without one. They are chrome:
                // they keep out of the home indicator.
                .overlay(alignment: .topLeading) { floatWindows(w, theme, p).padding(.bottom, bottom.reach) }
                // A terminal swipe into another tab: the tab left slides out as the new one slides
                // in, in the swipe's direction, as a pane swipe does. Nothing else changes it.
                .id(tabSlides)
                .transition(reduceMotion ? .opacity : slide)
        }
            .animation(reduceMotion ? .easeOut(duration: 0.2) : .snappy(duration: 0.24), value: tabSlides)
            .clipped()
            // Narrow: the float sheet, unclipped so its backing runs on under the home indicator.
            // Its floats are chrome as well: their panes keep out of it, as before.
            .overlay(alignment: .topLeading) { sheet(w, theme, p).padding(.bottom, bottom.reach) }
            // Measured again when the inset changes as well: with the keyboard up the area keeps
            // to the safe area, so a fold or a turn that changes only the home indicator's inset
            // leaves its size as it was.
            .onGeometryChange(for: PaneBottom.Measure.self) { PaneBottom.Measure(size: $0.size, restReach: bottom.restReach) }
            action: { m in
                // The room, the inset and the header as this layout had them: read with the size
                // they made.
                let rest = PaneLayout.restCanvas(now: m.size, room: keyboardRoom, home: m.restReach,
                                                 header: showsHeader ? 0 : headerHeight, limit: restLimit)
                if rest != canvasSize { canvasSize = rest }
                if m.restReach != restReach { restReach = m.restReach }
            }
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxX } action: { canvasMaxX = $0 }
            // The part of the bottom inset the corners don't allow, given back.
            .padding(.bottom, bottom.trim)
            // The keyboard's region too: as it goes, SwiftUI keeps it for a layout or two.
            .ignoresSafeArea([.container, .keyboard], edges: bottom.reachesEdge ? .bottom : [])
            // The terminal's color runs on to the window's bottom: no band of chrome under the
            // panes, and the key bar's glass floats on the terminal with the keyboard up.
            .background(theme.bg.ignoresSafeArea(.all, edges: .bottom))
    }

    /// The panes' area is at the bottom of the tab: everywhere but tabletop, where it stays above
    /// the crease.
    private var reachesBottom: Bool {
        if case .wide(_?) = mode { return false }
        return true
    }

    /// Under compact height (landscape iPhone, folded Duo on its side) the title bar steps aside while
    /// the keyboard is up, so the terminal keeps its rows. The edge swipe still goes back.
    private var showsHeader: Bool { !(vSize == .compact && keyboardUp) }

    /// Whether the confirmation shows from here: `here` is where it was asked to show.
    private func confirmShown(_ here: Bool) -> Binding<Bool> {
        Binding(get: { here && confirm != nil }, set: { if !$0 { confirm = nil } })
    }

    /// Puts up a confirmation: from the pane menu while the tab strip holds it, where a tap
    /// opened it, else from the tab.
    private func ask(_ c: Confirm) {
        confirmInStrip = stripMenuShown
        confirm = c
    }

    @ViewBuilder
    private func confirmButtons(_ c: Confirm) -> some View {
        switch c {
        case .pane(let b):
            Button("Close Pane", role: .destructive) { Task { await server.closeBlock(sessionID, b) } }
        case .tab:
            Button("Close Tab", role: .destructive) { closeTab() }
        case .others(let ids, _):
            Button(ids.count == 1 ? "Close Other Pane" : "Close Other Panes", role: .destructive) { closeOthers(ids) }
        }
        Button("Cancel", role: .cancel) {}
    }

    @ViewBuilder
    private func confirmMessage(_ c: Confirm) -> some View {
        switch c {
        case .others(_, agent: false): EmptyView()
        case .others: Text("The agents running there stop on \(server.config.name) too.")
        case .tab(let ask): Text(ask.message(computer: server.config.name))
        default: Text("The agent running there stops on \(server.config.name) too.")
        }
    }

    /// Tabletop: the panes stay above the crease, so with the keyboard down they are no taller
    /// than the region there leaves them.
    private var restLimit: CGFloat {
        guard case .wide(let t?) = mode else { return .infinity }
        return t.top - (showsHeader ? headerHeight : 0)
    }

    /// The header's height: the title bar's, or the strip's in tab mode.
    private var headerHeight: CGFloat { prefs.navigation == .tabs ? barHeight : titleBarHeight }

    private var confirmTitle: String {
        switch confirm {
        case .tab: return CloseTabAsk.title
        case .others(let ids, _): return ids.count == 1 ? "Close 1 other pane?" : "Close \(ids.count) other panes?"
        default: return "Close this pane?"
        }
    }

    // MARK: State helpers

    /// Splits as the Mac lays them out would show, zoom aside. Wide (unfolded), always; folded, only
    /// while every pane keeps a legible grid.
    private func splitsFit(_ w: WindowInfo) -> Bool {
        guard let layout = w.layout, w.pageBlockIDs.count > 1 else { return false }
        guard w.zoomedBlockID == nil else { return false }
        return SplitGeometry.legible(layout.leaves.map(\.rect), canvas: legibleCanvas, fontSize: prefs.fontSize)
    }

    /// The keyboard-down canvas inside the bottom safe area, as main measured it: what the
    /// legibility decisions read (`PaneBottom.inside`). Only the drawn panes run on to the edge.
    private var legibleCanvas: CGSize { PaneBottom.inside(canvasSize, restReach: restReach) }

    private func useSplits(_ w: WindowInfo) -> Bool { splitsFit(w) && !zoomedHere }

    /// How a tab with a floating window on screen is shown; nil for every other tab, which the
    /// functions above lay out as before.
    private func presentation(_ w: WindowInfo) -> TabPresentation? {
        guard !w.visibleFloating.isEmpty else { return nil }
        return TabPresentation.decide(.init(window: w, narrow: mode == .narrow, zoomed: w.zoomedBlockID != nil || zoomedHere,
                                            active: activeBlock(w), canvas: legibleCanvas, fontSize: prefs.fontSize,
                                            crease: floatCrease, front: frontOverride,
                                            tiledShown: PhoneState.shared.sheets[windowID]?.tiled))
    }

    /// A float the phone raised, until the server's view or time takes over. Another connection's
    /// views set the order alone.
    private var frontOverride: String? {
        guard let r = raised, r.serial == server.connectionSerial else { return nil }
        return r.layer
    }

    /// The crease the floats keep clear of, in the splits' area, from the keyboard-down canvas.
    private var floatCrease: FloatLayout.Crease? {
        guard let canvasMaxX, canvasSize.width > 0 else { return nil }
        let pad = PaneLayout.splitPadding
        return FloatLayout.crease(bookCrease, areaMinX: canvasMaxX - canvasSize.width + pad - rootOrigin.x,
                                  areaWidth: canvasSize.width - pad * 2)
    }

    /// Whether this tab, with the fold bent as it is now, would be in book mode if the sidebar
    /// were collapsed (`BookSidebar`). Nil until the tab is measured. Floats on screen don't
    /// change the answer: it is about the tiled splits under them, which beside the sidebar may
    /// show as pages and as splits once it collapses.
    private var bookFits: Bool? {
        guard let w = window, canvasSize != .zero, let canvasMaxX else { return nil }
        // Zoom aside, as `splitsFit`; beside the sidebar the splits may be too narrow to show.
        guard w.pageBlockIDs.count > 1, w.zoomedBlockID == nil, !zoomedHere else { return false }
        // A split whose layout hasn't arrived yet isn't measured.
        guard let layout = w.layout else { return nil }
        // Collapsed, the panes' area runs from the root's leading edge to where it ends now.
        return BookSplit.fitsCollapsed(leaves: layout.leaves.map(\.rect), splits: layout.splits,
                                       canvas: CGSize(width: canvasMaxX - rootOrigin.x, height: legibleCanvas.height),
                                       crease: CreaseSettle.live(division), fontSize: prefs.fontSize)
    }

    /// Zoom means something only while more than one pane is on screen.
    private func canZoom(_ w: WindowInfo) -> Bool { canZoom(w, presentation(w)) }

    private func canZoom(_ w: WindowInfo, _ p: TabPresentation?) -> Bool {
        zoomedHere || (p.map(\.canZoom) ?? splitsFit(w))
    }

    private func activeBlock(_ w: WindowInfo) -> String? { ActivePane.of(w, phone: model.focusedPane[w.id]) }

    /// Shows pane `id` with a slide in the direction of travel.
    private func pick(_ w: WindowInfo, _ id: String, forward fw: Bool? = nil) {
        let ids = w.pageBlockIDs
        guard let cur = activeBlock(w), id != cur else { return }
        forward = fw ?? ((ids.firstIndex(of: id) ?? 0) > (ids.firstIndex(of: cur) ?? 0))
        Haptic.selection()
        withAnimation(.snappy(duration: 0.24)) { model.focusedPane[w.id] = id }
        // A floating window on screen comes to the front as a tap brings it.
        if case .floating? = presentation(w), w.floatingLayer(of: id) != nil {
            tapFloat(id)
            return
        }
        Task { await server.focus(sessionID, block: id) }
    }

    /// Terminal swipe or pane command: +1 next pane, -1 previous pane. No wrap: at either end, a bump.
    /// Under the float sheet, from the pane swiped (`from`, else the active one) among its own
    /// group: the tiled panes, or the float's (`FloatSheet.group`).
    private func switchPane(_ w: WindowInfo, by dir: Int, from: String? = nil) {
        guard let cur = from ?? activeBlock(w) else { return }
        let ids = paneGroup(w, from: cur)
        guard let i = ids.firstIndex(of: cur) else { return }
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
    private func split(vertical: Bool, before: Bool = false, anchor a: String? = nil) {
        guard let w = window, let anchor = a ?? activeBlock(w) else { return }
        let existing = Set(w.orderedBlockIDs)
        let server = server, sid = sessionID, wid = windowID
        Haptic.tap()
        Task {
            await server.split(sid, anchor: anchor, vertical: vertical, before: before)
            guard let new = await Poll.until({ server.views[sid]?.window(wid)?.orderedBlockIDs.first { !existing.contains($0) } }),
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
        if server.meta[b]?.agentKind != nil { ask(.pane(b)); return }
        Task { await server.closeBlock(sessionID, b) }
    }

    private func requestCloseTab() {
        if let w = window, let ask = CloseTabAsk.decide(panes: w.allBlocks.count, agent: server.windowAgent(w) != nil) {
            self.ask(.tab(ask))
            return
        }
        closeTab()
    }

    /// Closes this tab. The model then shows the tab viewed before it, else its neighbour, as it
    /// does whenever the tab on screen closes (`CloseNext`).
    private func closeTab() {
        let server = server, sid = sessionID, wid = windowID, model = model
        Task {
            guard await server.closeWindow(sid, wid) else { return }
            model.closedTab(Selection(serverID: server.id, sessionID: sid, windowID: wid))
        }
    }

    /// A sideways swipe on tiled pane `b` of a tab without a float on screen: the next or previous
    /// pane while the tab pages its panes (`paged`), and past either end, or in a tab that doesn't
    /// page (one pane, splits), the next or previous tab of the session, round from the last to
    /// the first (`TabNav.step`). Read from the model, not from this screen's values: a pane
    /// still sliding out belongs to a tab no longer on screen, and its swipe does nothing.
    private func swipe(from b: String, by dir: Int, paged: Bool) {
        guard model.selection?.serverID == server.id, let sel = model.selection,
              let w = server.views[sel.sessionID]?.window(sel.windowID), w.block(b) != nil,
              w.visibleFloating.isEmpty else { return }
        switch TabNav.step(pages: paged ? w.pageBlockIDs : [], from: b, by: dir) {
        case .pane(let id): pick(w, id, forward: dir > 0)
        case .tab: crossTab(from: w, in: sel.sessionID, by: dir)
        }
    }

    /// The tab a swipe goes on to, round from the last to the first, with the same haptic as a
    /// pane swipe; a bump in a session with one tab. The slide takes the swipe's direction first,
    /// and the tab changes in the update after (`finishTab`), so the tab left slides out that way.
    private func crossTab(from w: WindowInfo, in sid: String, by dir: Int) {
        let order = server.views[sid]?.windows.map(\.id) ?? []
        guard let next = TabNav.wrapped(order, from: w.id, by: dir) else { Haptic.bump(); return }
        Haptic.selection()
        forward = dir > 0
        tabStep = TabStep(session: sid, from: w.id, to: next, forward: dir > 0)
    }

    /// Opens the tab a swipe asked for, if nothing moved on meanwhile. A tab that pages its panes
    /// shows its first pane going forward and its last going back, on the phone only: the Mac
    /// hears the tab change alone, as for any tab change, and its focus stays where it was.
    private func finishTab(_ s: TabStep) {
        tabStep = nil
        guard model.selection == Selection(serverID: server.id, sessionID: s.session, windowID: s.from),
              let tw = server.views[s.session]?.window(s.to) else { return }
        if pagesPanes(tw), let land = TabNav.landing(pages: tw.pageBlockIDs, forward: s.forward), land != activeBlock(tw) {
            model.focusedPane[tw.id] = land
        }
        tabSlides += 1
        onOpen(Selection(serverID: server.id, sessionID: s.session, windowID: s.to))
    }

    /// Whether tab `w` shows one pane at a time with a swipe between them, as this screen would
    /// show it: no float on screen, and splits that don't fit or a tab zoomed on the phone.
    private func pagesPanes(_ w: WindowInfo) -> Bool {
        w.visibleFloating.isEmpty && w.pageBlockIDs.count > 1 && !(splitsFit(w) && !PhoneState.shared.zoomed.contains(w.id))
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

    // MARK: Arrange

    #if DEBUG
    /// `-panesTest`: the same paths as the menu items and keys, for the simulator.
    private var panesTestActions: PanesTest.Actions {
        let server = server, sid = sessionID, wid = windowID
        return PanesTest.Actions(
            swapNext: {
                guard let w = window, let b = activeBlock(w) else { return }
                let ids = PaneScope.arrangeable(window: w)
                guard let i = ids.firstIndex(of: b) else { return }
                swap(with: ids[(i + 1) % ids.count])
            },
            moveTo: { n in
                let ws = view?.windows ?? []
                if ws.indices.contains(n - 1) { moveToTab(ws[n - 1].id) }
            },
            newTab: { moveToNewTab() },
            balance: { balance() },
            closeOthers: {
                guard let t = arrangeTarget(.closeOthers) else { return }
                closeOthers(PaneScope.arrangeable(window: t.window).filter { $0 != t.block })
            },
            moveTab: { moveTab(by: $0) },
            dragTab: { gap in
                if let m = TabOrder.before(server.orderedWindowIDs(sid), moving: wid, gap: gap) { server.dragTab(sid, wid, m) }
            },
            dragSession: { gap in
                if let m = TabOrder.before(server.orderedSessions.map(\.id), moving: sid, gap: gap) { server.dragSession(sid, order: m.order) }
            },
            tapFloat: { n in
                guard let w = window, w.visibleFloating.indices.contains(n - 1),
                      let b = w.visibleFloating[n - 1].layout?.leaves.first?.id else { return }
                tapFloat(b)
            },
            minimize: { minimizeFloat() },
            minimizeAll: { minimizeAllFloats() },
            restore: {
                if let l = window?.minimizedFloating.first { restoreFloat(l.id) }
            },
            sheet: { verb in sheetTest(verb) },
            // The tab on screen now, which may be another than this screen's first.
            swipe: { [model] d in
                guard let sel = model.selection, let w = server.views[sel.sessionID]?.window(sel.windowID),
                      let b = activeBlock(w) else { return }
                swipe(from: b, by: d, paged: pagesPanes(w))
            },
            state: { [model] in
                let shownTab = model.selection.flatMap { server.views[$0.sessionID]?.window($0.windowID) }
                return PanesTest.describe(server.views[sid], current: model.selection?.windowID ?? "")
                    + " shown=" + (shownTab.flatMap { activeBlock($0) }.map { String($0.suffix(4)) } ?? "-")
                    + " macFocus=" + (shownTab?.focusedBlockID.map { String($0.suffix(4)) } ?? "-")
                    + " sheet=" + (window.flatMap { sheetLayer(presentation($0)) }.map { String($0.suffix(4)) } ?? "-")
                    + "/" + (PhoneState.shared.sheets[wid]?.detent == .medium ? "medium" : "large")
                    + " sessions=" + server.orderedSessions.map { $0.label }.joined(separator: ",")
            })
    }
    #endif

    /// The active pane, if the command applies to it now. Checked at the tap or key press, so a
    /// menu opened before a reconnect to an older server sends nothing.
    private func arrangeTarget(_ c: PaneCommand) -> PaneTarget? {
        guard let w = window, let b = activeBlock(w) else { return nil }
        let t = PaneTarget(window: w, block: b, tabs: view?.windows ?? [w])
        return PaneArrange.isAvailable(c, target: t, support: server.capabilities.paneSupport) ? t : nil
    }

    /// Swap With: the two panes trade places. The pane on screen stays the one shown.
    private func swap(with other: String) {
        guard let t = arrangeTarget(.swap), t.window.block(other) != nil else { Haptic.bump(); return }
        Haptic.tap()
        let server = server, sid = sessionID, b = t.block
        Task { await server.swapBlocks(sid, b, other) }
    }

    /// Move to Tab: beside the target tab's focused (else first) tiled pane, then that tab opens
    /// once its view holds the pane.
    private func moveToTab(_ target: String) {
        guard let t = arrangeTarget(.moveToTab), let tw = view?.window(target), let anchor = MoveAnchor.pick(window: tw) else {
            Haptic.bump()
            return
        }
        Haptic.tap()
        let server = server, sid = sessionID, b = t.block
        let all = t.tabs.map(\.id)
        let name = PaneMenuModel.tabRow(tw, position: (all.firstIndex(of: target) ?? 0) + 1, server: server).name
        Task {
            guard await server.moveBlock(sid, b, anchor: anchor.block, direction: anchor.direction) else { return }
            await server.reloadView(sid)
            Self.dropZoom(server, sid, t.window.id)
            await follow(b, to: target, from: t.window.id, name: name)
        }
    }

    /// Move to New Tab: the pane gets a tab of its own, right after this one.
    private func moveToNewTab() {
        guard let t = arrangeTarget(.moveToNewTab) else { Haptic.bump(); return }
        Haptic.tap()
        let server = server, sid = sessionID, b = t.block
        Task {
            guard let tab = await server.moveToNewTab(sid, block: b, source: t.window.id) else { return }
            Self.dropZoom(server, sid, t.window.id)
            await follow(b, to: tab, from: t.window.id, name: "a new tab")
        }
    }

    /// Opens the tab a pane moved to, in the same update as the layout that holds it, so the pane's
    /// terminal carries over. If the views don't show it there within 2 s, this tab stays; with this
    /// tab gone too, a notice says where the pane went.
    private func follow(_ b: String, to target: String, from source: String, name: String) async {
        let server = server, sid = sessionID, open = onOpen, model = model
        let sel = Selection(serverID: server.id, sessionID: sid, windowID: target)
        let there: @MainActor (SessionView) -> Bool = { $0.window(target)?.block(b) != nil }
        if let v = server.views[sid], there(v) {
            model.focusedPane[target] = b
            open(sel)
            return
        }
        if await server.awaitView(sid, timeout: 2, there) {
            model.focusedPane[target] = b
            open(sel)
        } else if server.views[sid]?.window(source) == nil {
            Notice.shared.show("Moved the pane to \(name).", style: .neutral,
                               action: Notice.Action(title: "Show") { open(sel) })
        }
    }

    /// Balance Splits: every split even, in one go.
    private func balance() {
        guard let t = arrangeTarget(.balance), let layout = t.window.layout else { Haptic.bump(); return }
        let changes = SplitBalance.ratios(layout)
        guard !changes.isEmpty else { Haptic.bump(); return }
        Haptic.zoom()
        let server = server, sid = sessionID
        Task { await server.balance(sid, changes) }
    }

    /// Close Other Panes…: always asks, with the panes and whether an agent runs in one worked
    /// out now, so the dialog reads nothing later.
    private func requestCloseOthers() {
        guard let t = arrangeTarget(.closeOthers) else { Haptic.bump(); return }
        let ids = PaneScope.arrangeable(window: t.window).filter { $0 != t.block }
        guard !ids.isEmpty else { Haptic.bump(); return }
        ask(.others(ids, agent: ids.contains { server.meta[$0]?.agentKind != nil }))
    }

    private func closeOthers(_ ids: [String]) {
        guard server.capabilities.paneSupport.has(.closeOthers) else { Haptic.bump(); return }
        let server = server, sid = sessionID
        // One pane is left: phone zoom means nothing there.
        PhoneState.shared.zoomed.remove(windowID)
        Task { await server.closeBlocks(sid, ids) }
    }

    /// A tab a pane left keeps the phone's zoom only while it still has several panes.
    private static func dropZoom(_ server: ServerConnection, _ sid: String, _ wid: String) {
        let left = server.views[sid]?.window(wid).map { PaneScope.arrangeable(window: $0).count } ?? 0
        if left <= 1, PhoneState.shared.zoomed.contains(wid) { PhoneState.shared.zoomed.remove(wid) }
    }

    /// Move Pane to Tab… from its key: the session's other tabs to pick from.
    private func chooseMoveTarget() {
        guard let t = arrangeTarget(.moveToTab) else { Haptic.bump(); return }
        let all = t.tabs.map(\.id)
        moveChoices = MoveAnchor.targets(from: t.window.id, in: t.tabs).map { w in
            let r = PaneMenuModel.tabRow(w, position: (all.firstIndex(of: w.id) ?? 0) + 1, server: server)
            return MoveChoice(id: w.id, name: [r.name, r.subtitle].compactMap { $0 }.joined(separator: " · "))
        }
    }

    /// `client.tab.move.*`: this tab one place forward or back among the session's tabs.
    private func moveTab(by d: Int) {
        guard let t = arrangeTarget(.moveTab), let move = TabOrder.step(t.tabs.map(\.id), moving: windowID, by: d) else {
            Haptic.bump()
            return
        }
        Haptic.selection()
        let server = server, sid = sessionID, wid = windowID
        Task { await server.moveWindow(sid, wid, before: move.before) }
    }

    // MARK: Floating windows

    /// A tap (or a long press, a two-finger tap, a pointer drag) on a floating pane: it becomes
    /// the active pane, and the server hears only what changed (`FloatTap`). A raise shows at once
    /// and holds until the server's view agrees, at most `FloatRaise.hold`.
    private func tapFloat(_ block: String) {
        guard let w = window else { return }
        if model.focusedPane[w.id] != block { model.focusedPane[w.id] = block }
        let canRaise = server.capabilities.paneSupport.has(.raise)
        let front = frontOverride ?? w.visibleFloating.last?.id
        let server = server, sid = sessionID
        let decision = FloatTap.decide(window: w, block: block, front: front, canRaise: canRaise)
        #if DEBUG
        NSLog("FLOATS_TAP %@ %@", String(block.suffix(4)), String(describing: decision))
        #endif
        switch decision {
        case .none:
            return
        case .focus:
            Task { await server.focus(sid, block: block) }
        case .raise(let focusBlock):
            guard let layer = w.floatingLayer(of: block)?.id else { return }
            hold(raised: layer)
            Task { await server.raiseFloat(sid, layer, focus: focusBlock ? block : nil) }
        }
    }

    private func hold(raised layer: String) {
        let r = FloatRaise(layer: layer, serial: server.connectionSerial)
        raised = r
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: FloatRaise.hold)
            if raised?.token == r.token { raised = nil }
        }
    }

    /// Minimize: the active pane's floating window, where the tab keeps a pane on screen.
    private func minimizeFloat() {
        guard let t = arrangeTarget(.minimize), let layer = FloatArrange.minimizable(t.window, block: t.block) else {
            Haptic.bump()
            return
        }
        Haptic.tap()
        let server = server, sid = sessionID, id = layer.id
        Task { await server.minimizeFloat(sid, id) }
    }

    /// `pane.minimize_all_floating`: every floating window the tab can spare, in one turn.
    private func minimizeAllFloats() {
        guard let t = arrangeTarget(.minimizeAll) else { Haptic.bump(); return }
        let layers = FloatArrange.minimizeAll(t.window)
        Haptic.tap()
        let server = server, sid = sessionID
        Task { await server.minimizeFloats(sid, layers) }
    }

    /// A minimized floating window's row: it shows again, in front, with its pane active.
    private func restoreFloat(_ layer: String) {
        guard let t = arrangeTarget(.restore), let l = t.window.minimizedFloating.first(where: { $0.id == layer }) else {
            Haptic.bump()
            return
        }
        Haptic.tap()
        if let b = l.layout?.leaves.first?.id ?? l.blocks.first?.id { model.focusedPane[t.window.id] = b }
        hold(raised: layer)
        let server = server, sid = sessionID
        Task { await server.restoreFloat(sid, layer) }
    }

    // MARK: Float sheet (narrow)

    /// The panes a swipe or Next Pane walks from `block`: under the float sheet its own group
    /// (`FloatSheet.group`), else every page.
    private func paneGroup(_ w: WindowInfo, from block: String) -> [String] {
        if case .floatSheet? = presentation(w) { return FloatSheet.group(w, from: block) }
        return w.pageBlockIDs
    }

    /// The layer in the sheet, while it shows.
    private func sheetLayer(_ p: TabPresentation?) -> String? {
        if case .floatSheet(let s)? = p { return s.shown?.layer }
        return nil
    }

    /// Keeps the tiled pane last active, which stays shown under the sheet. Only a narrow tab
    /// with a float keeps one.
    private func noteTiled(_ b: String?) {
        guard mode == .narrow, let b, let w = window, !w.floating.isEmpty, w.floatingLayer(of: b) == nil,
              PhoneState.shared.sheets[windowID]?.tiled != b else { return }
        PhoneState.shared.sheets[windowID, default: FloatSheet.Phone()].tiled = b
    }

    /// Shows a float in the sheet: its pane becomes the active one. A tap raises it on the Mac
    /// (`raise`); a swipe on the grabber doesn't, unless the keyboard is up and typing goes there.
    private func showFloat(_ layer: String, forward fw: Bool? = nil, raise: Bool, large: Bool = true) {
        guard let w = window, let l = w.visibleFloating.first(where: { $0.id == layer }),
              let b = FloatSheet.pane(of: l, focused: w.focusedBlockID) else { return }
        if let fw { forward = fw }
        Haptic.selection()
        withAnimation(.snappy(duration: 0.28)) {
            if large { PhoneState.shared.sheets[windowID, default: FloatSheet.Phone()].detent = .large }
            model.focusedPane[w.id] = b
        }
        if raise { tapFloat(b) }
    }

    /// A float minimized on the Mac, from the floats' menu: shown again there, then in the sheet.
    private func showMinimized(_ layer: String) {
        PhoneState.shared.sheets[windowID, default: FloatSheet.Phone()].detent = .large
        restoreFloat(layer)
    }

    /// Back to the tab: the tiled pane shown under the sheet becomes active again, on the phone
    /// only. The float stays as it is on the Mac.
    private func hideSheet() {
        guard let w = window, case .floatSheet(let s)? = presentation(w) else { return }
        let target: String?
        switch s.tiled {
        case .page(let id, _): target = id
        case .splits: target = PhoneState.shared.sheets[windowID]?.tiled.flatMap { w.tiledPageIDs.contains($0) ? $0 : nil } ?? w.tiledPageIDs.first
        case .empty: target = nil
        }
        guard let target else { return }
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .snappy(duration: 0.25)) { model.focusedPane[w.id] = target }
    }

    /// The floats' control of a narrow tab, for the title bar, the tab strip or the vertical bar;
    /// nil without a float to list.
    private func floatsControl(_ w: WindowInfo, _ p: TabPresentation?, style: FloatsControl.Style, height: CGFloat = 44) -> FloatsControl? {
        let canRestore = PaneArrange.isAvailable(.restore, target: nil, support: server.capabilities.paneSupport)
        guard mode == .narrow, FloatsMenu.has(w, canRestore: canRestore) else { return nil }
        let canHide = !w.tiledPageIDs.isEmpty
        return FloatsControl(server: server, window: w, front: frontOverride, shown: sheetLayer(p), style: style, height: height,
                             onShow: { showFloat($0, raise: true) }, onRestore: { showMinimized($0) },
                             onHide: canHide ? { hideSheet() } : nil)
    }

    @ViewBuilder
    private func sheet(_ w: WindowInfo, _ theme: TermTheme, _ p: TabPresentation?) -> some View {
        if case .floatSheet(let s)? = p, let shown = s.shown { floatSheet(w, s, shown, theme) }
    }

    private func floatSheet(_ w: WindowInfo, _ s: FloatSheet.Layout, _ shown: FloatSheet.Shown, _ theme: TermTheme) -> some View {
        FloatSheetView(server: server, sessionID: sessionID, window: w, layout: s, shown: shown, active: activeBlock(w),
                       theme: theme, canvas: legibleCanvas, keyboardUp: keyboardUp,
                       mediumAllowed: vSize != .compact && s.hasTiled,
                       stored: PhoneState.shared.sheets[windowID]?.detent ?? .large, slide: slide,
                       actions: FloatSheetView.Actions(
                           tap: { id in
                               if PhoneState.shared.sheets[windowID]?.detent == .medium {
                                   withAnimation(.snappy(duration: 0.3)) { PhoneState.shared.sheets[windowID]?.detent = .large }
                               }
                               tapFloat(id)
                           },
                           swipePane: { id, dir in if let w = window { switchPane(w, by: dir, from: id) } },
                           show: { layer, fw in showFloat(layer, forward: fw, raise: liveKeyboard.up, large: false) },
                           detent: { d in
                               PhoneState.shared.sheets[windowID, default: FloatSheet.Phone()].detent = d
                               // Medium is for looking: typing lifts the sheet again.
                               if d == .medium, liveKeyboard.up, let b = activeBlock(w) { host(b)?.hideKeyboard() }
                           },
                           hide: { hideSheet() }))
            .transition(reduceMotion ? .opacity : .move(edge: .bottom))
    }

    #if DEBUG
    /// `-panesTest` `sheet:<verb>`: large, medium, hide, next, prev, or show<n> (the n-th drawn
    /// float from the front, as the floats' menu shows it).
    private func sheetTest(_ verb: String) {
        guard let w = window else { return }
        let floats = FloatLayout.ordered(w.visibleFloating, front: frontOverride).reversed().map(\.id)
        let shown = sheetLayer(presentation(w))
        switch verb {
        case "large", "medium":
            withAnimation(.snappy(duration: 0.3)) {
                PhoneState.shared.sheets[windowID, default: FloatSheet.Phone()].detent = verb == "large" ? .large : .medium
            }
        case "hide": hideSheet()
        case "next", "prev":
            if let s = shown, let n = FloatSheet.step(floats, from: s, by: verb == "next" ? 1 : -1) {
                showFloat(n, forward: verb == "next", raise: liveKeyboard.up, large: false)
            }
        default:
            if verb.hasPrefix("show"), let n = Int(verb.dropFirst(4)), floats.indices.contains(n - 1) { showFloat(floats[n - 1], raise: true) }
        }
    }
    #endif

    /// Runs the tab-scoped `RexCommand`s; RootView runs the app-wide ones.
    private func handle(_ r: CommandRequest) {
        guard r.command.isWindowCommand, PhoneState.shared.claim(r) else { return }
        guard let w = window else { return }
        switch r.command {
        case .newTab: newTab()
        case .splitRight: split(vertical: false)
        case .splitDown: split(vertical: true)
        case .splitLeft: split(vertical: false, before: true)
        case .splitUp: split(vertical: true, before: true)
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
        case .find(let step): if let b = activeBlock(w) { host(b)?.performFind(step) }
        case .balanceSplits: balance()
        case .closeOtherPanes: requestCloseOthers()
        case .moveToTab: chooseMoveTarget()
        case .moveToNewTab: moveToNewTab()
        case .moveTab(let d): moveTab(by: d)
        case .minimizeFloat: minimizeFloat()
        case .minimizeAllFloats: minimizeAllFloats()
        case .goTo(let scope): openGoTo(scope, w)
        case .newSession, .toggleSidebar, .toggleAgents, .jumpToWaiting, .fontBigger, .fontSmaller, .fontReset, .settings,
             .nextSession, .previousSession, .renameSession, .closeSession, .closeOtherTabs, .addComputer: break
        }
    }

    /// Opens the palette on this tab's active pane: its commands and actions run there.
    private func openGoTo(_ scope: GoToScope, _ w: WindowInfo) {
        model.palette.open(scope, target: GoToTarget(serverID: server.id, sessionID: sessionID, windowID: windowID,
                                                     blockID: activeBlock(w), canZoom: canZoom(w),
                                                     canSwitchPane: activeBlock(w).map { paneGroup(w, from: $0).count > 1 }))
    }

    // MARK: Title bar

    /// Where the system has a vertical bar, the sidebar toggle and the tab's actions are toolbar items
    /// there (Apple: navigation at the top, then actions, each with a title and a symbol). The title
    /// and status stay in the title bar: text and custom views stay off the vertical axis.
    /// While a pane's key bar is up, the root puts Hide Keyboard (the key bar's hide key, which the
    /// bar beside the keyboard takes in; `HideKeyboardItem`) at the top of the bar, above the
    /// sidebar toggle, and All Tabs, which has no room then, leaves these items; it comes back when
    /// the key bar goes (`TabActions.tabItems`). The swap rides the keyboard's animation. Where
    /// the bar fits fewer items above the keyboard (`TabActions.keyBarRoom`), Unzoom and then the
    /// sidebar toggle leave it first, so nothing goes into the system's "…" menu. Tab mode has no
    /// toggle (the strip's session chip opens the sessions), so All Tabs stays below Hide
    /// Keyboard where the bar fits three.
    @ToolbarContentBuilder
    private func barItems(_ theme: TermTheme, _ p: TabPresentation?) -> some ToolbarContent {
        if barEdge != nil, let w = window, let b = activeBlock(w) {
            let room = TabActions.keyBarRoom(column: barColumn, compactHeight: vSize == .compact)
            // The same test the root's Hide Keyboard uses, so the bar counts what it shows.
            let items = TabActions.tabItems(prefs.navigation, zoomed: zoomedHere, hidesKeyboard: pool?.hideKeyboard.pane != nil,
                                            room: room, floats: prefs.navigation == .sidebar && floatsControl(w, p, style: .bar) != nil)
            ToolbarItemGroup(placement: .topBarTrailing) {
                if items.contains(.unzoom) {
                    Button { toggleZoom() } label: { Label(TabAction.unzoom.title, systemImage: TabAction.unzoom.symbol) }
                }
                if items.contains(.allTabs) {
                    Button { openOverview() } label: { Label(TabAction.allTabs.title, systemImage: TabAction.allTabs.symbol) }
                }
                paneMenu(w, block: b, p)
                if items.contains(.floats) { floatsControl(w, p, style: .bar) }
            }
        }
    }

    /// The bar above the panes: the title bar, or in tab mode the tab strip in its place, each at
    /// its own height. Branched here, so a change of mode keeps the tab's panes and its state.
    private func header(_ w: WindowInfo?, _ theme: TermTheme, _ p: TabPresentation?) -> some View {
        bar(w, theme, p)
            // The palette opens just below the bar: where it ends, read at open.
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { [palette = model.palette] in
                palette.titleBarBottom = $0
            }
            .onDisappear { [palette = model.palette] in palette.titleBarBottom = nil }
    }

    @ViewBuilder
    private func bar(_ w: WindowInfo?, _ theme: TermTheme, _ p: TabPresentation?) -> some View {
        switch prefs.navigation {
        case .sidebar: titleHeader(w, theme, p)
        case .tabs: tabStrip(w, theme, p)
        }
    }

    /// Tab mode's strip. Under a short window (landscape iPhone) it is thinner, to leave rows for
    /// the panes.
    private var barHeight: CGFloat { vSize == .compact ? 34 : 44 }

    /// Sidebar mode's title bar: as tall as its one line and its glyphs, with even padding
    /// (`TitleLine.barHeight`). Every part of the bar takes this height as its hit height.
    private var titleBarHeight: CGFloat { TitleLine.barHeight(typeSize, compact: vSize == .compact) }

    /// Tab mode's bar (`TabStrip`): the session's tabs as chips, with what the title bar holds.
    private func tabStrip(_ w: WindowInfo?, _ theme: TermTheme, _ p: TabPresentation?) -> some View {
        let block = w.flatMap { activeBlock($0) }
        // The panes on screen and the panes the dots page through, as the title bar has them.
        var visible: Set<String> = [], dots: [String] = []
        if let w, let block {
            let single = p == nil && !useSplits(w)
            visible = p.map { VisiblePanes.inTab(w, $0) } ?? VisiblePanes.inTab(w, active: block, single: single)
            dots = (p.map(\.pageIDs) ?? (single ? w.pageBlockIDs : nil)) ?? []
        }
        let actions = StripActions(
            pick: { id in
                guard id != windowID else { return }
                Haptic.selection()
                onOpen(Selection(serverID: server.id, sessionID: sessionID, windowID: id))
            },
            // Closing the tab on screen shows its neighbor, as Close Tab does everywhere
            // (`StripRoutes.confirmCloseTab`).
            chip: { action, id in strip?.run(action, tab: id, session: sessionID, server: server) },
            newTab: { newTab() },
            unzoom: { toggleZoom() },
            stepPane: { dir in if let w = window { switchPane(w, by: dir, from: p?.pageCurrent) } },
            jump: jump,
            sessions: { strip?.run($0) })
        return TabStrip(target: StripTarget(server: server, sessionID: sessionID, windowID: w?.id, block: block),
                        dots: dots, dotsCurrent: p?.pageCurrent, visible: visible, zoomed: zoomedHere, bar: barEdge != nil,
                        height: barHeight, theme: theme, actions: actions,
                        floats: w.flatMap { floatsControl($0, p, style: .titleBar, height: barHeight) }, routes: strip) {
            if let w, let block {
                paneMenu(w, block: block, p)
                    .confirmationDialog(confirmTitle, isPresented: confirmShown(confirmInStrip), titleVisibility: .visible,
                                        presenting: confirm) { confirmButtons($0) } message: { confirmMessage($0) }
                    .onAppear { stripMenuShown = true }
                    .onDisappear { stripMenuShown = false }
            }
        }
    }

    /// Thin, like the Mac's title bar: the sidebar toggle, the tab's title with the shown pane's
    /// status and the session's name on one line (`TitleLine`), then the page dots and the pane
    /// menu. As tall as that line and the glyphs, with even padding (`titleBarHeight`): it grows
    /// with the text size up to the line's cap. Where the system has a vertical bar, the buttons
    /// are there instead and this keeps the title line.
    private func titleHeader(_ w: WindowInfo?, _ theme: TermTheme, _ p: TabPresentation?) -> some View {
        let bar = barEdge != nil
        let height = titleBarHeight
        return HStack(spacing: 0) {
            if !bar {
                IconButton(symbol: "sidebar.left", label: sidebarVisible ? "Hide Sidebar" : "Show Sidebar",
                           height: height) { sidebarVisible.toggle() }
            }
            if let w {
                titleBar(w, theme)
            } else {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(theme.chrome.tertiary)
                    .lineLimit(1)
                    .padding(.leading, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let w, let b = activeBlock(w) {
                let single = p == nil && !useSplits(w)
                let visible = p.map { VisiblePanes.inTab(w, $0) } ?? VisiblePanes.inTab(w, active: b, single: single)
                // One pane at a time: the dots say which, of the tab's panes on screen or a swipe away.
                let dots = p.map(\.pageIDs) ?? (single ? w.pageBlockIDs : nil)
                WaitingPill(visible: visible, theme: theme, height: height, onJump: jump)
                    .layoutPriority(1)
                if let dots, dots.count > 1 {
                    PaneDots(ids: dots, current: p?.pageCurrent ?? b, theme: theme, height: height) {
                        switchPane(w, by: $0, from: p?.pageCurrent)
                    }
                }
                if !bar {
                    if mode == .narrow { floatsControl(w, p, style: .titleBar, height: height) }
                    if zoomedHere { unzoomButton(theme, height: height) }
                    paneMenu(w, block: b, p)
                        .labelStyle(.iconOnly)
                        .frame(width: 44, height: height)
                        .contentShape(Rectangle())
                }
            }
        }
        .font(.system(size: 17))
        .foregroundStyle(theme.fg)
        // The bar's height follows the text only up to the line's cap, and so does its text:
        // the title, the pill's count, the floats' count. Nothing in it outgrows the bar.
        .dynamicTypeSize(...TitleLine.typeLimit)
        .frame(height: height)
        .padding(.leading, bar ? 12 : 4)
        .padding(.trailing, 4)
        .clearsWindowControls()
        .background(theme.chrome.canvas)
        .animation(.snappy(duration: 0.2), value: zoomedHere)
    }

    private func titleBar(_ w: WindowInfo, _ theme: TermTheme) -> some View {
        TabTitleBar(server: server, sessionID: sessionID, window: w, block: activeBlock(w), subtitle: subtitle,
                    theme: theme,
                    onSwipe: { switchTab(by: $0, haptic: false) },
                    onPick: { Haptic.selection(); onOpen($0) },
                    onOverview: { openOverview() },
                    onNewTab: { newTab() },
                    onRename: { rename() },
                    onGoTo: { if let w = window { openGoTo(.anything, w) } })
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

    private func paneMenu(_ w: WindowInfo, block: String, _ p: TabPresentation?) -> some View {
        Menu {
            Section {
                // All Tabs among them: it is here while Hide Keyboard has its place in the bar.
                ForEach(TabActions.paneMenuFirstSection, id: \.self) { a in
                    Button { runFirstSection(a) } label: { Label(a.title, systemImage: a.symbol) }
                }
            }
            Section {
                if canZoom(w, p) {
                    Button { toggleZoom() } label: {
                        Label(zoomedHere ? "Unzoom" : "Zoom Pane",
                              systemImage: zoomedHere ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        Text("or tap with two fingers")
                    }
                }
                Button { Task { await server.clear(sessionID, block) } } label: { Label("Clear Terminal", systemImage: "eraser") }
                Button { rename() } label: { Label("Rename Tab…", systemImage: "pencil") }
            }
            Section {
                FindMenuItem(keymap: server.keymap) { host(block)?.findFromMenu() }
                ShareMenuItem(server: server, sessionID: sessionID, block: block) { scope, styled in
                    host(block)?.share?.share(scope, styled: styled, anchor: barEdge.map { .bar($0) } ?? .titleBar)
                }
                AttachMenuItem(pool: pool, key: TerminalHostPool.Key(server: server.id, session: sessionID, block: block))
                PaneMenuItems(server: server, sessionID: sessionID, window: w, block: block,
                              onSwap: { swap(with: $0) }, onMove: { moveToTab($0) }, onMoveToNewTab: { moveToNewTab() },
                              onBalance: { balance() }, onCloseOthers: { requestCloseOthers() })
                PortsMenuRow(server: server, sessionID: sessionID, block: block) { host(block)?.ports?.open($0) }
            }
            FloatMenuSection(server: server, sessionID: sessionID, window: w, block: block,
                             sheet: mode == .narrow ? (frontOverride, sheetLayer(p)) : nil,
                             onMinimize: { minimizeFloat() }, onMinimizeAll: { minimizeAllFloats() },
                             onRestore: { showMinimized($0) }, onShow: { showFloat($0, raise: true) })
            Section {
                Button(role: .destructive) { requestClose(block) } label: { Label("Close Pane", systemImage: "xmark.square") }
                Button(role: .destructive) { requestCloseTab() } label: { Label("Close Tab", systemImage: "xmark") }
            }
        } label: {
            Label(TabAction.paneActions.title, systemImage: TabAction.paneActions.symbol)
        }
        .accessibilityLabel(TabAction.paneActions.title)
    }

    /// The Pane Actions menu's first section (`TabActions.paneMenuFirstSection`).
    private func runFirstSection(_ a: TabAction) {
        switch a {
        case .splitRight: split(vertical: false)
        case .splitDown: split(vertical: true)
        case .newTab: newTab()
        case .allTabs: openOverview()
        default: break
        }
    }

    /// The live host of a pane of this tab, if it is on screen.
    private func host(_ block: String) -> TerminalHost? {
        pool?.host(for: TerminalHostPool.Key(server: server.id, session: sessionID, block: block))
    }

    // MARK: Panes

    /// What the tiled canvas draws: the splits, or one pane, which is the active one (else a tap
    /// makes it so) and pages to the next with a swipe, or not under floating windows.
    private struct CanvasLook {
        var splits = false
        var block: String?
        var active = true
        var pages = true
    }

    private func canvasLook(_ w: WindowInfo, _ p: TabPresentation?) -> CanvasLook {
        guard let p else { return useSplits(w) ? CanvasLook(splits: true) : CanvasLook(block: activeBlock(w)) }
        switch p {
        case .pages(_, let current): return CanvasLook(block: current)
        case .floatSheet(let s):
            switch s.tiled {
            case .splits: return CanvasLook(splits: true)
            case .page(let id, let ids): return CanvasLook(block: id, active: id == activeBlock(w), pages: ids.count > 1)
            case .empty: return CanvasLook(block: nil, active: false, pages: false)
            }
        case .floating(.splits, _): return CanvasLook(splits: true)
        case .floating(.single(let id), _): return CanvasLook(block: id, active: id == activeBlock(w), pages: false)
        case .floating(.empty, _): return CanvasLook(block: nil, active: false, pages: false)
        }
    }

    /// A tap on a tiled pane: it becomes active, here and on the Mac. Under the float sheet that
    /// is the way back to the tab, so the sheet goes down with it.
    private func focusTiled(_ w: WindowInfo, _ b: String, _ p: TabPresentation?) {
        if sheetLayer(p) != nil {
            withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .snappy(duration: 0.25)) { model.focusedPane[w.id] = b }
        } else {
            model.focusedPane[w.id] = b
        }
        Task { await server.focus(sessionID, block: b) }
    }

    /// A sideways swipe on the one pane shown. In a tab without a float on screen it walks the
    /// panes and goes on to the tab beside past either end (`swipe`); under floats it walks the
    /// panes alone, with a bump at either end, or does nothing where the tab doesn't page.
    private func swipeAction(_ w: WindowInfo, _ b: String, _ p: TabPresentation?, pages: Bool) -> ((Int) -> Void)? {
        if p == nil { return { dir in swipe(from: b, by: dir, paged: true) } }
        return pages ? { dir in switchPane(w, by: dir, from: b) } : nil
    }

    @ViewBuilder
    private func canvas(_ w: WindowInfo, _ theme: TermTheme, _ p: TabPresentation?, bottom: PaneBottom) -> some View {
        let look = canvasLook(w, p)
        if !look.splits {
            if let b = look.block {
                let rounded = mode != .narrow
                let radius = rounded ? PaneLayout.singleRadius : 0
                ZStack {
                    PaneView(server: server, sessionID: sessionID, blockID: b, active: look.active,
                             onFocus: look.active ? {} : { focusTiled(w, b, p) },
                             onSwipe: swipeAction(w, b, p, pages: look.pages),
                             restSize: PaneLayout.single(canvas: canvasSize, rounded: rounded))
                        .id(b)
                        .padding(PaneLayout.clearance(radius: radius))
                        .transition(slide)
                }
                .background(rounded ? theme.bg : .clear)
                .clipShape(RoundedRectangle(cornerRadius: radius))
                .padding(rounded ? PaneLayout.roundedPadding : 0)
            }
        } else if let layout = w.layout {
            let active = activeBlock(w)
            GeometryReader { geo in
                let size = geo.size
                // Partly folded with a split across the crease: that divider is drawn on the crease.
                let book = BookSplit.decide(leaves: layout.leaves.map(\.rect), splits: layout.splits, areaWidth: size.width,
                                            areaMinX: geo.frame(in: .global).minX - rootOrigin.x,
                                            crease: bookCrease, canvas: legibleCanvas, fontSize: prefs.fontSize)
                // The splits divide the safe area as before; only panes on its bottom edge run on
                // under the home indicator.
                let area = CGSize(width: size.width, height: max(size.height - bottom.reach, 0))
                ZStack(alignment: .topLeading) {
                    ForEach(layout.leaves, id: \.id) { leaf in
                        let r = book?.rect(leaf.rect) ?? leaf.rect
                        let frame = PaneLayout.split(r, in: area, reach: bottom.reach)
                        PaneView(server: server, sessionID: sessionID, blockID: leaf.id, active: leaf.id == active,
                                 onFocus: { focusTiled(w, leaf.id, p) },
                                 // Splits as the Mac lays them out: a swipe goes to the tab beside.
                                 onSwipe: p == nil ? { dir in swipe(from: leaf.id, by: dir, paged: false) } : nil,
                                 restSize: PaneLayout.splitRest(r, canvas: canvasSize, reach: restReach))
                        .id(leaf.id)
                        .padding(PaneLayout.clearance(radius: PaneLayout.splitRadius))
                        .background(theme.bg)
                        .clipShape(RoundedRectangle(cornerRadius: PaneLayout.splitRadius))
                        .overlay(RoundedRectangle(cornerRadius: PaneLayout.splitRadius)
                            .stroke(leaf.id == active ? theme.chrome.activeBorder : theme.chrome.divider, lineWidth: leaf.id == active ? 1.5 : 1))
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                    }
                    ForEach(layout.splits, id: \.id) { sp in
                        if let handle = book.map({ $0.handle(sp) }) ?? sp {
                            SplitHandle(split: handle, canvas: area, theme: theme) { shown in
                                let ratio = book?.ratio(sp, shown: shown) ?? shown
                                Task { await server.resizePane(sessionID, direction: sp.direction, before: sp.beforeFirst, after: sp.afterFirst, ratio: ratio) }
                            }
                        }
                    }
                }
            }
            .padding(PaneLayout.splitPadding)
        }
    }

    /// The floating windows, back to front, in the splits' area. Each is the terminal's
    /// background with one soft shadow, and its panes drawn as split panes are: no title strip,
    /// no buttons. Nothing at all in a tab without one on screen.
    @ViewBuilder
    private func floatWindows(_ w: WindowInfo, _ theme: TermTheme, _ p: TabPresentation?) -> some View {
        if case .floating(_, let floats)? = p {
            // Their area keeps out of the home indicator, with the keyboard down as well.
            let rest = legibleCanvas
            let active = activeBlock(w)
            let radius = PaneLayout.splitRadius
            GeometryReader { geo in
                let size = geo.size
                ZStack(alignment: .topLeading) {
                    ForEach(floats) { f in
                        let outer = PaneLayout.split(f.rect, in: size)
                        ZStack(alignment: .topLeading) {
                            // The window's backing and shadow, never on the Metal view, and never hit.
                            RoundedRectangle(cornerRadius: radius)
                                .fill(theme.bg)
                                .shadow(color: .black.opacity(scheme == .dark ? 0.35 : 0.25), radius: 12, y: 4)
                                .frame(width: outer.width, height: outer.height)
                                .offset(x: outer.minX, y: outer.minY)
                                .allowsHitTesting(false)
                            ForEach(f.leaves, id: \.id) { leaf in
                                let frame = PaneLayout.split(leaf.rect, in: size)
                                PaneView(server: server, sessionID: sessionID, blockID: leaf.id, active: leaf.id == active,
                                         onFocus: { tapFloat(leaf.id) },
                                         restSize: PaneLayout.splitRest(leaf.rect, canvas: rest))
                                .id(leaf.id)
                                .padding(PaneLayout.clearance(radius: radius))
                                .background(theme.bg)
                                .clipShape(RoundedRectangle(cornerRadius: radius))
                                .overlay(RoundedRectangle(cornerRadius: radius)
                                    .stroke(leaf.id == active ? theme.chrome.activeBorder : theme.chrome.divider, lineWidth: leaf.id == active ? 1.5 : 1))
                                .frame(width: frame.width, height: frame.height)
                                .offset(x: frame.minX, y: frame.minY)
                            }
                        }
                    }
                }
            }
            .padding(PaneLayout.splitPadding)
        }
    }
}

/// Where the panes sit in the tab's canvas, and so how large each one is with the keyboard down.
enum PaneLayout {
    /// Around a single pane with rounded corners (wide windows).
    static let roundedPadding: CGFloat = 6
    /// Around the splits, and around each pane inside its share.
    static let splitPadding: CGFloat = 3
    /// How far in from the panes' area the first and last columns of the panes on its bottom
    /// edge sit: the padding around the splits and each split pane's share, or a rounded single
    /// pane's, and the clearance of the corners they are clipped to; nothing for a narrow single
    /// pane. What the window's corners have to keep clear of (`PaneBottom.cornerReach`).
    static func bottomPadding(splits: Bool, rounded: Bool) -> CGFloat {
        if splits { return splitPadding * 2 + clearance(radius: splitRadius) }
        return rounded ? roundedPadding + clearance(radius: singleRadius) : 0
    }

    /// The corners a single rounded pane and a split pane are clipped to.
    static let singleRadius: CGFloat = 10
    static let splitRadius: CGFloat = 8

    /// How far the terminal sits inside a pane clipped to corners of `radius`, on the terminal's
    /// background. The grid starts at the pane's corner and can end at its far edge (a pane an
    /// exact number of rows tall), and a corner's curve cuts `radius · (1 − 1/√2)` into its
    /// diagonal: without this the corner cells, a cursor on the last row among them, lose their
    /// outer edges.
    static func clearance(radius: CGFloat) -> CGFloat {
        (radius * (1 - 0.5.squareRoot())).rounded(.up)
    }

    /// A split pane's frame inside the splits' area `size`, from its normalized rect. A pane on
    /// the area's bottom edge runs `reach` further, under the home indicator (`PaneBottom`); the
    /// splits themselves stay proportional to the area.
    static func split(_ r: CGRect, in size: CGSize, reach: CGFloat = 0) -> CGRect {
        let frame = CGRect(x: r.minX * size.width, y: r.minY * size.height, width: r.width * size.width, height: r.height * size.height)
            .insetBy(dx: splitPadding, dy: splitPadding)
        let below = onBottomEdge(r) ? max(reach, 0) : 0
        return CGRect(x: frame.minX, y: frame.minY, width: max(frame.width, 10), height: max(frame.height, 10) + below)
    }

    /// The normalized rect reaches the bottom of its area.
    static func onBottomEdge(_ r: CGRect) -> Bool { r.maxY > 0.999 }

    /// The canvas the panes' rest sizes come from: the tab's canvas `now` as it would be with the
    /// software keyboard down. The keyboard's cover leaves the grid alone, so with it up that is
    /// `now` with the keyboard's `room` given back, less a `header` that stepped aside for it (a
    /// short window), and no taller than `limit` (tabletop: the region above the crease). Worked
    /// out from one layout's facts alone: a height kept from before the keyboard showed would be
    /// another posture's after a fold or a rotation, and the panes would get its rows, then
    /// another resize when the keyboard went down. The room and the header are each counted
    /// whichever comes first as the keyboard shows or hides, so no layout in between gives
    /// another size. The key bar alone takes its room: the grid fits above it. Nothing measured
    /// yet stays unmeasured.
    ///
    /// `home` is the home indicator's inset under the keyboard (`PaneBottom.restReach`), given back
    /// with its room, since with the keyboard down the panes run on to the window's edge.
    static func restCanvas(now: CGSize, room: CGFloat, home: CGFloat = 0, header: CGFloat = 0,
                           limit: CGFloat = .infinity) -> CGSize {
        guard now.width > 0, now.height > 0 else { return now }
        let keyboard = PaneBottom.softwareKeyboard(room) ? room + home : 0
        return CGSize(width: now.width, height: max(min(now.height + keyboard - header, limit), 1))
    }

    /// A single pane's terminal size in a canvas of size `canvas`; nil for a canvas not measured yet.
    static func single(canvas: CGSize, rounded: Bool) -> CGSize? {
        guard canvas.width > 0, canvas.height > 0 else { return nil }
        let pad = rounded ? (roundedPadding + clearance(radius: singleRadius)) * 2 : 0
        return CGSize(width: max(canvas.width - pad, 0), height: max(canvas.height - pad, 0))
    }

    /// A split pane's terminal size in a canvas of size `canvas`; nil for a canvas not measured yet.
    /// The canvas runs `reach` past the safe area (`PaneBottom.restReach`): the splits divide the
    /// rest, and a pane on the bottom edge takes it.
    static func splitRest(_ r: CGRect, canvas: CGSize, reach: CGFloat = 0) -> CGSize? {
        guard canvas.width > 0, canvas.height > 0 else { return nil }
        let reach = min(max(reach, 0), canvas.height)
        let area = CGSize(width: max(canvas.width - splitPadding * 2, 0), height: max(canvas.height - reach - splitPadding * 2, 0))
        let pane = split(r, in: area, reach: reach).size, inset = clearance(radius: splitRadius) * 2
        return CGSize(width: max(pane.width - inset, 0), height: max(pane.height - inset, 0))
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
    nonisolated static func spoken(_ state: String?) -> String {
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
    /// The count at any number of panes: the tab strip's, where dots would be crowded
    /// (`StripLayout.dotsForm`). The title bar leaves it off.
    var counts = false
    /// The hit height: the bar's.
    var height: CGFloat = 44
    let onStep: (Int) -> Void

    var body: some View {
        let idx = ids.firstIndex(of: current) ?? 0
        Group {
            if !counts, ids.count <= StripLayout.maxDots {
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
                    .lineLimit(1).fixedSize()
                    .foregroundStyle(theme.chrome.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .frame(minHeight: height)
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
            .navigationTitle("All Tabs")
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
                    // The title truncates before the pane count and status do.
                    HStack(spacing: 6) {
                        if window.allBlocks.count > 1 {
                            Text("\(window.allBlocks.count)")
                                .font(.caption2.weight(.semibold))
                                .monospacedDigit()
                                .foregroundStyle(theme.chrome.tertiary)
                        }
                        WindowBadge(server: server, window: window, theme: theme, showsProgress: true)
                    }
                    .fixedSize()
                    .layoutPriority(1)
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

/// A tab's combined status, observing only that tab's blocks. The overview card passes
/// `showsProgress` for a program's progress ring; the title bar's swipe neighbour doesn't.
struct WindowBadge: View {
    let server: ServerConnection
    let window: WindowInfo
    let theme: TermTheme
    var showsProgress = false
    var body: some View {
        WindowStatusBadge(server: server, window: window, theme: theme, showsProgress: showsProgress)
    }
}

// MARK: - Small pieces

/// The keyboard's state as last reported, kept outside SwiftUI's state so writing it draws
/// nothing (`WindowScreen.liveKeyboard`).
@MainActor
final class LiveKeyboard {
    var up = false
}

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

/// The draggable border between two sides of a split. Its touch area reaches over the panes on
/// either side, and `HandleStrip` tells them that a drag across it is the handle's.
struct SplitHandle: View {
    let split: (id: String, direction: String, ratio: Double, rect: CGRect, beforeFirst: String, afterFirst: String)
    let canvas: CGSize
    let theme: TermTheme
    let onCommit: (Double) -> Void
    @State private var drag: CGFloat = 0
    @State private var inDetent = false

    /// How far the touch area reaches past the capsule on each side.
    static let reach: CGFloat = 20

    var body: some View {
        let g = SplitGeometry(rect: split.rect, ratio: split.ratio, direction: split.direction, canvas: canvas)
        let horizontal = g.sideBySide
        let len = g.length
        let size = CGSize(width: horizontal ? 4 : len * 0.9, height: horizontal ? len * 0.9 : 4)
        ZStack {
            HandleStrip(sideways: horizontal)
                .frame(width: size.width + Self.reach * 2, height: size.height + Self.reach * 2)
                .position(x: g.origin.x + (horizontal ? 0 : len / 2), y: g.origin.y + (horizontal ? len / 2 : 0))
                .allowsHitTesting(false)
            Capsule()
                .fill(drag != 0 ? theme.accent : Color.clear)
                .frame(width: size.width, height: size.height)
                .contentShape(Rectangle().inset(by: -Self.reach))
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
}
