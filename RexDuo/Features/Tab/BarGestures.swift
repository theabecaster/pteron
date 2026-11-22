import SwiftUI
import RexKit

// MARK: - Header title: tap for the tab menu, swipe for the next tab

/// The tab's title in the header. Tap opens a menu of the session's tabs; a sideways swipe moves to
/// the previous or next tab, with that tab's title sliding in under the finger (Safari's address bar).
/// Drag state lives here, so a swipe re-renders only the title.
struct TabTitleBar: View {
    let server: ServerConnection
    let sessionID: String
    let window: WindowInfo
    /// The pane on screen: its status sits right after the title.
    let block: String?
    /// The session's name (and the computer's, with more than one), after the title.
    let subtitle: String
    let theme: TermTheme
    /// A committed swipe: +1 next tab, -1 previous tab.
    let onSwipe: (Int) -> Void
    let onPick: (Selection) -> Void
    let onOverview: @MainActor () -> Void
    let onNewTab: () -> Void
    let onRename: @MainActor () -> Void
    /// Opens Go to Anything on this tab.
    let onGoTo: @MainActor () -> Void

    @State private var dx: CGFloat = 0
    @State private var width: CGFloat = 200
    @State private var armed = false
    @State private var bumped = false
    @State private var showMenu = false

    private static let commit: CGFloat = 64

    var body: some View {
        let dir = dx < 0 ? 1 : -1
        let next = dx == 0 ? nil : neighbor(dir)
        ZStack(alignment: .leading) {
            label(window, subtitle, current: true)
                .offset(x: dx)
                .opacity(dx == 0 ? 1 : max(0.2, 1 - abs(dx) / max(width * 0.8, 1)))
            if let n = next {
                label(n.window, n.subtitle, current: false)
                    .offset(x: dx + (dir > 0 ? width : -width))
                    .opacity(min(1, abs(dx) / Self.commit))
            }
        }
        .popover(isPresented: $showMenu, arrowEdge: .top) {
            TabMenu(server: server, sessionID: sessionID, currentWindowID: window.id, theme: theme,
                    close: { showMenu = false },
                    onPick: { sel in
                        onPick(sel)
                    },
                    onOverview: onOverview, onNewTab: onNewTab, onRename: onRename, onGoTo: onGoTo)
                .presentationCompactAdaptation(.popover)
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .clipped()
        .contentShape(Rectangle())
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = max($0, 1) }
        .onTapGesture { Haptic.tap(); showMenu = true }
        .gesture(drag)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { showMenu = true }
        .accessibilityAction(named: "Go to Anything") { onGoTo() }
        .accessibilityHint("Shows this session's tabs. Swipe up or down for the next or previous tab.")
        .accessibilityAdjustableAction { d in onSwipe(d == .increment ? 1 : -1) }
    }

    /// One line (`TitleLine`): title, then status, then the session's name in a quieter color,
    /// then the menu chevron. The status rides with the title, so it stays beside the text however
    /// long it is; the title truncates before the status does, and the session's name before the
    /// title. The tab sliding in under a swipe shows its own status, as its sidebar row does.
    private func label(_ w: WindowInfo, _ sub: String, current: Bool) -> some View {
        TitleLineLayout {
            TabTitle(server: server, window: w)
                .layoutValue(key: TitleLineLayout.RoleKey.self, value: .title)
            Group {
                if current {
                    if let block { BlockBadge(server: server, block: block, theme: theme) }
                } else {
                    WindowBadge(server: server, window: w, theme: theme)
                }
            }
            .fixedSize()
            .layoutValue(key: TitleLineLayout.RoleKey.self, value: .status)
            Text(sub)
                .font(.subheadline)
                .foregroundStyle(theme.chrome.secondary)
                .lineLimit(1)
                .layoutValue(key: TitleLineLayout.RoleKey.self, value: .session)
            if current {
                WakingSlot(server: server)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(theme.chrome.tertiary)
                    .accessibilityHidden(true)
            }
        }
        // The line stops growing where the bar does (`TitleLine.barHeight`), and truncates past
        // it instead of clipping.
        .dynamicTypeSize(...TitleLine.typeLimit)
        .padding(.leading, 2)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }

    private func neighbor(_ d: Int) -> (window: WindowInfo, subtitle: String)? {
        guard let sel = TabNav.neighbor(server, sessionID, window.id, by: d),
              let v = server.views[sel.sessionID], let w = v.window(sel.windowID) else { return nil }
        return (w, v.label.isEmpty ? "session" : v.label)
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { v in
                let t = v.translation.width
                guard dx != 0 || abs(t) > abs(v.translation.height) else { return }
                let d = t < 0 ? 1 : -1
                if neighbor(d) != nil {
                    dx = t
                    let past = abs(t) > Self.commit
                    if past != armed {
                        armed = past
                        if past { Haptic.threshold() }
                    }
                } else {
                    // Nothing that way: resist, and bump once.
                    dx = t * 0.25
                    armed = false
                    if !bumped, abs(t) > 30 { bumped = true; Haptic.bump() }
                }
            }
            .onEnded { v in
                let t = v.translation.width
                let d = t < 0 ? 1 : -1
                let fling = abs(v.predictedEndTranslation.width) > Self.commit * 2.2 && (v.predictedEndTranslation.width < 0) == (t < 0)
                if dx != 0, neighbor(d) != nil, abs(t) > Self.commit || fling {
                    if !armed { Haptic.selection() }
                    onSwipe(d)
                }
                armed = false
                bumped = false
                withAnimation(.snappy(duration: 0.22)) { dx = 0 }
            }
    }
}

/// The title menu: the session's tabs, then All Tabs, Go to Anything, New Tab and Rename.
struct TabMenu: View {
    let server: ServerConnection
    let sessionID: String
    let currentWindowID: String
    let theme: TermTheme
    let close: () -> Void
    let onPick: (Selection) -> Void
    // Main-actor closures are Sendable, so `later` can run them after the menu closes.
    let onOverview: @MainActor () -> Void
    let onNewTab: () -> Void
    let onRename: @MainActor () -> Void
    let onGoTo: @MainActor () -> Void

    var body: some View {
        let v = server.views[sessionID]
        let windows = v?.windows ?? []
        VStack(alignment: .leading, spacing: 0) {
            Text((v?.label).flatMap { $0.isEmpty ? nil : $0 } ?? "session")
                .font(.caption.weight(.semibold))
                .foregroundStyle(theme.chrome.tertiary)
                .lineLimit(1)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 4)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(windows) { w in
                        let current = w.id == currentWindowID
                        Button {
                            close()
                            if !current { onPick(Selection(serverID: server.id, sessionID: sessionID, windowID: w.id)) }
                        } label: {
                            HStack(spacing: 0) {
                                TabRowLabel(server: server, window: w, textSize: 15, theme: theme)
                                Image(systemName: "checkmark")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(theme.accent)
                                    .opacity(current ? 1 : 0)
                                    .frame(width: 24)
                            }
                            .padding(.horizontal, 8)
                            .background(current ? theme.chrome.rowSelected : .clear)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(current ? .isSelected : [])
                    }
                }
            }
            .frame(maxHeight: min(CGFloat(max(windows.count, 1)) * 44, 264))
            Divider().overlay(theme.chrome.divider)
            // All Tabs among them: it is here while Hide Keyboard has its place in the vertical bar.
            ForEach(TabActions.titleMenu, id: \.self) { a in
                switch a {
                case .allTabs: row(a.title, a.symbol) { later(onOverview) }
                // After the menu has closed, so the palette's field can take the keyboard.
                case .goTo:
                    row(a.title, a.symbol, key: KeyLabel.for(action: "pane.go_to", in: server.keymap)) { later(onGoTo) }
                case .newTab: row(a.title, a.symbol) { close(); onNewTab() }
                case .rename: row(a.title, a.symbol) { later(onRename) }
                default: EmptyView()
                }
            }
            Divider().overlay(theme.chrome.divider)
            Label("Swipe the title sideways to switch tabs", systemImage: "arrow.left.and.right")
                .font(.caption2)
                .foregroundStyle(theme.chrome.tertiary)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
        .frame(width: 300)
        .foregroundStyle(theme.fg)
        .presentationBackground(theme.chrome.sidebar)
    }

    /// Runs `f` once the menu has closed, so a sheet or alert can open.
    private func later(_ f: @escaping @MainActor () -> Void) {
        close()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            f()
        }
    }

    private func row(_ title: String, _ symbol: String, key: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol).frame(width: 22)
                Text(title)
                Spacer()
                if let key {
                    Text(key)
                        .font(.callout.monospaced())
                        .foregroundStyle(theme.chrome.tertiary)
                }
            }
            .font(.body)
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The waking mark beside the title, in its own view so only it re-renders when `waking` flips.
private struct WakingSlot: View {
    let server: ServerConnection

    var body: some View {
        if server.waking {
            WakingMark().transition(.opacity)
        }
    }
}
