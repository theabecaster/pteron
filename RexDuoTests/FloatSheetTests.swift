import CoreGraphics
import Foundation
import Testing
import RexKit
@testable import RexDuo

/// The narrow float sheet's pure parts (`FloatSheet`): what a narrow tab with floats shows, the
/// sheet's sizes at every narrow width, the drags on its grabber, the panes a swipe and the keys
/// walk, the floats' menu, the vertical bar, and what VoiceOver hears.
@MainActor
struct FloatSheetTests {
    typealias F = FloatsTests

    /// Narrow canvases (the panes' area, keyboard down): iPhone SE, the folded Duo beside its bar,
    /// iPhone 17 Pro, the folded Duo's full width.
    static let narrow: [CGSize] = [CGSize(width: 375, height: 559), CGSize(width: 382, height: 600),
                                   CGSize(width: 402, height: 740), CGSize(width: 466, height: 610)]
    static let canvas = CGSize(width: 402, height: 740)

    static func decide(_ w: WindowInfo, active: String? = nil, zoomed: Bool = false, canvas: CGSize = canvas,
                       tiledShown: String? = nil, front: String? = nil) -> TabPresentation? {
        TabPresentation.decide(.init(window: w, narrow: true, zoomed: zoomed, active: active ?? ActivePane.of(w, phone: nil),
                                     canvas: canvas, fontSize: F.font, crease: nil, front: front,
                                     tiledShown: tiledShown))
    }

    static func sheet(_ p: TabPresentation?) -> FloatSheet.Layout? {
        if case .floatSheet(let s)? = p { return s }
        return nil
    }

    static let stacked = F.split("vertical", [0.1, 0.1, 0.8, 0.8], F.leaf("S1", [0.1, 0.1, 0.8, 0.4]), F.leaf("S2", [0.1, 0.5, 0.8, 0.4]))
    static let twoPaneFloat: JSONObject = ["layer_id": "layer:s", "kind": "floating", "bounds": [0.1, 0.1, 0.8, 0.8],
                                           "layout": stacked, "blocks": [F.block("S1"), F.block("S2")]]

    // MARK: Deciding

    @Test func aNarrowTabShowsItsTiledPanesAsBeforeAndTheSheetOnlyWhileAFloatIsActive() throws {
        let w = F.window(tiled: F.two, tiledBlocks: ["A", "B"], floats: [F.floatF])
        // The tiled pane active: no sheet, the tiled panes as a narrow tab without floats.
        let tab = try #require(Self.sheet(Self.decide(w, active: "B", canvas: CGSize(width: 382, height: 600))))
        #expect(tab.shown == nil)
        #expect(tab.tiled == .page("B", ids: ["A", "B"]), "too narrow for two side by side: tiled pages, not the float")
        #expect(Self.decide(w, active: "B")?.pageIDs == ["A", "B"], "the title bar's dots count tiled panes only")
        // The float active: the sheet shows it, and the tiled page shown last stays under it.
        let float = try #require(Self.sheet(Self.decide(w, active: "F", canvas: CGSize(width: 382, height: 600), tiledShown: "B")))
        #expect(float.shown?.layer == "layer:f")
        #expect(float.tiled == .page("B", ids: ["A", "B"]))
        #expect(Self.decide(w, active: "F", tiledShown: "B")?.pageCurrent == "B")
        // Legible tiled splits stay splits under the sheet; a float no longer forces pages.
        let wide = try #require(Self.sheet(Self.decide(w, active: "F", canvas: CGSize(width: 700, height: 600))))
        #expect(wide.tiled == .splits)
        #expect(Self.decide(w, active: "F", canvas: CGSize(width: 700, height: 600))?.pageIDs == nil)
    }

    @Test func aTabWithOnlyFloatsAlwaysShowsTheFrontOne() throws {
        let w = F.window(tiled: nil, tiledBlocks: [], floats: [F.floatF, F.float("layer:g", "G", [0.5, 0.5, 0.4, 0.4])])
        #expect(ActivePane.of(w, phone: nil) == "G", "no tiled pane: the front float's")
        let s = try #require(Self.sheet(Self.decide(w)))
        #expect(s.tiled == .empty && !s.hasTiled)
        #expect(s.shown?.layer == "layer:g")
        #expect(s.floats == ["layer:g", "layer:f"], "front first")
    }

    @Test func aFloatsSplitsShowInTheSheetWhenLegibleElseItsPages() throws {
        let w = F.window(tiled: F.one, tiledBlocks: ["A"], floats: [Self.twoPaneFloat])
        let tall = try #require(Self.sheet(Self.decide(w, active: "S2")))
        #expect(tall.shown?.page == nil, "two rows of 8 fit an iPhone's sheet")
        #expect(tall.shown?.ids == ["S1", "S2"])
        #expect(tall.shown?.leaves.map(\.id) == ["S1", "S2"])
        let leaves = try #require(tall.shown?.leaves)
        #expect(F.near(leaves[0].rect, CGRect(x: 0, y: 0, width: 1, height: 0.5)), "fractions of the float, not the window")
        #expect(F.near(leaves[1].rect, CGRect(x: 0, y: 0.5, width: 1, height: 0.5)))
        // Too short for two (a landscape phone): one at a time, the active one.
        let short = try #require(Self.sheet(Self.decide(w, active: "S2", canvas: CGSize(width: 600, height: 260))))
        #expect(short.shown?.page == "S2" && short.shown?.current == "S2")
        #expect(Self.decide(w, active: "S2", canvas: CGSize(width: 600, height: 260))?.visible(in: w) == ["A", "S2"])
    }

    @Test func severalFloatsAreWalkedFrontFirstAndAPhoneRaiseCounts() throws {
        let w = F.window(tiled: F.one, tiledBlocks: ["A"], floats: [
            F.float("layer:a", "FA", [0.1, 0.1, 0.4, 0.4]), F.float("layer:b", "FB", [0.2, 0.2, 0.4, 0.4]),
            F.float("layer:c", "FC", [0.3, 0.3, 0.4, 0.4]),
        ])
        let s = try #require(Self.sheet(Self.decide(w, active: "FB")))
        #expect(s.floats == ["layer:c", "layer:b", "layer:a"])
        #expect(s.shown?.layer == "layer:b")
        #expect(Self.sheet(Self.decide(w, active: "FB", front: "layer:a"))?.floats == ["layer:a", "layer:c", "layer:b"])
        #expect(FloatSheet.step(s.floats, from: "layer:b", by: 1) == "layer:a")
        #expect(FloatSheet.step(s.floats, from: "layer:b", by: -1) == "layer:c")
        #expect(FloatSheet.step(s.floats, from: "layer:a", by: 1) == nil, "no wrap")
        #expect(FloatSheet.step(s.floats, from: "layer:c", by: -1) == nil)
    }

    @Test func zoomIsAsBeforeAndTheSheetCanZoom() {
        let w = F.window(zoomed: "F", tiled: F.two, tiledBlocks: ["A", "B"], floats: [F.floatF])
        #expect(Self.decide(w, zoomed: true) == .pages(ids: ["A", "B", "F"], current: "F"), "zoomed: pages with the float, as before")
        let open = F.window(tiled: F.one, tiledBlocks: ["A"], floats: [F.floatF])
        #expect(Self.decide(open, active: "F")?.canZoom == true, "the sheet over the tab: two panes on screen")
        #expect(Self.decide(open, active: "A")?.canZoom == false, "one tiled pane, the sheet down")
    }

    @Test func onScreenIsTheTiledPageAndTheSheetsPanesOnly() {
        let w = F.window(tiled: F.two, tiledBlocks: ["A", "B"], floats: [
            F.floatF, F.float("layer:g", "G", [0.5, 0.5, 0.4, 0.4]), F.float("layer:m", "M", [0.1, 0.1, 0.4, 0.4], state: "minimized"),
        ])
        let narrow = CGSize(width: 382, height: 600)
        #expect(Self.decide(w, active: "A", canvas: narrow)?.visible(in: w) == ["A"], "the sheet down: no float is on screen")
        #expect(Self.decide(w, active: "F", canvas: narrow, tiledShown: "B")?.visible(in: w) == ["B", "F"],
                "the float behind in the sheet's order isn't on screen")
    }

    // MARK: Active pane and pane order

    @Test func theSheetsFloatIsTheActivePaneAndAHiddenOneNeverIs() {
        let w = F.window(focused: "M", tiled: F.one, tiledBlocks: ["A"],
                         floats: [F.floatF, F.float("layer:m", "M", [0.1, 0.1, 0.4, 0.4], state: "minimized")])
        #expect(ActivePane.of(w, phone: "F") == "F")
        #expect(ActivePane.of(w, phone: "M") == "A", "minimized on the Mac: the first tiled pane")
        // The sheet goes down by making a tiled pane active: then no float is.
        #expect(Self.sheet(Self.decide(w, active: ActivePane.of(w, phone: "A")))?.shown == nil)
    }

    @Test func swipesAndTheKeysWalkTheirOwnGroup() {
        let w = F.window(tiled: F.two, tiledBlocks: ["A", "B"], floats: [Self.twoPaneFloat, F.floatF])
        #expect(w.tiledPageIDs == ["A", "B"])
        #expect(w.floatPageIDs == ["F", "S1", "S2"])
        #expect(w.pageBlockIDs == ["A", "B", "F", "S1", "S2"], "wide and zoomed: one order, as before")
        #expect(FloatSheet.group(w, from: "B") == ["A", "B"], "a tiled swipe never reaches a float")
        #expect(FloatSheet.group(w, from: "S1") == ["S1", "S2"], "a float's swipe stays in it")
        #expect(FloatSheet.group(w, from: "F") == ["F"])
        let m = F.window(tiled: F.one, tiledBlocks: ["A"], floats: [F.float("layer:m", "M", [0.1, 0.1, 0.4, 0.4], state: "minimized")])
        #expect(FloatSheet.group(m, from: "M").isEmpty)
    }

    // MARK: Geometry

    @Test func theSheetsSizesAtEveryNarrowWidth() throws {
        for c in Self.narrow {
            let g = FloatSheet.Geometry(canvas: c, live: c, keyboardUp: false, mediumAllowed: true)
            #expect(g.content.width == c.width - 8, "\(c): the canvas less 4 pt each side")
            #expect(g.largeTop == (c.height * 0.15).rounded(), "\(c): the tab peeks above Large")
            let m = try #require(g.mediumTop)
            #expect(abs(m - c.height * 0.45) <= 0.5, "\(c): Medium is about 55 %")
            // One-handed: Medium's grabber is within the lower part of the canvas.
            #expect(m > c.height * 0.4)
            // What the panes claim is the panes' size at Large with the keyboard down.
            let rest = try #require(FloatSheet.Geometry.rest(canvas: c))
            #expect(rest == g.content.size, "\(c)")
            // Legible: a pane fits 40 columns at the default size.
            #expect(rest.width >= 40 * F.font * 0.6)
        }
        #expect(FloatSheet.Geometry.rest(canvas: .zero) == nil)
    }

    @Test func noSizeChangeOrKeyboardChangesWhatThePanesClaim() throws {
        // The panes' bounds are the same at Large and Medium: a size change moves the sheet, and
        // only the cover changes. The keyboard covers them; what they claim stays.
        for c in Self.narrow {
            let g = FloatSheet.Geometry(canvas: c, live: c, keyboardUp: false, mediumAllowed: true)
            let rest = FloatSheet.Geometry.rest(canvas: c)
            #expect(g.top(.medium) > g.top(.large))
            #expect(g.content.size == rest, "\(c): the panes' size doesn't depend on the size")
            let typing = CGSize(width: c.width, height: c.height - 300)
            let up = FloatSheet.Geometry(canvas: c, live: typing, keyboardUp: true, mediumAllowed: true)
            #expect(up.content.width == g.content.width, "\(c): same width, so the rest size still counts")
            #expect(up.content.height < (rest?.height ?? 0), "\(c): covered, not refitted")
            #expect(up.largeTop <= FloatSheet.Geometry.typingPeek)
            #expect(up.mediumTop == nil, "typing: Large only")
        }
        #expect(FloatSheet.cover(200, paneBottom: 500, area: 500) == 200, "a pane at the bottom: all of it")
        #expect(FloatSheet.cover(200, paneBottom: 250, area: 500) == 0, "a pane in the top half: none")
        #expect(FloatSheet.cover(200, paneBottom: 400, area: 500) == 100)
    }

    @Test func compactHeightAndNoTiledPaneHaveLargeOnly() {
        let c = CGSize(width: 594, height: 364)
        let g = FloatSheet.Geometry(canvas: c, live: c, keyboardUp: false, mediumAllowed: false)
        #expect(g.mediumTop == nil)
        #expect(g.stops(canHide: true).map(\.0) == [.large, .hidden])
        #expect(g.stops(canHide: false).map(\.0) == [.large], "no tiled pane: it can't go")
        #expect(FloatSheet.detent(.medium, keyboardUp: false, mediumAllowed: false) == .large)
        #expect(FloatSheet.detent(.medium, keyboardUp: true, mediumAllowed: true) == .large, "typing lifts it")
        #expect(FloatSheet.detent(.medium, keyboardUp: false, mediumAllowed: true) == .medium)
    }

    // MARK: Gestures

    @Test func theGrabbersDragPicksOneAxisAndLetsGoWhereItWouldCoast() {
        #expect(FloatSheet.axis(CGSize(width: 4, height: 5)) == nil, "inside the slop")
        #expect(FloatSheet.axis(CGSize(width: 30, height: 4)) == .horizontal)
        #expect(FloatSheet.axis(CGSize(width: -3, height: 25)) == .vertical)
        #expect(FloatSheet.axis(CGSize(width: 20, height: 20)) == .vertical, "a diagonal resizes")
        #expect(FloatSheet.swipe(dx: -60, velocity: 0) == 1, "to the left: the next float, as pages")
        #expect(FloatSheet.swipe(dx: 70, velocity: 0) == -1)
        #expect(FloatSheet.swipe(dx: -20, velocity: -600) == 1, "a flick")
        #expect(FloatSheet.swipe(dx: 20, velocity: 100) == 0)
        let stops: [(FloatSheet.Stop, CGFloat)] = [(.large, 100), (.medium, 300), (.hidden, 700)]
        #expect(FloatSheet.settle(top: 120, velocity: 0, stops: stops) == .large)
        #expect(FloatSheet.settle(top: 260, velocity: 0, stops: stops) == .medium)
        #expect(FloatSheet.settle(top: 260, velocity: 2500, stops: stops) == .hidden, "flung down")
        #expect(FloatSheet.settle(top: 320, velocity: -1500, stops: stops) == .large, "flung up")
        #expect(FloatSheet.settle(top: 600, velocity: 0, stops: [(.large, 100), (.hidden, 700)]) == .hidden)
    }

    // MARK: The floats' menu and the bar

    @Test func theFloatsMenuListsDrawnFloatsFrontFirstThenTheMinimizedOnes() {
        let w = F.window(tiled: F.one, tiledBlocks: ["A"], floats: [
            F.float("layer:back", "B1", [0.1, 0.1, 0.4, 0.4]), F.float("layer:m", "M", [0.1, 0.1, 0.4, 0.4], state: "minimized"),
            Self.twoPaneFloat,
        ])
        let m = FloatsMenu.build(w, front: nil, shown: "layer:back", canRestore: true)
        #expect(m.drawn.map(\.id) == ["layer:s", "layer:back"])
        #expect(m.drawn.map(\.shown) == [false, true])
        #expect(m.drawn.first?.subtitle == "2 panes")
        #expect(m.minimized.map(\.id) == ["layer:m"])
        #expect(m.count == 3)
        #expect(FloatsMenu.build(w, front: "layer:back", shown: nil, canRestore: false).drawn.map(\.id) == ["layer:back", "layer:s"])
        #expect(FloatsMenu.build(w, front: nil, shown: nil, canRestore: false).minimized.isEmpty, "an old server can't show it again")
        // No float: no control, in the title bar, the strip or the bar.
        #expect(FloatsMenu.build(F.window(tiled: F.one, tiledBlocks: ["A"]), front: nil, shown: nil, canRestore: true).count == 0)
        #expect(!FloatsMenu.has(F.window(tiled: F.one, tiledBlocks: ["A"]), canRestore: true))
        let onlyMinimized = F.window(tiled: F.one, tiledBlocks: ["A"], floats: [F.float("layer:m", "M", [0.1, 0.1, 0.4, 0.4], state: "minimized")])
        #expect(FloatsMenu.has(onlyMinimized, canRestore: true))
        #expect(!FloatsMenu.has(onlyMinimized, canRestore: false), "nothing it could show")
        #expect(FloatsMenu.has(w, canRestore: false))
        // Names never come from a title: a pane without a label is named by its place.
        #expect(m.minimized.first?.name == "Pane 5", "A, S1, S2, B1, then M")
    }

    @Test func floatingWindowsIsASectionOfItsOwnWithMinimizeAll() throws {
        let w = F.window(focused: "A", tiled: F.one, tiledBlocks: ["A"],
                         floats: [F.floatF, F.float("layer:g", "G", [0.5, 0.5, 0.4, 0.4])])
        let onTiled = try #require(PaneMenuModel.build(PaneTarget(window: w, block: "A", tabs: [w]), support: F.full))
        #expect(!onTiled.minimize && onTiled.minimizeAll, "from a tiled pane: Minimize All")
        let onFloat = try #require(PaneMenuModel.build(PaneTarget(window: w, block: "F", tabs: [w]), support: F.full))
        #expect(onFloat.minimize && onFloat.minimizeAll)
        let one = F.window(tiled: F.one, tiledBlocks: ["A"], floats: [F.floatF])
        let single = try #require(PaneMenuModel.build(PaneTarget(window: one, block: "F", tabs: [one]), support: F.full))
        #expect(single.minimize && !single.minimizeAll, "one float, its own pane: Minimize says it all")
        // Arrange no longer holds the floats: a tab whose only Arrange items were floats' has none.
        let m = F.window(tiled: F.one, tiledBlocks: ["A"], floats: [F.float("layer:m", "M", [0.1, 0.1, 0.4, 0.4], state: "minimized")])
        let old = try #require(PaneMenuModel.build(PaneTarget(window: m, block: "A", tabs: [m]),
                                                   support: PaneSupport(revision: 18, absent: ["session.move_block", "block.close", "session.swap_blocks"])))
        #expect(old.minimized.map(\.id) == ["layer:m"])
        #expect(!old.arrange)
    }

    @Test func theBarsFloatsItemIsLastAndGoesWhileTypingWithoutMovingAnother() {
        for zoomed in [false, true] {
            let resting = TabActions.tabItems(.sidebar, zoomed: zoomed, hidesKeyboard: false, floats: true)
            let typing = TabActions.tabItems(.sidebar, zoomed: zoomed, hidesKeyboard: true, floats: true)
            #expect(resting.last == .floats)
            #expect(!typing.contains(.floats), "the bar has room for three while typing")
            #expect(Array(resting.dropLast()).filter { typing.contains($0) } == typing, "the rest keep their order")
            #expect(typing.last == .paneActions)
            #expect(TabActions.tabItems(.sidebar, zoomed: zoomed, hidesKeyboard: false, room: 3, floats: true) == resting,
                    "with the keyboard down nothing is trimmed")
            #expect(!TabActions.tabItems(.sidebar, zoomed: zoomed, hidesKeyboard: true, room: 2, floats: true).contains(.floats))
            #expect(TabActions.tabItems(.sidebar, zoomed: zoomed, hidesKeyboard: false) == Array(resting.dropLast()), "no float: as before")
        }
        #expect(TabAction.floats.symbol != TabAction.allTabs.symbol)
        #expect(TabAction.floats.title == "Floating Windows")
    }

    // MARK: VoiceOver

    @Test func voiceOverHearsTheFloatAndWhereItIs() {
        let one = FloatSheet.Spoken.grabber(name: "float 1", index: 0, count: 1)
        #expect(one.label == "Floating window, float 1" && one.value.isEmpty && one.hint.isEmpty)
        let three = FloatSheet.Spoken.grabber(name: "logs", index: 1, count: 3)
        #expect(three.value == "2 of 3")
        #expect(three.hint.contains("Swipe up or down"))
        #expect(FloatSheet.Spoken.control(count: 1) == "1 floating window")
        #expect(FloatSheet.Spoken.control(count: 3) == "3 floating windows")
    }
}
