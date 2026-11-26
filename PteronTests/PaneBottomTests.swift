import CoreGraphics
import Testing
@testable import Pteron

/// The panes run to the window's bottom edge with the keyboard down, and end where they always
/// did with it up (`PaneBottom`, `PaneLayout`). Numbers from the iPhone 17 Pro simulator: 34 pt of
/// home indicator, a 355 pt keyboard with its key bar (321 pt of room beyond the indicator), a
/// 744 pt canvas above the indicator and 778 pt to the window's edge.
struct PaneBottomTests {
    private let indicator: CGFloat = 34
    private let room: CGFloat = 321
    private let safe = CGSize(width: 402, height: 744)
    private let edge = CGSize(width: 402, height: 778)

    /// A window with square corners, which lets the panes run to its edge.
    private func pane(home: CGFloat, keyboardRoom: CGFloat, reaches: Bool = true) -> PaneBottom {
        PaneBottom(window: WindowBottom(home: home, corners: .square), keyboardRoom: keyboardRoom, padding: 0,
                   tolerance: 0, reaches: reaches)
    }

    @Test func withTheKeyboardDownThePanesReachTheEdge() {
        let b = pane(home: indicator, keyboardRoom: 0)
        #expect(b.reachesEdge)
        #expect(b.reach == indicator)
        #expect(b.restReach == indicator)
        #expect(PaneLayout.restCanvas(now: edge, room: 0, home: b.restReach) == edge)
    }

    @Test func withTheKeyboardUpThePanesKeepToTheSafeArea() {
        // As before: the area keeps to the safe area, so the panes end at the keyboard's top.
        let b = pane(home: indicator, keyboardRoom: room)
        #expect(!b.reachesEdge)
        #expect(b.reach == 0)
        #expect(b.restReach == indicator, "the canvas with the keyboard down still runs under the indicator")
    }

    @Test func showingOrHidingTheKeyboardKeepsTheRestCanvas() {
        // H-1: with the keyboard up the canvas is the safe one less the room; its rest is the
        // canvas to the edge, the one it has with the keyboard down. So no resize either way.
        let up = pane(home: indicator, keyboardRoom: room)
        let now = CGSize(width: safe.width, height: safe.height - room)
        #expect(PaneLayout.restCanvas(now: now, room: room, home: up.restReach) == edge)
        let down = pane(home: indicator, keyboardRoom: 0)
        #expect(PaneLayout.restCanvas(now: edge, room: 0, home: down.restReach) == edge)
        // The palette's hold keeps the room as it was: the same answer.
        #expect(PaneLayout.restCanvas(now: now, room: room, home: indicator) == edge)
    }

    @Test func aTurnWithTheKeyboardUpGivesTheNewPosturesEdge() {
        // Landscape iPhone: 21 pt of indicator, 402 pt tall. Turned with the keyboard up, the rest
        // comes from this layout's own canvas, room and inset.
        let up = pane(home: 21, keyboardRoom: 180)
        #expect(PaneLayout.restCanvas(now: CGSize(width: 750, height: 147), room: 180, home: up.restReach)
                == CGSize(width: 750, height: 348))
    }

    @Test func withoutAHomeIndicatorNothingChanges() {
        // An iPhone SE: no bottom inset, so nothing to reach into, keyboard up or down.
        let down = pane(home: 0, keyboardRoom: 0)
        #expect(down.reach == 0 && down.restReach == 0)
        let up = pane(home: 0, keyboardRoom: 260)
        #expect(up.reach == 0 && up.restReach == 0)
        #expect(PaneLayout.restCanvas(now: CGSize(width: 375, height: 300), room: 260, home: up.restReach)
                == CGSize(width: 375, height: 560))
    }

    @Test func theKeyBarAloneKeepsThePaneAboveIt() {
        // A hardware keyboard: the area keeps to the safe area as before, and the grid fits above
        // the bar.
        let b = pane(home: indicator, keyboardRoom: 42)
        #expect(!b.reachesEdge)
        #expect(b.reach == 0)
        #expect(b.restReach == 0)
        #expect(PaneLayout.restCanvas(now: CGSize(width: 402, height: 702), room: 42, home: b.restReach)
                == CGSize(width: 402, height: 702))
    }

    @Test func aHeaderThatSteppedAsideIsStillLeftOut() {
        // Short window: the 34 pt strip steps aside while the keyboard is up.
        let up = pane(home: 20, keyboardRoom: 147)
        #expect(PaneLayout.restCanvas(now: CGSize(width: 594, height: 241), room: 147, home: up.restReach, header: 34)
                == CGSize(width: 594, height: 374))
    }

    @Test func tabletopChangesNothing() {
        // The panes sit above the crease and don't reach the bottom. The region gave way to a tall
        // keyboard; the room comes back, no taller than the region, as before.
        let b = pane(home: 20, keyboardRoom: 360, reaches: false)
        #expect(!b.reachesEdge && b.reach == 0 && b.restReach == 0)
        let down = pane(home: 20, keyboardRoom: 0, reaches: false)
        #expect(!down.reachesEdge && down.reach == 0 && down.restReach == 0)
        #expect(PaneLayout.restCanvas(now: CGSize(width: 669, height: 380), room: 360, home: b.restReach, limit: 411)
                == CGSize(width: 669, height: 411))
    }

    @Test func theHomeInsetIsTheWindowsUnderTheRoot() {
        let window = CGRect(x: 0, y: 0, width: 402, height: 874)
        #expect(KeyboardInset.home(view: window, window: window, windowSafeBottom: 34) == 34)
        // A root that ends 20 pt above the window's bottom has 14 pt of it.
        #expect(KeyboardInset.home(view: CGRect(x: 0, y: 0, width: 402, height: 854), window: window, windowSafeBottom: 34) == 14)
        #expect(KeyboardInset.home(view: window, window: window, windowSafeBottom: 0) == 0)
        #expect(KeyboardInset.home(view: .zero, window: window, windowSafeBottom: 34) == 0)
    }

    @Test func onlyPanesOnTheBottomEdgeGrowAndTheSplitStaysProportional() throws {
        // H-5: a two-row split, 50/50, in a canvas that runs 34 pt under the indicator.
        let top = CGRect(x: 0, y: 0, width: 1, height: 0.5)
        let bottom = CGRect(x: 0, y: 0.5, width: 1, height: 0.5)
        let canvas = CGSize(width: 382, height: 644)
        let safe = CGSize(width: 382, height: 644 - indicator)
        // The top pane is the size it was in the safe area; the bottom one 34 pt taller.
        #expect(PaneLayout.splitRest(top, canvas: canvas, reach: indicator) == PaneLayout.splitRest(top, canvas: safe))
        let was = try #require(PaneLayout.splitRest(bottom, canvas: safe))
        #expect(PaneLayout.splitRest(bottom, canvas: canvas, reach: indicator)
                == CGSize(width: was.width, height: was.height + indicator))
        // On screen: the divider stays where it was, and only the bottom pane runs on.
        let area = CGSize(width: 376, height: 600)
        #expect(PaneLayout.split(top, in: area, reach: indicator) == PaneLayout.split(top, in: area))
        let low = PaneLayout.split(bottom, in: area, reach: indicator)
        #expect(low.minY == PaneLayout.split(bottom, in: area).minY)
        #expect(low.maxY == PaneLayout.split(bottom, in: area).maxY + indicator)
        // Side by side, both are on the bottom edge.
        let left = CGRect(x: 0, y: 0, width: 0.5, height: 1)
        #expect(PaneLayout.split(left, in: area, reach: indicator).height == PaneLayout.split(left, in: area).height + indicator)
    }

    @Test func legibilityReadsTheCanvasInsideTheSafeArea() {
        // A two-row split just short of legible inside the safe area: 8 rows of 13.75 pt each
        // need 220 pt of canvas, and it has 214. The 34 pt under the indicator would make it
        // legible, so a tab would flip from pages to splits; the canvas the decision reads is
        // the one inside the safe area, as before.
        let rows = [CGRect(x: 0, y: 0, width: 1, height: 0.5), CGRect(x: 0, y: 0.5, width: 1, height: 0.5)]
        let before = CGSize(width: 402, height: 214)
        let measured = CGSize(width: 402, height: 214 + indicator)
        #expect(!SplitGeometry.legible(rows, canvas: before, fontSize: 11))
        #expect(SplitGeometry.legible(rows, canvas: measured, fontSize: 11), "the edge alone would flip it")
        let read = PaneBottom.inside(measured, restReach: pane(home: indicator, keyboardRoom: 0).restReach)
        #expect(read == before)
        #expect(SplitGeometry.legible(rows, canvas: read, fontSize: 11) == SplitGeometry.legible(rows, canvas: before, fontSize: 11))
        // With the keyboard up the rest canvas runs past the safe area just the same.
        #expect(PaneBottom.inside(measured, restReach: pane(home: indicator, keyboardRoom: room).restReach) == before)
        // The key bar alone and devices without an indicator: nothing to take off.
        #expect(PaneBottom.inside(before, restReach: pane(home: indicator, keyboardRoom: 42).restReach) == before)
        #expect(PaneBottom.inside(before, restReach: pane(home: 0, keyboardRoom: 0).restReach) == before)
        #expect(PaneBottom.inside(.zero, restReach: indicator) == .zero)
    }

    // MARK: The window's corners

    /// How far each display's corner mask reaches in from the side, in points, at heights above
    /// the bottom edge (0, 3, 6 … 69 pt): measured from `simctl io screenshot --mask=black` in the
    /// iOS 27.2 simulators.
    private static let masks: [(name: String, radius: CGFloat, reach: [CGFloat])] = [
        ("iPhone 17 Pro", 61, [66.3, 44.7, 35.7, 29.7, 25.3, 21.3, 18.0, 15.0, 12.7, 10.7, 9.0, 7.3, 6.0, 5.0, 4.0, 3.0,
                               2.3, 1.7, 1.3, 1.0, 0.7, 0.3, 0.3, 0]),
        ("iPad Pro 13-inch", 29, [27.0, 16.0, 11.5, 8.0, 5.5, 3.5, 2.5, 1.5, 0.5, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        ("iPhone Duo, bar side", 59, [61.7, 41.0, 33.0, 27.7, 23.0, 19.3, 16.3, 13.7, 11.3, 9.3, 7.7, 6.0, 5.0, 3.7, 3.0,
                                      2.0, 1.7, 1.0, 0.7, 0.3, 0.3, 0, 0, 0]),
        ("iPhone Duo, hinge side", 8, [6.0, 1.3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
    ]

    @Test func theCornerModelStaysOutsideEveryMeasuredMask() {
        // At each height the model says a gap is clear from, the mask reaches in no further.
        for m in Self.masks {
            for gap in stride(from: CGFloat(0), through: 80, by: 0.5) {
                let y = PaneBottom.clearHeight(radius: m.radius, gap: gap)
                for (i, reach) in m.reach.enumerated() where CGFloat(i * 3) >= y {
                    #expect(reach <= gap, "\(m.name): at \(i * 3) pt the mask reaches \(reach) pt, past a gap of \(gap)")
                }
            }
        }
    }

    private let half = PaneBottom.tolerance(fontSize: 11)

    @Test func anUprightIPhoneKeepsMainsBottom() {
        // iPhone 17 Pro portrait, a single pane from edge to edge: its corners would take cells off
        // the last rows anywhere below the safe area, so the panes end where they always did.
        let w = WindowBottom(home: 34, corners: .init(left: 61, right: 61))
        let b = PaneBottom(window: w, keyboardRoom: 0, padding: PaneLayout.bottomPadding(splits: false, rounded: false),
                           tolerance: half)
        #expect(b.reach == 0 && b.restReach == 0 && b.trim == 0 && !b.reachesEdge)
    }

    @Test func aPhoneOnItsSideReachesTheEdge() {
        // iPhone 17 Pro landscape: the corners stay outside the 62 pt side insets and the rounded pane.
        let w = WindowBottom(home: 21, left: 62, right: 62, corners: .init(left: 61, right: 61))
        let b = PaneBottom(window: w, keyboardRoom: 0, padding: PaneLayout.bottomPadding(splits: false, rounded: true),
                           tolerance: half)
        #expect(b.reach == 21 && b.trim == 0 && b.reachesEdge)
    }

    @Test func theFoldedDuoReachesAlmostToTheEdge() {
        // The outer screen: a small corner on the hinge side, the large one under the 84 pt bar.
        let w = WindowBottom(home: 34, right: 84, corners: .init(left: 8, right: 59))
        let b = PaneBottom(window: w, keyboardRoom: 0, padding: PaneLayout.bottomPadding(splits: false, rounded: false),
                           tolerance: half)
        #expect(b.reach > 30 && b.reach < 34)
        #expect(b.trim == 34 - b.reach)
    }

    @Test func anIPadReachesAsFarAsItsCornersAllow() {
        let w = WindowBottom(home: 20, corners: .init(left: 29, right: 29))
        let b = PaneBottom(window: w, keyboardRoom: 0, padding: PaneLayout.bottomPadding(splits: false, rounded: true),
                           tolerance: half)
        #expect(b.reach > 10 && b.reach < 20)
        // Split panes sit as far in, so they reach as far.
        let s = PaneBottom(window: w, keyboardRoom: 0, padding: PaneLayout.bottomPadding(splits: true, rounded: true),
                           tolerance: half)
        #expect(s.reach == b.reach)
    }

    @Test func squareCornersReachTheEdgeAndNoIndicatorChangesNothing() {
        let square = PaneBottom(window: WindowBottom(home: 34, corners: .init(left: 0, right: 0)), keyboardRoom: 0,
                                padding: 0, tolerance: half)
        #expect(square.reach == 34 && square.trim == 0)
        // iPhone SE: no bottom inset, nothing to run on into.
        let se = PaneBottom(window: WindowBottom(home: 0, corners: .init(left: 0, right: 0)), keyboardRoom: 0, padding: 0,
                            tolerance: half)
        #expect(se.reach == 0 && !se.reachesEdge)
    }

    @Test func unknownCornersKeepMainsBottom() {
        // Before iOS 26 the system doesn't give the corners: the panes keep to the safe area.
        let b = PaneBottom(window: WindowBottom(home: 34, left: 62, right: 62, corners: nil), keyboardRoom: 0, padding: 9,
                           tolerance: half)
        #expect(b.reach == 0 && b.restReach == 0 && b.trim == 0 && !b.reachesEdge)
    }

    @Test func theKeyboardUpKeepsTheCornersReachForTheRestCanvas() {
        let w = WindowBottom(home: 34, right: 84, corners: .init(left: 8, right: 59))
        let down = PaneBottom(window: w, keyboardRoom: 0, padding: 0, tolerance: half)
        let up = PaneBottom(window: w, keyboardRoom: room, padding: 0, tolerance: half)
        #expect(up.reach == 0 && up.trim == 0 && !up.reachesEdge)
        #expect(up.restReach == down.reach)
        let bar = PaneBottom(window: w, keyboardRoom: 42, padding: 0, tolerance: half)
        #expect(bar.restReach == 0)
    }

    @Test func aControlKeepsClearOfThePanesBottomSafeArea() {
        let pane = CGRect(x: 0, y: 0, width: 382, height: 600)
        #expect(PaneBottom.clear(pane, safeBottom: indicator) == CGRect(x: 0, y: 0, width: 382, height: 566))
        #expect(PaneBottom.clear(pane, safeBottom: 0) == pane)
    }

    @Test func theEndHandleOnTheLastRowKeepsItsKnobOutOfTheIndicator() {
        // H-3: the last row ends 13 pt above the pane's bottom, inside the indicator's 34 pt and
        // with room for the 12 pt knob below it.
        let pane = CGRect(x: 0, y: 0, width: 382, height: 600)
        let last = CGRect(x: 100, y: 570, width: 7, height: 17)
        let under = SelectionHandleLayout(start: nil, end: last, in: PaneBottom.clear(pane, safeBottom: indicator))
        #expect(under.end?.knob.maxY == last.minY, "above its row")
        // Without an indicator there is room below the row, as before.
        let flat = SelectionHandleLayout(start: nil, end: last, in: PaneBottom.clear(pane, safeBottom: 0))
        #expect(flat.end?.knob.minY == last.maxY)
    }

    @Test func theJumpButtonClearsTheIndicator() {
        // H-3: 4 pt above a 34 pt safe area; 12 pt up without one.
        let r = JumpToBottomButton.diameter / 2
        #expect(JumpToBottomButton.centerY(bottom: 600, safeBottom: indicator) == 600 - 38 - r)
        #expect(JumpToBottomButton.centerY(bottom: 600, safeBottom: 0) == 600 - 12 - r)
        #expect(JumpToBottomButton.centerY(bottom: 600, safeBottom: indicator) + r <= 600 - indicator)
    }

    @Test func theFindBarClearsTheIndicator() {
        let pane = CGRect(x: 0, y: 0, width: 382, height: 600)
        let bar = FindBarPlacement.frame(bounds: pane, safeTop: 0, safeBottom: indicator, edge: .bottom, barHeight: 46,
                                         chipShown: false, crease: nil)
        #expect(bar.maxY <= pane.maxY - indicator)
        let flat = FindBarPlacement.frame(bounds: pane, safeTop: 0, safeBottom: 0, edge: .bottom, barHeight: 46,
                                          chipShown: false, crease: nil)
        #expect(flat.maxY == pane.maxY - FindBarPlacement.sideMargin)
    }
}
