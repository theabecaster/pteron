import SwiftUI
import UIKit

/// iPhone Duo first.
/// - Folded (or any regular iPhone): a navigation stack with one pane at a time.
/// - Unfolded portrait: two pages split at the crease. Sidebar fills the left page, the tab the right;
///   or, with dual pages on, one pane per page.
/// - Unfolded landscape (laptop posture): the tab on the top half, the sidebar on the bottom half.
/// - Wide with no crease known (iPad landscape, hinge info missing): a narrow sidebar beside the tab.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    @State private var sidebarVisible = true
    @State private var path: [Selection] = []

    var body: some View {
        let theme = ThemeStore.current(scheme)
        GeometryReader { geo in
            let ins = geo.safeAreaInsets
            let full = CGSize(width: geo.size.width + ins.leading + ins.trailing,
                              height: geo.size.height + ins.top + ins.bottom)
            Group {
                switch arrangement(geo.size, full: full) {
                case .compact:
                    compactLayout(theme: theme)
                case .pages:
                    pagedLayout(theme: theme, firstPage: max(full.width / 2 - ins.leading, 200))
                case .sidebar:
                    pagedLayout(theme: theme, firstPage: min(max(geo.size.width * 0.28, 240), 320))
                case .stacked:
                    stackedLayout(theme: theme, firstPage: max(full.height / 2 - ins.top, 200))
                }
            }
            .background(theme.chrome.canvas.ignoresSafeArea())
        }
        .overlay(alignment: .top) { NoticeBanner(theme: theme) }
        .background(HingeObserver { model.hinge = AppModel.hingeOverride ?? $0 })
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
        .onAppear { if let h = AppModel.hingeOverride { model.hinge = h } }
    }

    private enum Arrangement { case compact, pages, sidebar, stacked }

    /// Picks the layout from the size and the hinge. The crease is assumed to sit at the screen's center:
    /// vertical in portrait, horizontal in landscape.
    private func arrangement(_ size: CGSize, full: CGSize) -> Arrangement {
        guard size.width >= 600 else { return .compact }
        let landscape = full.width > full.height
        switch model.hinge {
        case .some(let h) where h.isOpen:
            return landscape ? .stacked : .pages
        case .some(let h) where h.status == .closed:
            return .sidebar
        default:
            // No hinge info: portrait wide screens are treated as two pages; landscape gets a narrow sidebar.
            return landscape ? .sidebar : .pages
        }
    }

    private var paneCount: Int { model.current?.window.orderedBlockIDs.count ?? 0 }
    private var dual: Bool { model.dualPages && paneCount >= 2 }

    // MARK: Wide

    @ViewBuilder
    private func pagedLayout(theme: TermTheme, firstPage: CGFloat) -> some View {
        if dual {
            tab(mode: .dual(split: firstPage, vertical: false))
        } else {
            HStack(spacing: 0) {
                if sidebarVisible {
                    sidebar(theme)
                        .frame(width: firstPage)
                        .overlay(alignment: .trailing) {
                            Rectangle().fill(theme.chrome.divider).frame(width: 1).ignoresSafeArea()
                        }
                        .transition(.move(edge: .leading))
                }
                tab(mode: sidebarVisible ? .page : .full)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .animation(.snappy(duration: 0.25), value: sidebarVisible)
        }
    }

    /// Laptop posture: the terminal stays on the top half; the keyboard and sidebar share the bottom half.
    @ViewBuilder
    private func stackedLayout(theme: TermTheme, firstPage: CGFloat) -> some View {
        Group {
            if dual {
                tab(mode: .dual(split: firstPage, vertical: true))
            } else {
                VStack(spacing: 0) {
                    tab(mode: .full)
                        .frame(height: sidebarVisible ? firstPage : nil)
                        .frame(maxHeight: sidebarVisible ? nil : .infinity)
                    if sidebarVisible {
                        sidebar(theme)
                            .overlay(alignment: .top) { Rectangle().fill(theme.chrome.divider).frame(height: 1) }
                            .frame(maxHeight: .infinity)
                            .transition(.move(edge: .bottom))
                    }
                }
                .animation(.snappy(duration: 0.25), value: sidebarVisible)
            }
        }
        .ignoresSafeArea(.keyboard)
    }

    private func sidebar(_ theme: TermTheme) -> some View {
        SidebarView(onSelect: { _ in })
            .background(theme.chrome.sidebar.ignoresSafeArea())
    }

    @ViewBuilder
    private func tab(mode: WindowScreen.Mode) -> some View {
        if let cur = model.current {
            WindowScreen(server: cur.server, sessionID: cur.view.sessionID, windowID: cur.window.id,
                         mode: mode, sidebarVisible: $sidebarVisible, onOpen: open)
        } else {
            EmptyState(sidebarVisible: $sidebarVisible)
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

    // MARK: Compact

    @ViewBuilder
    private func compactLayout(theme: TermTheme) -> some View {
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

struct EmptyState: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    @Binding var sidebarVisible: Bool

    var body: some View {
        let theme = ThemeStore.current(scheme)
        VStack(spacing: 14) {
            Image(systemName: "terminal")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(theme.chrome.tertiary)
            Text(statusText)
                .font(.subheadline)
                .foregroundStyle(theme.chrome.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
            if !sidebarVisible {
                Button("Show Sidebar") { sidebarVisible = true }
                    .frame(minHeight: 44)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.bg)
    }

    private var statusText: String {
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
