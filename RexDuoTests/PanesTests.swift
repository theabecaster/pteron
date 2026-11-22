import CoreGraphics
import Foundation
import Observation
import Testing
import RexKit
@testable import RexDuo

/// The pane commands' pure parts: the even split ratios, where a moved pane lands, pane names,
/// the one tiled-only filter, new places in an order, the sidebar's held order and gaps, and the
/// one availability check that the menu, the keys and the shortcut list share.
@MainActor
struct PanesTests {
    // MARK: Fixtures

    static let terminal = "com.superlogical.terminal"

    static func block(_ id: String, label: String = "shell") -> JSONObject {
        ["block_id": id, "creator_name": terminal, "flavor": "\(terminal).shell", "label": label]
    }

    static func leaf(_ id: String, _ r: [Double]) -> JSONObject { ["block_id": id, "rect": r] }

    static func split(_ dir: String, _ ratio: Double, _ r: [Double], _ before: JSONObject, _ after: JSONObject) -> JSONObject {
        ["rect": r, "split": ["split_id": "split:\(UUID().uuidString.prefix(4))", "direction": dir, "ratio": ratio,
                              "before": before, "after": after] as JSONObject]
    }

    /// A window with a tiled layout over `blocks`, and optionally a floating layer.
    static func window(_ id: String, label: String = "", focused: String? = nil, layout: JSONObject?, blocks: [JSONObject],
                       floats: [JSONObject] = []) -> WindowInfo {
        var tiled: JSONObject = ["kind": "tiled", "layer_id": "layer:\(id)", "bounds": [0, 0, 1, 1], "blocks": blocks]
        if let layout { tiled["layout"] = layout }
        var layers: [JSONObject] = [tiled]
        if !floats.isEmpty {
            layers.append(["kind": "floating", "layer_id": "float:\(id)", "bounds": [0.6, 0.6, 0.3, 0.3], "blocks": floats,
                           "layout": leaf(floats[0].str("block_id") ?? "", [0.6, 0.6, 0.3, 0.3])])
        }
        var w: JSONObject = ["window_id": id, "label": label, "layers": layers]
        if let focused { w["focused_block_id"] = focused }
        return WindowInfo(w)
    }

    /// `a | b | c`, side by side: a split of a and (b | c).
    static func threeAcross(_ id: String = "window:1", ratios: (Double, Double) = (0.5, 0.5)) -> WindowInfo {
        window(id, layout: split("horizontal", ratios.0, [0, 0, 1, 1], leaf("a", [0, 0, 0.5, 1]),
                                 split("horizontal", ratios.1, [0.5, 0, 0.5, 1], leaf("b", [0.5, 0, 0.25, 1]), leaf("c", [0.75, 0, 0.25, 1]))),
               blocks: [block("a"), block("b"), block("c")])
    }

    static let full = PaneSupport(revision: 18)

    // MARK: Balance

    @Test func balancingThreeAcrossGivesAThirdThenAHalf() throws {
        let layout = try #require(Self.threeAcross().layout)
        let changes = SplitBalance.ratios(layout)
        #expect(changes.count == 1)
        let outer = try #require(changes.first)
        #expect(abs(outer.ratio - 1.0 / 3) < 0.0001)
        #expect(outer.direction == "horizontal" && outer.before == "a" && outer.after == "b")
        // The inner split is even already.
        let inner = SplitBalance.ratios(try #require(Self.threeAcross(ratios: (0.4, 0.7)).layout))
        #expect(inner.count == 2)
        #expect(inner.contains { $0.before == "b" && $0.after == "c" && abs($0.ratio - 0.5) < 0.0001 })
    }

    @Test func aSplitTheOtherWayCountsAsOnePane() throws {
        // a | (b over c): the outer split is even, the inner one too.
        let w = Self.window("window:1", layout: Self.split("horizontal", 0.7, [0, 0, 1, 1], Self.leaf("a", [0, 0, 0.7, 1]),
                                                          Self.split("vertical", 0.2, [0.7, 0, 0.3, 1], Self.leaf("b", [0.7, 0, 0.3, 0.2]), Self.leaf("c", [0.7, 0.2, 0.3, 0.8]))),
                            blocks: [Self.block("a"), Self.block("b"), Self.block("c")])
        let changes = SplitBalance.ratios(try #require(w.layout))
        #expect(changes.map(\.ratio) == [0.5, 0.5])
        #expect(changes.map(\.direction) == ["horizontal", "vertical"])
    }

    @Test func aBalancedLayoutChangesNothing() throws {
        let layout = try #require(Self.threeAcross(ratios: (1.0 / 3, 0.5)).layout)
        #expect(SplitBalance.ratios(layout).isEmpty)
        // Within the tolerance counts as balanced.
        #expect(SplitBalance.ratios(try #require(Self.threeAcross(ratios: (1.0 / 3 + 0.004, 0.496)).layout)).isEmpty)
    }

    @Test func ratiosAreClamped() {
        // 1 pane against 30 in a row: 1/31 is below the server's floor.
        var after = LayoutNode.block(id: "z", rect: .zero)
        for i in 0..<29 {
            after = .split(id: "s\(i)", direction: "horizontal", ratio: 0.5, before: .block(id: "p\(i)", rect: .zero), after: after, rect: .zero)
        }
        let root = LayoutNode.split(id: "root", direction: "horizontal", ratio: 0.5, before: .block(id: "a", rect: .zero), after: after, rect: .zero)
        let outer = SplitBalance.ratios(root).first { $0.before == "a" }
        #expect(outer?.ratio == 0.05)
    }

    // MARK: Where a moved pane lands

    @Test func aFocusedFloatAnchorsOnTheFirstTiledPane() {
        let w = Self.window("window:2", focused: "f", layout: Self.split("horizontal", 0.5, [0, 0, 1, 1], Self.leaf("x", [0, 0, 0.5, 1]), Self.leaf("y", [0.5, 0, 0.5, 1])),
                            blocks: [Self.block("x"), Self.block("y")], floats: [Self.block("f")])
        #expect(MoveAnchor.pick(window: w)?.block == "x")
        let focusedTiled = Self.window("window:2", focused: "y", layout: Self.split("vertical", 0.5, [0, 0, 1, 1], Self.leaf("x", [0, 0, 1, 0.5]), Self.leaf("y", [0, 0.5, 1, 0.5])),
                                       blocks: [Self.block("x"), Self.block("y")])
        #expect(MoveAnchor.pick(window: focusedTiled) == MoveAnchor.Pick(block: "y", direction: "horizontal"))
        let tall = Self.window("window:3", layout: Self.leaf("t", [0, 0, 0.3, 1]), blocks: [Self.block("t")])
        #expect(MoveAnchor.pick(window: tall)?.direction == "vertical")
    }

    @Test func aTabWithOnlyAFloatTakesThePaneBesideIt() {
        let floats = Self.window("window:2", layout: nil, blocks: [], floats: [Self.block("f")])
        #expect(MoveAnchor.pick(window: floats)?.block == "f")
        let empty = Self.window("window:4", layout: nil, blocks: [])
        #expect(MoveAnchor.pick(window: empty) == nil)
        let tabs = [Self.threeAcross(), floats, Self.window("window:3", layout: Self.leaf("t", [0, 0, 1, 1]), blocks: [Self.block("t")]), empty]
        #expect(MoveAnchor.targets(from: "window:1", in: tabs).map(\.id) == ["window:2", "window:3"])
    }

    // MARK: Names

    @Test func onlyAGivenLabelIsCustom() {
        func b(_ label: String) -> BlockInfo { BlockInfo(Self.block("a", label: label)) }
        #expect(!PaneName.isCustom(b("shell")))
        #expect(!PaneName.isCustom(b("")))
        #expect(!PaneName.isCustom(b("Block 89abcdef")))
        #expect(PaneName.isCustom(b("Block 89abcdeg")))
        #expect(PaneName.isCustom(b("server")))
        #expect(PaneName.isCustom(b("  build  ")))
    }

    @Test func aNameIsTheLabelThenTheAgentThenTheProgramThenItsPlace() {
        let custom = BlockInfo(Self.block("a", label: "server"))
        let plain = BlockInfo(Self.block("a"))
        let claude = PaneNameParts(agent: .claude, process: "node")
        #expect(PaneName.menu(custom, position: 2, parts: claude) == "server")
        #expect(PaneName.menu(plain, position: 2, parts: claude) == "Claude")
        #expect(PaneName.menu(plain, position: 2, parts: PaneNameParts(agent: nil, process: "vim")) == "vim")
        #expect(PaneName.menu(plain, position: 2, parts: nil) == "Pane 2")
        #expect(PaneName.symbol(claude) == "agent.claude")
        #expect(PaneName.symbol(nil) == "terminal")
    }

    @Test func aTitleNeverNamesAPane() {
        var m = BlockMeta()
        m.title = "✳ Fixing the tests"
        // The title says Claude, so the agent is Claude; the title itself is never the name.
        #expect(PaneName.menu(BlockInfo(Self.block("a")), position: 1, parts: PaneNameParts(m)) == "Claude")
        var shell = BlockMeta()
        shell.title = "abe@mac:~/code/project"
        #expect(PaneNameParts(shell) == nil)
        #expect(PaneName.menu(BlockInfo(Self.block("a")), position: 3, parts: PaneNameParts(shell)) == "Pane 3")
    }

    @Test func aSpinningTitleWritesNoName() {
        var a = BlockMeta()
        a.title = "✳ Claude Code"
        a.foreground = "claude"
        var b = a
        b.title = "✶ Claude Code"
        #expect(PaneNameParts(a) == PaneNameParts(b))
    }

    // MARK: One pane filter

    @Test func everyPaneListReadsTheOneFilterFloatsIncluded() {
        // Two tiled panes and a float: the float is in the list, the snapshot and the count.
        let w = Self.window("window:1", focused: "a", layout: Self.split("horizontal", 0.5, [0, 0, 1, 1], Self.leaf("a", [0, 0, 0.5, 1]), Self.leaf("b", [0.5, 0, 0.5, 1])),
                            blocks: [Self.block("a"), Self.block("b")], floats: [Self.block("f")])
        #expect(PaneScope.arrangeable(window: w) == ["a", "b", "f"])
        #expect(w.allBlocks.count == 3)
        let t = PaneTarget(window: w, block: "a", tabs: [w])
        #expect(PaneArrange.isAvailable(.swap, target: t, support: Self.full))
        #expect(PaneArrange.isAvailable(.moveToNewTab, target: t, support: Self.full))
        #expect(PaneArrange.isAvailable(.swap, target: PaneTarget(window: w, block: "f", tabs: [w]), support: Self.full))
        let single = Self.window("window:2", layout: Self.leaf("x", [0, 0, 1, 1]), blocks: [Self.block("x")], floats: [Self.block("g")])
        let one = PaneTarget(window: single, block: "x", tabs: [w, single])
        // The tab's only tiled pane shares the tab with a float: New Tab and Close Other Panes apply.
        #expect(PaneArrange.isAvailable(.moveToNewTab, target: one, support: Self.full))
        #expect(PaneArrange.isAvailable(.closeOthers, target: one, support: Self.full))
        #expect(PaneArrange.showsArrange(one, support: Self.full))
        #expect(PaneArrange.isAvailable(.moveToTab, target: one, support: Self.full))
        // Without floats nothing changes: one pane, no Arrange.
        let alone = Self.window("window:3", layout: Self.leaf("y", [0, 0, 1, 1]), blocks: [Self.block("y")])
        #expect(!PaneArrange.showsArrange(PaneTarget(window: alone, block: "y", tabs: [alone]), support: Self.full))
        #expect(PaneScope.arrangeable(window: alone) == ["y"])
    }

    // MARK: Orders

    @Test func aNewPlaceGivesTheOrderAndTheNeighbor() {
        let ids = ["a", "b", "c"]
        #expect(TabOrder.before(ids, moving: "a", gap: 3) == TabOrder.Move(order: ["b", "c", "a"], before: nil))
        #expect(TabOrder.before(ids, moving: "c", gap: 0) == TabOrder.Move(order: ["c", "a", "b"], before: "a"))
        #expect(TabOrder.before(ids, moving: "a", gap: 2) == TabOrder.Move(order: ["b", "a", "c"], before: "c"))
        #expect(TabOrder.before(ids, moving: "a", gap: 0) == nil)
        #expect(TabOrder.before(ids, moving: "a", gap: 1) == nil)
        #expect(TabOrder.before(ids, moving: "z", gap: 1) == nil)
        #expect(TabOrder.step(ids, moving: "b", by: 1) == TabOrder.Move(order: ["a", "c", "b"], before: nil))
        #expect(TabOrder.step(ids, moving: "b", by: -1) == TabOrder.Move(order: ["b", "a", "c"], before: "a"))
        #expect(TabOrder.step(ids, moving: "c", by: 1) == nil)
        #expect(TabOrder.applied(["a", "b", "c", "d"], ["c", "a", "b"]) == ["c", "a", "b", "d"])
    }

    @Test func aTabHoldWaitsForTheNewestRevision() {
        var h = PendingOrder.Hold(order: ["b", "a"], token: 2)
        #expect(!PendingOrder.released(h, viewRevision: 99), "no answer yet")
        h.revision = 7
        #expect(!PendingOrder.released(h, viewRevision: 6))
        #expect(PendingOrder.released(h, viewRevision: 7))
        #expect(PendingOrder.released(PendingOrder.Hold(order: ["b", "a"], token: 1), listed: ["b", "a"]))
        #expect(!PendingOrder.released(PendingOrder.Hold(order: ["b", "a"], token: 1), listed: ["a", "b"]))
    }

    // MARK: Gaps

    static func frames(_ rows: [(String, SidebarOutline.Row.Kind, CGFloat, CGFloat)]) -> [String: SidebarDrag.Frame] {
        Dictionary(uniqueKeysWithValues: rows.map { ($0.0, SidebarDrag.Frame(kind: $0.1, minY: $0.2, maxY: $0.3)) })
    }

    static let m = UUID()

    static var outline: [String: SidebarDrag.Frame] {
        frames([
            ("s1", .session(m, "s1"), 0, 30), ("t1", .tab(m, session: "s1", window: "w1"), 30, 66), ("t2", .tab(m, session: "s1", window: "w2"), 66, 102),
            ("s2", .session(m, "s2"), 110, 140), ("t3", .tab(m, session: "s2", window: "w3"), 140, 176),
        ])
    }

    static let orders = SidebarDrag.Orders(sessions: { _ in ["s1", "s2"] },
                                           tabs: { _, s in s == "s1" ? ["w1", "w2"] : ["w3"] })

    @Test func aTabGapIsTheNearestBoundaryInItsSession() {
        let item = SidebarDrag.Item.tab(server: Self.m, session: "s1", window: "w1")
        #expect(SidebarGaps.gap(for: item, at: 70, frames: Self.outline, orders: Self.orders)?.index == 1)
        let end = SidebarGaps.gap(for: item, at: 99, frames: Self.outline, orders: Self.orders)
        #expect(end?.index == 2 && end?.y == 102)
        // Over the other session: still the nearest edge of its own session.
        #expect(SidebarGaps.gap(for: item, at: 160, frames: Self.outline, orders: Self.orders)?.index == 2)
        #expect(SidebarGaps.gap(for: item, at: 160, frames: Self.outline, orders: Self.orders)?.leading == SidebarMetrics.tabLeading)
    }

    @Test func aSessionGapSnapsToASessionsEdge() {
        let item = SidebarDrag.Item.session(server: Self.m, session: "s2")
        // Over s1's tabs: s1's nearer edge.
        #expect(SidebarGaps.gap(for: item, at: 40, frames: Self.outline, orders: Self.orders)?.y == 0)
        let below = SidebarGaps.gap(for: item, at: 90, frames: Self.outline, orders: Self.orders)
        #expect(below?.index == 1 && below?.y == 110)
        #expect(SidebarGaps.gap(for: item, at: 170, frames: Self.outline, orders: Self.orders)?.index == 2)
        // Another server's rows don't count.
        #expect(SidebarGaps.gap(for: .session(server: UUID(), session: "s2"), at: 40, frames: Self.outline, orders: Self.orders) == nil)
    }

    @Test func framesAreForgottenWhenRowsLeave() {
        let d = SidebarDrag()
        d.record("t1", .tab(Self.m, session: "s1", window: "w1"), CGRect(x: 0, y: 30, width: 100, height: 36))
        #expect(d.frames["t1"]?.maxY == 66)
        d.forget("t1")
        #expect(d.frames.isEmpty)
    }

    // MARK: Keys

    @Test func theNewActionsResolveWhereTheServerHasThem() {
        func command(_ name: String, _ s: PaneSupport) -> RexCommand? {
            if case .command(let c)? = AppAction.resolve(name, nil, panes: s) { return c }
            return nil
        }
        #expect(command("pane.balance", Self.full) == .balanceSplits)
        #expect(command("pane.close_others", Self.full) == .closeOtherPanes)
        #expect(command("pane.move_to_tab", Self.full) == .moveToTab)
        #expect(command("pane.move_to_new_tab", Self.full) == .moveToNewTab)
        #expect(command("client.tab.move.backward", Self.full) == .moveTab(-1))
        #expect(command("client.tab.move.forward", Self.full) == .moveTab(1))
        for name in ["pane.balance", "pane.close_others", "pane.move_to_tab", "pane.move_to_new_tab", "client.tab.move.forward"] {
            #expect(AppAction.resolve(name, nil) == nil, "\(name) falls through with no support")
            #expect(AppAction.resolve(name, nil, panes: PaneSupport(revision: 12)) == nil)
        }
        #expect(AppAction.resolve("pane.balance", nil, panes: PaneSupport(revision: 18, absent: ["session.resize_pane"])) == nil)
        #expect(command("pane.close_others", PaneSupport(revision: 18, absent: ["session.resize_pane"])) == .closeOtherPanes)
    }

    @Test func renameAndMoveByDirectionStayUnbound() {
        for name in ["pane.rename", "pane.move.left", "pane.move.right", "pane.move.up", "pane.move.down", "pane.move"] {
            #expect(AppAction.resolve(name, nil, panes: Self.full) == nil, "\(name)")
        }
    }

    @Test func theNewActionsHaveTheMacsTitles() {
        #expect(KeyActions.byName["pane.balance"]?.title == "Balance Splits")
        #expect(KeyActions.byName["pane.close_others"]?.title == "Close Other Panes")
        #expect(KeyActions.byName["pane.move_to_tab"]?.title == "Move Pane to Tab…")
        #expect(KeyActions.byName["pane.move_to_new_tab"]?.title == "Move Pane to New Tab")
        #expect(KeyActions.byName["client.tab.move.backward"]?.title == "Move Tab Backward")
        #expect(KeyActions.byName["client.tab.move.forward"]?.title == "Move Tab Forward")
        #expect(KeyActions.byName["pane.rename"] == nil)
    }

    @Test func aBoundKeyShowsInTheShortcutListOnlyWithSupport() {
        let bindings = [KeyBinding(chord: KeyChord(spelling: "ctrl+cmd+b")!, action: "pane.balance", args: nil)] + KeyDefaults.resolved
        #expect(AppShortcuts.list(bindings, panes: Self.full).contains { $0.command == .balanceSplits })
        #expect(!AppShortcuts.list(bindings).contains { $0.command == .balanceSplits })
        #expect(KeyLabel.for(action: "pane.balance", in: bindings, panes: Self.full) == "⌃⌘B")
        #expect(KeyLabel.for(action: "pane.balance", in: bindings) == nil)
    }

    @Test func theKeymapsSupportIsANewGeneration() {
        let k = KeymapStore(control: RexControl(address: "", client: ClientInfo(name: "test", version: "0", label: "test")))
        let g = k.generation
        k.panes = Self.full
        #expect(k.generation == g + 1)
        k.panes = Self.full
        #expect(k.generation == g + 1, "the same support is no change")
        let chord = KeyChord(spelling: "ctrl+cmd+b")!
        k.apply([KeyBinding(chord: chord, action: "pane.balance", args: nil)])
        if case .command(.balanceSplits)? = k.resolve([chord])?.1 {} else { Issue.record("expected Balance Splits") }
        k.panes = .none
        #expect(k.resolve([chord]) == nil, "falls through")
    }

    // MARK: One availability check

    /// For each server the menu shows an item exactly where its key resolves and the predicate says
    /// yes: rev 0, 13, 16, 18, and 18 with each method missing.
    @Test func theMenuTheKeysAndThePredicateAgree() {
        var cases: [PaneSupport] = [PaneSupport(revision: 0), PaneSupport(revision: 13), PaneSupport(revision: 16), Self.full]
        for m in PaneCommand.allMethods.sorted() { cases.append(PaneSupport(revision: 18, absent: [m])) }
        cases.append(PaneSupport(revision: 18, absent: PaneCommand.allMethods))
        let two = Self.window("window:1", layout: Self.split("horizontal", 0.3, [0, 0, 1, 1], Self.leaf("a", [0, 0, 0.3, 1]), Self.leaf("b", [0.3, 0, 0.7, 1])),
                              blocks: [Self.block("a"), Self.block("b")])
        let other = Self.window("window:2", layout: Self.leaf("x", [0, 0, 1, 1]), blocks: [Self.block("x")])
        let t = PaneTarget(window: two, block: "a", tabs: [two, other])
        let keys: [(PaneCommand, String)] = [(.balance, "pane.balance"), (.closeOthers, "pane.close_others"),
                                             (.moveToTab, "pane.move_to_tab"), (.moveToNewTab, "pane.move_to_new_tab"),
                                             (.moveTab, "client.tab.move.forward")]
        for s in cases {
            let model = PaneMenuModel.build(t, support: s)
            for (c, name) in keys {
                let live = PaneArrange.isAvailable(c, target: t, support: s)
                #expect((AppAction.resolve(name, nil, panes: s) != nil) == PaneArrange.isAvailable(c, target: nil, support: s), "\(name) \(s)")
                switch c {
                case .balance: #expect((model?.balance ?? false) == live, "\(s)")
                case .closeOthers: #expect((model?.closeOthers ?? false) == live, "\(s)")
                case .moveToTab: #expect(!(model?.tabs.isEmpty ?? true) == live, "\(s)")
                case .moveToNewTab: #expect((model?.newTab ?? false) == live, "\(s)")
                default: break
                }
            }
            #expect(!(model?.swap.isEmpty ?? true) == PaneArrange.isAvailable(.swap, target: t, support: s))
            if s.revision < 13 || s.absent == PaneCommand.allMethods { #expect(model == nil, "no Arrange at all") }
        }
    }
}
