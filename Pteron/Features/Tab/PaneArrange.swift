import CoreGraphics
import Foundation
import GlanceUI
import RexKit

// The pane and order commands of the pane menu's Arrange, the keymap and the sidebar's drag:
// what each needs from the server, which panes they work on, and the layout math. Pure, so it
// is tested; the views and `ServerConnection+Panes` call it.

/// A command that rearranges panes, tabs or sessions on the server.
enum PaneCommand: CaseIterable, Sendable {
    case swap, moveToTab, moveToNewTab, balance, closeOthers
    /// `client.tab.move.*` and the sidebar's tab drag.
    case moveTab
    /// The sidebar's session drag.
    case moveSession
    /// Floating windows: Minimize (`pane.minimize_floating`), Minimize All
    /// (`pane.minimize_all_floating`), a minimized float's row in Arrange, and the raise a tap on
    /// a float behind another sends.
    case minimize, minimizeAll, restore, raise

    /// The server methods it calls. A server that lacks one doesn't get the command.
    var methods: [String] {
        switch self {
        case .swap: ["session.swap_blocks"]
        case .moveToTab: ["session.move_block"]
        case .moveToNewTab: ["session.new_window", "session.move_block", "block.close", "session.move_window"]
        case .balance: ["session.resize_pane"]
        case .closeOthers: ["block.close"]
        case .moveTab: ["session.move_window"]
        case .moveSession: ["session.move"]
        case .minimize, .minimizeAll, .restore, .raise: [FloatArrange.layerStateMethod]
        }
    }

    /// Every method any of them calls, for the runtime guard.
    static let allMethods: Set<String> = Set(allCases.flatMap(\.methods))

    /// The keymap action that runs it, with the Rex Mac app's name; nil for menu-only commands.
    static func forAction(_ name: String) -> PaneCommand? {
        switch name {
        case "pane.balance": .balance
        case "pane.close_others": .closeOthers
        case "pane.move_to_tab": .moveToTab
        case "pane.move_to_new_tab": .moveToNewTab
        case "client.tab.move.backward", "client.tab.move.forward": .moveTab
        case "pane.minimize_floating": .minimize
        case "pane.minimize_all_floating": .minimizeAll
        default: nil
        }
    }
}

/// What one server can do of the pane commands: its API revision and the methods a call there
/// found missing (`method_not_found`). A plain value, so key resolution can read it anywhere.
struct PaneSupport: Equatable, Sendable {
    var revision: Int
    var absent: Set<String> = []

    /// Every method the pane commands use is in revision 13. Below it nothing is known, so they
    /// stay away, exactly as before they existed.
    static let minimumRevision = 13
    static let none = PaneSupport(revision: 0)

    func has(_ c: PaneCommand) -> Bool {
        revision >= Self.minimumRevision && c.methods.allSatisfy { !absent.contains($0) }
    }
}

/// The pane a command would act on, in its tab, with the session's tabs.
struct PaneTarget {
    var window: WindowInfo
    var block: String
    var tabs: [WindowInfo]
}

/// The one availability check: the Arrange items, the bound keys and (later) the palette's rows
/// all read this, so a key never runs where the menu hides its item.
enum PaneArrange {
    /// With no target, whether the server can do it at all (what a key's resolution asks). With a
    /// target, whether it applies to that pane now.
    static func isAvailable(_ c: PaneCommand, target: PaneTarget?, support: PaneSupport) -> Bool {
        guard support.has(c) else { return false }
        guard let t = target else { return true }
        let w = t.window
        let panes = PaneScope.arrangeable(window: w)
        let here = panes.contains(t.block)
        switch c {
        case .swap: return here && !PaneScope.swappable(window: w, except: t.block).isEmpty
        case .closeOthers: return here && panes.count > 1
        case .moveToTab: return here && !MoveAnchor.targets(from: w.id, in: t.tabs).isEmpty
        case .moveToNewTab: return here && panes.count > 1
        // Balance evens the tiled splits; floats have none.
        case .balance: return (w.layout?.leaves.count ?? 0) > 1
        case .moveTab: return t.tabs.count > 1
        case .moveSession: return true
        case .minimize: return FloatArrange.minimizable(w, block: t.block) != nil
        case .minimizeAll: return !FloatArrange.minimizeAll(w).isEmpty
        case .restore: return !w.minimizedFloating.isEmpty
        case .raise: return w.floatingLayer(of: t.block) != nil
        }
    }

    /// Arrange shows for a tab with several panes when one of its items applies, and for a tab
    /// with a floating window to minimize or a minimized one to show, even with one pane.
    static func showsArrange(_ t: PaneTarget, support: PaneSupport) -> Bool {
        if [.minimize, .restore].contains(where: { isAvailable($0, target: t, support: support) }) { return true }
        guard PaneScope.arrangeable(window: t.window).count > 1 else { return false }
        return [.swap, .moveToTab, .moveToNewTab, .balance, .closeOthers].contains {
            isAvailable($0, target: t, support: support)
        }
    }
}

/// Which panes the commands work on: the tab's tiled panes in reading order, then its floating
/// windows' panes, front first, the minimized ones last. With no floating layer, the tiled panes.
enum PaneScope {
    static func arrangeable(window w: WindowInfo) -> [String] {
        var ids = w.layout?.leaves.map(\.id) ?? []
        for layer in w.visibleFloating.reversed() + w.minimizedFloating.reversed() {
            for id in layer.layout?.leaves.map(\.id) ?? [] where !ids.contains(id) { ids.append(id) }
        }
        return ids
    }

    /// The panes Swap With lists: every other pane on screen or a swipe away. A minimized float's
    /// pane isn't one: the pane swapped in would vanish with it.
    static func swappable(window w: WindowInfo, except block: String) -> [String] {
        arrangeable(window: w).filter { $0 != block && !w.isHidden($0) }
    }
}

/// The floating-window commands' rules, as the server keeps them: a window always keeps a pane
/// on screen, so a minimize that would leave none fails there and isn't offered here.
enum FloatArrange {
    static let layerStateMethod = "session.set_layer_state"

    /// The drawn floating layer that holds `block`, when minimizing it leaves a pane on screen.
    static func minimizable(_ w: WindowInfo, block: String) -> LayerInfo? {
        guard let layer = w.floatingLayer(of: block), layer.isDrawnFloat else { return nil }
        let rest = !(w.layout?.leaves.isEmpty ?? true) || w.visibleFloating.contains { $0.id != layer.id }
        return rest ? layer : nil
    }

    /// The layers Minimize All minimizes, back to front, in the order they are sent. With no tiled
    /// pane the front one stays, since minimizing it too would fail.
    static func minimizeAll(_ w: WindowInfo) -> [String] {
        let ids = w.visibleFloating.map(\.id)
        return (w.layout?.leaves.isEmpty ?? true) ? Array(ids.dropLast()) : ids
    }
}

/// Where a pane goes in another tab: beside that tab's focused pane if it is tiled, else beside
/// its first tiled pane, so a pane doesn't land in a floating layer while the tab has a tiled
/// one. A tab whose layout is empty takes it beside its focused (else front) floating pane.
enum MoveAnchor {
    struct Pick: Equatable {
        var block: String
        /// The anchor's longer side, as Split Pane Best Fit: `horizontal` side by side.
        var direction: String
    }

    static func pick(window w: WindowInfo) -> Pick? {
        var leaves = w.layout?.leaves ?? []
        if leaves.isEmpty {
            for layer in w.visibleFloating.reversed() { leaves += layer.layout?.leaves ?? [] }
        }
        guard !leaves.isEmpty else { return nil }
        let leaf = leaves.first { $0.id == w.focusedBlockID } ?? leaves[0]
        return Pick(block: leaf.id, direction: leaf.rect.width >= leaf.rect.height ? "horizontal" : "vertical")
    }

    /// The session's other tabs a pane can move to, in tab order.
    static func targets(from source: String, in tabs: [WindowInfo]) -> [WindowInfo] {
        tabs.filter { $0.id != source && pick(window: $0) != nil }
    }
}

/// Even sizes for a tab's splits, as the Mac's Balance Splits makes them: each pane in a row (or
/// column) of splits the same way gets the same share.
enum SplitBalance {
    struct Change: Equatable {
        var direction: String
        var before: String
        var after: String
        var ratio: Double
    }

    /// Within this of balanced, a split counts as balanced.
    static let tolerance = 0.005

    /// The splits whose ratio isn't balanced, with the ratio that balances each. Empty when the
    /// layout is balanced already.
    static func ratios(_ layout: LayoutNode) -> [Change] {
        var out: [Change] = []
        func walk(_ n: LayoutNode) {
            guard case .split(_, let dir, let ratio, let before, let after, _) = n else { return }
            let wb = weight(before, dir), wa = weight(after, dir)
            let even = min(max(wb / (wb + wa), 0.05), 0.95)
            if abs(even - ratio) > tolerance, let b = before.leaves.last?.id, let a = after.leaves.first?.id {
                out.append(Change(direction: dir, before: b, after: a, ratio: even))
            }
            walk(before)
            walk(after)
        }
        walk(layout)
        return out
    }

    /// How many panes share a node's space along `direction`: a split the same way adds its two
    /// sides, anything else counts as one.
    static func weight(_ n: LayoutNode, _ direction: String) -> Double {
        guard case .split(_, let dir, _, let b, let a, _) = n, dir == direction else { return 1 }
        return weight(b, direction) + weight(a, direction)
    }
}

/// What a pane's name in a menu is made of, besides its view: kept per block in its own table
/// (`ServerConnection.paneNames`), written only when one of these changes, so a title that
/// changes ten times a second (an agent's spinner) never rebuilds a menu.
struct PaneNameParts: Equatable, Sendable {
    var agent: AgentKind?
    var process: String?

    init?(_ meta: BlockMeta?) {
        let process = meta?.foreground.flatMap { $0.isEmpty ? nil : $0 }
        guard let meta, meta.agentKind != nil || process != nil else { return nil }
        agent = meta.agentKind
        self.process = process
    }

    init(agent: AgentKind?, process: String?) {
        self.agent = agent
        self.process = process
    }
}

/// A pane's name in menus and Go to Anything's rows. Never its title, which changes all the time.
enum PaneName {
    /// A label someone gave the block (on the Mac, from the CLI or a layout), not the one a block
    /// starts with: the last part of its flavor (`shell`), or `Block 89abcdef` after a label was
    /// cleared.
    static func isCustom(_ b: BlockInfo) -> Bool {
        let l = b.label.trimmingCharacters(in: .whitespaces)
        guard !l.isEmpty else { return false }
        if let last = b.flavor.split(separator: ".").last, l == last { return false }
        return !isPlaceholder(l)
    }

    /// `Block ` and eight hex digits: the label the server gives a block whose label was cleared.
    static func isPlaceholder(_ l: String) -> Bool {
        guard l.hasPrefix("Block ") else { return false }
        let id = l.dropFirst(6)
        return id.count == 8 && id.allSatisfy(\.isHexDigit)
    }

    /// Its custom label, else its agent's name, else its program, else "Pane N" by its place.
    static func menu(_ b: BlockInfo?, position: Int, parts: PaneNameParts?) -> String {
        if let b, isCustom(b) { return b.label.trimmingCharacters(in: .whitespaces) }
        if let a = parts?.agent { return a.displayName }
        if let p = parts?.process { return p }
        return "Pane \(position)"
    }

    /// Its agent's glyph name (`AgentGlyph`): a mark or an SF Symbol.
    static func symbol(_ parts: PaneNameParts?) -> String { AgentGlyph.name(agent: parts?.agent) }
}

/// A new place in an order: the row's id list, the row that moves, and the gap it is dropped in
/// (0 before the first row, `ids.count` after the last).
enum TabOrder {
    struct Move: Equatable {
        var order: [String]
        /// The id it goes in front of; nil for the end.
        var before: String?
    }

    /// Nil when it lands where it is, or isn't in the list.
    static func before(_ ids: [String], moving id: String, gap: Int) -> Move? {
        guard let from = ids.firstIndex(of: id), (0...ids.count).contains(gap) else { return nil }
        var rest = ids
        rest.remove(at: from)
        let at = gap > from ? gap - 1 : gap
        var order = rest
        order.insert(id, at: at)
        guard order != ids else { return nil }
        return Move(order: order, before: at < rest.count ? rest[at] : nil)
    }

    /// One place forward (+1) or back (-1), for `client.tab.move.*`; nil at the end.
    static func step(_ ids: [String], moving id: String, by d: Int) -> Move? {
        guard let i = ids.firstIndex(of: id), ids.indices.contains(i + d) else { return nil }
        return before(ids, moving: id, gap: d > 0 ? i + 2 : i - 1)
    }

    /// `ids` in the order `pending` gives; ids it doesn't name keep their place after the rest.
    static func applied(_ ids: [String], _ pending: [String]) -> [String] {
        let rank = Dictionary(pending.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return ids.enumerated().sorted { a, b in
            let ra = rank[a.element] ?? Int.max, rb = rank[b.element] ?? Int.max
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
    }
}
