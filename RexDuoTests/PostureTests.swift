import CoreGraphics
import SwiftUI
import Testing
@testable import RexDuo

/// Layout from the window's width and the fold (`Arrangement.decide`), and the folded split check.
struct ArrangementTests {
    private func decide(_ w: CGFloat, _ h: CGFloat, _ d: Division? = nil) -> Arrangement {
        Arrangement.decide(size: CGSize(width: w, height: h), division: d)
    }

    @Test func unfoldedLandscapeIsInlineWithTheCreaseAsASnapPoint() {
        let flat = Division(frame: CGRect(x: 475.5, y: 0, width: 0, height: 669), isActive: false)
        #expect(decide(951, 669, flat) == Arrangement(inline: true, crease: 475.5))
        let bent = Division(frame: CGRect(x: 455, y: 0, width: 40, height: 669), isActive: true)
        #expect(decide(951, 669, bent) == Arrangement(inline: true, crease: 455))
    }

    @Test(arguments: [
        (951.0, 669.0),  // unfolded landscape, no fold reported
        (669, 951),      // unfolded portrait
        (874, 402),      // iPhone landscape
        (956, 440),      // Pro Max landscape
        (678, 466),      // folded Duo on its side
    ])
    func wideWindowsGetTheInlineSidebar(w: Double, h: Double) {
        #expect(decide(w, h) == Arrangement(inline: true))
    }

    @Test(arguments: [
        (382.0, 678.0),  // folded, beside the vertical bar
        (475, 669),      // half of the inner screen
        (402, 874),      // iPhone portrait
    ])
    func narrowWindowsGetTheDrawer(w: Double, h: Double) {
        #expect(decide(w, h) == Arrangement(inline: false))
    }

    @Test func unfoldedPortraitKeepsTheTerminalAboveTheCreaseOnlyWhenBent() {
        let flat = Division(frame: CGRect(x: 0, y: 475.5, width: 669, height: 0), isActive: false)
        #expect(decide(669, 951, flat) == Arrangement(inline: true))
        let bent = Division(frame: CGRect(x: 0, y: 455, width: 669, height: 40), isActive: true)
        #expect(decide(669, 951, bent) == Arrangement(inline: true, tabletop: .init(top: 455, gap: 40)))
    }
}

struct SidebarWidthTests {
    @Test func limitsAreHalfInlineAndMostOfTheWindowAsADrawer() {
        #expect(SidebarWidth.max(container: 951, inline: true) == 476)
        #expect(SidebarWidth.max(container: 382, inline: false) == 325)
        #expect(SidebarWidth.clamp(120, container: 951, inline: true) == SidebarWidth.min)
        #expect(SidebarWidth.clamp(900, container: 951, inline: true) == 476)
    }

    @Test func snapsToTheDefaultAndTheCrease() {
        #expect(SidebarWidth.live(268, container: 951, inline: true, crease: 475.5) == (260, 260))
        #expect(SidebarWidth.live(470, container: 951, inline: true, crease: 475.5) == (475.5, 475.5))
        #expect(SidebarWidth.live(330, container: 951, inline: true, crease: 475.5) == (330, nil))
        // The drawer doesn't snap to a crease.
        #expect(SidebarWidth.live(300, container: 382, inline: false, crease: 191).snapped == nil)
    }

    @Test func stretchesWithResistancePastTheLimits() {
        let under = SidebarWidth.live(150, container: 951, inline: true, crease: nil).width
        #expect(under < SidebarWidth.min && under > SidebarWidth.min - 24)
        let over = SidebarWidth.live(700, container: 951, inline: true, crease: nil).width
        #expect(over > 476 && over < 500)
    }

    @Test func lettingGoNarrowCollapses() {
        #expect(SidebarWidth.release(100, container: 951, inline: true, crease: nil) == nil)
        #expect(SidebarWidth.release(170, container: 951, inline: true, crease: nil) == SidebarWidth.min)
        #expect(SidebarWidth.release(800, container: 951, inline: true, crease: nil) == 476)
        #expect(SidebarWidth.release(330, container: 951, inline: true, crease: nil) == 330)
    }

    /// The sidebar and its background, which runs under the leading inset, end left of the
    /// window's edge when hidden, with or without a vertical bar or the Dynamic Island there.
    @Test(arguments: [0, 59, 62, 84] as [CGFloat])
    func hiddenSidebarLeavesTheWindowWhateverTheLeadingInset(inset: CGFloat) {
        for width: CGFloat in [200, 260, 400] {
            // In window coordinates: the sidebar's place at the safe area's edge, moved.
            let x = inset + SidebarWidth.hiddenOffset(width: width, leadingInset: inset)
            #expect(x + width <= -24)
        }
    }

    @Test func eachPostureHasItsOwnWidth() {
        #expect(SidebarWidth.key(container: 951, inline: true) != SidebarWidth.key(container: 874, inline: true))
        #expect(SidebarWidth.key(container: 382, inline: false) == "drawer-382")
    }
}

struct SplitLegibilityTests {
    private let halves = [CGRect(x: 0, y: 0, width: 0.5, height: 1), CGRect(x: 0.5, y: 0, width: 0.5, height: 1)]
    private let stacked = [CGRect(x: 0, y: 0, width: 1, height: 0.5), CGRect(x: 0, y: 0.5, width: 1, height: 0.5)]

    @Test func sideBySideIsTooNarrowFolded() {
        #expect(!SplitGeometry.legible(halves, canvas: CGSize(width: 382, height: 560), fontSize: 11))
    }

    @Test func stackedFitsFolded() {
        #expect(SplitGeometry.legible(stacked, canvas: CGSize(width: 382, height: 560), fontSize: 11))
    }

    @Test func sideBySideFitsOnAWideScreen() {
        #expect(SplitGeometry.legible(halves, canvas: CGSize(width: 874, height: 300), fontSize: 11))
    }

    @Test func unmeasuredIsNotLegible() {
        #expect(!SplitGeometry.legible(halves, canvas: .zero, fontSize: 11))
    }
}

#if DEBUG
/// The `-simulateDuo` postures: each window's size, insets and fold, and what the root, the
/// sidebar and the tab get from them.
struct DuoSimulationTests {
    struct Expected: Sendable {
        var name: String
        var size: CGSize
        /// Top, leading, bottom, trailing.
        var insets: [CGFloat]
        var fold: CGRect? = nil
        var foldActive = false
        var fills = true
        /// What the root is laid out in, and the arrangement that gives.
        var root: CGSize
        var inline: Bool
    }

    static let expected: [Expected] = [
        .init(name: "unfolded", size: CGSize(width: 951, height: 669), insets: [0, 0, 20, 84],
              fold: CGRect(x: 475.5, y: 0, width: 0, height: 669), root: CGSize(width: 867, height: 649), inline: true),
        .init(name: "book", size: CGSize(width: 951, height: 669), insets: [0, 0, 20, 84],
              fold: CGRect(x: 455.5, y: 0, width: 40, height: 669), foldActive: true,
              root: CGSize(width: 867, height: 649), inline: true),
        .init(name: "unfoldedPortrait", size: CGSize(width: 669, height: 951), insets: [44, 0, 20, 0],
              fold: CGRect(x: 0, y: 475.5, width: 669, height: 0), root: CGSize(width: 669, height: 887), inline: true),
        .init(name: "tabletop", size: CGSize(width: 669, height: 951), insets: [44, 0, 20, 0],
              fold: CGRect(x: 0, y: 455.5, width: 669, height: 40), foldActive: true,
              root: CGSize(width: 669, height: 887), inline: true),
        .init(name: "folded", size: CGSize(width: 466, height: 678), insets: [0, 0, 20, 84],
              root: CGSize(width: 382, height: 658), inline: false),
        .init(name: "foldedLandscape", size: CGSize(width: 678, height: 466), insets: [0, 0, 20, 84],
              root: CGSize(width: 594, height: 446), inline: false),
        .init(name: "foldedLandscapeBarLeft", size: CGSize(width: 678, height: 466), insets: [0, 84, 34, 0],
              root: CGSize(width: 594, height: 432), inline: false),
        .init(name: "halfWindow", size: CGSize(width: 475, height: 669), insets: [0, 0, 20, 84], fills: false,
              root: CGSize(width: 391, height: 649), inline: false),
        .init(name: "halfWindowBarLeft", size: CGSize(width: 475, height: 669), insets: [0, 84, 20, 0], fills: false,
              root: CGSize(width: 391, height: 649), inline: false),
        .init(name: "iPhone", size: CGSize(width: 402, height: 874), insets: [62, 0, 34, 0],
              root: CGSize(width: 402, height: 778), inline: false),
        .init(name: "iPhoneLandscape", size: CGSize(width: 874, height: 402), insets: [0, 62, 21, 62],
              root: CGSize(width: 750, height: 381), inline: true),
        .init(name: "iPhoneLandscapeIslandLeft", size: CGSize(width: 874, height: 402), insets: [0, 62, 20, 62],
              root: CGSize(width: 750, height: 382), inline: true),
        .init(name: "proMaxLandscape", size: CGSize(width: 956, height: 440), insets: [0, 62, 21, 62],
              root: CGSize(width: 832, height: 419), inline: true),
    ]

    @Test func everyPostureIsListedOnce() {
        #expect(DuoSimulation.postures.map(\.name) == Self.expected.map(\.name))
        #expect(Set(DuoSimulation.postures.map(\.name)).count == DuoSimulation.postures.count)
    }

    @Test(arguments: expected)
    func aPostureIsItsWindowItsInsetsAndItsFold(e: Expected) throws {
        let sim = try #require(DuoSimulation.named(e.name))
        #expect(sim.size == e.size)
        #expect(sim.safeArea == EdgeInsets(top: e.insets[0], leading: e.insets[1], bottom: e.insets[2], trailing: e.insets[3]))
        #expect(sim.division == e.fold.map { Division(frame: $0, isActive: e.foldActive) })
        #expect(sim.fillsScreen == e.fills)
    }

    /// The root is laid out inside the insets, so they decide between the inline sidebar and the
    /// drawer: the outer screen on its side is 594 pt inside its bar, on either side.
    @Test(arguments: expected)
    func theRootIsLaidOutInsideTheInsets(e: Expected) throws {
        let sim = try #require(DuoSimulation.named(e.name))
        #expect(sim.rootSize == e.root)
        #expect(Arrangement.decide(size: sim.rootSize, division: sim.rootDivision).inline == e.inline)
    }

    /// The sidebar and the tab get the posture's whole safe area, on the sides it has it.
    @Test(arguments: expected)
    func theTabGetsThePosturesInsets(e: Expected) throws {
        let sim = try #require(DuoSimulation.named(e.name))
        #expect(sim.insets() == sim.safeArea)
        #expect(sim.insets(keyboard: 0) == sim.safeArea)
    }

    /// The keyboard covers the home indicator: nothing is left under the tab but the keyboard.
    @Test(arguments: expected)
    func theKeyboardTakesTheBottomInset(e: Expected) throws {
        let sim = try #require(DuoSimulation.named(e.name))
        var want = sim.safeArea
        want.bottom = 0
        #expect(sim.insets(keyboard: 336) == want)
    }

    @Test func theFoldIsGivenInTheRootsCoordinates() throws {
        let portrait = try #require(DuoSimulation.named("unfoldedPortrait"))
        #expect(portrait.rootDivision?.frame == CGRect(x: 0, y: 431.5, width: 669, height: 0))
        let book = try #require(DuoSimulation.named("book"))
        #expect(book.rootDivision == book.division)
        #expect(DuoSimulation.named("folded")?.rootDivision == nil)
    }

    @Test func namesAreTrimmedAndUnknownOnesAreNoPosture() {
        #expect(DuoSimulation.named(" halfWindowBarLeft ")?.name == "halfWindowBarLeft")
        #expect(DuoSimulation.named("sideways") == nil)
    }

    /// The postures that catch what only a leading inset shows, like a hidden sidebar that moves
    /// by its width alone and stays in view under the bar: the bar or the island is on the left.
    @Test func thePosturesWithTheBarOrTheIslandOnTheLeft() {
        let left = DuoSimulation.postures.filter { $0.safeArea.leading > 0 }.map(\.name)
        #expect(left == ["foldedLandscapeBarLeft", "halfWindowBarLeft", "iPhoneLandscape", "iPhoneLandscapeIslandLeft",
                         "proMaxLandscape"])
        for name in left {
            let inset = DuoSimulation.named(name)?.insets().leading ?? 0
            // A sidebar at the safe area's edge, moved left by its width and its shadow's 24 pt.
            #expect(inset - 24 > 0, "\(name)")
        }
    }
}
#endif
