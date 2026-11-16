import SwiftUI
import RexKit
import TipKit

// MARK: - Pane actions

/// What a pane's menus can do. WindowScreen fills it in; the ⋯ menu, the pager's context menu and
/// the dock's buttons all run the same closures.
struct PaneActions {
    var split: (_ vertical: Bool) -> Void
    var newTab: () -> Void
    /// Nil when there's nothing to zoom (one pane fills the screen already).
    var zoom: (() -> Void)?
    var zoomed: Bool
    /// Two pages: put this pane on the other page.
    var swapPages: (() -> Void)?
    var clear: () -> Void
    var renameTab: () -> Void
    var close: () -> Void
    var overview: () -> Void
}

/// The pane context menu (touch and hold the pager): split, zoom, clear, rename, close last.
struct PaneMenuItems: View {
    let actions: PaneActions

    var body: some View {
        Section {
            Button { actions.split(false) } label: { Label("Split Right", systemImage: "rectangle.split.2x1") }
            Button { actions.split(true) } label: { Label("Split Down", systemImage: "rectangle.split.1x2") }
        }
        Section {
            if let z = actions.zoom {
                Button(action: z) {
                    Label(actions.zoomed ? "Unzoom" : "Zoom Pane",
                          systemImage: actions.zoomed ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                }
            }
            if let s = actions.swapPages {
                Button(action: s) { Label("Swap Pages", systemImage: "arrow.left.arrow.right") }
            }
            Button(action: actions.clear) { Label("Clear", systemImage: "eraser") }
            Button(action: actions.renameTab) { Label("Rename Tab…", systemImage: "pencil") }
        }
        Section {
            Button(role: .destructive, action: actions.close) { Label("Close Pane", systemImage: "xmark.square") }
        }
    }
}

// MARK: - Header title: tap for the tab menu, swipe for the next tab

/// The tab's title in the header. Tap opens a menu of the session's tabs; a sideways swipe moves to
/// the previous or next tab, with that tab's title sliding in under the finger (Safari's address bar).
/// Drag state lives here, so a swipe re-renders only the title.
struct TabTitleBar: View {
    let server: ServerConnection
    let sessionID: String
    let window: WindowInfo
    let subtitle: String
    let theme: TermTheme
    /// A committed swipe: +1 next tab, -1 previous tab.
    let onSwipe: (Int) -> Void
    let onPick: (Selection) -> Void
    let onOverview: @MainActor () -> Void
    let onNewTab: () -> Void
    let onRename: @MainActor () -> Void

    @State private var dx: CGFloat = 0
    @State private var width: CGFloat = 200
    @State private var armed = false
    @State private var bumped = false
    @State private var showMenu = false
    private let tip = TabSwipeTip()

    private static let commit: CGFloat = 64

    var body: some View {
        let dir = dx < 0 ? 1 : -1
        let next = dx == 0 ? nil : neighbor(dir)
        ZStack(alignment: .leading) {
            label(window, subtitle, menuChevron: true)
                .offset(x: dx)
                .opacity(dx == 0 ? 1 : max(0.2, 1 - abs(dx) / max(width * 0.8, 1)))
            if let n = next {
                label(n.window, n.subtitle, menuChevron: false)
                    .offset(x: dx + (dir > 0 ? width : -width))
                    .opacity(min(1, abs(dx) / Self.commit))
            }
        }
        .popover(isPresented: $showMenu, arrowEdge: .top) {
            TabMenu(server: server, sessionID: sessionID, currentWindowID: window.id, theme: theme,
                    close: { showMenu = false },
                    onPick: { sel in
                        GestureTips.donate(TabSwipeTip.switchedTabs)
                        GestureTips.donate(OverviewGestureTip.switchedFromTitleMenu)
                        onPick(sel)
                    },
                    onOverview: onOverview, onNewTab: onNewTab, onRename: onRename)
                .presentationCompactAdaptation(.popover)
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .clipped()
        .contentShape(Rectangle())
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = max($0, 1) }
        .onTapGesture { Haptic.tap(); showMenu = true }
        .gesture(drag)
        .popoverTip(tip, arrowEdge: .top)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { showMenu = true }
        .accessibilityHint("Shows this session's tabs. Swipe up or down for the next or previous tab.")
        .accessibilityAdjustableAction { d in onSwipe(d == .increment ? 1 : -1) }
    }

    private func label(_ w: WindowInfo, _ sub: String, menuChevron: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                TabTitle(server: server, window: w)
                if menuChevron {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(theme.chrome.tertiary)
                        .accessibilityHidden(true)
                }
            }
            Text(sub)
                .font(.caption2)
                .foregroundStyle(theme.chrome.tertiary)
                .lineLimit(1)
        }
        .padding(.leading, 2)
        .padding(.vertical, 3)
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

/// The title menu: the session's tabs, then All Tabs, New Tab and Rename.
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
            row("All Tabs", "square.on.square") { later(onOverview) }
            row("New Tab", "plus.square") { close(); onNewTab() }
            row("Rename Tab…", "pencil") { later(onRename) }
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

    private func row(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol).frame(width: 22)
                Text(title)
                Spacer()
            }
            .font(.body)
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Dock pager: swipe sideways for panes, up for all tabs, past the end for a new pane

/// The middle of the dock pager: the pane's name and dots. Drags here pick their direction from the
/// first movement: up opens the tab overview, sideways changes pane, and past the last pane a
/// "New Pane" card slides in and commits on release. Touch and hold for the pane menu.
struct PagerCenter: View {
    let server: ServerConnection
    let window: WindowInfo
    let block: String
    /// The panes a swipe steps through (two pages: not the one on the other page).
    let stepIDs: [String]
    let theme: TermTheme
    let actions: PaneActions
    let onPick: (String) -> Void
    let onStep: (Int) -> Void
    let onNewPane: () -> Void

    @State private var dx: CGFloat = 0
    @State private var dy: CGFloat = 0
    @State private var axis: Axis?
    @State private var armed = false
    @State private var bumped = false
    private let tip = OverviewGestureTip()

    private static let upCommit: CGFloat = 36
    private static let newCommit: CGFloat = 100
    private static let newDamping: CGFloat = 0.4

    var body: some View {
        let ids = window.orderedBlockIDs
        let idx = ids.firstIndex(of: block) ?? 0
        let step = stepIDs.firstIndex(of: block) ?? 0
        let newProgress = (axis == .horizontal && step == stepIDs.count - 1 && dx < 0)
            ? min(1, -dx / (Self.newCommit * Self.newDamping)) : 0
        ZStack {
            VStack(spacing: 2) {
                Image(systemName: "chevron.compact.up")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(axis == .vertical && armed ? theme.accent : theme.chrome.tertiary.opacity(0.7))
                    .frame(height: 7)
                    .accessibilityHidden(true)
                PaneName(server: server, window: window, block: block)
                    .font(.caption.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(theme.fg)
                if ids.count > 1 { dots(ids, idx) }
            }
            .offset(x: dx, y: dy)
            if newProgress > 0 {
                newPaneCard
                    .opacity(newProgress)
                    .scaleEffect(0.85 + 0.15 * newProgress)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 4)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44)
        .contentShape(Rectangle())
        .gesture(drag(stepIDs, step))
        .contextMenu { PaneMenuItems(actions: actions) }
        .popoverTip(tip, arrowEdge: .bottom)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Pane \(idx + 1) of \(ids.count)")
        .accessibilityHint("Swipe up or down to change pane.")
        .accessibilityAdjustableAction { d in onStep(d == .increment ? 1 : -1) }
        .accessibilityAction(named: "All Tabs", actions.overview)
        .accessibilityAction(named: "New Pane", onNewPane)
        .accessibilityAction(named: "Clear", actions.clear)
        .accessibilityAction(named: "Close Pane", actions.close)
    }

    private var newPaneCard: some View {
        HStack(spacing: 4) {
            Image(systemName: "plus").font(.system(size: 11, weight: .bold))
            Text("New Pane").font(.caption.weight(.semibold))
        }
        .foregroundStyle(armed ? theme.bg : theme.fg)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(Capsule().fill(armed ? theme.accent : theme.fg.opacity(0.1)))
        .fixedSize()
        .accessibilityHidden(true)
    }

    private func dots(_ ids: [String], _ idx: Int) -> some View {
        Group {
            if ids.count <= 9 {
                HStack(spacing: 5) {
                    ForEach(Array(ids.enumerated()), id: \.element) { i, bid in
                        PagerDot(server: server, block: bid, selected: i == idx, theme: theme)
                            .onTapGesture { onPick(bid) }
                    }
                }
            } else {
                Text("\(idx + 1) / \(ids.count)").font(.caption2.weight(.semibold)).foregroundStyle(theme.chrome.tertiary)
            }
        }
    }

    private func setArmed(_ on: Bool) {
        guard on != armed else { return }
        armed = on
        if on { Haptic.threshold() }
    }

    private func drag(_ ids: [String], _ idx: Int) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { v in
                let t = v.translation
                if axis == nil {
                    axis = t.height < 0 && abs(t.height) > 2 * abs(t.width) ? .vertical : .horizontal
                }
                if axis == .vertical {
                    dy = max(min(0, t.height) * 0.35, -18)
                    setArmed(t.height < -Self.upCommit)
                    return
                }
                let d = t.width < 0 ? 1 : -1
                if ids.indices.contains(idx + d) {
                    dx = t.width * 0.6
                    setArmed(false)
                } else if d == 1 {
                    // Past the last pane: the New Pane card slides in.
                    dx = t.width * Self.newDamping
                    setArmed(-t.width > Self.newCommit)
                } else {
                    // Before the first pane: nothing there.
                    dx = t.width * 0.2
                    if !bumped, t.width > 30 { bumped = true; Haptic.bump() }
                }
            }
            .onEnded { v in
                let t = v.translation
                if axis == .vertical {
                    if armed { actions.overview() }
                } else {
                    let d = t.width < 0 ? 1 : -1
                    if ids.indices.contains(idx + d) {
                        if abs(t.width) > 36 || abs(v.predictedEndTranslation.width) > 90 { onStep(d) }
                    } else if d == 1, armed {
                        onNewPane()
                    }
                }
                axis = nil
                armed = false
                bumped = false
                withAnimation(.snappy(duration: 0.22)) { dx = 0; dy = 0 }
            }
    }
}
