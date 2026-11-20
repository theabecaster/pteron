import CoreGraphics
import Testing
import UIKit
@testable import RexDuo

/// Where the key bar's hide key goes (`KeyBarPlacement.hideKey`) and how keys keep off a crease.
struct KeyBarPlacementTests {
    private func hide(_ edge: NSDirectionalRectEdge?, width: CGFloat = 466, left: CGFloat = 0, right: CGFloat = 0,
                      rtl: Bool = false) -> KeyBarPlacement.HideKey {
        KeyBarPlacement.hideKey(barEdge: edge, rightToLeft: rtl, width: width, height: 50, leftInset: left, rightInset: right)
    }

    private let rightColumn = KeyBarPlacement.HideKey.strip(column: CGRect(x: 382, y: 0, width: 84, height: 50), midX: 418)
    private let leftColumn = KeyBarPlacement.HideKey.strip(column: CGRect(x: 0, y: 0, width: 84, height: 50), midX: 48)

    @Test func foldedDuoPutsItInTheVerticalBarsColumn() {
        // Outer screen: 466 pt wide, the vertical bar's 84 pt on the trailing edge. The whole column
        // takes touches; the key sits in line with the bar's items, 48 pt from the edge.
        #expect(hide(.trailing, right: 84) == rightColumn)
    }

    @Test func unfoldedLandscapeAlsoHasTheColumn() {
        #expect(hide(.trailing, width: 951, right: 84)
            == .strip(column: CGRect(x: 867, y: 0, width: 84, height: 50), midX: 903))
    }

    @Test func aLeadingBarPutsItOnTheLeft() {
        // Split View on the left half: the bar sits on the outer (leading) edge.
        #expect(hide(.leading, width: 475, left: 84)
            == .strip(column: CGRect(x: 0, y: 0, width: 84, height: 50), midX: 48))
    }

    @Test func rightToLeftMirrorsTheEdge() {
        #expect(hide(.trailing, left: 84, rtl: true) == leftColumn)
        #expect(hide(.leading, right: 84, rtl: true) == rightColumn)
    }

    @Test func noVerticalBarKeepsItInTheBar() {
        // Regular iPhone portrait, and landscape, whose insets are the sensor housing, not a bar.
        #expect(hide(nil, width: 402) == .inBar)
        #expect(hide(nil, width: 874, left: 62, right: 62) == .inBar)
    }

    @Test func aBarWithoutAColumnBesideTheKeyboardKeepsItInTheBar() {
        // The trait reports a bar, but the keyboard runs under it (no inset), or the column is too
        // narrow to tap, or the inset is on the other side.
        #expect(hide(.trailing, right: 0) == .inBar)
        #expect(hide(.trailing, right: 30) == .inBar)
        #expect(hide(.trailing, left: 84) == .inBar)
    }

    @Test func theColumnMustBeTappable() {
        // A full touch target beside the edge margin.
        let least = KeyBarPlacement.minStripWidth + KeyBarPlacement.stripEdgeMargin
        #expect(hide(.trailing, right: least) != .inBar)
        #expect(hide(.trailing, right: least - 1) == .inBar)
    }

    // MARK: Crease

    private let widths: [CGFloat] = [50, 44, 44, 60, 44, 44]  // keys at 6, 62, 112, 162, 228, 278

    @Test func aKeyOnTheCreaseMovesPastIt() {
        // The crease at 170 lands in the fourth key (162–222): it moves to 170 + 12.
        let gap = KeyBarPlacement.creaseGap(widths: widths, start: 6, spacing: 6, crease: 170...170)
        #expect(gap?.index == 3)
        #expect(gap?.extra == 20)
    }

    @Test func aKeyWithinTheClearanceMovesToo() {
        // The third key ends at 156; a crease at 160 is closer than 12 pt.
        let gap = KeyBarPlacement.creaseGap(widths: widths, start: 6, spacing: 6, crease: 160...160)
        #expect(gap?.index == 2)
        #expect(gap?.extra == 60)  // the key moves from 112 to 172
    }

    @Test func aWideActiveCreaseClearsItsWholeSpan() {
        let gap = KeyBarPlacement.creaseGap(widths: widths, start: 6, spacing: 6, crease: 150...190)
        #expect(gap?.index == 2)
        #expect(gap?.extra == 90)  // the key moves from 112 to 202
    }

    @Test func noKeyNearTheCreaseLeavesTheBarAlone() {
        #expect(KeyBarPlacement.creaseGap(widths: widths, start: 6, spacing: 6, crease: 475...475) == nil)
        #expect(KeyBarPlacement.creaseGap(widths: [], start: 6, spacing: 6, crease: 100...100) == nil)
        // In a gap between keys, with room on both sides.
        let wide: [CGFloat] = [50, 50]  // 6–56, 82–132 with 26 pt spacing
        #expect(KeyBarPlacement.creaseGap(widths: wide, start: 6, spacing: 26, crease: 69...69) == nil)
    }

    @Test func aCreaseLeftOfTheBarIsIgnored() {
        #expect(KeyBarPlacement.creaseGap(widths: widths, start: 6, spacing: 6, crease: -200 ... -200) == nil)
    }
}

/// The pinned attach key: before Return with the bar's gap between them, Return where it always
/// was, and neither on the Duo's vertical crease in any posture.
@MainActor
struct PinnedAttachKeyTests {
    /// A key bar laid out over `width` points of keyboard, with or without the attach key.
    private func bar(width: CGFloat, attach: Bool) -> KeyBar {
        let bar = KeyBar()
        bar.frame = CGRect(x: 0, y: 0, width: width, height: KeyBar.barHeight)
        bar.attachAvailable = attach
        for _ in 0..<3 {
            bar.setNeedsLayout()
            bar.layoutIfNeeded()
            for cap in bar.pinnedCaps { cap.superview?.superview?.layoutIfNeeded() }
        }
        return bar
    }

    private func frames(_ bar: KeyBar) -> [CGRect] { bar.pinnedCaps.map { $0.convert($0.bounds, to: bar) } }

    @Test(arguments: [320, 375, 402, 466, 669, 951] as [CGFloat])
    func attachSitsBeforeReturnAndReturnKeepsItsPlace(width: CGFloat) {
        let without = bar(width: width, attach: false)
        let with = bar(width: width, attach: true)
        #expect(without.pinnedCaps.map(\.key) == ["enter"], "no uploads: no attach key, as before")
        #expect(with.pinnedCaps.map(\.key) == ["attach", "enter"])
        let ret = frames(without)[0]
        let f = frames(with)
        #expect(f[1] == ret, "Return keeps its size and its place at the trailing end")
        #expect(f[0].width >= 44 && f[1].width >= 44)
        #expect(f[1].minX - f[0].maxX >= 6, "at least the bar's 6 pt between attach and Return")
    }

    /// Every posture with a vertical crease: the pinned keys sit clear of it by the crease
    /// clearance. The bar gets the posture's width inside its side insets, where the capsule ends
    /// nearest the crease (the hide key in the bar, not in the vertical bar's column).
    @Test func pinnedKeysStayOffEveryVerticalCrease() {
        let creased = DuoSimulation.postures.filter { p in
            guard let d = p.division?.frame else { return false }
            return d.height > 0 && d.width < 100
        }
        #expect(!creased.isEmpty)
        for p in creased {
            let lead = p.safeArea.leading
            let inner = p.size.width - lead - p.safeArea.trailing
            let fold = p.division!.frame.insetBy(dx: -KeyBarPlacement.creaseClearance, dy: 0)
            for f in frames(bar(width: inner, attach: true)) {
                let x = f.offsetBy(dx: lead, dy: 0)
                #expect(x.maxX <= fold.minX || x.minX >= fold.maxX, "\(p.name): \(x) on \(fold)")
            }
        }
    }
}
