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
/// place, at its own height (44 pt, 34 pt in a short window). `StripLayout` says what shows and
/// where; `TabChip`, `SessionChip` and `SessionPopover` say what each part shows.
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
    /// The close confirmations the chips and the session popover ask, and what their answers
    /// run (`StripRoutes`). The strip shows each from the control that was tapped
    /// (`StripDialogs`). Nil shows none.
    var routes: StripRoutes?
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
            let input = StripLayout.Input(width: geo.size.width, height: height,
                                          originX: geo.frame(in: .global).minX - rootOrigin.x, crease: bookCrease,
                                          bar: bar, hasSession: session != nil, hasPane: target?.block != nil,
                                          zoomed: zoomed, panes: dots.count, waiting: waiting,
                                          hasFloatsControl: floats != nil)
            // What each part shows is decided without the session's name; where the parts sit
            // is decided with it, by the row, in the same layout pass.
            let layout = StripLayout(input)
            StripRow(input: input) {
                ForEach(layout.parts, id: \.self) { part in
                    self.part(part, layout, session)
                        // A part fills the frame the row gives it, as wide as its own content
                        // where the row asks (the session chip).
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .layoutValue(key: StripRow.PartKey.self, value: part)
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
            SessionChipSlot(target: target, form: layout.session, theme: theme, routes: routes, onAction: actions.sessions)
        case .chips:
            if let target, let session {
                TabChips(target: target, session: session, layout: layout, theme: theme, actions: actions, routes: routes)
            }
        case .dots:
            // The title bar's own dots, or their count where dots would be crowded.
            if let block = dotsCurrent ?? target?.block {
                PaneDots(ids: dots, current: block, theme: theme, counts: layout.dots == .count, onStep: actions.stepPane)
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

/// The session's tabs as chips, in a row that scrolls. The tab on screen is kept in view: the
/// row scrolls to its chip when another tab shows, and when the tabs change order.
private struct TabChips: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let target: StripTarget
    let session: SessionView
    let layout: StripLayout
    let theme: TermTheme
    let actions: StripActions
    let routes: StripRoutes?
    /// Where each chip is in the row, for the close questions (`ChipsAnchor`).
    @State private var frames = ChipFrames()

    var body: some View {
        // A move's new order shows at once, as in the sidebar (`PendingOrder`).
        let ids = target.server.orderedWindowIDs(target.sessionID)
        let windows = ids.compactMap { session.window($0) }
        // The row's own width, as the strip placed it: a short session name leaves it more
        // than the layout the parts were built from counts on.
        GeometryReader { geo in
            let room = geo.size.width
            ScrollViewReader { scroll in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: StripLayout.gap) {
                        ForEach(Array(windows.enumerated()), id: \.element.id) { n, w in
                            TabChipSlot(server: target.server, window: w, position: n + 1, count: windows.count,
                                        active: w.id == target.windowID, block: target.block, layout: layout, room: room,
                                        theme: theme, actions: actions)
                                .id(w.id)
                                // In the row's own space, so a scroll changes nothing here.
                                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(ChipFrames.space)) } action: { [frames] in
                                    frames.byID[w.id] = $0
                                }
                        }
                    }
                    .coordinateSpace(.named(ChipFrames.space))
                    // Not a chip: chips are drawn only in view, and a question stays up while
                    // they are drawn again, scrolled away or moved.
                    .overlay(alignment: .topLeading) {
                        ChipsAnchor(routes: routes, frames: frames, active: target.windowID, showsClose: layout.showsClose)
                    }
                }
                .onChange(of: InView(tab: target.windowID, order: ids, width: room), initial: true) { was, now in
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
        #if DEBUG
        .modifier(StripChipRuns(tab: target.windowID, run: actions.chip))
        #endif
    }

    /// What decides where the row rests.
    private struct InView: Equatable {
        var tab: String?
        var order: [String]
        var width: CGFloat
    }
}

/// Places the strip's parts. It asks the session chip for its own width with its name, hands
/// that to `StripLayout` (which stays pure) and puts every part in the frame the layout gives
/// it. One layout pass: the first frame a strip draws already has the chip at its name's width,
/// and nothing is measured outside a layout.
///
/// The parts are built from the layout made without the name's width. That one gives the
/// session chip the most a name may have, so it never shows a part the placed layout lacks,
/// and the name's width changes no part's form.
struct StripRow: Layout {
    /// The part a subview is.
    struct PartKey: LayoutValueKey {
        static let defaultValue: StripLayout.Part? = nil
    }

    /// The bar, without the session chip's width.
    var input: StripLayout.Input

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? input.width, height: input.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = Self.layout(input, subviews: subviews)
        for view in subviews {
            guard let part = view[PartKey.self], let frame = layout.frame(part) else {
                view.place(at: bounds.origin, proposal: .zero)
                continue
            }
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                       proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }

    /// The layout with the session chip as wide as its own content asks, to the next point.
    static func layout(_ input: StripLayout.Input, subviews: Subviews) -> StripLayout {
        var i = input
        if let chip = subviews.first(where: { $0[PartKey.self] == .session }) {
            i.sessionIdeal = chip.sizeThatFits(ProposedViewSize(width: nil, height: input.height)).width.rounded(.up)
        }
        return StripLayout(i)
    }
}

/// The session chip and its popover. Its own view, so the session's name and its waiting count
/// are read here and not by the strip.
private struct SessionChipSlot: View {
    @Environment(AppModel.self) private var model
    let target: StripTarget?
    let form: StripLayout.SessionForm
    let theme: TermTheme
    let routes: StripRoutes?
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
        // Close Session, from the popover's menu: by the chip, once the popover has gone. On a
        // view of its own beside the popover's.
        .background { Color.clear.modifier(StripDialogs(routes: routes, shows: [.closeSession])) }
        #if DEBUG
        .modifier(StripPopoverOpens(open: $open))
        #endif
    }
}

/// The session popover's contents, for the session chip. It builds the rows in its own body, so
/// the servers' sessions are read only while the popover is open, and the rows follow them
/// meanwhile. A row's action closes the popover; one that puts something on screen runs once
/// the popover has gone (`DismissalWait`).
struct SessionPopoverHost: View {
    @Environment(AppModel.self) private var model
    let theme: TermTheme
    let close: () -> Void
    let onAction: (SessionPopover.Action) -> Void
    @State private var wait = DismissalWait()

    var body: some View {
        SessionPopoverView(popover: SessionPopover(model), theme: theme, onAction: tap)
            .presentationCompactAdaptation(.popover)
            // The popover's content leaves when its dismissal has ended.
            .onDisappear { wait.dismissed() }
            #if DEBUG
            .task {
                // `-stripRow`: the row's tap, as a finger's.
                guard let row = StripPopoverTest.takeRow() else { return }
                try? await Task.sleep(for: StripPopoverTest.rowDelay)
                if let action = StripPopoverTest.action(row, in: SessionPopover(model)) { tap(action) }
            }
            #endif
    }

    /// A row's tap: the popover closes, and the row runs at once or, when it puts something on
    /// screen, once the popover has gone.
    private func tap(_ action: SessionPopover.Action) {
        let run = onAction
        if action.presents { wait.hold { run(action) } }
        close()
        if !action.presents { run(action) }
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
    /// The chips' row, as wide as it was placed.
    let room: CGFloat
    let theme: TermTheme
    let actions: StripActions

    var body: some View {
        #if DEBUG
        let _ = RenderCount.bump(.tabChips)
        #endif
        let chip = TabChip.of(window, position: position, count: count, server: server, active: active, block: block,
                              strip: layout)
        let width = active ? layout.activeChip(room: room) : layout.chip(room: room)
        TabChipView(chip: chip, theme: theme, onTap: { actions.pick(chip.id) }, onAction: { actions.chip($0, chip.id) })
            .frame(minWidth: width.lowerBound, maxWidth: width.upperBound, maxHeight: .infinity)
    }
}
