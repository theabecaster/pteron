import SwiftUI

/// iPhone Duo first: unfolded (wide) shows Rex's sidebar beside the window canvas with real splits;
/// folded (or any regular iPhone) uses a navigation stack with one pane at a time.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    @State private var sidebarVisible = true
    @State private var path: [Selection] = []

    var body: some View {
        let theme = ThemeStore.current(scheme)
        GeometryReader { geo in
            let wide = geo.size.width >= 600
            Group {
                if wide {
                    wideLayout(theme: theme, width: geo.size.width)
                } else {
                    compactLayout(theme: theme)
                }
            }
            .background(theme.chrome.canvas.ignoresSafeArea())
        }
        .tint(theme.accent)
        .preferredColorScheme(theme.isDark ? .dark : .light)
        .sheet(isPresented: Binding(get: { model.showSettings }, set: { model.showSettings = $0 })) {
            SettingsView().environment(model)
        }
        .onChange(of: model.servers.map { $0.views.count }) { _, _ in
            model.autoSelect()
            if path.isEmpty, let t = model.autoOpenTarget() { path = [t] }
        }
    }

    @ViewBuilder
    private func wideLayout(theme: TermTheme, width: CGFloat) -> some View {
        HStack(spacing: 0) {
            if sidebarVisible {
                SidebarView(onSelect: { _ in })
                    .frame(width: min(max(width * 0.28, 240), 320))
                    .background(theme.chrome.sidebar)
                    .transition(.move(edge: .leading))
                Rectangle().fill(theme.chrome.divider).frame(width: 1).ignoresSafeArea()
            }
            Group {
                if let cur = model.current {
                    WindowScreen(server: cur.server, sessionID: cur.view.sessionID, windowID: cur.window.id,
                                 wide: true, sidebarVisible: $sidebarVisible)
                } else {
                    EmptyState(sidebarVisible: $sidebarVisible)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(.snappy(duration: 0.25), value: sidebarVisible)
    }

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
                                     wide: false, sidebarVisible: .constant(false))
                            .toolbar(.hidden, for: .navigationBar)
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
                .font(.system(size: 14))
                .foregroundStyle(theme.chrome.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
            if !sidebarVisible {
                Button("Show Sidebar") { sidebarVisible = true }
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
