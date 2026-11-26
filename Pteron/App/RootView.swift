import SwiftUI
import UIKit

/// iPhone Duo first, and one model for every screen, like the Rex Mac app: the tab fills the window,
/// and the sidebar sits beside it when the window is wide (`Arrangement.inline`) or slides over it as
/// a drawer when narrow (folded Duo, iPhone portrait, half the inner screen). Same sidebar, same
/// toggle, same gestures and the same open or closed state in every posture (`SidebarSplit`).
///
/// Bars follow the system. Where the system has a vertical bar (the Duo's outer screen, and its inner
/// screen in landscape), the navigation bar shows and the sidebar toggle and tab actions are toolbar
/// items, which the system puts in that bar beside the status bar. Elsewhere the bar stays hidden and
/// the tab's own thin title bar holds them. The chrome background runs edge to edge, under the bar.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    @Environment(Prefs.self) private var prefs
    @Environment(\.verticalSizeClass) private var vSize
    /// The sidebar is showing: inline beside the tab, or the drawer over it. Read what is on screen
    /// with `shows(inline:)`.
    @State private var sidebar: SidebarState
    /// The sidebar is inline (wide window). Mirrors the arrangement for commands.
    @State private var inline = false
    /// The room the docked keyboard takes at the bottom (`KeyboardInset`). The root pads itself by
    /// this instead of following SwiftUI's keyboard safe area.
    @State private var keyboardPad: CGFloat = 0
    /// The window's bottom inset under the root, as UIKit reports it (`KeyboardInset.home`).
    @State private var homeInset: CGFloat = 0
    /// Where the system puts its vertical bar, if it has one here.
    @State private var barEdge: HorizontalEdge?
    /// That bar's column, in screen coordinates, for the key bar beside the keyboard.
    @State private var barColumn: CGRect?
    /// The crease book mode lays out against, once the fold has held still.
    @State private var creaseSettle = CreaseSettle()
    /// Book mode collapsing the inline sidebar and bringing it back.
    @State private var bookSidebar = BookSidebar()
    /// Whether the tab on screen would be in book mode with the sidebar collapsed. Nil with no tab.
    @State private var bookFits: Bool?
    /// Keeps each pane's terminal alive while a fold or unfold rebuilds the layout.
    @State private var hostPool = TerminalHostPool()
    /// Where the resize handles reach over the panes (`HandleStrips`).
    @State private var handleStrips = HandleStrips()
    /// Tab mode's rename alert and close confirmations, which the sidebar's list shows itself.
    /// The root shows the alert; the strip shows each confirmation by the control that was
    /// tapped (`StripDialogs`).
    @State private var stripDialogs = SidebarActions()
    /// What a row of the ports sheet opens, held until the sheet has gone.
    @State private var portsWait = DismissalWait()
    #if DEBUG
    @State private var simIndex = 0
    @State private var simKeyboard: CGFloat = 0
    private let simulations = DuoSimulation.sequence
    #endif

    /// `launchHold`: a cold launch's first window, with a tab to show (`AppModel.launchHold`). A
    /// narrow window's drawer starts closed, decided here so the first frame already has it.
    init(launchHold: Bool = false) {
        _sidebar = State(initialValue: SidebarState(launchHold: launchHold))
    }

    var body: some View {
        let theme = prefs.theme(for: scheme)
        rootContent(theme)
            .ignoresSafeArea(.keyboard)
            .background(KeyboardInsetReader(padHold: model.palette.padHold, onHome: { h in if homeInset != h { homeInset = h } }) {
                setKeyboardPad($0)
            }.ignoresSafeArea())
            .environment(hostPool)
            .environment(\.handleStrips, handleStrips)
            .overlay(alignment: .top) { NoticeBanner(theme: theme) }
            .background(CommandListener { handle($0) })
            .background(WaitingWatcher())
            .background(GlanceWatcher())
            .background(VerticalBarObserver { e, column in
                if barEdge != e { barEdge = e }
                if barColumn != column { barColumn = column }
            })
            .background(ParkWatcher(pool: hostPool))
            .modifier(SidebarDialogs(actions: stripDialogs, shows: [.rename]))
            .accessibilityAction(.magicTap) { model.perform(.jumpToWaiting) }
            .tint(theme.accent)
            .preferredColorScheme(theme.isDark ? .dark : .light)
            .sheet(isPresented: Binding(get: { model.showSettings }, set: { model.showSettings = $0 }),
                   onDismiss: { model.helperSetup.presentPending() }) {
                SettingsView().environment(model)
            }
            .sheet(isPresented: Binding(get: { model.agentsShown }, set: { model.agentsShown = $0 }),
                   onDismiss: { model.helperSetup.presentPending() }) {
                AgentsSheet().environment(model)
            }
            .sheet(isPresented: Binding(get: { model.portsShown != nil }, set: { if !$0 { model.portsShown = nil } }),
                   onDismiss: {
                       portsWait.dismissed()
                       model.helperSetup.presentPending()
                   }) {
                if let server = model.server(model.portsShown) {
                    PortsSheet(server: server, wait: portsWait).environment(model)
                }
            }
            #if DEBUG
            .modifier(PortsSheetAtLaunch())
            #endif
            .helperSetupCover(model: model)
            .pairingCover(isPresented: Binding(get: { model.showPairing }, set: { model.showPairing = $0 }), model: model) {
                model.openSettings(at: .addServer)
            }
            .onChange(of: model.autoSelectInputs) { _, _ in
                model.autoSelect()
            }
            .onChange(of: model.openRequest) { _, r in if let r { show(r.selection) } }
            // The mode the sidebar had last time, and saved when it changes.
            .onChange(of: sidebar.mode) { _, m in if prefs.sidebarMode != m { prefs.sidebarMode = m } }
            // `open`, not what shows: book mode concerns only the inline sidebar, which shows `open`.
            .onChange(of: sidebar.open) { _, open in bookSidebar.sidebarChanged(open: open) }
            // The tab on screen always has a row: its folded session and machine open (a tap, Jump to
            // Waiting, a push, a toast, a new session).
            .onChange(of: model.selection) { _, sel in
                guard let sel else { return }
                let open = SidebarCollapse.revealing(prefs.sidebarCollapsed, sel)
                if open != prefs.sidebarCollapsed {
                    withAnimation(SidebarCollapse.animation) { prefs.sidebarCollapsed = open }
                }
            }
            .onAppear {
                connectPalette()
                // A window made after this one starts as before.
                model.launchHoldTaken()
                // Nothing to list yet: the tab area, which says how to add a server, shows.
                if model.servers.isEmpty { sidebar.open = false }
                sidebar.mode = prefs.sidebarMode
                #if DEBUG
                // `-simulateScan <payload>` (testing): open the scanner at launch.
                if UserDefaults.standard.string(forKey: "simulateScan") != nil, SettingsPage.debugLaunch == nil {
                    model.showPairing = true
                }
                // `-pairHost <https address>` (testing): open the pairing flow at that address.
                if let host = UserDefaults.standard.string(forKey: "pairHost").flatMap(URL.init(string:)) {
                    model.startPairing(prefilled: host, guessed: true)
                }
                // `-simulateHelperSetup <state>` (testing): the helper install sheet in that state.
                model.helperSetup.simulateFromLaunchArguments()
                // `-sidebar closed` (testing): start with the sidebar hidden.
                if UserDefaults.standard.string(forKey: "sidebar") == "closed" { sidebar.open = false }
                // `-sidebar open` (testing): a drawer shows at launch too, over the tab.
                if UserDefaults.standard.string(forKey: "sidebar") == "open" { sidebar.open = true }
                // `-showAgents YES` (testing): open the Agents sheet at launch.
                if UserDefaults.standard.bool(forKey: "showAgents") { model.showAgents() }
                #endif
            }
    }

    @ViewBuilder
    private func rootContent(_ theme: TermTheme) -> some View {
        #if DEBUG
        if !simulations.isEmpty {
            simulated(simulations[simIndex % simulations.count], theme)
        } else {
            layout(theme, fake: nil)
        }
        #else
        layout(theme, fake: nil)
        #endif
    }

    #if DEBUG
    /// `-simulateDuo`: the root in that posture's size at the bottom-leading corner of a bigger
    /// simulator screen, with that posture's size classes and a fake fold, drawn as a dashed red line.
    /// The keyboard shrinks it from below by its height, as on the device. The posture's insets
    /// are given twice, as a device gives them: around the root, which is laid out inside them,
    /// and to the sidebar and the tab inside the navigation stack, which fills the window.
    private func simulated(_ sim: DuoSimulation, _ theme: TermTheme) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                // The panes reach under the posture's inset and the simulator's own, which the
                // simulated window sits on.
                layout(theme, fake: .some(sim.rootDivision), fills: sim.fillsScreen, insets: sim.insets(keyboard: simKeyboard),
                       room: sim.keyboardRoom(simKeyboard), home: sim.safeArea.bottom + homeInset)
                    .safeAreaPadding(sim.safeArea)
                    .frame(width: sim.size.width, height: max(sim.size.height - simKeyboard, 100))
                    .frame(width: sim.size.width, height: sim.size.height, alignment: .top)
                    .environment(\.horizontalSizeClass, sim.horizontal)
                    .environment(\.verticalSizeClass, sim.vertical)
                    .overlay(alignment: .topLeading) {
                        if let d = sim.division {
                            Path { p in
                                if d.isVertical {
                                    p.move(to: CGPoint(x: d.frame.midX, y: 0))
                                    p.addLine(to: CGPoint(x: d.frame.midX, y: sim.size.height))
                                } else {
                                    p.move(to: CGPoint(x: 0, y: d.frame.midY))
                                    p.addLine(to: CGPoint(x: sim.size.width, y: d.frame.midY))
                                }
                            }
                            .stroke(Color.red.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                            .allowsHitTesting(false)
                        }
                    }
                    .border(Color.gray)
                Spacer(minLength: 0)
            }
        }
        // On the screen's bottom edge, as a device's window is, so panes that run to the window's
        // edge end at the simulated window's bottom and not under it. The screen's own bottom
        // inset then lies inside the simulated window, which `home` counts.
        .ignoresSafeArea(.container, edges: .bottom)
        .background(Color(white: 0.45).ignoresSafeArea())
        .ignoresSafeArea(.keyboard)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { n in
            let f = (n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect) ?? .zero
            let h = (n.object as? UIScreen).map { f.intersection($0.bounds).height } ?? 0
            if model.palette.padHold.offer(.sim, h) { return }
            simKeyboard = h
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            if model.palette.padHold.offer(.sim, 0) { return }
            simKeyboard = 0
        }
        .task(id: simulations.count) {
            guard simulations.count > 1 else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(DuoSimulation.interval * 1_000_000_000))
                if Task.isCancelled { break }
                simIndex += 1
            }
        }
    }
    #endif

    /// The sidebar and the tab, arranged for the window's width and the fold. `fake` replaces the fold
    /// (debug simulation), which then also says whether its window `fills` its screen, gives the
    /// safe area's `insets` and the `room` its keyboard takes.
    private func layout(_ theme: TermTheme, fake: Division??, fills: Bool? = nil, insets: EdgeInsets = EdgeInsets(),
                        room: CGFloat? = nil, home: CGFloat? = nil) -> some View {
        GeometryReader { geo in
            let division = fake ?? Self.division(geo)
            // The root ignores the keyboard, so the arrangement doesn't change when it shows.
            let arr = Arrangement.decide(size: geo.size, division: division)
            NavigationStack {
                let shown = sidebar.shows(inline: arr.inline)
                SidebarSplit(arrangement: arr, theme: theme, navigation: prefs.navigation,
                             open: Binding(get: { sidebar.shows(inline: arr.inline) }, set: { sidebar.open = $0 })) {
                    SidebarView(mode: $sidebar.mode, onSelect: { _ in writeSidebar { $0.tabShown(inline: arr.inline) } })
                        // A hidden sidebar reads no port: its machines' ports buttons catch up when it shows.
                        .environment(\.sidebarShown, shown)
                } tab: {
                    tab(arr)
                }
                #if DEBUG
                // `-simulateDuo`: the navigation stack fills the simulated window and takes its
                // safe area from the real one, so the posture's insets are given again here.
                .safeAreaPadding(insets)
                #endif
                // The keyboard's room, from its frames (`KeyboardInset`), not SwiftUI's keyboard
                // safe area, which can stay at a frame the keyboard had for a moment. Here, inside
                // the navigation stack: its content is hosted on its own.
                .safeAreaPadding(.bottom, keyboardPad)
                .ignoresSafeArea(.keyboard)
                .background(theme.chrome.canvas.ignoresSafeArea())
                .background(EdgeReveal(enabled: !shown && prefs.navigation == .sidebar) { revealSidebar() })
                // Only where the system has a vertical bar: the toggle and the tab's actions go there.
                // Elsewhere the tab's title bar holds them, Mac-like, with no second bar above it.
                // While the setup guide covers the app, its own bar is the one (`OnboardingScreen`).
                .toolbar(barEdge == nil || model.guide != nil ? .hidden : .visible, for: .navigationBar)
                .toolbar {
                    // While a pane's key bar is up, and only then, Hide Keyboard is the bar's top
                    // item, above the sidebar toggle, which gives its place up where the bar is short
                    // (`TabActions.leadingItems`) and comes back with the keyboard. Tab mode has no
                    // toggle: the strip's session chip opens the sessions.
                    let leading = barEdge == nil ? [] : TabActions.leadingItems(
                        prefs.navigation, hidesKeyboard: hostPool.hideKeyboard.pane != nil,
                        room: TabActions.keyBarRoom(column: barColumn, compactHeight: vSize == .compact))
                    if leading.contains(.hideKeyboard), let pane = hostPool.hideKeyboard.pane {
                        ToolbarItem(placement: .topBarLeading) {
                            Button { hostPool.host(for: pane)?.hideKeyboard() } label: {
                                Label(TabAction.hideKeyboard.title, systemImage: TabAction.hideKeyboard.symbol)
                            }
                        }
                    }
                    if leading.contains(.sidebar) {
                        ToolbarItem(placement: .topBarLeading) {
                            Button { toggleSidebar() } label: {
                                Label(shown ? "Hide Sidebar" : "Show Sidebar", systemImage: "sidebar.left")
                            }
                        }
                    }
                }
            }
            // Standing as a tent, the agent board covers all of it (`TentBoard`).
            .modifier(TentBoard(division: division, size: geo.size, inline: arr.inline, fills: fills, sidebar: boardSidebar,
                                pool: hostPool, keyboardHeight: keyboardHeight, theme: theme))
            // The palette, over the tab and the sidebar, while it is open; nothing while closed.
            .modifier(GoToOverlay(theme: theme, narrow: !arr.inline, division: division, keyboardPad: keyboardHeight))
            // The setup guide, over everything, while it shows (first run, Setup Guide).
            .modifier(OnboardingCover())
            // A new width resizes the panes anyway: the palette's hold on the keyboard's room ends.
            .onChange(of: geo.size.width) { _, _ in model.palette.padHold.endNow() }
            .environment(\.division, division)
            .environment(\.rootOrigin, geo.frame(in: .global).origin)
            .environment(\.bookCrease, creaseSettle.crease(division))
            .environment(\.verticalBarEdge, barEdge)
            .environment(\.verticalBarColumn, barColumn)
            .environment(\.keyboardRoom, room ?? keyboardPad)
            .environment(\.homeInset, home ?? homeInset)
            .onChange(of: arr.inline, initial: true) { _, new in
                // Wide: the launch's hold on the drawer ends, and the sidebar shows as it is.
                if new { sidebar.resolve(inline: true) }
                inline = new
            }
            .task(id: CreaseSettle.live(division)) { await settleCrease(division) }
            // The tab was measured after a launch in book mode, or the window is wide again.
            .onChange(of: bookFits) { _, _ in bookObserved(division) }
            .onChange(of: inline) { _, _ in bookObserved(division) }
            // Back from tab mode: book mode may have come or gone meanwhile.
            .onChange(of: prefs.navigation) { _, _ in bookObserved(division) }
        }
    }

    /// Book mode goes on or off once the fold has held still (`CreaseSettle`), and takes the inline
    /// sidebar with it (`BookSidebar`). Each way the tab changes size once: going in, the sidebar
    /// gives its room and the split moves to the crease in one layout; going out, the sidebar slides
    /// back over the tab first, as when it is toggled, and the tab makes room as book mode ends.
    private func settleCrease(_ division: Division?) async {
        if creaseSettle.started {
            try? await Task.sleep(nanoseconds: CreaseSettle.delay)
            if Task.isCancelled { return }
        }
        let book = CreaseSettle.live(division) != nil
        if !book, bookChanged(false) == .reopen {
            try? await Task.sleep(nanoseconds: BookSidebar.slideTime)
            // The fold moved again while the sidebar slid: the new settle decides.
            if Task.isCancelled { return }
        }
        creaseSettle.settle(division)
        if book { bookChanged(true) }
    }

    /// The window turned wide or narrow, or the tab's answer changed. Opened from shut into book
    /// mode, the fold hasn't settled yet: book mode isn't over, so the sidebar waits for the settle.
    private func bookObserved(_ division: Division?) {
        guard !creaseSettle.pending(division) else { return }
        bookChanged(creaseSettle.crease(division) != nil)
    }

    @discardableResult
    private func bookChanged(_ book: Bool) -> BookSidebar.Action? {
        // Tab mode has no sidebar for book mode to collapse, and leaves its state alone.
        guard prefs.navigation == .sidebar else { return nil }
        let action = bookSidebar.update(book: book, fits: bookFits, open: sidebar.open, inline: inline)
        switch action {
        case .collapse: sidebar.open = false
        case .reopen: sidebar.open = true
        case nil: break
        }
        return action
    }

    /// The room the docked keyboard or the key bar takes, under `-simulateDuo` too.
    private var keyboardHeight: CGFloat {
        #if DEBUG
        if simKeyboard > 0 { return simKeyboard }
        #endif
        return keyboardPad
    }

    /// Not under `-simulateDuo`, which shrinks its root for the keyboard itself.
    private func setKeyboardPad(_ pad: CGFloat) {
        #if DEBUG
        guard simulations.isEmpty else { return }
        #endif
        // The palette holds the room it opened with (`PadHold`).
        if model.palette.padHold.offer(.pad, pad) { return }
        guard pad != keyboardPad else { return }
        keyboardPad = pad
    }

    /// Lets the palette's hold write the keyboard's room back when it ends.
    private func connectPalette() {
        let center = model.palette
        center.pool = hostPool
        center.padHold.apply[.pad] = { pad in if keyboardPad != pad { keyboardPad = pad } }
        #if DEBUG
        center.padHold.apply[.sim] = { h in if simKeyboard != h { simKeyboard = h } }
        #endif
    }

    /// The fold, from the reserved regions (iOS 27.1+). Inactive regions count: a flat device still
    /// has a crease, and the sidebar's edge snaps to it.
    static func division(_ geo: GeometryProxy) -> Division? {
        if #available(iOS 27.1, *) {
            guard let r = geo.reservedRegions(kind: .division, options: .includeInactive).first else { return nil }
            return Division(frame: r.frame, isActive: r.isActive)
        }
        return nil
    }

    @ViewBuilder
    private func tab(_ arr: Arrangement) -> some View {
        let mode: WindowScreen.Mode = arr.inline ? .wide(tabletop: arr.tabletop) : .narrow
        ZStack {
            if let cur = model.current {
                WindowScreen(server: cur.server, sessionID: cur.view.sessionID, windowID: cur.window.id,
                             mode: mode, sidebarVisible: sidebarBinding, onOpen: open,
                             onBookFits: { if bookFits != $0 { bookFits = $0 } }, strip: stripRoutes)
                    .overlay { TabOfflineOverlay(server: cur.server, sidebarVisible: sidebarBinding) }
                    .transition(.opacity)
            } else {
                EmptyState(sidebarVisible: sidebarBinding, strip: stripRoutes)
                    .transition(.opacity)
            }
        }
        // Signal back: the offline screen dissolves into the tab.
        .animation(.easeInOut(duration: 0.35), value: model.current == nil)
        .onChange(of: model.current == nil) { _, none in if none { bookFits = nil } }
    }

    private var sidebarBinding: Binding<Bool> {
        Binding(get: { sidebar.shows(inline: inline) }, set: { if $0 != sidebar.shows(inline: inline) { toggleSidebar() } })
    }

    /// Every change to the sidebar's state from here: in tab mode there is none
    /// (`SidebarState.write`), so the sidebar comes back as it was left.
    private func writeSidebar(_ change: (inout SidebarState) -> Void) {
        sidebar.write(in: prefs.navigation) {
            $0.resolve(inline: inline)
            change(&$0)
        }
    }

    /// The sidebar as the agent board sees it, as it is on screen. In tab mode the board reads it
    /// and changes nothing.
    private var boardSidebar: Binding<SidebarState> {
        Binding(get: {
            var s = sidebar
            s.resolve(inline: inline)
            return s
        }, set: { new in writeSidebar { $0 = new } })
    }

    /// What tab mode's strip runs.
    private var stripRoutes: StripRoutes {
        StripRoutes(model: model, dialogs: stripDialogs, open: show)
    }

    // MARK: Commands

    /// Runs the app-wide `RexCommand`s. Tab commands go to the visible WindowScreen; with no tab on
    /// screen, tab commands open the selected tab first.
    private func handle(_ r: CommandRequest) {
        if r.command.isWindowCommand {
            guard model.current == nil, PhoneState.shared.claim(r) else { return }
            switch r.command {
            case .newTab:
                newTabOffscreen()
            case .nextTab, .previousTab, .goToTab, .tabOverview:
                if let sel = model.selection ?? firstTab() { show(sel) } else { Haptic.bump() }
            case .find:
                // No pane to search: as before find existed, the key does nothing.
                break
            case .goTo(let scope):
                // No tab: places and the commands that need no pane.
                model.palette.open(scope, target: nil)
            default:
                Haptic.bump()
            }
            return
        }
        guard PhoneState.shared.claim(r) else { return }
        switch r.command {
        case .newSession: newSession()
        case .toggleSidebar, .toggleAgents:
            // Tab mode: the agents are a sheet, and there is no sidebar to toggle.
            guard prefs.navigation == .sidebar else {
                if r.command == .toggleAgents {
                    Haptic.tap()
                    model.showAgents()
                }
                return
            }
            Haptic.tap()
            sidebar.resolve(inline: inline)
            _ = sidebar.perform(r.command)
        case .jumpToWaiting: jumpToWaiting()
        case .settings: model.showSettings = true
        case .fontBigger: setFont(prefs.fontSize + 1)
        case .fontSmaller: setFont(prefs.fontSize - 1)
        case .fontReset: setFont(Prefs.defaultFontSize)
        default: break
        }
    }

    private func setFont(_ size: Double) {
        let v = Prefs.fontSize(size)
        guard v != prefs.fontSize else { Haptic.bump(); return }
        Haptic.selection()
        prefs.fontSize = v
    }

    /// The toggle button, the shortcut and the menu command: show or hide the sidebar, in any posture.
    private func toggleSidebar() {
        guard prefs.navigation == .sidebar else { return }
        Haptic.tap()
        sidebar.resolve(inline: inline)
        sidebar.toggle()
    }

    /// The left-edge swipe brings the sidebar back.
    private func revealSidebar() {
        guard prefs.navigation == .sidebar else { return }
        Haptic.threshold()
        sidebar.reveal()
    }

    private func jumpToWaiting() {
        guard let first = Waiting.all(model.servers).first else {
            Haptic.bump()
            Notice.shared.show("No agent is waiting for you.")
            return
        }
        Haptic.selection()
        show(Waiting.prepare(model, first))
    }

    private var activeServer: ServerConnection? {
        model.current?.server ?? model.servers.first { $0.phase == .online } ?? model.servers.first
    }

    private func firstTab() -> Selection? {
        activeServer.flatMap { TabNav.first($0) }
    }

    private func newSession() {
        guard let s = activeServer else { return }
        Haptic.tap()
        Task {
            if let id = await s.createSession(label: nil), let w = s.views[id]?.windows.first {
                show(Selection(serverID: s.id, sessionID: id, windowID: w.id))
            }
        }
    }

    /// New tab with none on screen: in the selected tab's session, else the first session.
    private func newTabOffscreen() {
        guard let s = model.selection.flatMap({ model.server($0.serverID) }) ?? activeServer,
              let sid = model.selection?.sessionID ?? s.sessions.first?.id else { Haptic.bump(); return }
        let before = Set(s.views[sid]?.windows.map(\.id) ?? [])
        Haptic.tap()
        Task {
            await s.newWindow(sid)
            if let wid = await Poll.until({ s.views[sid]?.windows.first { !before.contains($0.id) }?.id }) {
                show(Selection(serverID: s.id, sessionID: sid, windowID: wid))
            }
        }
    }

    /// Selects a tab and puts it on screen: a drawer closes so the tab shows.
    private func show(_ sel: Selection) {
        open(sel)
        writeSidebar { $0.tabShown(inline: inline) }
    }

    /// Opens a tab (tab overview, title menu, tab swipes, waiting pill) in place.
    private func open(_ sel: Selection) {
        guard let s = model.server(sel.serverID) else { return }
        model.select(s, session: sel.sessionID, window: sel.windowID)
    }
}

struct EmptyState: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    @Environment(Prefs.self) private var prefs
    @Environment(\.verticalSizeClass) private var vSize
    @Environment(\.verticalBarEdge) private var barEdge
    @Binding var sidebarVisible: Bool
    /// Tab mode: what the strip's session chip and waiting pill run.
    var strip: StripRoutes?
    /// New Session is creating the first session.
    @State private var creating = false

    var body: some View {
        #if DEBUG
        let _ = RenderCount.bump(.emptyStates)
        #endif
        if prefs.navigation == .tabs {
            // The strip stays above whatever fills the tab's place, so every session and
            // machine is a tap away with no tab on screen, also while this machine is down.
            let theme = prefs.theme(for: scheme)
            VStack(spacing: 0) {
                TabStrip(target: nil, bar: barEdge != nil, height: vSize == .compact ? 34 : 44, theme: theme,
                         actions: StripActions(jump: { strip?.jump($0) }, sessions: { strip?.run($0) }), routes: strip) {
                    EmptyView()
                }
                content
            }
            .background(theme.chrome.canvas.ignoresSafeArea())
        } else {
            content
        }
    }

    @ViewBuilder private var content: some View {
        if let down = downServer {
            OfflineScreen(server: down, sidebarVisible: $sidebarVisible)
        } else {
            message
        }
    }

    /// The server to show the offline screen for: only when no server is up, so one server down
    /// among several stays a quiet note in the sidebar. The open tab's server first.
    private var downServer: ServerConnection? {
        guard !model.servers.contains(where: { $0.phase == .online && !$0.showsOffline }) else { return nil }
        let last = model.prefs.lastSelection.flatMap { model.server($0.serverID) }
        if let last, last.showsOffline { return last }
        return model.servers.first { $0.showsOffline }
    }

    private var message: some View {
        let theme = prefs.theme(for: scheme)
        let copy = EmptyStateCopy.decide(model.servers.map {
            EmptyStateCopy.Computer(name: $0.config.name, online: $0.phase == .online, synced: $0.synced, sessions: $0.sessions.count)
        }, tabs: prefs.navigation == .tabs)
        return VStack(spacing: 14) {
            Image(systemName: "terminal")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(theme.chrome.tertiary)
            Text(LocalizedStringKey(copy.text))
                .font(.subheadline)
                .foregroundStyle(theme.chrome.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
                .accessibilityLabel(PairingCopy.spoken(copy.text))
            switch copy {
            case .noComputer:
                PrimaryButton(title: "Pair via QR Code", busy: false, theme: theme) { model.showPairing = true }
                Button("Enter Address") { model.openSettings(at: .addServer) }
                    .font(.subheadline.weight(.medium))
                    .frame(minWidth: 200, minHeight: 44)
                Button("Setup Guide") { model.openGuide() }
                    .font(.footnote)
                    .foregroundStyle(theme.chrome.secondary)
                    .frame(minWidth: 200, minHeight: 44)
            case .noSessions(_, let index):
                PrimaryButton(title: "New Session", busy: creating, theme: theme) { newSession(on: model.servers[index]) }
            case .pickTab where prefs.navigation == .tabs:
                Button("Change Session") { strip?.changeSession() }
                    .frame(minHeight: 44)
            case .pickTab where !sidebarVisible:
                Button("Show Sidebar") { sidebarVisible = true }
                    .frame(minHeight: 44)
            case .pickTab, .loading, .connecting:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.bg.ignoresSafeArea())
    }

    /// The first session on a computer that has none, through the same call as New Session
    /// elsewhere; its first tab opens.
    private func newSession(on s: ServerConnection) {
        guard !creating else { return }
        Haptic.tap()
        creating = true
        Task {
            defer { creating = false }
            if let id = await s.createSession(label: nil), let w = s.views[id]?.windows.first {
                model.select(s, session: id, window: w.id)
            }
        }
    }
}

/// What the tab's place says with no tab on screen. Pure, so it is tested.
enum EmptyStateCopy: Equatable {
    /// No computer yet: where the pairing code is.
    case noComputer
    /// Every connected computer has loaded its sessions and none has one: the first of them.
    case noSessions(name: String, index: Int)
    /// Sessions are there; `tabs` is tab mode, where the strip is above.
    case pickTab(tabs: Bool)
    /// Connected, sessions not in yet: nothing is claimed about them.
    case loading
    case connecting

    struct Computer {
        var name: String
        var online: Bool
        var synced: Bool
        var sessions: Int
    }

    static func decide(_ computers: [Computer], tabs: Bool) -> EmptyStateCopy {
        if computers.isEmpty { return .noComputer }
        let online = computers.indices.filter { computers[$0].online }
        guard let first = online.first else { return .connecting }
        if online.contains(where: { computers[$0].sessions > 0 }) { return .pickTab(tabs: tabs) }
        guard online.allSatisfy({ computers[$0].synced }) else { return .loading }
        return .noSessions(name: computers[first].name, index: first)
    }

    var text: String {
        switch self {
        case .noComputer: PairingCopy.showCode + " Then scan the code."
        case .noSessions(let name, _): "No sessions on \(name) yet."
        case .pickTab(let tabs): tabs ? "Pick a session." : "Pick a tab in the sidebar."
        case .loading: "Loading your sessions…"
        case .connecting: "Connecting to Rex…"
        }
    }
}

/// The open tab's server is down: the last known tab stays under the offline screen, dimmed and
/// read-only, until the server is back and its sessions have reloaded. Its own view, so only it
/// re-renders when the server's phase changes.
struct TabOfflineOverlay: View {
    @Environment(Prefs.self) private var prefs
    @Environment(\.verticalSizeClass) private var vSize
    let server: ServerConnection
    @Binding var sidebarVisible: Bool

    var body: some View {
        ZStack {
            if server.showsOffline {
                OfflineScreen(server: server, overTab: true, sidebarVisible: $sidebarVisible)
                    .transition(.opacity)
            }
        }
        // Tab mode: the offline screen starts below the strip, which stays in reach, so another
        // machine's sessions are a tap away.
        .padding(.top, prefs.navigation == .tabs ? (vSize == .compact ? 34 : 44) : 0)
        .animation(.easeInOut(duration: 0.35), value: server.showsOffline)
    }
}

/// A small capsule for `Notice` messages. Tap to dismiss; it also fades by itself. A notice with a
/// button (Retry, Cancel) shows it after the text, and a running job's notice a thin progress line.
struct NoticeBanner: View {
    let theme: TermTheme
    private var notice: Notice { Notice.shared }

    var body: some View {
        ZStack {
            if let m = notice.message {
                HStack(spacing: 12) {
                    Text(m)
                        .font(.footnote.monospacedDigit())
                        .multilineTextAlignment(.center)
                        .foregroundStyle(theme.fg)
                        .accessibilityAddTraits(.isStaticText)
                    if let title = notice.actionTitle {
                        Button(title) { notice.runAction() }
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(theme.accent)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(Capsule().fill(theme.chrome.sidebar))
                .overlay(alignment: .bottomLeading) {
                    if let p = notice.progress {
                        GeometryReader { g in
                            Capsule().fill(theme.accent)
                                .frame(width: max(4, (g.size.width - 32) * p), height: 2)
                                .padding(.leading, 16)
                        }
                        .frame(height: 2)
                        .padding(.bottom, 3)
                        .accessibilityHidden(true)
                    }
                }
                .overlay(Capsule().stroke(notice.style == .error ? theme.chrome.error.opacity(0.5) : theme.chrome.divider, lineWidth: 1))
                .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
                .padding(.horizontal, 24)
                .padding(.top, 6)
                .frame(minHeight: 44)
                // A running job's notice goes only with its Cancel.
                .onTapGesture { if notice.progress == nil { notice.dismiss() } }
                .transition(.move(edge: .top).combined(with: .opacity))
                .accessibilityElement(children: .contain)
            }
        }
        // Not on every change of a progress notice's text.
        .animation(.snappy(duration: 0.25), value: notice.message == nil)
        .animation(.snappy(duration: 0.25), value: notice.actionTitle)
    }
}

// MARK: - Vertical bar

/// Reports where the system puts its vertical bar (`UITraitCollection.verticalBarEdge`, iOS 27.1+), or
/// nil where bars are horizontal. The trait gives the system's preferred edge whether or not a bar
/// shows yet, so the navigation bar can be shown only where it turns vertical. With the edge it
/// reports the bar's column, in screen coordinates (`KeyBarPlacement.column`), which the key bar
/// beside the keyboard ends short of. Both are read again on every change of the traits behind
/// the edge, the safe area and the layout: a rotation or a fold, not once.
struct VerticalBarObserver: UIViewRepresentable {
    let onChange: (HorizontalEdge?, CGRect?) -> Void

    func makeUIView(context: Context) -> Probe { Probe() }

    func updateUIView(_ v: Probe, context: Context) {
        v.onChange = onChange
        v.report()
    }

    final class Probe: UIView {
        var onChange: (HorizontalEdge?, CGRect?) -> Void = { _, _ in }

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            var traits: [UITrait] = [UITraitHorizontalSizeClass.self, UITraitVerticalSizeClass.self, UITraitLayoutDirection.self]
            if #available(iOS 27.1, *) { traits += UITraitCollection.systemTraitsAffectingVerticalBarEdge }
            registerForTraitChanges(traits) { (v: Probe, _) in v.report() }
        }

        required init?(coder: NSCoder) { fatalError() }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            report()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            report()
        }

        override func safeAreaInsetsDidChange() {
            super.safeAreaInsetsDidChange()
            report()
        }

        /// Measured and reported after this layout pass: the window's insets are settled by then,
        /// and the report changes SwiftUI state.
        func report() {
            guard window != nil else { return }
            DispatchQueue.main.async { [weak self] in self?.measure() }
        }

        private func measure() {
            guard let window, let screen = window.windowScene?.screen else { return }
            var edge: HorizontalEdge?
            if #available(iOS 27.1, *) {
                switch traitCollection.verticalBarEdge {
                case .leading: edge = .leading
                case .trailing: edge = .trailing
                default: edge = nil
                }
            }
            let column = KeyBarPlacement.column(edge: edge.map { $0 == .leading ? .leading : .trailing },
                                                rightToLeft: traitCollection.layoutDirection == .rightToLeft,
                                                bounds: window.bounds, insets: window.safeAreaInsets)
            onChange(edge, column.map { window.convert($0, to: screen.coordinateSpace) })
        }
    }
}
