import CoreGraphics
import Testing
import UIKit
@testable import RexDuo

/// Where the key bar's hide key goes (`KeyBarPlacement.hideKey`), the vertical bar's column the
/// keys end short of, and how keys keep off a crease.
struct KeyBarPlacementTests {
    // MARK: The vertical bar's column

    /// The outer screen in portrait: 466 pt wide, the bar's 84 pt on the trailing edge.
    private let folded = CGRect(x: 0, y: 0, width: 466, height: 678)
    private let trailingBar = UIEdgeInsets(top: 0, left: 0, bottom: 34, right: 84)
    /// The outer screen on its side with the bar on the left (`foldedLandscapeBarLeft`).
    private let sideways = CGRect(x: 0, y: 0, width: 678, height: 466)
    private let leadingBar = UIEdgeInsets(top: 0, left: 84, bottom: 34, right: 0)

    private func column(_ edge: NSDirectionalRectEdge?, rtl: Bool = false, bounds: CGRect? = nil,
                        insets: UIEdgeInsets) -> CGRect? {
        KeyBarPlacement.column(edge: edge, rightToLeft: rtl, bounds: bounds ?? folded, insets: insets)
    }

    @Test func theColumnIsTheWindowsInsetOnTheBarsEdge() {
        #expect(column(.trailing, insets: trailingBar) == CGRect(x: 382, y: 0, width: 84, height: 678))
        // The inner screen in landscape: the same bar beside a wider window.
        #expect(column(.trailing, bounds: CGRect(x: 0, y: 0, width: 951, height: 669), insets: trailingBar)
            == CGRect(x: 867, y: 0, width: 84, height: 669))
    }

    @Test func aLeadingBarHasItsColumnOnTheLeft() {
        // foldedLandscapeBarLeft, and Split View on the left half (the bar on the outer edge).
        #expect(column(.leading, bounds: sideways, insets: leadingBar) == CGRect(x: 0, y: 0, width: 84, height: 466))
        #expect(column(.leading, bounds: CGRect(x: 0, y: 0, width: 475, height: 669), insets: leadingBar)
            == CGRect(x: 0, y: 0, width: 84, height: 669))
    }

    @Test func rightToLeftMirrorsTheEdge() {
        #expect(column(.trailing, rtl: true, bounds: sideways, insets: leadingBar) == CGRect(x: 0, y: 0, width: 84, height: 466))
        #expect(column(.leading, rtl: true, insets: trailingBar) == CGRect(x: 382, y: 0, width: 84, height: 678))
    }

    @Test func noBarOrNoInsetOnItsEdgeHasNoColumn() {
        // A regular iPhone: no bar, also in landscape, whose insets are the sensor housing.
        #expect(column(nil, insets: UIEdgeInsets(top: 62, left: 0, bottom: 34, right: 0)) == nil)
        #expect(column(nil, bounds: CGRect(x: 0, y: 0, width: 874, height: 402),
                       insets: UIEdgeInsets(top: 0, left: 62, bottom: 20, right: 62)) == nil)
        // The trait reports a bar, but the window has no inset on that side.
        #expect(column(.trailing, insets: .zero) == nil)
        #expect(column(.trailing, insets: leadingBar) == nil)
    }

    @Test func theHideKeyIsTheVerticalBarsOnlyWithAColumn() {
        #expect(KeyBarPlacement.hideKey(column: nil) == .inBar)
        #expect(KeyBarPlacement.hideKey(column: CGRect(x: 382, y: 0, width: 84, height: 678)) == .verticalBar)
    }

    // MARK: Where the keys go

    private func span(_ width: CGFloat = 466, left: CGFloat = 0, right: CGFloat = 0, column: CGRect? = nil) -> ClosedRange<CGFloat> {
        // The key bar's side inset.
        KeyBarPlacement.span(width: width, leftInset: left, rightInset: right, sideInset: 6, column: column)
    }

    @Test func withoutAColumnTheKeysGoWhereTheyAlwaysWent() {
        // iPhone portrait and landscape: 6 pt inside the bar's insets.
        #expect(span(402) == 6...396)
        #expect(span(874, left: 62, right: 62) == 68...806)
    }

    @Test func aTrailingColumnEndsTheKeysShortOfIt() {
        let bar = CGRect(x: 382, y: -400, width: 84, height: 678)
        // The keyboard runs under the bar and gives the key bar no inset: the keys stop 6 pt short.
        #expect(span(column: bar) == 6...376)
        // The keyboard gives the key bar the inset as well: the same place, whichever says it.
        #expect(span(right: 84, column: bar) == 6...376)
    }

    @Test func aLeadingColumnStartsTheKeysPastIt() {
        let bar = CGRect(x: 0, y: -200, width: 84, height: 466)
        #expect(span(678, column: bar) == 90...672)
        #expect(span(678, left: 84, column: bar) == 90...672)
    }

    @Test func aColumnOffTheBarBoundsNothing() {
        // A stale frame during a rotation.
        #expect(span(column: CGRect(x: 466, y: 0, width: 84, height: 678)) == 6...460)
        #expect(span(column: CGRect(x: -84, y: 0, width: 84, height: 678)) == 6...460)
    }

    @Test func nothingThatTakesTouchesReachesIntoTheColumn() {
        #expect(KeyBarPlacement.reach(width: 466, column: nil) == 0...466)
        #expect(KeyBarPlacement.reach(width: 466, column: CGRect(x: 382, y: 0, width: 84, height: 678)) == 0...382)
        #expect(KeyBarPlacement.reach(width: 678, column: CGRect(x: 0, y: 0, width: 84, height: 466)) == 84...678)
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
