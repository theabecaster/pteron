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
    /// The sidebar is showing: inline beside the tab, or the drawer over it.
    @State private var sidebar = SidebarState()
    /// The sidebar is inline (wide window). Mirrors the arrangement for commands.
    @State private var inline = false
    /// The root's height without the keyboard.
    @State private var keyboardFreeHeight: CGFloat = 0
    /// Where the system puts its vertical bar, if it has one here.
    @State private var barEdge: HorizontalEdge?
    /// Keeps each pane's terminal alive while a fold or unfold rebuilds the layout.
    @State private var hostPool = TerminalHostPool()
    #if DEBUG
    @State private var simIndex = 0
    @State private var simKeyboard: CGFloat = 0
    private let simulations = DuoSimulation.sequence
    #endif

    var body: some View {
        let theme = prefs.theme(for: scheme)
        rootContent(theme)
            .environment(hostPool)
            .overlay(alignment: .top) { NoticeBanner(theme: theme) }
            .background(CommandListener { handle($0) })
            .background(WaitingWatcher())
            .background(VerticalBarObserver { e in if barEdge != e { barEdge = e } })
            .accessibilityAction(.magicTap) { model.perform(.jumpToWaiting) }
            .tint(theme.accent)
            .preferredColorScheme(theme.isDark ? .dark : .light)
            .sheet(isPresented: Binding(get: { model.showSettings }, set: { model.showSettings = $0 })) {
                SettingsView().environment(model)
            }
            .pairingCover(isPresented: Binding(get: { model.showPairing }, set: { model.showPairing = $0 }), model: model) {
                model.openSettings(at: .addServer)
            }
            .onChange(of: model.servers.map { $0.views.count }) { _, _ in
                model.autoSelect()
            }
            .onChange(of: model.openRequest) { _, r in if let r { show(r.selection) } }
            .onAppear {
                // Nothing to list yet: the tab area, which says how to add a server, shows.
                if model.servers.isEmpty { sidebar.open = false }
                #if DEBUG
                // `-simulateScan <payload>` (testing): open the scanner at launch.
                if UserDefaults.standard.string(forKey: "simulateScan") != nil, SettingsPage.debugLaunch == nil {
                    model.showPairing = true
                }
                // `-pairHost <https address>` (testing): open the pairing flow at that address.
                if let host = UserDefaults.standard.string(forKey: "pairHost").flatMap(URL.init(string:)) {
                    model.startPairing(prefilled: host, guessed: true)
                }
                // `-sidebar closed` (testing): start with the sidebar hidden.
                if UserDefaults.standard.string(forKey: "sidebar") == "closed" { sidebar.open = false }
                // `-sidebarMode agents` (testing): start in Agents mode.
                if let m = UserDefaults.standard.string(forKey: "sidebarMode").flatMap(SidebarMode.init(rawValue:)) {
                    sidebar.mode = m
                }
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
    /// The keyboard shrinks it from below by its height, as on the device.
    private func simulated(_ sim: DuoSimulation, _ theme: TermTheme) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                layout(theme, fake: .some(sim.rootDivision))
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
        .background(Color(white: 0.45).ignoresSafeArea())
        .ignoresSafeArea(.keyboard)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { n in
            let f = (n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect) ?? .zero
            simKeyboard = (n.object as? UIScreen).map { f.intersection($0.bounds).height } ?? 0
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
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
    /// (debug simulation).
    private func layout(_ theme: TermTheme, fake: Division??) -> some View {
        GeometryReader { geo in
            let division = fake ?? Self.division(geo)
            // The keyboard shrinks the height; the arrangement must not change when it shows.
            let size = CGSize(width: geo.size.width, height: max(geo.size.height, keyboardFreeHeight))
            let arr = Arrangement.decide(size: size, division: division)
            NavigationStack {
                SidebarSplit(arrangement: arr, theme: theme, open: $sidebar.open) {
                    SidebarView(mode: $sidebar.mode, onSelect: { _ in sidebar.tabShown(inline: arr.inline) })
                } tab: {
                    tab(arr)
                }
                .background(theme.chrome.canvas.ignoresSafeArea())
                .background(EdgeReveal(enabled: !sidebar.open) { revealSidebar() })
                // Only where the system has a vertical bar: the toggle and the tab's actions go there.
                // Elsewhere the tab's title bar holds them, Mac-like, with no second bar above it.
                .toolbar(barEdge == nil ? .hidden : .visible, for: .navigationBar)
                .toolbar {
                    if barEdge != nil {
                        ToolbarItem(placement: .topBarLeading) {
                            Button { toggleSidebar() } label: {
                                Label(sidebar.open ? "Hide Sidebar" : "Show Sidebar", systemImage: "sidebar.left")
                            }
                        }
                    }
                }
            }
            .environment(\.division, division)
            .environment(\.rootOrigin, geo.frame(in: .global).origin)
            .environment(\.verticalBarEdge, barEdge)
            .onChange(of: arr.inline, initial: true) { _, new in inline = new }
        }
        .background {
            Color.clear
                .ignoresSafeArea(.keyboard)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { keyboardFreeHeight = $0 }
        }
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
                             mode: mode, sidebarVisible: sidebarBinding, onOpen: open)
                    .overlay { TabOfflineOverlay(server: cur.server, sidebarVisible: sidebarBinding) }
                    .transition(.opacity)
            } else {
                EmptyState(sidebarVisible: sidebarBinding)
                    .transition(.opacity)
            }
        }
        // Signal back: the offline screen dissolves into the tab.
        .animation(.easeInOut(duration: 0.35), value: model.current == nil)
    }

    private var sidebarBinding: Binding<Bool> {
        Binding(get: { sidebar.open }, set: { if $0 != sidebar.open { toggleSidebar() } })
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
            default:
                Haptic.bump()
            }
            return
        }
        guard PhoneState.shared.claim(r) else { return }
        switch r.command {
        case .newSession: newSession()
        case .toggleSidebar, .toggleAgents:
            Haptic.tap()
            _ = sidebar.perform(r.command)
        case .jumpToWaiting: jumpToWaiting()
        case .settings: model.showSettings = true
        case .fontBigger: setFont(prefs.fontSize + 1)
        case .fontSmaller: setFont(prefs.fontSize - 1)
        case .fontReset: setFont(11)
        default: break
        }
    }

    private func setFont(_ size: Double) {
        let v = min(max((size * 2).rounded() / 2, 7), 20)
        guard v != prefs.fontSize else { Haptic.bump(); return }
        Haptic.selection()
        prefs.fontSize = v
    }

    /// The toggle button, the shortcut and the menu command: show or hide the sidebar, in any posture.
    private func toggleSidebar() {
        Haptic.tap()
        sidebar.toggle()
    }

    /// The left-edge swipe brings the sidebar back.
    private func revealSidebar() {
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
        sidebar.tabShown(inline: inline)
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
    @Binding var sidebarVisible: Bool

    var body: some View {
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
        return VStack(spacing: 14) {
            Image(systemName: "terminal")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(theme.chrome.tertiary)
            Text(LocalizedStringKey(statusText))
                .font(.subheadline)
                .foregroundStyle(theme.chrome.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
            if model.servers.isEmpty {
                PrimaryButton(title: "Pair via QR Code", busy: false, theme: theme) { model.showPairing = true }
                Button("Enter Address") { model.openSettings(at: .addServer) }
                    .font(.subheadline.weight(.medium))
                    .frame(minWidth: 200, minHeight: 44)
            } else if !sidebarVisible {
                Button("Show Sidebar") { sidebarVisible = true }
                    .frame(minHeight: 44)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.bg.ignoresSafeArea())
    }

    private var statusText: String {
        if model.servers.isEmpty {
            return "On your computer, run `rex server tailscale pair`, then scan the code it shows."
        }
        if model.servers.contains(where: { $0.phase == .online }) { return "Pick a tab in the sidebar." }
        return "Connecting to Rex…"
    }
}

/// The open tab's server is down: the last known tab stays under the offline screen, dimmed and
/// read-only, until the server is back and its sessions have reloaded. Its own view, so only it
/// re-renders when the server's phase changes.
struct TabOfflineOverlay: View {
    let server: ServerConnection
    @Binding var sidebarVisible: Bool

    var body: some View {
        ZStack {
            if server.showsOffline {
                OfflineScreen(server: server, overTab: true, sidebarVisible: $sidebarVisible)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: server.showsOffline)
    }
}

/// A small capsule for `Notice` messages. Tap to dismiss; it also fades by itself.
struct NoticeBanner: View {
    let theme: TermTheme
    private var notice: Notice { Notice.shared }

    var body: some View {
        ZStack {
            if let m = notice.message {
                Text(m)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(theme.fg)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(Capsule().fill(theme.chrome.sidebar))
                    .overlay(Capsule().stroke(notice.style == .error ? theme.chrome.error.opacity(0.5) : theme.chrome.divider, lineWidth: 1))
                    .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
                    .padding(.horizontal, 24)
                    .padding(.top, 6)
                    .frame(minHeight: 44)
                    .onTapGesture { notice.dismiss() }
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .accessibilityAddTraits(.isStaticText)
            }
        }
        .animation(.snappy(duration: 0.25), value: notice.message)
    }
}

// MARK: - Vertical bar

/// Reports where the system puts its vertical bar (`UITraitCollection.verticalBarEdge`, iOS 27.1+), or
/// nil where bars are horizontal. The trait gives the system's preferred edge whether or not a bar
/// shows yet, so the navigation bar can be shown only where it turns vertical.
struct VerticalBarObserver: UIViewRepresentable {
    let onChange: (HorizontalEdge?) -> Void

    func makeUIView(context: Context) -> Probe { Probe() }

    func updateUIView(_ v: Probe, context: Context) {
        v.onChange = onChange
        v.report()
    }

    final class Probe: UIView {
        var onChange: (HorizontalEdge?) -> Void = { _ in }

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            registerForTraitChanges([UITraitHorizontalSizeClass.self, UITraitVerticalSizeClass.self]) { (v: Probe, _) in
                v.report()
            }
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

        func report() {
            guard window != nil else { return }
            var edge: HorizontalEdge?
            if #available(iOS 27.1, *) {
                switch traitCollection.verticalBarEdge {
                case .leading: edge = .leading
                case .trailing: edge = .trailing
                default: edge = nil
                }
            }
            let send = onChange
            // Reported after this layout pass: it changes SwiftUI state.
            DispatchQueue.main.async { send(edge) }
        }
    }
}
