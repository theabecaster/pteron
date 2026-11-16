import CoreGraphics
import SwiftUI
import Testing
@testable import RexConnect

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
