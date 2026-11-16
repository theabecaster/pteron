import CoreGraphics
import SwiftUI
import Testing
@testable import RexConnect

/// Layout from size classes and the fold (`Arrangement.decide`), and the folded split check.
struct ArrangementTests {
    private func decide(_ w: CGFloat, _ h: CGFloat, _ hs: UserInterfaceSizeClass, _ vs: UserInterfaceSizeClass,
                        _ d: Division? = nil) -> Arrangement {
        Arrangement.decide(size: CGSize(width: w, height: h), horizontal: hs, vertical: vs, division: d)
    }

    @Test func unfoldedLandscapeIsTwoPagesAtTheCrease() {
        let flat = Division(frame: CGRect(x: 475.5, y: 0, width: 0, height: 669), isActive: false)
        #expect(decide(951, 669, .regular, .regular, flat) == .pages(first: 475.5, gap: 0))
        let bent = Division(frame: CGRect(x: 455, y: 0, width: 40, height: 669), isActive: true)
        #expect(decide(951, 669, .regular, .regular, bent) == .pages(first: 455, gap: 40))
    }

    @Test func unfoldedLandscapeWithoutAFoldSplitsAtTheCenter() {
        #expect(decide(951, 669, .regular, .regular) == .pages(first: 475.5, gap: 0))
    }

    @Test func unfoldedPortraitIsOneColumnUntilItBends() {
        let flat = Division(frame: CGRect(x: 0, y: 475.5, width: 669, height: 0), isActive: false)
        #expect(decide(669, 951, .regular, .regular, flat) == .overlay)
        let bent = Division(frame: CGRect(x: 0, y: 455, width: 669, height: 40), isActive: true)
        #expect(decide(669, 951, .regular, .regular, bent) == .tabletop(top: 455, gap: 40))
        #expect(decide(669, 951, .regular, .regular) == .overlay)
    }

    @Test(arguments: [
        (466.0, 678.0, UserInterfaceSizeClass.compact, UserInterfaceSizeClass.regular),  // folded
        (475, 669, .compact, .regular),   // half of the inner screen
        (402, 874, .compact, .regular),   // iPhone portrait
        (874, 402, .compact, .compact),   // iPhone landscape
        (956, 440, .regular, .compact),   // Pro Max landscape
    ])
    func compactWidthOrHeightStacks(w: Double, h: Double, hs: UserInterfaceSizeClass, vs: UserInterfaceSizeClass) {
        #expect(decide(w, h, hs, vs) == .stack)
    }

    @Test func aFoldTooCloseToTheEdgeSplitsAtTheCenter() {
        let edge = Division(frame: CGRect(x: 100, y: 0, width: 0, height: 669), isActive: false)
        #expect(decide(951, 669, .regular, .regular, edge) == .pages(first: 476, gap: 0))
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
