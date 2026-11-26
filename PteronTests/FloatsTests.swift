import CoreGraphics
import Foundation
import Testing
import RexKit
@testable import Pteron

/// Floating windows' pure parts: when a tab has a presentation at all, how it is shown, where each
/// float is drawn, which pane is active, what a tap sends, what counts as on screen, and the
/// commands' availability on old and new servers.
@MainActor
struct FloatsTests {
    // MARK: Fixtures

    static let terminal = "com.superlogical.terminal"
    /// An unfolded Duo's tab, about: wide enough for splits and floats at 13 pt.
    static let canvas = CGSize(width: 1000, height: 700)
    static let font = 13.0

    static func block(_ id: String) -> JSONObject {
        ["block_id": id, "creator_name": terminal, "flavor": "\(terminal).shell", "label": "shell"]
    }

    static func leaf(_ id: String, _ r: [Double]) -> JSONObject { ["block_id": id, "rect": r] }

    static func split(_ dir: String, _ r: [Double], _ before: JSONObject, _ after: JSONObject) -> JSONObject {
        ["rect": r, "split": ["split_id": "split:\(UUID().uuidString.prefix(4))", "direction": dir, "ratio": 0.5,
                              "before": before, "after": after] as JSONObject]
    }

    /// A floating layer holding one pane at `r`.
    static func float(_ id: String, _ block: String, _ r: [Double], state: String? = nil) -> JSONObject {
        var l: JSONObject = ["layer_id": id, "kind": "floating", "bounds": r, "layout": leaf(block, r), "blocks": [Self.block(block)]]
        if let state { l["state"] = state }
        return l
    }

    static func window(focused: String? = nil, zoomed: String? = nil, tiled: JSONObject?, tiledBlocks: [String],
                       floats: [JSONObject] = []) -> WindowInfo {
        var t: JSONObject = ["layer_id": "layer:t", "kind": "tiled", "bounds": [0, 0, 1, 1], "blocks": tiledBlocks.map(block)]
        if let tiled { t["layout"] = tiled }
        var w: JSONObject = ["window_id": "window:1", "label": "", "layers": [t] + floats]
        if let focused { w["focused_block_id"] = focused }
        if let zoomed { w["zoomed_block_id"] = zoomed }
        return WindowInfo(w)
    }

    static let one = leaf("A", [0, 0, 1, 1])
    static let two = split("horizontal", [0, 0, 1, 1], leaf("A", [0, 0, 0.5, 1]), leaf("B", [0.5, 0, 0.5, 1]))
    static let floatF = float("layer:f", "F", [0.3, 0.2, 0.5, 0.6])

    static func decide(_ w: WindowInfo, narrow: Bool = false, zoomed: Bool = false, active: String? = nil,
                       canvas: CGSize = canvas, crease: FloatLayout.Crease? = nil, front: String? = nil) -> TabPresentation? {
        TabPresentation.decide(.init(window: w, narrow: narrow, zoomed: zoomed, active: active ?? ActivePane.of(w, phone: nil),
                                     canvas: canvas, fontSize: font, crease: crease, front: front))
    }

    static func near(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 1e-9 && abs(a.minY - b.minY) < 1e-9 && abs(a.width - b.width) < 1e-9 && abs(a.height - b.height) < 1e-9
    }

    static let full = PaneSupport(revision: 18)

    // MARK: The gate

    @Test func aTabWithoutAFloatOnScreenHasNoPresentation() {
        #expect(Self.decide(Self.window(tiled: Self.two, tiledBlocks: ["A", "B"])) == nil)
        // Only minimized floats: today's layout over the tiled panes.
        let minimized = Self.window(tiled: Self.two, tiledBlocks: ["A", "B"],
                                    floats: [Self.float("layer:m", "M", [0.1, 0.1, 0.4, 0.4], state: "minimized")])
        #expect(Self.decide(minimized) == nil)
        #expect(Self.decide(minimized, narrow: true) == nil)
        // A float the server gives no place isn't drawn either.
        var unplaced = Self.float("layer:x", "X", [0.1, 0.1, 0.4, 0.4])
        unplaced["bounds"] = [0.1, 0.1]
        #expect(Self.decide(Self.window(tiled: Self.one, tiledBlocks: ["A"], floats: [unplaced])) == nil)
        // An older server's view: no layers at all.
        #expect(Self.decide(WindowInfo(["window_id": "window:1"])) == nil)
    }

    // MARK: Pages

    @Test func zoomedPagesLeaveOutMinimizedFloatsAndASwipeFromTheLastTiledPaneReachesTheFrontFloat() {
        let w = Self.window(tiled: Self.two, tiledBlocks: ["A", "B"], floats: [
            Self.float("layer:back", "F", [0.1, 0.1, 0.4, 0.4]),
            Self.float("layer:m", "M", [0.2, 0.2, 0.4, 0.4], state: "minimized"),
            Self.float("layer:front", "G", [0.5, 0.5, 0.4, 0.4]),
        ])
        guard case .pages(let ids, let current)? = Self.decide(w, narrow: true, zoomed: true, active: "B") else {
            Issue.record("zoomed is pages, narrow or wide")
            return
        }
        #expect(ids == ["A", "B", "G", "F"])
        #expect(current == "B")
        #expect(ids[ids.firstIndex(of: "B")! + 1] == "G", "the next page after the last tiled pane is the front float")
        #expect(!ids.contains("M"))
    }

    /// Narrow windows never draw floating windows nor page into them: the float sheet
    /// (`FloatSheetTests`), however big the canvas.
    @Test func narrowIsAlwaysTheFloatSheet() {
        let w = Self.window(tiled: Self.one, tiledBlocks: ["A"], floats: [Self.floatF])
        guard case .floatSheet(let s)? = Self.decide(w, narrow: true, active: "A", canvas: CGSize(width: 3000, height: 3000)) else {
            Issue.record("narrow is the sheet")
            return
        }
        #expect(s.tiled == .page("A", ids: ["A"]) && s.shown == nil && s.floats == ["layer:f"])
        #expect(Self.decide(w, narrow: true, active: "A")?.pageIDs == ["A"], "a float is never a page")
    }

    @Test func zoomShowsTheZoomedPaneAsAnyZoomedTabDoes() {
        let w = Self.window(zoomed: "F", tiled: Self.two, tiledBlocks: ["A", "B"], floats: [Self.floatF])
        #expect(Self.decide(w, zoomed: true) == .pages(ids: ["A", "B", "F"], current: "F"))
        #expect(Self.decide(w, zoomed: true)?.canZoom == false)
    }

    // MARK: Wide

    @Test func oneTiledPaneAndAFloatDrawTheFloatAtTheMacsRect() throws {
        let w = Self.window(tiled: Self.one, tiledBlocks: ["A"], floats: [Self.floatF])
        guard case .floating(let tiled, let floats)? = Self.decide(w) else {
            Issue.record("wide with room is floating")
            return
        }
        #expect(tiled == .single("A"))
        let f = try #require(floats.first)
        #expect(f.id == "layer:f")
        #expect(Self.near(f.rect, CGRect(x: 0.3, y: 0.2, width: 0.5, height: 0.6)), "big enough: drawn where the Mac has it")
        #expect(Self.decide(w)?.canZoom == true)
        #expect(Self.decide(w)?.pageIDs == nil, "no dots, no pane swipe")
    }

    @Test func illegibleTiledSplitsGivePages() {
        let three = Self.split("horizontal", [0, 0, 1, 1], Self.leaf("A", [0, 0, 0.34, 1]),
                               Self.split("horizontal", [0.34, 0, 0.66, 1], Self.leaf("B", [0.34, 0, 0.33, 1]), Self.leaf("C", [0.67, 0, 0.33, 1])))
        let w = Self.window(tiled: three, tiledBlocks: ["A", "B", "C"], floats: [Self.floatF])
        #expect(Self.decide(w, canvas: CGSize(width: 700, height: 700))?.pageIDs == ["A", "B", "C", "F"])
        guard case .floating(.splits, _)? = Self.decide(w, canvas: CGSize(width: 1400, height: 700)) else {
            Issue.record("legible splits stay splits under the float")
            return
        }
    }

    @Test func anEmptyLayoutLeavesTheFloatsOnTheBackground() {
        let w = Self.window(tiled: nil, tiledBlocks: [], floats: [Self.floatF])
        guard case .floating(.empty, let floats)? = Self.decide(w) else {
            Issue.record("only floats left")
            return
        }
        #expect(floats.map(\.id) == ["layer:f"])
    }

    /// Book mode's sidebar collapse asks whether the tiled splits would fit the two pages with the
    /// sidebar gone, as for any tab: beside the sidebar the same tab shows pages, and its floats
    /// must not keep the sidebar open.
    @Test func besideTheSidebarSplitsUnderAFloatArePagesAndCollapsedTheyAreSplits() {
        let w = Self.window(tiled: Self.two, tiledBlocks: ["A", "B"], floats: [Self.float("layer:x", "X", [0.6, 0.2, 0.35, 0.5])])
        let beside = CGSize(width: 607, height: 669), collapsed = CGSize(width: 867, height: 669)
        #expect(Self.decide(w, canvas: beside)?.pageIDs != nil)
        guard case .floating(.splits, _)? = Self.decide(w, canvas: collapsed) else { Issue.record("splits once collapsed"); return }
        let leaves = w.layout?.leaves.map(\.rect) ?? []
        #expect(BookSplit.fitsCollapsed(leaves: leaves, splits: w.layout?.splits ?? [], canvas: collapsed,
                                        crease: CGRect(x: 455.5, y: 0, width: 40, height: 669), fontSize: Self.font))
    }

    @Test func anUnknownKindAndStateDrawAsAFloat() {
        var odd = Self.floatF
        odd["kind"] = "popover"
        odd["state"] = "shaded"
        let w = Self.window(tiled: Self.one, tiledBlocks: ["A"], floats: [odd])
        #expect(Self.decide(w)?.visible(in: w) == ["A", "F"])
    }

    // MARK: Geometry

    @Test func growingASplitFloatKeepsItsPanesProportions() throws {
        // Two panes stacked in a small float: each needs 8 rows, so the float grows tall enough
        // for both, around its center, and stays as wide as 40 columns need.
        let stacked = Self.split("vertical", [0.4, 0.4, 0.2, 0.2], Self.leaf("F1", [0.4, 0.4, 0.2, 0.1]), Self.leaf("F2", [0.4, 0.5, 0.2, 0.1]))
        let layer = LayerInfo(["layer_id": "layer:s", "kind": "floating", "bounds": [0.4, 0.4, 0.2, 0.2], "layout": stacked,
                               "blocks": [Self.block("F1"), Self.block("F2")]])
        let least = try #require(FloatLayout.minimumPane(canvas: Self.canvas, fontSize: Self.font))
        let f = try #require(FloatLayout.place(layer, canvas: Self.canvas, fontSize: Self.font, crease: nil))
        #expect(abs(f.rect.width - least.width) < 1e-9)
        #expect(abs(f.rect.height - least.height * 2) < 1e-9)
        #expect(abs(f.rect.midX - 0.5) < 1e-9 && abs(f.rect.midY - 0.5) < 1e-9, "grown around its center")
        #expect(f.leaves.map(\.id) == ["F1", "F2"])
        #expect(abs(f.leaves[0].rect.height - f.leaves[1].rect.height) < 1e-9)
        #expect(abs(f.leaves[1].rect.minY - f.leaves[0].rect.maxY) < 1e-9)
        #expect(f.leaves.allSatisfy { abs($0.rect.width - f.rect.width) < 1e-9 })
    }

    @Test func aGrownFloatStaysInsideTheArea() throws {
        let layer = LayerInfo(Self.float("layer:c", "C", [0.9, 0.9, 0.1, 0.1]))
        let f = try #require(FloatLayout.place(layer, canvas: Self.canvas, fontSize: Self.font, crease: nil))
        #expect(f.rect.maxX <= 1 + 1e-9 && f.rect.maxY <= 1 + 1e-9)
        #expect(f.rect.minX >= 0 && f.rect.minY >= 0)
    }

    @Test func aFloatAcrossTheCreaseMovesOntoItsPageWithOneTiledPaneAndNoBookMode() throws {
        let crease = try #require(FloatLayout.crease(CGRect(x: 490, y: 0, width: 20, height: 700), areaMinX: 0, areaWidth: 1000))
        #expect(crease == FloatLayout.Crease(lead: 0.49, trail: 0.51))
        let w = Self.window(tiled: Self.one, tiledBlocks: ["A"], floats: [Self.float("layer:x", "X", [0.3, 0.2, 0.3, 0.5])])
        guard case .floating(.single("A"), let floats)? = Self.decide(w, crease: crease), let f = floats.first else {
            Issue.record("the tiled pane spans the fold as before; the float moves")
            return
        }
        #expect(f.rect.maxX <= 0.49 + 1e-9, "on the left page, clear of the crease")
        #expect(f.rect.width >= (FloatLayout.minimumPane(canvas: Self.canvas, fontSize: Self.font)?.width ?? 1) - 1e-9)
        // Its center on the right: the right page.
        let right = Self.window(tiled: Self.one, tiledBlocks: ["A"], floats: [Self.float("layer:x", "X", [0.45, 0.2, 0.3, 0.5])])
        #expect((Self.decide(right, crease: crease)?.visible(in: right)).map { $0.contains("X") } == true)
        guard case .floating(_, let rf)? = Self.decide(right, crease: crease) else { Issue.record("floating"); return }
        #expect((rf.first?.rect.minX ?? 0) >= 0.51 - 1e-9)
    }

    @Test func aFloatTooWideForAPageGivesPages() throws {
        let crease = FloatLayout.Crease(lead: 0.49, trail: 0.51)
        let across = Self.split("horizontal", [0.1, 0.2, 0.8, 0.5], Self.leaf("L", [0.1, 0.2, 0.4, 0.5]), Self.leaf("R", [0.5, 0.2, 0.4, 0.5]))
        let wide: JSONObject = ["layer_id": "layer:w", "kind": "floating", "bounds": [0.1, 0.2, 0.8, 0.5], "layout": across,
                                "blocks": [Self.block("L"), Self.block("R")]]
        let w = Self.window(tiled: Self.one, tiledBlocks: ["A"], floats: [wide])
        #expect(Self.decide(w, crease: crease)?.pageIDs == ["A", "L", "R"])
        guard case .floating? = Self.decide(w) else { Issue.record("flat, it fits"); return }
    }

    @Test func noSizeInsideTheAreaGivesPages() {
        // Two side by side need 80 columns: wider than a small window.
        let across = Self.split("horizontal", [0, 0, 1, 1], Self.leaf("L", [0, 0, 0.5, 1]), Self.leaf("R", [0.5, 0, 0.5, 1]))
        let layer: JSONObject = ["layer_id": "layer:w", "kind": "floating", "bounds": [0, 0, 1, 1], "layout": across,
                                 "blocks": [Self.block("L"), Self.block("R")]]
        let w = Self.window(tiled: Self.one, tiledBlocks: ["A"], floats: [layer])
        #expect(Self.decide(w, canvas: CGSize(width: 500, height: 700))?.pageIDs != nil)
        #expect(FloatLayout.place(LayerInfo(layer), canvas: .zero, fontSize: Self.font, crease: nil) == nil, "unmeasured")
    }

    @Test func aRaiseOnThePhoneComesFirstUntilTheServerAgrees() {
        let layers = ["a", "b", "c"].map { LayerInfo(Self.float("layer:\($0)", $0.uppercased(), [0.1, 0.1, 0.4, 0.4])) }
        #expect(FloatLayout.ordered(layers, front: "layer:a").map(\.id) == ["layer:b", "layer:c", "layer:a"])
        #expect(FloatLayout.ordered(layers, front: "layer:c").map(\.id) == ["layer:a", "layer:b", "layer:c"])
        #expect(FloatLayout.ordered(layers, front: nil).map(\.id) == ["layer:a", "layer:b", "layer:c"])
        #expect(FloatLayout.ordered(layers, front: "layer:gone").map(\.id) == ["layer:a", "layer:b", "layer:c"])
        let w = Self.window(tiled: Self.one, tiledBlocks: ["A"], floats: [
            Self.float("layer:back", "F", [0.1, 0.1, 0.4, 0.4]), Self.float("layer:front", "G", [0.5, 0.5, 0.4, 0.4]),
        ])
        guard case .floating(_, let floats)? = Self.decide(w, front: "layer:back") else { Issue.record("floating"); return }
        #expect(floats.map(\.id) == ["layer:front", "layer:back"])
    }

    // MARK: Active pane

    @Test func aMinimizedPaneIsNeverActive() {
        let w = Self.window(focused: "M", tiled: Self.two, tiledBlocks: ["A", "B"],
                            floats: [Self.float("layer:m", "M", [0.1, 0.1, 0.4, 0.4], state: "minimized"), Self.floatF])
        #expect(ActivePane.of(w, phone: "M") == "A", "the phone's pick, minimized on the Mac, falls back")
        #expect(ActivePane.of(w, phone: "F") == "F")
        #expect(ActivePane.of(w, phone: nil) == "A", "the server's focus on a minimized float too")
        #expect(ActivePane.of(w, phone: "gone") == "A")
        // Without floats, as before: the server's focus, else the first pane.
        #expect(ActivePane.of(Self.window(focused: "B", tiled: Self.two, tiledBlocks: ["A", "B"]), phone: nil) == "B")
    }

    // MARK: Taps

    @Test func tapsOnAFrontFocusedFloatSendNothing() {
        let w = Self.window(focused: "G", tiled: Self.one, tiledBlocks: ["A"], floats: [
            Self.float("layer:back", "F", [0.1, 0.1, 0.4, 0.4]), Self.float("layer:front", "G", [0.5, 0.5, 0.4, 0.4]),
        ])
        var sent = 0
        for _ in 0..<5 where FloatTap.decide(window: w, block: "G", front: "layer:front", canRaise: true) != .none { sent += 1 }
        #expect(sent == 0)
        #expect(FloatTap.decide(window: w, block: "F", front: "layer:front", canRaise: true) == .raise(focusBlock: false))
        // Once raised on the phone, the next tap only focuses until the view comes back.
        #expect(FloatTap.decide(window: w, block: "F", front: "layer:back", canRaise: true) == .focus)
        // Without `set_layer_state`: focus as a tiled pane, no raise.
        #expect(FloatTap.decide(window: w, block: "F", front: "layer:front", canRaise: false) == .focus)
        #expect(FloatTap.decide(window: w, block: "G", front: "layer:front", canRaise: false) == .none)
        // A float with two panes: the raise focuses the tapped one after it.
        let stacked = Self.split("vertical", [0.1, 0.1, 0.4, 0.4], Self.leaf("S1", [0.1, 0.1, 0.4, 0.2]), Self.leaf("S2", [0.1, 0.3, 0.4, 0.2]))
        let two = Self.window(focused: "A", tiled: Self.one, tiledBlocks: ["A"], floats: [
            ["layer_id": "layer:s", "kind": "floating", "bounds": [0.1, 0.1, 0.4, 0.4], "layout": stacked, "blocks": [Self.block("S1"), Self.block("S2")]],
            Self.float("layer:front", "G", [0.5, 0.5, 0.4, 0.4]),
        ])
        #expect(FloatTap.decide(window: two, block: "S2", front: "layer:front", canRaise: true) == .raise(focusBlock: true))
    }

    // MARK: On screen

    @Test func theWaitingPillAndTheToastsSeeTheSamePanes() {
        let w = Self.window(tiled: Self.one, tiledBlocks: ["A"], floats: [
            Self.floatF, Self.float("layer:m", "M", [0.1, 0.1, 0.4, 0.4], state: "minimized"),
        ])
        let wide = Self.decide(w)!
        #expect(VisiblePanes.inTab(w, wide) == ["A", "F"], "a drawn float is on screen; a minimized one isn't")
        let narrow = Self.decide(w, narrow: true, active: "A")!
        #expect(VisiblePanes.inTab(w, narrow) == ["A"], "the sheet down: the float isn't on screen")
        let zoomed = Self.decide(w, narrow: true, zoomed: true, active: "A")!
        #expect(VisiblePanes.inTab(w, zoomed) == ["A"], "a page a swipe away isn't on screen")
        // Only minimized floats: the tab's splits are on screen, the float isn't.
        let minimized = Self.window(tiled: Self.two, tiledBlocks: ["A", "B"],
                                    floats: [Self.float("layer:m", "M", [0.1, 0.1, 0.4, 0.4], state: "minimized")])
        #expect(VisiblePanes.inTab(minimized, active: "A", single: false) == ["A", "B"])
    }

    // MARK: Commands

    @Test func minimizeIsOfferedOnlyWhereThePaneStaysOnScreen() {
        let w = Self.window(tiled: Self.one, tiledBlocks: ["A"], floats: [Self.floatF])
        #expect(FloatArrange.minimizable(w, block: "F")?.id == "layer:f")
        #expect(FloatArrange.minimizable(w, block: "A") == nil, "a tiled pane has no floating window")
        // Only floats: the last one holds the window's last visible pane.
        let alone = Self.window(tiled: nil, tiledBlocks: [], floats: [Self.floatF])
        #expect(FloatArrange.minimizable(alone, block: "F") == nil)
        let pair = Self.window(tiled: nil, tiledBlocks: [], floats: [Self.floatF, Self.float("layer:g", "G", [0.5, 0.5, 0.4, 0.4])])
        #expect(FloatArrange.minimizable(pair, block: "F")?.id == "layer:f")
        #expect(FloatArrange.minimizeAll(pair) == ["layer:f"], "the front one stays")
        #expect(FloatArrange.minimizeAll(Self.window(tiled: Self.one, tiledBlocks: ["A"], floats: [Self.floatF])) == ["layer:f"])
    }

    @Test func arrangeShowsForAMinimizedFloatOnAOnePaneTabFromRevision13() {
        let w = Self.window(tiled: Self.one, tiledBlocks: ["A"],
                            floats: [Self.float("layer:m", "M", [0.1, 0.1, 0.4, 0.4], state: "minimized")])
        let t = PaneTarget(window: w, block: "A", tabs: [w])
        #expect(PaneMenuModel.build(t, support: PaneSupport(revision: 0)) == nil, "rev 0: no Arrange, as before")
        let m = PaneMenuModel.build(t, support: PaneSupport(revision: 13))
        #expect(m?.minimized.map(\.id) == ["layer:m"])
        #expect(m?.minimized.first?.name == "Pane 2")
        #expect(m?.minimize == false)
        #expect(m?.swap.isEmpty == true, "a minimized pane isn't one to swap with")
        // `set_layer_state` missing: the float rows go. The minimized pane still counts as one of
        // the tab's panes for the commands that don't need the method.
        let without = PaneMenuModel.build(t, support: PaneSupport(revision: 18, absent: [FloatArrange.layerStateMethod]))
        #expect(without?.minimized.isEmpty == true && without?.minimize == false)
        #expect(without?.newTab == true && without?.closeOthers == true)
        // A drawn float on a one-pane tab: Minimize.
        let drawn = Self.window(tiled: Self.one, tiledBlocks: ["A"], floats: [Self.floatF])
        #expect(PaneMenuModel.build(PaneTarget(window: drawn, block: "F", tabs: [drawn]), support: Self.full)?.minimize == true)
    }

    @Test func theMinimizeKeysTheMenuAndThePaletteAgree() {
        let w = Self.window(tiled: Self.one, tiledBlocks: ["A"], floats: [Self.floatF])
        let cases = [PaneSupport(revision: 0), PaneSupport(revision: 13), Self.full,
                     PaneSupport(revision: 18, absent: [FloatArrange.layerStateMethod])]
        for s in cases {
            for (block, name, c, cmd) in [("F", "pane.minimize_floating", PaneCommand.minimize, RexCommand.minimizeFloat),
                                          ("F", "pane.minimize_all_floating", .minimizeAll, .minimizeAllFloats)] {
                let key = AppAction.resolve(name, nil, panes: s)
                #expect((key != nil) == PaneArrange.isAvailable(c, target: nil, support: s), "\(name) \(s)")
                let t = PaneTarget(window: w, block: block, tabs: [w])
                let live = PaneArrange.isAvailable(c, target: t, support: s)
                if c == .minimize { #expect((PaneMenuModel.build(t, support: s)?.minimize ?? false) == live, "\(s)") }
                if case .command(let r)? = key { #expect(r == cmd) }
            }
        }
        #expect(KeyActions.byName["pane.minimize_floating"]?.title == "Minimize Floating Window")
        #expect(KeyActions.byName["pane.minimize_all_floating"]?.title == "Minimize All Floating Windows")
    }

    @Test func swapMoveCloseOthersAndNewTabSeeFloats() {
        let w = Self.window(focused: "A", tiled: Self.one, tiledBlocks: ["A"], floats: [
            Self.floatF, Self.float("layer:m", "M", [0.1, 0.1, 0.4, 0.4], state: "minimized"),
        ])
        #expect(PaneScope.arrangeable(window: w) == ["A", "F", "M"])
        let t = PaneTarget(window: w, block: "A", tabs: [w])
        let m = PaneMenuModel.build(t, support: Self.full)
        #expect(m?.swap.map(\.id) == ["F"], "a drawn float, not a minimized one")
        #expect(m?.newTab == true, "the tiled pane isn't the tab's only pane")
        #expect(m?.closeOthers == true)
        #expect(PaneArrange.isAvailable(.swap, target: PaneTarget(window: w, block: "F", tabs: [w]), support: Self.full))
        #expect(!PaneArrange.isAvailable(.balance, target: t, support: Self.full), "no tiled splits to even")
        // A tab with only floats takes a moved pane beside its float.
        let floatsOnly = WindowInfo(["window_id": "window:2", "layers": [
            ["layer_id": "layer:t2", "kind": "tiled", "bounds": [0, 0, 1, 1], "blocks": [JSONObject]()] as JSONObject,
            Self.float("layer:g", "G", [0.2, 0.2, 0.6, 0.3]),
        ]])
        #expect(MoveAnchor.pick(window: floatsOnly) == MoveAnchor.Pick(block: "G", direction: "horizontal"))
        #expect(MoveAnchor.targets(from: "window:1", in: [w, floatsOnly]).map(\.id) == ["window:2"])
    }
}
