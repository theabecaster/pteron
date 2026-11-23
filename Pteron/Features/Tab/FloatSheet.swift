import GlanceUI
import SwiftUI
import RexKit

/// Floating windows in a narrow window (folded Duo, iPhone portrait, SE): one float at a time in
/// a sheet over the tab, as Maps and Music show theirs, never mixed into the tab's pages.
///
/// - **One rule decides it all.** The sheet shows exactly while the tab's active pane is a
///   drawn float's. Showing a float makes its pane active; going back to the tab makes a tiled
///   pane active. So every path that points the phone at a pane (a tap, the waiting pill, a
///   link, the palette) shows or hides the sheet with no extra state, and a hidden sheet's float
///   never takes the keyboard (`ActivePane`).
/// - **Sizes.** Large leaves about 15 % of the tab showing above it; Medium about 55 %. Compact
///   height and a tab with no tiled pane have Large only. Hidden is the tab alone. The phone
///   keeps the size per tab (`PhoneState.sheets`); nothing of it goes to the Mac.
/// - **No resize on the Mac.** The float's panes claim their grid once, at Large with the
///   keyboard down (`Geometry.rest`). Medium doesn't shrink them: the sheet moves down and the
///   part below the screen counts as covered, as under the keyboard, so the row the program
///   writes on stays in view. The keyboard covers the sheet as it covers any pane.
///
/// Pure parts here; the view is `FloatSheetView`, the title bar's control `FloatsControl`.
enum FloatSheet {
    enum Detent: Equatable {
        case large, medium
    }

    /// Where a drag on the grabber comes to rest.
    enum Stop: Equatable {
        case large, medium, hidden
    }

    enum Axis: Equatable {
        case horizontal, vertical
    }

    /// The phone's own state for one tab: the sheet's size, and the tiled pane shown last, which
    /// stays shown under the sheet and gets the keyboard when the sheet goes.
    struct Phone: Equatable {
        var detent: Detent = .large
        var tiled: String?
    }

    /// What a narrow tab with a drawn float shows.
    struct Layout: Equatable {
        /// The tiled layer, as a narrow tab without floats shows it.
        enum Tiled: Equatable {
            /// No tiled pane: the sheet can't go.
            case empty
            /// The tiled splits, legible.
            case splits
            /// One tiled pane at a time, with the title bar's dots when there are several.
            case page(String, ids: [String])
        }

        var tiled: Tiled
        /// The drawn floats, front first: what a sideways swipe on the grabber walks.
        var floats: [String]
        /// The float in the sheet; nil while the sheet is hidden.
        var shown: Shown?

        var hasTiled: Bool { tiled != .empty }
    }

    /// The float in the sheet and how its panes are drawn there.
    struct Shown: Equatable {
        var layer: String
        /// Its panes in reading order.
        var ids: [String]
        /// Each pane's rect as fractions of the sheet's content.
        var leaves: [FloatLayout.Leaf]
        /// The one pane drawn when the float's splits aren't legible in the sheet (or it has one
        /// pane); nil when they all show.
        var page: String?
        /// The float's pane the grabber names: the active one.
        var current: String
    }

    // MARK: Deciding

    /// The narrow presentation (`TabPresentation.floatSheet`).
    static func layout(_ i: TabPresentation.Input) -> Layout {
        let w = i.window
        let floats = FloatLayout.ordered(w.visibleFloating, front: i.front).reversed()
        let ids = w.tiledPageIDs
        let leaves = w.layout?.leaves ?? []
        let tiled: Layout.Tiled
        if ids.isEmpty {
            tiled = .empty
        } else if leaves.count > 1, SplitGeometry.legible(leaves.map(\.rect), canvas: i.canvas, fontSize: i.fontSize) {
            tiled = .splits
        } else {
            let current = [i.active, i.tiledShown, w.focusedBlockID].compactMap { $0 }.first { ids.contains($0) } ?? ids[0]
            tiled = .page(current, ids: ids)
        }
        var layer = i.active.flatMap { a in floats.first { l in l.blocks.contains { $0.id == a } } }
        // With no tiled pane the sheet can't go: the front float shows.
        if layer == nil, ids.isEmpty { layer = floats.first }
        let content = Geometry.rest(canvas: i.canvas) ?? .zero
        return Layout(tiled: tiled, floats: floats.map(\.id),
                      shown: layer.flatMap { shown($0, active: i.active, focused: w.focusedBlockID, content: content, fontSize: i.fontSize) })
    }

    /// One float in the sheet: its splits when every pane keeps a legible grid there, else one
    /// pane at a time.
    static func shown(_ layer: LayerInfo, active: String?, focused: String?, content: CGSize, fontSize: Double) -> Shown? {
        guard let leaves = shares(layer), !leaves.isEmpty else { return nil }
        let ids = leaves.map(\.id)
        let current = [active, focused].compactMap { $0 }.first { ids.contains($0) } ?? ids[0]
        let fits = leaves.count > 1 && SplitGeometry.legible(leaves.map(\.rect), canvas: content, fontSize: fontSize)
        return Shown(layer: layer.id, ids: ids, leaves: leaves, page: fits ? nil : current, current: current)
    }

    /// Each pane's share of its layer, as fractions of the layer: the float's own splits.
    static func shares(_ layer: LayerInfo) -> [FloatLayout.Leaf]? {
        guard let leaves = layer.layout?.leaves, layer.hasBounds else { return nil }
        let b = layer.bounds
        guard b.width > 0, b.height > 0 else { return nil }
        return leaves.map { l in
            FloatLayout.Leaf(id: l.id, rect: CGRect(x: (l.rect.minX - b.minX) / b.width, y: (l.rect.minY - b.minY) / b.height,
                                                    width: l.rect.width / b.width, height: l.rect.height / b.height))
        }
    }

    /// The pane that shows a float: its pane the server focuses, else its first.
    static func pane(of layer: LayerInfo, focused: String?) -> String? {
        let ids = layer.layout?.leaves.map(\.id) ?? layer.blocks.map(\.id)
        if let f = focused, ids.contains(f) { return f }
        return ids.first
    }

    /// The panes Next and Previous Pane and a swipe walk from `block`: a float's own panes under
    /// the sheet, else the tiled ones. Never from one to the other: the sheet is its own place.
    static func group(_ w: WindowInfo, from block: String) -> [String] {
        if let layer = w.floatingLayer(of: block) {
            return layer.isDrawnFloat ? (layer.layout?.leaves.map(\.id) ?? []) : []
        }
        return w.tiledPageIDs
    }

    /// The size the sheet shows at: Large while typing, in compact height and with no tiled
    /// pane to show above it.
    static func detent(_ stored: Detent, keyboardUp: Bool, mediumAllowed: Bool) -> Detent {
        keyboardUp || !mediumAllowed ? .large : stored
    }

    // MARK: Gestures

    /// A drag on the grabber picks its axis once, past a small slop: sideways changes the float,
    /// up and down the size. Nil until it is clear.
    static func axis(_ t: CGSize) -> Axis? {
        let w = abs(t.width), h = abs(t.height)
        guard max(w, h) >= 10 else { return nil }
        return w > h * 1.2 ? .horizontal : .vertical
    }

    /// A sideways swipe's step: +1 the next float (a swipe to the left, as pages), -1 the one
    /// before, 0 too short and too slow.
    static func swipe(dx: CGFloat, velocity: CGFloat) -> Int {
        guard abs(dx) > 50 || abs(velocity) > 400 else { return 0 }
        let d = abs(dx) > 50 ? dx : velocity
        return d < 0 ? 1 : -1
    }

    /// The float `by` steps from `from`; nil past either end (no wrap).
    static func step(_ floats: [String], from: String, by d: Int) -> String? {
        guard let i = floats.firstIndex(of: from), floats.indices.contains(i + d), d != 0 else { return nil }
        return floats[i + d]
    }

    /// Where a vertical drag lets go: the stop nearest to where it would coast, from the top
    /// it reached and its speed (points per second, down positive).
    static func settle(top: CGFloat, velocity: CGFloat, stops: [(Stop, CGFloat)]) -> Stop {
        let projected = top + velocity * 0.15
        return stops.min { abs($0.1 - projected) < abs($1.1 - projected) }?.0 ?? .large
    }

    /// How much of a pane Medium leaves below the screen: the sheet's drop `cover`, less the room
    /// under the pane inside the sheet's area (a pane at the bottom of a float's splits loses
    /// all of it, one at the top only what reaches past the screen).
    static func cover(_ cover: CGFloat, paneBottom: CGFloat, area: CGFloat) -> CGFloat {
        max(0, cover - max(area - paneBottom, 0))
    }

    /// What VoiceOver says for the sheet and the floats' control.
    enum Spoken {
        /// The grabber, an adjustable element when there are several floats: swiping up or down
        /// on it shows the next or the previous one.
        static func grabber(name: String, index: Int, count: Int) -> (label: String, value: String, hint: String) {
            ("Floating window, \(name)", count > 1 ? "\(index + 1) of \(count)" : "",
             count > 1 ? "Swipe up or down to show another floating window." : "")
        }

        static func control(count: Int) -> String {
            count == 1 ? "1 floating window" : "\(count) floating windows"
        }
    }

    // MARK: Geometry

    /// Where the sheet sits in the tab's canvas. Pure.
    struct Geometry: Equatable {
        /// From each side of the canvas.
        static let inset: CGFloat = 4
        /// The grabber strip at the sheet's top.
        static let grabber: CGFloat = 36
        static let radius: CGFloat = 12
        /// The part of the tab that shows above Large.
        static let peek: CGFloat = 0.15
        /// Medium's top, as a part of the canvas.
        static let medium: CGFloat = 0.45
        /// What shows of the tab above Large while the keyboard is up, at most.
        static let typingPeek: CGFloat = 24
        /// How far the backing runs on below the canvas, under the home indicator.
        static let underhang: CGFloat = 60

        /// The canvas now (smaller while the keyboard is up).
        var size: CGSize
        var largeTop: CGFloat
        var mediumTop: CGFloat?
        /// The float's panes at Large: their size at every size (Medium moves them down).
        var content: CGRect

        /// - canvas: the panes' area with the keyboard down; live: the same now.
        init(canvas: CGSize, live: CGSize, keyboardUp: Bool, mediumAllowed: Bool) {
            size = live
            let peek = Self.largeTop(canvas.height)
            largeTop = keyboardUp ? min(peek, Self.typingPeek) : peek
            mediumTop = mediumAllowed && !keyboardUp ? max((canvas.height * Self.medium).rounded(), largeTop) : nil
            content = CGRect(x: Self.inset, y: largeTop + Self.grabber, width: max(live.width - Self.inset * 2, 0),
                             height: max(live.height - largeTop - Self.grabber, 0))
        }

        static func largeTop(_ height: CGFloat) -> CGFloat { (height * peek).rounded() }

        /// The float's panes' size at Large with the keyboard down: what they claim, and what
        /// they keep while the keyboard covers them. Nil for a canvas not measured yet.
        static func rest(canvas: CGSize) -> CGSize? {
            guard canvas.width > 0, canvas.height > 0 else { return nil }
            return CGSize(width: max(canvas.width - inset * 2, 0), height: max(canvas.height - largeTop(canvas.height) - grabber, 0))
        }

        func top(_ d: Detent) -> CGFloat {
            d == .medium ? (mediumTop ?? largeTop) : largeTop
        }

        /// Where a drag can come to rest.
        func stops(canHide: Bool) -> [(Stop, CGFloat)] {
            var out: [(Stop, CGFloat)] = [(.large, largeTop)]
            if let m = mediumTop { out.append((.medium, m)) }
            if canHide { out.append((.hidden, size.height)) }
            return out
        }
    }
}

// MARK: - The floats' menu

/// What the title bar's floats control lists (`FloatsControl`): the drawn floats, front first,
/// then the ones minimized on the Mac. Names never come from a title (`PaneName`).
@MainActor
struct FloatsMenu: Equatable {
    struct Row: Identifiable, Equatable {
        /// The layer.
        var id: String
        var name: String
        var subtitle: String?
        var symbol: String
        /// In the sheet now.
        var shown = false
    }

    var drawn: [Row] = []
    var minimized: [Row] = []

    var count: Int { drawn.count + minimized.count }

    /// - front: a layer raised on the phone that the server hasn't put in front yet.
    /// - shown: the layer in the sheet, if it shows.
    /// - canRestore: the server shows a minimized float again (`set_layer_state`).
    static func build(_ w: WindowInfo, front: String?, shown: String?, canRestore: Bool,
                      names: PaneMenuModel.Names = { _ in nil }) -> FloatsMenu {
        let drawn = FloatLayout.ordered(w.visibleFloating, front: front).reversed()
        var m = FloatsMenu()
        m.drawn = PaneMenuModel.layerRows(w, Array(drawn), names: names).map { r in
            Row(id: r.id, name: r.name, subtitle: r.subtitle, symbol: r.symbol, shown: r.id == shown)
        }
        if canRestore {
            m.minimized = PaneMenuModel.layerRows(w, w.minimizedFloating.reversed(), names: names).map {
                Row(id: $0.id, name: $0.name, subtitle: $0.subtitle, symbol: $0.symbol)
            }
        }
        return m
    }

    /// The menu has a row: a drawn float, or a minimized one the server can show again. Reads
    /// no name, so the screen asks it without redrawing for one.
    static func has(_ w: WindowInfo, canRestore: Bool) -> Bool {
        !w.visibleFloating.isEmpty || (canRestore && !w.minimizedFloating.isEmpty)
    }

    static func make(server: ServerConnection, window: WindowInfo, front: String?, shown: String?) -> FloatsMenu {
        build(window, front: front, shown: shown,
              canRestore: PaneArrange.isAvailable(.restore, target: nil, support: server.capabilities.paneSupport)) {
            server.paneNames.value($0)
        }
    }
}

/// The title bar's floating windows control in a narrow window: one glyph with the count, only
/// while the tab has a float. Its menu shows any float in the sheet, one minimized on the Mac
/// included (shown again there too), and hides the sheet. Its own view, so tab mode's strip can
/// host it as the title bar does, and only it reads the panes' names.
struct FloatsControl: View {
    enum Style {
        /// In the title bar: the glyph and the count.
        case titleBar
        /// A toolbar item in the system's vertical bar: a Label, which the bar shows as a glyph.
        case bar
    }

    let server: ServerConnection
    let window: WindowInfo
    var front: String?
    /// The layer in the sheet, while it shows.
    var shown: String?
    var style: Style = .titleBar
    var height: CGFloat = 44
    let onShow: (String) -> Void
    let onRestore: (String) -> Void
    /// Hides the sheet; nil when it can't go.
    var onHide: (() -> Void)?

    var body: some View {
        let m = FloatsMenu.make(server: server, window: window, front: front, shown: shown)
        if m.count > 0 {
            Menu {
                FloatsMenuRows(menu: m, onShow: onShow, onRestore: onRestore, onHide: onHide)
            } label: {
                switch style {
                case .bar:
                    Label(TabAction.floats.title, systemImage: TabAction.floats.symbol)
                case .titleBar:
                    HStack(spacing: 3) {
                        Image(systemName: TabAction.floats.symbol).font(.system(size: 15))
                        Text("\(m.count)").font(.caption.weight(.semibold)).monospacedDigit()
                    }
                    .fixedSize()
                    .frame(minWidth: 44, minHeight: height)
                    .contentShape(Rectangle())
                }
            }
            .accessibilityLabel(FloatSheet.Spoken.control(count: m.count))
            .accessibilityHint("Shows the floating windows.")
        }
    }
}

/// The floats' rows, for the control's menu and the pane menu's Floating Windows section.
struct FloatsMenuRows: View {
    let menu: FloatsMenu
    let onShow: (String) -> Void
    let onRestore: (String) -> Void
    var onHide: (() -> Void)?

    var body: some View {
        Section {
            ForEach(menu.drawn) { r in
                Button { onShow(r.id) } label: {
                    Label(r.name, glyph: r.shown ? "checkmark" : r.symbol)
                    if let s = r.subtitle { Text(s) }
                }
                .accessibilityLabel(r.shown ? "\(r.name), shown" : r.name)
            }
        }
        if !menu.minimized.isEmpty {
            Section("Minimized") {
                ForEach(menu.minimized) { r in
                    Button { onRestore(r.id) } label: {
                        Label(r.name, glyph: r.symbol)
                        if let s = r.subtitle { Text(s) }
                    }
                    .accessibilityLabel("\(r.name), minimized")
                }
            }
        }
        if let onHide, menu.drawn.contains(where: \.shown) {
            Section {
                Button(action: onHide) { Label("Back to the Tab", systemImage: "chevron.down") }
            }
        }
    }
}

/// The pane menu's Floating Windows section, a section of its own (not inside Arrange) while
/// the tab has a float: Minimize, Minimize All and each minimized float to show again. In a
/// narrow window it also lists the drawn floats, so the sheet is in reach where the title bar
/// steps aside (compact height while typing).
struct FloatMenuSection: View {
    let server: ServerConnection
    let sessionID: String
    let window: WindowInfo
    let block: String
    /// Narrow: the drawn floats are rows too.
    var sheet: (front: String?, shown: String?)?
    let onMinimize: () -> Void
    let onMinimizeAll: () -> Void
    let onRestore: (String) -> Void
    var onShow: (String) -> Void = { _ in }

    var body: some View {
        let m = PaneMenuModel.make(server: server, sessionID: sessionID, window: window, block: block)
        let floats = sheet.map { FloatsMenu.make(server: server, window: window, front: $0.front, shown: $0.shown) }
        let drawn = floats?.drawn.filter { !$0.shown } ?? []
        if m?.minimize == true || m?.minimizeAll == true || !(m?.minimized.isEmpty ?? true) || !drawn.isEmpty {
            Section("Floating Windows") {
                ForEach(drawn) { r in
                    Button { onShow(r.id) } label: {
                        Label("Show \(r.name)", systemImage: TabAction.floats.symbol)
                        if let s = r.subtitle { Text(s) }
                    }
                }
                if m?.minimize == true {
                    Button(action: onMinimize) {
                        Label("Minimize", systemImage: "minus.square")
                        Text("On every screen")
                    }
                }
                if m?.minimizeAll == true {
                    Button(action: onMinimizeAll) { Label("Minimize All", systemImage: "rectangle.stack.badge.minus") }
                }
                ForEach(m?.minimized ?? []) { r in
                    Button { onRestore(r.id) } label: {
                        Label("Show \(r.name)", glyph: r.symbol)
                        Text(r.subtitle.map { "Minimized · \($0)" } ?? "Minimized")
                    }
                }
            }
        }
    }
}

// MARK: - The sheet

/// The float sheet itself, drawn over the tab's canvas (not a system sheet: the terminal and the
/// keyboard stay where they are). Backing, grabber and panes move as one, by position only: a
/// size change lays nothing out and the panes keep their bounds, so their grid and their claim
/// on the Mac never change. At Medium the part of the panes below the screen counts as covered,
/// as under the keyboard (`TerminalHost.setSheetCover`), so the row the program writes on stays
/// in view. Only the float shown is in the view tree: the others park as panes off screen do.
struct FloatSheetView: View {
    struct Actions {
        /// A tap (or any touch that focuses) on a pane of the float.
        var tap: (String) -> Void
        /// A sideways swipe on a pane of a float drawn one pane at a time.
        var swipePane: (String, Int) -> Void
        /// A sideways swipe on the grabber: the layer to show, and whether it is the next one.
        var show: (String, Bool) -> Void
        var detent: (FloatSheet.Detent) -> Void
        var hide: () -> Void
    }

    let server: ServerConnection
    let sessionID: String
    let window: WindowInfo
    let layout: FloatSheet.Layout
    let shown: FloatSheet.Shown
    let active: String?
    let theme: TermTheme
    /// The panes' area with the keyboard down.
    let canvas: CGSize
    let keyboardUp: Bool
    let mediumAllowed: Bool
    /// The size the phone keeps for this tab.
    let stored: FloatSheet.Detent
    /// The slide between floats and between a float's pages, in the direction of travel.
    let slide: AnyTransition
    let actions: Actions

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The grabber's vertical drag, from the size's top.
    @State private var drag: CGFloat = 0
    /// The grabber's sideways drag, which the sheet follows a little.
    @State private var slideX: CGFloat = 0
    @State private var axis: FloatSheet.Axis?
    /// Reduce Motion: a size change fades the sheet out and in at its new size instead of moving it.
    @State private var fade: Double = 1
    /// The sheet has come to rest at Medium: its panes take the cover. Set once it has stopped,
    /// so a pane never shifts its rows while it moves.
    @State private var restsAtMedium = false

    private var detent: FloatSheet.Detent { FloatSheet.detent(stored, keyboardUp: keyboardUp, mediumAllowed: mediumAllowed) }

    var body: some View {
        GeometryReader { geo in
            let g = FloatSheet.Geometry(canvas: canvas, live: geo.size, keyboardUp: keyboardUp, mediumAllowed: mediumAllowed)
            let top = min(max(g.top(detent) + drag, g.largeTop - 12), g.size.height)
            let radius = FloatSheet.Geometry.radius
            let shape = UnevenRoundedRectangle(topLeadingRadius: radius, topTrailingRadius: radius)
            let cover = restsAtMedium && detent == .medium ? g.top(.medium) - g.largeTop : 0
            ZStack(alignment: .topLeading) {
                // The backing and its shadow: never on the Metal view, never hit.
                shape
                    .fill(theme.bg)
                    .overlay(shape.stroke(theme.chrome.divider, lineWidth: 1))
                    .shadow(color: .black.opacity(scheme == .dark ? 0.4 : 0.22), radius: 14, y: -2)
                    // On past the canvas, under the home indicator, as the terminal's color runs.
                    .frame(width: g.content.width, height: max(g.size.height - top, 0) + FloatSheet.Geometry.underhang)
                    .offset(x: g.content.minX + slideX, y: top)
                    .allowsHitTesting(false)
                panes(g, cover: cover)
                    .frame(width: g.content.width, height: g.content.height, alignment: .topLeading)
                    .offset(x: g.content.minX + slideX, y: top + FloatSheet.Geometry.grabber)
                grabber(g)
                    .frame(width: g.content.width, height: FloatSheet.Geometry.grabber)
                    .background(theme.chrome.canvas, in: shape)
                    .offset(x: g.content.minX + slideX, y: top)
            }
            .opacity(fade)
        }
        .onAppear { restsAtMedium = detent == .medium }
        .onChange(of: detent) { _, d in
            guard d == .medium else { restsAtMedium = false; return }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(320))
                if detent == .medium { restsAtMedium = true }
            }
        }
    }

    // MARK: Panes

    /// - cover: how far Medium leaves the panes' area below the screen.
    @ViewBuilder
    private func panes(_ g: FloatSheet.Geometry, cover: CGFloat) -> some View {
        let rest = FloatSheet.Geometry.rest(canvas: canvas)
        ZStack(alignment: .topLeading) {
            if let page = shown.page {
                PaneView(server: server, sessionID: sessionID, blockID: page, active: page == active,
                         onFocus: { actions.tap(page) },
                         onSwipe: shown.ids.count > 1 ? { dir in actions.swipePane(page, dir) } : nil,
                         restSize: rest, sheetCover: cover)
                    .id(page)
                    .transition(reduceMotion ? .opacity : slide)
            } else {
                let size = CGSize(width: max(g.content.width - PaneLayout.splitPadding * 2, 0),
                                  height: max(g.content.height - PaneLayout.splitPadding * 2, 0))
                let radius = PaneLayout.splitRadius
                ZStack(alignment: .topLeading) {
                    ForEach(shown.leaves, id: \.id) { leaf in
                        let frame = PaneLayout.split(leaf.rect, in: size)
                        PaneView(server: server, sessionID: sessionID, blockID: leaf.id, active: leaf.id == active,
                                 onFocus: { actions.tap(leaf.id) },
                                 restSize: rest.flatMap { PaneLayout.splitRest(leaf.rect, canvas: $0) },
                                 sheetCover: FloatSheet.cover(cover, paneBottom: frame.maxY + PaneLayout.splitPadding, area: g.content.height))
                            .id(leaf.id)
                            .padding(PaneLayout.clearance(radius: radius))
                            .background(theme.bg)
                            .clipShape(RoundedRectangle(cornerRadius: radius))
                            .overlay(RoundedRectangle(cornerRadius: radius)
                                .stroke(leaf.id == active ? theme.chrome.activeBorder : theme.chrome.divider,
                                        lineWidth: leaf.id == active ? 1.5 : 1))
                            .frame(width: frame.width, height: frame.height)
                            .offset(x: frame.minX, y: frame.minY)
                    }
                }
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .padding(PaneLayout.splitPadding)
            }
        }
        .id(shown.layer)
        .transition(reduceMotion ? .opacity : slide)
    }

    // MARK: Grabber

    private func grabber(_ g: FloatSheet.Geometry) -> some View {
        let several = layout.floats.count > 1
        let index = layout.floats.firstIndex(of: shown.layer) ?? 0
        let name = Self.name(window, shown.current, server: server)
        return HStack(spacing: 0) {
            ZStack {
                HStack(spacing: 6) {
                    BlockBadge(server: server, block: shown.current, theme: theme)
                    Text(name)
                        .font(.footnote.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if shown.page != nil, shown.ids.count > 1 {
                        Dots(count: shown.ids.count, index: shown.ids.firstIndex(of: shown.current) ?? 0, theme: theme, small: true)
                    }
                    Spacer(minLength: several ? 56 : 0)
                }
                if several {
                    Dots(count: layout.floats.count, index: index, theme: theme, small: false)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.trailing, 6)
                }
            }
            .padding(.leading, 12)
            .padding(.top, 6)
            .frame(maxHeight: .infinity)
            .overlay(alignment: .top) {
                // The sheet's handle, as iOS draws one.
                Capsule().fill(theme.chrome.tertiary.opacity(0.6)).frame(width: 36, height: 4).padding(.top, 5)
            }
            .contentShape(Rectangle())
            .gesture(grabberDrag(g))
            .onTapGesture { toggle() }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(FloatSheet.Spoken.grabber(name: name, index: index, count: layout.floats.count).label)
            .accessibilityValue(FloatSheet.Spoken.grabber(name: name, index: index, count: layout.floats.count).value)
            .accessibilityHint(FloatSheet.Spoken.grabber(name: name, index: index, count: layout.floats.count).hint)
            .accessibilityAdjustableAction { d in
                guard several else { return }
                step(d == .increment ? 1 : -1)
            }
            .accessibilityAction(named: detent == .large ? "Medium Size" : "Large Size") { toggle() }
            .accessibilityAction(named: "Back to the Tab") { if layout.hasTiled { hide(animated: true, g: g) } }
            if layout.hasTiled {
                Button { hide(animated: true, g: g) } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(theme.chrome.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
                .accessibilityLabel("Back to the Tab")
                .accessibilityHint("Hides the floating window on this iPhone. It stays open on \(server.config.name).")
            }
        }
        .foregroundStyle(theme.fg)
    }

    /// A pane's name for the grabber: never its title (`PaneName`).
    static func name(_ w: WindowInfo, _ id: String, server: ServerConnection) -> String {
        let ids = PaneScope.arrangeable(window: w)
        return PaneName.menu(w.block(id), position: (ids.firstIndex(of: id) ?? 0) + 1, parts: server.paneNames.value(id))
    }

    private func grabberDrag(_ g: FloatSheet.Geometry) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .onChanged { v in
                if axis == nil { axis = FloatSheet.axis(v.translation) }
                switch axis {
                case .vertical:
                    // Above Large it gives a little, as a sheet does.
                    let t = v.translation.height
                    drag = t < 0 && g.top(detent) + t < g.largeTop ? -pow(-t, 0.6) : t
                case .horizontal:
                    let next = FloatSheet.step(layout.floats, from: shown.layer, by: v.translation.width < 0 ? 1 : -1) != nil
                    slideX = v.translation.width * (next ? 0.35 : 0.12)
                case nil: break
                }
            }
            .onEnded { v in
                defer { axis = nil }
                switch axis {
                case .vertical:
                    let stop = FloatSheet.settle(top: g.top(detent) + drag, velocity: v.velocity.height,
                                                 stops: g.stops(canHide: layout.hasTiled))
                    switch stop {
                    case .hidden: hide(animated: true, g: g)
                    case .large: resize(.large)
                    case .medium: resize(.medium)
                    }
                case .horizontal:
                    let d = FloatSheet.swipe(dx: v.translation.width, velocity: v.velocity.width)
                    withAnimation(.snappy(duration: 0.24)) { slideX = 0 }
                    if d != 0 { step(d) }
                case nil: break
                }
            }
    }

    private func step(_ d: Int) {
        guard let next = FloatSheet.step(layout.floats, from: shown.layer, by: d) else { Haptic.bump(); return }
        actions.show(next, d > 0)
    }

    /// A tap on the grabber: Large and Medium in turn, where there is a Medium.
    private func toggle() {
        guard mediumAllowed, !keyboardUp else { return }
        resize(detent == .large ? .medium : .large)
    }

    private func resize(_ d: FloatSheet.Detent) {
        if d != detent { Haptic.selection() }
        if reduceMotion {
            withAnimation(.easeOut(duration: 0.12)) { fade = 0 } completion: {
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) {
                    drag = 0
                    actions.detent(d)
                }
                withAnimation(.easeIn(duration: 0.16)) { fade = 1 }
            }
        } else {
            withAnimation(.snappy(duration: 0.3)) {
                drag = 0
                actions.detent(d)
            }
        }
    }

    private func hide(animated: Bool, g: FloatSheet.Geometry) {
        guard layout.hasTiled else { return }
        Haptic.selection()
        if reduceMotion {
            actions.hide()
            return
        }
        withAnimation(.snappy(duration: 0.25)) { drag = g.size.height - g.top(detent) } completion: {
            actions.hide()
        }
    }
}

/// Page dots: the shown one a short bar, as the title bar's.
private struct Dots: View {
    let count: Int
    let index: Int
    let theme: TermTheme
    let small: Bool

    var body: some View {
        if count <= 6 {
            HStack(spacing: small ? 2 : 3) {
                ForEach(0..<count, id: \.self) { i in
                    Capsule()
                        .fill(i == index ? theme.fg : theme.chrome.tertiary)
                        .frame(width: i == index ? (small ? 7 : 9) : (small ? 3 : 4), height: small ? 3 : 4)
                }
            }
            .animation(.snappy(duration: 0.2), value: index)
        } else {
            Text("\(index + 1)/\(count)").font(.caption2.weight(.semibold)).monospacedDigit()
                .foregroundStyle(theme.chrome.tertiary)
        }
    }
}
