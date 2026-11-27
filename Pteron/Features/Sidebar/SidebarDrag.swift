import SwiftUI
import UniformTypeIdentifiers

/// A sidebar drag's new order, shown until the server agrees. Held on the server's connection,
/// where the views and the session list land, and applied where the outline's lists come from
/// (`ServerConnection.orderedSessions`, `orderedWindowIDs`), so everything derived from the
/// order (a session's top gap, the tabs under it) follows it.
struct PendingOrder: Equatable {
    struct Hold: Equatable {
        var order: [String]
        /// The drag this hold is for; only the newest drag's answer releases it.
        var token: Int
        /// Tabs: the revision the newest `move_window` returned; nil while it is out.
        var revision: Int?
        /// Sessions: the newest `session.move` returned.
        var returned = false
    }

    /// Per session, the tab order of the newest tab drag.
    var tabs: [String: Hold] = [:]
    /// The session order of the newest session drag.
    var sessions: Hold?

    var isEmpty: Bool { tabs.isEmpty && sessions == nil }

    /// How long a hold waits, counted from its newest call's return, for the server to agree.
    static let timeout = 2.0

    /// A tab order is done once a view at or above its newest call's revision arrives. An
    /// earlier drag's revision is never kept, so it can't release a later one.
    static func released(_ h: Hold, viewRevision: Int) -> Bool {
        guard let r = h.revision else { return false }
        return viewRevision >= r
    }

    /// A session order is done once the server's list (hidden sessions left out on both sides)
    /// is the same. `session.move` returns no revision to wait for.
    static func released(_ h: Hold, listed: [String]) -> Bool { listed == h.order }
}

/// One sidebar drag: what is lifted, where its rows are, the gap it would drop in, and the edge
/// scroll. One for the list (in `SidebarActions`), so rows compare equal while it stays the same.
///
/// Rows record their frames here without being observed, so recording re-renders nothing; only
/// the gap line reads `gap`.
@MainActor
@Observable
final class SidebarDrag {
    enum Item: Equatable {
        case tab(server: UUID, session: String, window: String)
        case session(server: UUID, session: String)

        var serverID: UUID {
            switch self {
            case .tab(let s, _, _), .session(let s, _): s
            }
        }
    }

    /// Where the gap line is drawn: the boundary's y in the list, and its indent.
    struct Gap: Equatable {
        var y: CGFloat
        var leading: CGFloat
        /// The place in the order: 0 before the first row, the count after the last.
        var index: Int
        /// A tab's gap: the session whose tabs `index` counts in. Another session than the
        /// lifted tab's is a move there (`session.transfer_window`).
        var session: String? = nil
    }

    struct Frame: Equatable {
        var kind: SidebarOutline.Row.Kind
        var minY: CGFloat
        var maxY: CGFloat
    }

    /// The coordinate space of the list's stack: frames and drop locations are in it.
    nonisolated static let space = "sidebarStack"
    /// The private type of a lifted row. Nothing outside the app reads it.
    nonisolated static let type = UTType(exportedAs: "dev.abrahamgonzalez.rexduo.sidebar-row")
    /// The band at the top and bottom that scrolls while a row is held there.
    static let edge: CGFloat = 44
    static let scrollStep: CGFloat = 36
    static let scrollEvery: TimeInterval = 0.06

    private(set) var gap: Gap?
    @ObservationIgnored private(set) var item: Item?
    @ObservationIgnored var frames: [String: Frame] = [:]
    /// The list's visible part, in the stack's space: its offset, its height and how far it
    /// can scroll.
    @ObservationIgnored var visible: (y: CGFloat, height: CGFloat, room: CGFloat) = (0, 0, 0)
    /// Scrolls the list to an offset. Set by the list.
    @ObservationIgnored var scrollTo: ((CGFloat) -> Void)?
    /// Runs when a lift begins: closes an open swipe row.
    @ObservationIgnored var onLift: () -> Void = {}
    @ObservationIgnored private var location: CGFloat?
    /// What the latest hover measured against; the edge scroll measures against it too.
    @ObservationIgnored private var orders: Orders?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var scrollDirection: CGFloat = 0

    // MARK: Lift

    /// The drag source's item, built when a lift begins.
    func lift(_ item: Item) -> NSItemProvider {
        self.item = item
        onLift()
        let p = NSItemProvider()
        p.registerDataRepresentation(forTypeIdentifier: Self.type.identifier, visibility: .ownProcess) { done in
            done(Data(), nil)
            return nil
        }
        return p
    }

    func record(_ id: String, _ kind: SidebarOutline.Row.Kind, _ frame: CGRect) {
        let f = Frame(kind: kind, minY: frame.minY, maxY: frame.maxY)
        if frames[id] != f { frames[id] = f }
    }

    func forget(_ id: String) { frames[id] = nil }

    // MARK: Gaps

    /// Moves the gap to where `y` falls for the lifted item. A change ticks.
    func hover(_ y: CGFloat, orders: Orders) {
        location = y
        self.orders = orders
        move(to: item.flatMap { SidebarGaps.gap(for: $0, at: y, frames: frames, orders: orders) })
        edgeScroll(y)
    }

    private func move(to next: Gap?) {
        guard next != gap else { return }
        if next != nil, next?.index != gap?.index || next?.session != gap?.session { Haptic.selection() }
        gap = next
    }

    /// The lift ended without a drop here, or after one.
    func end() {
        gap = nil
        item = nil
        location = nil
        orders = nil
        stopScroll()
    }

    // MARK: Edge scroll

    private func edgeScroll(_ y: CGFloat) {
        let top = visible.y, bottom = visible.y + visible.height
        let dir: CGFloat = y < top + Self.edge ? -1 : y > bottom - Self.edge ? 1 : 0
        guard dir != scrollDirection else { return }
        scrollDirection = dir
        timer?.invalidate()
        timer = nil
        guard dir != 0 else { return }
        // `dropUpdated` comes only when the finger moves, so a held finger scrolls on a timer.
        timer = Timer.scheduledTimer(withTimeInterval: Self.scrollEvery, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scrollStepFired() }
        }
    }

    private func scrollStepFired() {
        guard let y = location, let orders, visible.height > 0 else { stopScroll(); return }
        let target = min(max(0, visible.y + scrollDirection * Self.scrollStep), max(visible.room, 0))
        guard target != visible.y else { return }
        let moved = target - visible.y
        scrollTo?(target)
        // The finger stays put while the rows move under it.
        let held = y + moved
        location = held
        move(to: item.flatMap { SidebarGaps.gap(for: $0, at: held, frames: frames, orders: orders) })
    }

    private func stopScroll() {
        timer?.invalidate()
        timer = nil
        scrollDirection = 0
    }

    /// What a drop is measured against: each server's sessions and each session's tabs, in the
    /// order the sidebar shows.
    struct Orders {
        var sessions: (UUID) -> [String]
        var tabs: (UUID, String) -> [String]
        /// Whether the computer moves tabs between sessions: a lifted tab may then drop into
        /// another of its sessions.
        var transfers: (UUID) -> Bool = { _ in false }
    }
}

/// Which gap a point falls in, from the rows' frames. Pure, so it is tested.
enum SidebarGaps {
    /// Tabs move within their session: the gap between two of its tab rows nearest to `y`.
    /// Sessions move within their machine: a gap is above a session's header or below its last
    /// tab, so a point over a session's tabs goes to that session's nearer edge.
    static func gap(for item: SidebarDrag.Item, at y: CGFloat, frames: [String: SidebarDrag.Frame],
                    orders: SidebarDrag.Orders) -> SidebarDrag.Gap? {
        // Over another computer's row there is nowhere to drop: tabs and sessions stay on theirs.
        if frames.values.contains(where: { $0.kind.serverID != item.serverID && $0.minY <= y && y < $0.maxY }) { return nil }
        switch item {
        case .tab(let server, let session, _):
            guard orders.transfers(server) else {
                let ids = orders.tabs(server, session)
                let rows = frames.values.compactMap { f -> (Int, SidebarDrag.Frame)? in
                    guard case .tab(server, session, let w) = f.kind, let i = ids.firstIndex(of: w) else { return nil }
                    return (i, f)
                }
                return nearest(y, rows, leading: SidebarMetrics.tabLeading).map { var g = $0; g.session = session; return g }
            }
            return acrossSessions(y, server: server, frames: frames, orders: orders)
        case .session(let server, _):
            let ids = orders.sessions(server)
            var blocks: [Int: SidebarDrag.Frame] = [:]
            for f in frames.values {
                let sid: String
                switch f.kind {
                case .session(server, let s): sid = s
                case .tab(server, let s, _): sid = s
                default: continue
                }
                guard let i = ids.firstIndex(of: sid) else { continue }
                if var b = blocks[i] {
                    b.minY = min(b.minY, f.minY)
                    b.maxY = max(b.maxY, f.maxY)
                    blocks[i] = b
                } else {
                    blocks[i] = f
                }
            }
            return nearest(y, blocks.map { ($0.key, $0.value) }, leading: SidebarMetrics.sessionLeading)
        }
    }

    /// A tab on a computer that moves tabs between sessions: the gap nearest to `y` among every
    /// session's tab rows, as within one session. A session that shows no tab rows (folded, or
    /// without tabs) has one gap, under its header, which puts the tab last there.
    static func acrossSessions(_ y: CGFloat, server: UUID, frames: [String: SidebarDrag.Frame],
                               orders: SidebarDrag.Orders) -> SidebarDrag.Gap? {
        var best: SidebarDrag.Gap?
        func consider(_ g: SidebarDrag.Gap?) {
            guard let g else { return }
            if best.map({ abs(g.y - y) < abs($0.y - y) }) ?? true { best = g }
        }
        var tabRows: [String: [(Int, SidebarDrag.Frame)]] = [:]
        var headers: [String: SidebarDrag.Frame] = [:]
        var orderOf: [String: [String]] = [:]
        for f in frames.values {
            switch f.kind {
            case .tab(server, let s, let w):
                let ids = orderOf[s] ?? orders.tabs(server, s)
                orderOf[s] = ids
                if let i = ids.firstIndex(of: w) { tabRows[s, default: []].append((i, f)) }
            case .session(server, let s):
                headers[s] = f
            default:
                continue
            }
        }
        for (s, rows) in tabRows {
            consider(nearest(y, rows, leading: SidebarMetrics.tabLeading).map { var g = $0; g.session = s; return g })
        }
        for (s, h) in headers where tabRows[s] == nil {
            consider(SidebarDrag.Gap(y: h.maxY, leading: SidebarMetrics.tabLeading, index: orders.tabs(server, s).count, session: s))
        }
        return best
    }

    /// The boundary nearest to `y` among the rows (each with its place in the full order): above
    /// each row, and below the last one.
    static func nearest(_ y: CGFloat, _ rows: [(Int, SidebarDrag.Frame)], leading: CGFloat) -> SidebarDrag.Gap? {
        let sorted = rows.sorted { $0.0 < $1.0 }
        guard let last = sorted.last else { return nil }
        var edges = sorted.map { (index: $0.0, y: $0.1.minY) }
        edges.append((index: last.0 + 1, y: last.1.maxY))
        guard let best = edges.min(by: { abs($0.y - y) < abs($1.y - y) }) else { return nil }
        return SidebarDrag.Gap(y: best.y, leading: leading, index: best.index)
    }
}

/// The one drop target of the sessions list: it follows a lifted row, draws nothing itself (the
/// gap line does) and moves the row on drop.
struct SidebarDropDelegate: DropDelegate {
    let drag: SidebarDrag
    let orders: SidebarDrag.Orders
    let onDrop: (SidebarDrag.Item, SidebarDrag.Gap) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        drag.item != nil && info.hasItemsConforming(to: [SidebarDrag.type])
    }

    func dropEntered(info: DropInfo) { drag.hover(info.location.y, orders: orders) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        drag.hover(info.location.y, orders: orders)
        // Nowhere to drop here (another computer's rows): the row goes back where it was.
        return DropProposal(operation: drag.gap == nil ? .forbidden : .move)
    }

    func dropExited(info: DropInfo) { drag.end() }

    func performDrop(info: DropInfo) -> Bool {
        defer { drag.end() }
        guard let item = drag.item, let gap = drag.gap else { return false }
        onDrop(item, gap)
        return true
    }
}

/// The 2 pt accent line where a lifted row would land. Only this view reads the gap.
struct SidebarGapLine: View {
    let drag: SidebarDrag
    let theme: TermTheme

    var body: some View {
        if let g = drag.gap {
            Capsule()
                .fill(theme.accent)
                .frame(height: 2)
                .padding(.leading, g.leading + 8)
                .padding(.trailing, 14)
                .offset(y: g.y - 1)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}
