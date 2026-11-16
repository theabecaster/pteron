import SwiftUI
import UIKit

/// iPhone Duo first. The layout comes from size classes and the fold's reserved region
/// (`Arrangement.decide`), never from orientation or the hinge:
/// - Folded, any other iPhone, any landscape iPhone (compact width or height): a navigation stack,
///   sidebar then tab, one pane at a time.
/// - Unfolded (inner screen, landscape, vertical crease): two pages split at the crease. The sidebar
///   fills the left page and the tab's panes, split as the Mac lays them out, the right.
/// - Unfolded portrait (horizontal crease): the tab the full width, the sidebar as an overlay. Partly
///   folded (tabletop), the terminal sits above the crease and the controls below it.
/// The hinge (`model.hinge`) only tints the crease while the device is partly open.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    @Environment(\.horizontalSizeClass) private var hSize
    @Environment(\.verticalSizeClass) private var vSize
    @Environment(Prefs.self) private var prefs
    /// Unfolded portrait: the sidebar overlay is open.
    @State private var overlaySidebar = false
    @State private var path: [Selection] = []
    /// The navigation stack is in use (folded or any other iPhone). Mirrors the arrangement for commands.
    @State private var stacked = true
    /// The root's height without the keyboard.
    @State private var keyboardFreeHeight: CGFloat = 0
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
            .accessibilityAction(.magicTap) { model.perform(.jumpToWaiting) }
            .background(HingeObserver { h in
                // Layout never reads the hinge. Only a status change matters (the crease tint), so an
                // angle change alone invalidates nothing.
                let new = AppModel.hingeOverride ?? h
                if model.hinge?.status != new?.status { model.hinge = new }
            })
            .tint(theme.accent)
            .preferredColorScheme(theme.isDark ? .dark : .light)
            .sheet(isPresented: Binding(get: { model.showSettings }, set: { model.showSettings = $0 })) {
                SettingsView().environment(model)
            }
            .onChange(of: model.servers.map { $0.views.count }) { _, _ in
                model.autoSelect()
            }
            .onChange(of: model.autoOpenTarget(), initial: true) { _, t in
                if path.isEmpty, let t { path = [t] }
            }
            .onAppear {
                if let h = AppModel.hingeOverride { model.hinge = h }
                #if DEBUG
                // `-overlaySidebar YES` (testing): start with the unfolded-portrait sidebar open.
                if UserDefaults.standard.bool(forKey: "overlaySidebar") { overlaySidebar = true }
                #endif
            }
    }

    @ViewBuilder
    private func rootContent(_ theme: TermTheme) -> some View {
        #if DEBUG
        if !simulations.isEmpty {
            simulated(simulations[simIndex % simulations.count], theme)
        } else {
            layout(theme, h: hSize, v: vSize)
        }
        #else
        layout(theme, h: hSize, v: vSize)
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
                layout(theme, h: sim.horizontal, v: sim.vertical, fake: .some(sim.division))
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

    /// Lays out the sidebar and tab for the size classes and the fold. `fake` replaces the fold
    /// (debug simulation).
    private func layout(_ theme: TermTheme, h: UserInterfaceSizeClass?, v: UserInterfaceSizeClass?,
                        fake: Division?? = nil) -> some View {
        GeometryReader { geo in
            let division = fake ?? Self.division(geo)
            // The keyboard shrinks the height; the arrangement must not change when it shows.
            let size = CGSize(width: geo.size.width, height: max(geo.size.height, keyboardFreeHeight))
            arranged(Arrangement.decide(size: size, horizontal: h, vertical: v, division: division),
                     division: division, theme: theme)
        }
        .background {
            Color.clear
                .ignoresSafeArea(.keyboard)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { keyboardFreeHeight = $0 }
        }
    }

    /// The fold, from the reserved regions (iOS 27.1+). Inactive regions count: a flat device still
    /// has a crease, and two pages split at it read better than one page across it.
    private static func division(_ geo: GeometryProxy) -> Division? {
        if #available(iOS 27.1, *) {
            guard let r = geo.reservedRegions(kind: .division, options: .includeInactive).first else { return nil }
            return Division(frame: r.frame, isActive: r.isActive)
        }
        return nil
    }

    private func arranged(_ arr: Arrangement, division: Division?, theme: TermTheme) -> some View {
        Group {
            switch arr {
            case .stack:
                stackLayout(theme: theme)
            case .pages(let first, let gap):
                pagesLayout(theme: theme, first: first, gap: gap)
            case .overlay:
                overlayLayout(theme: theme, mode: .full())
                    .background(edgeReveal(arr))
            case .tabletop(let top, let gap):
                overlayLayout(theme: theme, mode: .full(top: top, gap: gap))
                    .background(edgeReveal(arr))
            }
        }
        .environment(\.division, division)
        .background(theme.chrome.canvas.ignoresSafeArea())
        .onChange(of: arr, initial: true) { old, new in
            stacked = new.isStack
            if old.isStack != new.isStack { folded(into: new.isStack) }
        }
    }

    /// A fold or an unfold switched between the stack and a wide layout. Keeps what was on screen:
    /// folding while a tab shows pushes that tab, so the outer screen shows it rather than the sidebar.
    private func folded(into stack: Bool) {
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            if stack {
                if let sel = model.selection, model.current != nil { path = [sel] }
            } else {
                overlaySidebar = false
            }
        }
    }

    // MARK: Commands

    /// Is a tab on screen (so its WindowScreen runs the tab commands)?
    private var tabShown: Bool { stacked ? !path.isEmpty : model.current != nil }

    /// Runs the app-wide `RexCommand`s. Tab commands go to the visible WindowScreen; with no tab on
    /// screen, tab commands open the selected tab first.
    private func handle(_ r: CommandRequest) {
        if r.command.isWindowCommand {
            guard !tabShown, PhoneState.shared.claim(r) else { return }
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
        case .toggleSidebar: toggleSidebar()
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

    /// Stack: back to the sidebar, or into the selected tab. One column: the overlay opens or closes.
    /// Two pages: the sidebar always has its page.
    private func toggleSidebar() {
        guard !stacked else {
            if !path.isEmpty { path = [] } else if let sel = model.selection { path = [sel] }
            return
        }
        withAnimation(.snappy(duration: 0.25)) { overlaySidebar.toggle() }
    }

    /// One column: the left-edge swipe brings the sidebar overlay in.
    private func revealSidebar() {
        Haptic.threshold()
        withAnimation(.snappy(duration: 0.25)) { overlaySidebar = true }
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

    /// Selects a tab and puts it on screen, pushing it when the sidebar is all that shows.
    private func show(_ sel: Selection) {
        open(sel)
        if path.isEmpty, stacked { path = [sel] }
    }

    // MARK: Wide

    private func edgeReveal(_ arr: Arrangement) -> some View {
        EdgeReveal(enabled: !overlaySidebar) { revealSidebar() }
    }

    /// Two pages split at the crease, like the Mac app's window: the sidebar, then the tab's panes.
    /// Nothing interactive or textual sits on the crease.
    private func pagesLayout(theme: TermTheme, first: CGFloat, gap: CGFloat) -> some View {
        HStack(spacing: 0) {
            sidebar(theme) { _ in }
                .frame(width: first)
            Crease(gap: gap, theme: theme)
            tab(mode: .page, sidebarVisible: .constant(true))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// One column the full width (unfolded portrait), the sidebar as an overlay from the leading edge.
    private func overlayLayout(theme: TermTheme, mode: WindowScreen.Mode) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                tab(mode: mode, sidebarVisible: $overlaySidebar)
                if overlaySidebar {
                    Color.black.opacity(0.3)
                        .ignoresSafeArea()
                        .onTapGesture { withAnimation(.snappy(duration: 0.25)) { overlaySidebar = false } }
                        .accessibilityLabel("Hide Sidebar")
                        .accessibilityAddTraits(.isButton)
                        .transition(.opacity)
                    sidebar(theme) { _ in withAnimation(.snappy(duration: 0.25)) { overlaySidebar = false } }
                        .frame(width: min(320, geo.size.width * 0.6))
                        .overlay(alignment: .trailing) {
                            Rectangle().fill(theme.chrome.divider).frame(width: 1).ignoresSafeArea()
                        }
                        .shadow(color: .black.opacity(0.25), radius: 12)
                        .transition(.move(edge: .leading))
                }
            }
        }
    }

    private func sidebar(_ theme: TermTheme, onSelect: @escaping (Selection) -> Void) -> some View {
        SidebarView(onSelect: onSelect)
            .background(theme.chrome.sidebar.ignoresSafeArea())
    }

    @ViewBuilder
    private func tab(mode: WindowScreen.Mode, sidebarVisible: Binding<Bool>) -> some View {
        if let cur = model.current {
            WindowScreen(server: cur.server, sessionID: cur.view.sessionID, windowID: cur.window.id,
                         mode: mode, sidebarVisible: sidebarVisible, onOpen: open)
        } else {
            EmptyState(sidebarVisible: sidebarVisible, showsSidebarButton: mode != .page)
        }
    }

    /// Opens a tab from the tab overview: swaps the shown tab in place, without a push animation.
    private func open(_ sel: Selection) {
        guard let s = model.server(sel.serverID) else { return }
        model.select(s, session: sel.sessionID, window: sel.windowID)
        if !path.isEmpty {
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { path = [sel] }
        }
    }

    // MARK: Stack

    @ViewBuilder
    private func stackLayout(theme: TermTheme) -> some View {
        NavigationStack(path: $path) {
            SidebarView(onSelect: { sel in path = [sel] })
                .background(theme.chrome.sidebar.ignoresSafeArea())
                .navigationTitle("Rex")
                .navigationBarTitleDisplayMode(.inline)
                .navigationDestination(for: Selection.self) { sel in
                    if let s = model.server(sel.serverID) {
                        WindowScreen(server: s, sessionID: sel.sessionID, windowID: sel.windowID,
                                     mode: .compact, sidebarVisible: .constant(false), onOpen: open)
                            .toolbar(.hidden, for: .navigationBar)
                            .background(SwipeBackEnabler())
                    }
                }
        }
    }
}

/// The crease between two pages. Flat, a hairline; partly folded, the region's width (its tap
/// margins included), so nothing interactive sits there. The hinge only strengthens the line, and
/// this view is the only one that reads it.
struct Crease: View {
    @Environment(AppModel.self) private var model
    let gap: CGFloat
    let theme: TermTheme

    var body: some View {
        let bent = model.hinge?.status == .partial
        Rectangle()
            .fill(theme.chrome.canvas)
            .frame(width: max(gap, 1))
            .overlay {
                Rectangle().fill(bent ? theme.chrome.activeBorder.opacity(0.6) : theme.chrome.divider).frame(width: 1)
            }
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }
}

struct EmptyState: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    @Environment(Prefs.self) private var prefs
    @Binding var sidebarVisible: Bool
    /// Beside the sidebar, there's no sidebar to show.
    var showsSidebarButton = true

    var body: some View {
        let theme = prefs.theme(for: scheme)
        VStack(spacing: 14) {
            Image(systemName: "terminal")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(theme.chrome.tertiary)
            Text(statusText)
                .font(.subheadline)
                .foregroundStyle(theme.chrome.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
            if model.servers.isEmpty {
                Button("Add a Server") { model.showSettings = true }
                    .frame(minHeight: 44)
            } else if showsSidebarButton, !sidebarVisible {
                Button("Show Sidebar") { sidebarVisible = true }
                    .frame(minHeight: 44)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.bg)
    }

    private var statusText: String {
        if model.servers.isEmpty {
            return "Add your Rex server's Tailscale address, https://<name>.<tailnet>.ts.net, in Settings."
        }
        if model.servers.contains(where: { $0.phase == .online }) { return "Pick a tab in the sidebar." }
        if let s = model.servers.first, case .offline(let m) = s.phase {
            return "Can't reach \(s.config.name).\n\(m)\n\nTailscale must be on, signed in as the same account as the Mac."
        }
        return "Connecting to Rex…"
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
                    .overlay(Capsule().stroke(theme.chrome.error.opacity(0.5), lineWidth: 1))
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

// MARK: - Hinge

/// Reads the hinge with `UIHingeInteraction` (iOS 27.1+). Reports nil when there's no hinge info.
struct HingeObserver: UIViewRepresentable {
    let onChange: (HingeInfo?) -> Void

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.isUserInteractionEnabled = false
        if #available(iOS 27.1, *) {
            let report = onChange
            let interaction = UIHingeInteraction { _, update in
                guard let h = update.hinge else { report(nil); return }
                let status: HingeInfo.Status
                switch h.status {
                case .closed: status = .closed
                case .partiallyOpen: status = .partial
                case .fullyOpen: status = .full
                default: status = .unknown
                }
                report(HingeInfo(status: status, angle: Double(h.angle)))
            }
            v.addInteraction(interaction)
        }
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

// MARK: - Edge swipe back

/// Keeps the navigation stack's edge swipe-back working while the navigation bar is hidden.
/// The edge swipe wins over the terminal's own pans and swipes, which wait for it to fail.
struct SwipeBackEnabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ vc: Controller, context: Context) {}

    final class Controller: UIViewController {
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard let nav = navigationController, let pop = nav.interactivePopGestureRecognizer else { return }
            PopGestureDelegate.shared.nav = nav
            pop.delegate = PopGestureDelegate.shared
            pop.isEnabled = true
            // iOS 26's full-width content swipe would fight the terminal's pane swipes; keep the edge only.
            if #available(iOS 26.0, *) { nav.interactiveContentPopGestureRecognizer?.isEnabled = false }
        }
    }
}

/// Outlives any one screen so the pop gesture never points at a freed delegate.
final class PopGestureDelegate: NSObject, UIGestureRecognizerDelegate {
    static let shared = PopGestureDelegate()
    weak var nav: UINavigationController?

    func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        guard let nav else { return false }
        return nav.viewControllers.count > 1 && nav.transitionCoordinator == nil
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        other is UIPanGestureRecognizer || other is UISwipeGestureRecognizer
    }
}
