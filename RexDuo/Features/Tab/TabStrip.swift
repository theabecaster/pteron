import SwiftUI
import RexKit

/// What the strip is about: the session on screen, and the tab and pane shown, if any.
struct StripTarget {
    let server: ServerConnection
    let sessionID: String
    /// The tab on screen; nil once it has closed.
    var windowID: String?
    /// The pane on screen: the active chip shows its status.
    var block: String?
}

/// What the strip reports. It decides nothing itself: the screen that shows it runs these.
struct StripActions {
    /// A tab chip was tapped: that tab's id.
    var pick: (String) -> Void = { _ in }
    /// A chip's action on the tab with that id: its close button, or a row of its menu.
    var chip: (TabChip.Action, String) -> Void = { _, _ in }
    var newTab: () -> Void = {}
    var unzoom: () -> Void = {}
    /// The pane dots, stepped by VoiceOver: +1 next pane, -1 previous.
    var stepPane: (Int) -> Void = { _ in }
    /// The waiting pill: show that agent.
    var jump: (Waiting.Item) -> Void = { _ in }
    /// A row of the session chip's popover.
    var sessions: (SessionPopover.Action) -> Void = { _ in }
}

/// Tab mode's title bar (`NavigationStyle.tabs`), like the Mac app's tabs above: the session
/// chip, the session's tabs as chips, then what the title bar holds. It takes the title bar's
/// place at the title bar's height. `StripLayout` says what shows and where; `TabChip`,
/// `SessionChip` and `SessionPopover` say what each part shows.
struct TabStrip<PaneMenu: View>: View {
    @Environment(AppModel.self) private var model
    @Environment(\.rootOrigin) private var rootOrigin
    @Environment(\.bookCrease) private var bookCrease

    /// Nil with no session on screen: the session chip alone.
    let target: StripTarget?
    /// The panes the dots page through, when one shows at a time.
    var dots: [String] = []
    /// The panes on screen: agents waiting there are in view already.
    var visible: Set<String> = []
    var zoomed = false
    /// The system's vertical bar holds the pane menu and Unzoom.
    var bar = false
    var height: CGFloat = 44
    let theme: TermTheme
    var actions = StripActions()
    /// The Pane Actions menu, as the title bar shows it.
    @ViewBuilder var paneMenu: PaneMenu

    var body: some View {
        #if DEBUG
        let _ = RenderCount.bump(.tabStrips)
        #endif
        let session = target.flatMap { $0.server.views[$0.sessionID] }
        // The agent index only, as the pill reads it: a status line or a title changes nothing here.
        let waiting = Waiting.all(model.servers).filter { !visible.contains($0.id) }.count
        GeometryReader { geo in
            let layout = StripLayout(.init(width: geo.size.width, height: height,
                                           originX: geo.frame(in: .global).minX - rootOrigin.x, crease: bookCrease,
                                           bar: bar, hasSession: session != nil, hasPane: target?.block != nil,
                                           zoomed: zoomed, panes: dots.count, waiting: waiting))
            ZStack(alignment: .topLeading) {
                ForEach(layout.parts, id: \.self) { part in
                    if let frame = layout.frame(part) {
                        self.part(part, layout, session)
                            .frame(width: frame.width, height: frame.height)
                            .offset(x: frame.minX)
                    }
                }
            }
        }
        .frame(height: height)
        .font(.system(size: 17))
        .foregroundStyle(theme.fg)
        .background(theme.chrome.canvas)
    }

    @ViewBuilder
    private func part(_ part: StripLayout.Part, _ layout: StripLayout, _ session: SessionView?) -> some View {
        switch part {
        case .session:
            SessionChipSlot(target: target, form: layout.session, theme: theme, onAction: actions.sessions)
        case .chips:
            if let target, let session {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: StripLayout.gap) {
                        ForEach(session.windows) { w in
                            TabChipSlot(server: target.server, session: session, window: w, active: w.id == target.windowID,
                                        block: target.block, layout: layout, theme: theme, actions: actions)
                        }
                    }
                }
            }
        case .dots:
            if let block = target?.block {
                if layout.dots == .count {
                    PaneCount(ids: dots, current: block, theme: theme, onStep: actions.stepPane)
                } else {
                    PaneDots(ids: dots, current: block, theme: theme, onStep: actions.stepPane)
                }
            }
        case .waiting:
            WaitingPill(visible: visible, theme: theme, onJump: actions.jump)
        case .unzoom:
            IconButton(symbol: TabAction.unzoom.symbol, label: TabAction.unzoom.title, height: height, action: actions.unzoom)
                .foregroundStyle(theme.accent)
        case .floats:
            // The slot is kept by the layout; the control comes with floating windows' own change.
            EmptyView()
        case .newTab:
            IconButton(symbol: "plus", label: TabAction.newTab.title, height: height, action: actions.newTab)
        case .paneMenu:
            paneMenu
                .labelStyle(.iconOnly)
                .frame(width: StripLayout.hit, height: height)
                .contentShape(Rectangle())
        }
    }
}

/// The pane dots as a count ("2/5"), for a strip too narrow for dots. It says and does what
/// `PaneDots` does: a place among the panes, stepped by VoiceOver.
private struct PaneCount: View {
    let ids: [String]
    let current: String
    let theme: TermTheme
    let onStep: (Int) -> Void

    var body: some View {
        let idx = ids.firstIndex(of: current) ?? 0
        Text("\(idx + 1)/\(ids.count)").font(.caption2.weight(.semibold)).monospacedDigit()
            .lineLimit(1).fixedSize()
            .foregroundStyle(theme.chrome.tertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Pane \(idx + 1) of \(ids.count)")
            .accessibilityHint("Swipe the terminal sideways to change pane.")
            .accessibilityAdjustableAction { d in onStep(d == .increment ? 1 : -1) }
    }
}

/// The session chip and its popover. Its own view, so the session's name, its waiting count
/// and, while the popover is open, every server's sessions are read here and not by the strip.
private struct SessionChipSlot: View {
    @Environment(AppModel.self) private var model
    let target: StripTarget?
    let form: StripLayout.SessionForm
    let theme: TermTheme
    let onAction: (SessionPopover.Action) -> Void
    @State private var open = false

    var body: some View {
        let chip = target.map { SessionChip.of($0.sessionID, server: $0.server, servers: model.servers.count, form: form) }
            ?? .none(form: form)
        SessionChipView(chip: chip, theme: theme) { open = true }
            .popover(isPresented: $open, arrowEdge: .top) {
                SessionPopoverView(popover: SessionPopover(model), theme: theme) { action in
                    open = false
                    onAction(action)
                }
                .presentationCompactAdaptation(.popover)
            }
    }
}

/// One tab chip. It builds its `TabChip` in its own body, so a status or title change in one
/// tab draws only that chip again.
private struct TabChipSlot: View {
    let server: ServerConnection
    let session: SessionView
    let window: WindowInfo
    let active: Bool
    let block: String?
    let layout: StripLayout
    let theme: TermTheme
    let actions: StripActions

    var body: some View {
        #if DEBUG
        let _ = RenderCount.bump(.tabChips)
        #endif
        let chip = TabChip.of(window, in: session, server: server, active: active, block: block, strip: layout)
        let width = active ? layout.activeChip : layout.chip
        TabChipView(chip: chip, theme: theme, onTap: { actions.pick(chip.id) }, onAction: { actions.chip($0, chip.id) })
            .frame(minWidth: width.lowerBound, maxWidth: width.upperBound, maxHeight: .infinity)
    }
}
