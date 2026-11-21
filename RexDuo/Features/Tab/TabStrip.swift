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
    /// The pane the dots mark, when it isn't the active one (a narrow tab's float sheet: the
    /// tiled pane under it).
    var dotsCurrent: String?
    /// The panes on screen: agents waiting there are in view already.
    var visible: Set<String> = []
    var zoomed = false
    /// The system's vertical bar holds the pane menu and Unzoom.
    var bar = false
    var height: CGFloat = 44
    let theme: TermTheme
    var actions = StripActions()
    /// A narrow tab's floating windows control (`FloatsControl`); nil without a float.
    var floats: FloatsControl?
    /// The Pane Actions menu, as the title bar shows it.
    @ViewBuilder var paneMenu: PaneMenu
    /// The session chip's own width with its name (`SessionChipIdeal`). Nil until measured.
    @State private var sessionIdeal: CGFloat?

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
                                           zoomed: zoomed, panes: dots.count, waiting: waiting,
                                           hasFloatsControl: floats != nil, sessionIdeal: sessionIdeal))
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
        // The layout stays pure: the chip's width is measured here and handed to it.
        .background(alignment: .topLeading) {
            SessionChipMeasure(target: target, height: height, theme: theme) { sessionIdeal = $0 }
        }
        .background(theme.chrome.canvas)
    }

    @ViewBuilder
    private func part(_ part: StripLayout.Part, _ layout: StripLayout, _ session: SessionView?) -> some View {
        switch part {
        case .session:
            SessionChipSlot(target: target, form: layout.session, theme: theme, onAction: actions.sessions)
        case .chips:
            if let target, let session {
                TabChips(target: target, session: session, layout: layout, theme: theme, actions: actions)
            }
        case .dots:
            if let block = dotsCurrent ?? target?.block {
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
            floats
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

/// The session's tabs as chips, in a row that scrolls. The tab on screen is kept in view: the
/// row scrolls to its chip when another tab shows, and when the tabs change order.
private struct TabChips: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let target: StripTarget
    let session: SessionView
    let layout: StripLayout
    let theme: TermTheme
    let actions: StripActions

    var body: some View {
        // A move's new order shows at once, as in the sidebar (`PendingOrder`).
        let ids = target.server.orderedWindowIDs(target.sessionID)
        let windows = ids.compactMap { session.window($0) }
        ScrollViewReader { scroll in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: StripLayout.gap) {
                    ForEach(Array(windows.enumerated()), id: \.element.id) { n, w in
                        TabChipSlot(server: target.server, window: w, position: n + 1, count: windows.count,
                                    active: w.id == target.windowID, block: target.block, layout: layout, theme: theme,
                                    actions: actions)
                            .id(w.id)
                    }
                }
            }
            .onChange(of: InView(tab: target.windowID, order: ids, width: layout.chipsWidth), initial: true) { was, now in
                guard let tab = now.tab else { return }
                // The first layout, and a rotation or a fold, place the chip; only a change of
                // tab or of order moves the row under the eye.
                if was == now || was.width != now.width || reduceMotion {
                    scroll.scrollTo(tab, anchor: .center)
                } else {
                    withAnimation(.snappy(duration: 0.2)) { scroll.scrollTo(tab, anchor: .center) }
                }
            }
        }
    }

    /// What decides where the row rests.
    private struct InView: Equatable {
        var tab: String?
        var order: [String]
        var width: CGFloat
    }
}

/// Measures the session chip for the strip: the chip with its name, drawn hidden at its own
/// width, which `StripLayout` then cuts at `sessionMax`. Its own view, so a new name is read
/// here and the strip is drawn again only when the width it reports changes. Nothing is
/// measured per frame: the width is reported when the name, the machine or the text size
/// changes it.
private struct SessionChipMeasure: View {
    @Environment(AppModel.self) private var model
    let target: StripTarget?
    let height: CGFloat
    let theme: TermTheme
    let report: (CGFloat) -> Void

    var body: some View {
        let chip = target.map {
            SessionChip(name: $0.server.views[$0.sessionID]?.label ?? "", machine: model.servers.count > 1 ? $0.server.config.name : nil,
                        waiting: 0)
        } ?? .none()
        SessionChipIdeal(chip: chip, height: height, theme: theme)
            .hidden()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onGeometryChange(for: CGFloat.self) { $0.size.width.rounded(.up) } action: { report($0) }
    }
}

/// The session chip and its popover. Its own view, so the session's name and its waiting count
/// are read here and not by the strip.
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
        SessionChipView(chip: chip, theme: theme) {
            Haptic.tap()
            open = true
        }
        .popover(isPresented: $open, arrowEdge: .top) {
            SessionPopoverHost(theme: theme, close: { open = false }, onAction: onAction)
                .environment(model)
        }
    }
}

/// The session popover's contents, for the session chip and for the vertical bar's Sessions
/// item. It builds the rows in its own body, so the servers' sessions are read only while the
/// popover is open, and the rows follow them meanwhile. A row's action closes the popover; one
/// that puts something on screen runs once the popover has gone (`DismissalWait`).
struct SessionPopoverHost: View {
    @Environment(AppModel.self) private var model
    let theme: TermTheme
    let close: () -> Void
    let onAction: (SessionPopover.Action) -> Void
    @State private var wait = DismissalWait()

    var body: some View {
        SessionPopoverView(popover: SessionPopover(model), theme: theme) { action in
            let run = onAction
            if action.presents { wait.hold { run(action) } }
            close()
            if !action.presents { run(action) }
        }
        .presentationCompactAdaptation(.popover)
        // The popover's content leaves when its dismissal has ended.
        .onDisappear { wait.dismissed() }
    }
}

/// The vertical bar's first item in tab mode: Sessions, which opens the session chip's popover
/// from the item. Drawn by the root, so it is there with no tab on screen.
struct SessionsBarItem: View {
    @Environment(AppModel.self) private var model
    let theme: TermTheme
    let onAction: (SessionPopover.Action) -> Void
    @State private var open = false

    var body: some View {
        Button {
            Haptic.tap()
            open = true
        } label: {
            Label(TabAction.sessions.title, systemImage: TabAction.sessions.symbol)
        }
        .popover(isPresented: $open) {
            SessionPopoverHost(theme: theme, close: { open = false }, onAction: onAction)
                .environment(model)
        }
    }
}

/// One tab chip. It builds its `TabChip` in its own body, so a status or title change in one
/// tab draws only that chip again.
private struct TabChipSlot: View {
    let server: ServerConnection
    let window: WindowInfo
    let position: Int
    let count: Int
    let active: Bool
    let block: String?
    let layout: StripLayout
    let theme: TermTheme
    let actions: StripActions

    var body: some View {
        #if DEBUG
        let _ = RenderCount.bump(.tabChips)
        #endif
        let chip = TabChip.of(window, position: position, count: count, server: server, active: active, block: block,
                              strip: layout)
        let width = active ? layout.activeChip : layout.chip
        TabChipView(chip: chip, theme: theme, onTap: { actions.pick(chip.id) }, onAction: { actions.chip($0, chip.id) })
            .frame(minWidth: width.lowerBound, maxWidth: width.upperBound, maxHeight: .infinity)
    }
}
