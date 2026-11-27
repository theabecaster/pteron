import CoreGraphics
import Testing
import UIKit
@testable import Pteron

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

/// The fixed keys: ⌘, ✎ and attach in the left capsule, Return pinned at the middle capsule's
/// end, ✥ and the hide key in the right one; none of them on the Duo's vertical crease in any
/// posture.
@MainActor
struct FixedKeysTests {
    /// A key bar in a window `width` wide, with or without the attach key, and a crease.
    private func bar(width: CGFloat, attach: Bool, crease: CGRect? = nil) throws -> (KeyBar, UIWindow) {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let w = UIWindow(windowScene: scene)
        w.frame = CGRect(x: 0, y: 0, width: width, height: 600)
        let bar = KeyBar()
        bar.frame = CGRect(x: 0, y: 500, width: width, height: KeyBar.barHeight)
        bar.attachAvailable = attach
        bar.crease = crease
        w.addSubview(bar)
        for _ in 0..<3 {
            bar.setNeedsLayout()
            bar.layoutIfNeeded()
            for cap in bar.allCaps { cap.superview?.superview?.layoutIfNeeded() }
        }
        return (bar, w)
    }

    private func frame(_ cap: KeyCap) -> CGRect { cap.convert(cap.bounds, to: nil) }

    @Test(arguments: [375, 402, 466, 669, 951] as [CGFloat])
    func theFixedKeysAreWhereTheyBelong(width: CGFloat) throws {
        let (without, w1) = try bar(width: width, attach: false)
        defer { w1.isHidden = true }
        let (with, w2) = try bar(width: width, attach: true)
        defer { w2.isHidden = true }
        #expect(without.leftCaps.map(\.key) == ["palette", "compose"], "no uploads: no attach key, as before")
        #expect(with.leftCaps.map(\.key) == ["palette", "compose", "attach"])
        let pinned = (Prefs.shared.keyBarSetup.showsShiftReturn ? [KeyBarSetup.shiftReturn] : []) + ["enter"]
        #expect(with.pinnedCaps.map(\.key) == pinned)
        #expect(with.rightCaps.map(\.key) == ["arrows", "hide"])
        for b in [without, with] {
            let left = b.leftCaps.map(frame), right = b.rightCaps.map(frame), ret = frame(b.pinnedCaps.last!)
            // Narrower spaces where the bar makes room for its scrolling keys (`KeyBarRoomTests`).
            let inset = KeyBar.sideInset - b.tightening.gap, gap = KeyBar.capsuleGap - b.tightening.gap
            #expect(abs(left[0].minX - (inset + KeyBar.ring)) < 0.5, "\(left[0])")
            #expect(abs(right.last!.maxX - (width - inset - KeyBar.ring)) < 0.5, "\(right.last!)")
            let pinned = b.pinnedCaps.map(frame)
            #expect(pinned.first!.minX > left.last!.maxX + gap)
            #expect(ret.maxX < right[0].minX - gap)
            for (a, c) in zip(pinned, pinned.dropFirst()) { #expect(a.maxX <= c.minX + 0.5, "pinned keys side by side") }
            for f in left + right + pinned { #expect(f.width >= 40) }
        }
    }

    /// The pinned ⇧⏎ takes a key's room from the scrolling keys; at every width, from the folded
    /// Duo to an iPhone in landscape (its width less the safe area, and the whole of it) and wider,
    /// the first scrolling key, esc, still shows whole. At 375 pt (iPhone SE, mini) with the attach
    /// key the bar makes room for its title instead (`KeyBarRoomTests`).
    @Test(arguments: [(375, false), (402, true), (466, true), (669, true), (750, true), (874, true), (951, true)]
          as [(CGFloat, Bool)])
    func escStillShowsBesideThePinnedKeys(width: CGFloat, attach: Bool) throws {
        let saved = Prefs.shared.keyBarSetup
        defer { Prefs.shared.keyBarSetup = saved }
        Prefs.shared.keyBarSetup = .standard
        let (b, w) = try bar(width: width, attach: attach)
        defer { w.isHidden = true }
        #expect(b.pinnedCaps.map(\.key) == [KeyBarSetup.shiftReturn, "enter"])
        let esc = try #require(b.caps.first)
        #expect(esc.key == "esc")
        let f = frame(esc), pinned = frame(b.pinnedCaps[0])
        #expect(f.minX > frame(b.leftCaps.last!).maxX + KeyBar.capsuleGap, "\(width): \(f)")
        #expect(f.maxX <= pinned.minX - 6, "\(width): esc \(f) under the pinned keys \(pinned)")
    }

    /// Every posture with a vertical crease: no fixed key, and no scrolling key with the bar at
    /// its start, sits within the crease clearance of it.
    @Test func noKeyIsOnAVerticalCrease() throws {
        let creased = DuoSimulation.postures.filter { p in
            guard let d = p.division?.frame else { return false }
            return d.height > 0 && d.width < 100
        }
        #expect(!creased.isEmpty)
        for p in creased {
            let crease = p.division!.frame
            let (b, w) = try bar(width: p.size.width, attach: true, crease: crease)
            defer { w.isHidden = true }
            let fold = crease.insetBy(dx: -KeyBarPlacement.creaseClearance + 0.5, dy: 0)
            for cap in b.allCaps where !cap.isHidden {
                let f = frame(cap)
                #expect(f.maxX <= fold.minX || f.minX >= fold.maxX, "\(p.name) \(cap.key): \(f) on \(fold)")
            }
        }
    }

    // MARK: Room for the scrolling keys

    private func tight(_ shortfall: CGFloat, spaces: Int = 4, spare: CGFloat = 16.5, scale: CGFloat = 2)
        -> KeyBarPlacement.Tightening {
        KeyBarPlacement.tightening(shortfall: shortfall, spaces: spaces, shiftReturnSpare: spare, scale: scale)
    }

    @Test func aBarWithRoomGivesUpNothing() {
        #expect(tight(0) == .none)
        #expect(tight(-30) == .none)
        #expect(tight(10, spaces: 0) == .none)
    }

    @Test func theSpacesGoFirstThenShiftReturnThenTheSpacesAgain() {
        // Up to 2 pt off each of the four spaces.
        #expect(tight(6) == .init(gap: 1.5, shiftReturn: 0))
        #expect(tight(8) == .init(gap: 2, shiftReturn: 0))
        // A 375 pt iPhone with attach: 14 pt short.
        #expect(tight(14) == .init(gap: 2, shiftReturn: 6))
        #expect(tight(24.5) == .init(gap: 2, shiftReturn: 16.5))
        // Then the spaces again, to 2 pt.
        #expect(tight(28.5) == .init(gap: 3, shiftReturn: 16.5))
        #expect(tight(100) == .init(gap: 4, shiftReturn: 16.5))
    }

    @Test func withoutShiftReturnOrASideCapsuleTheSpacesTakeAll() {
        #expect(tight(12, spare: 0) == .init(gap: 3, shiftReturn: 0))
        #expect(tight(9, spaces: 3, spare: 0) == .init(gap: 3, shiftReturn: 0))
        // A negative spare (a narrow pair) gives nothing.
        #expect(tight(12, spare: -2) == .init(gap: 3, shiftReturn: 0))
    }

    @Test func spacesAreWholePixels() {
        // 5 pt over four spaces is 1.25 pt each: 1 1/3 pt on a 3x screen, 1.5 on a 2x one.
        #expect(tight(5, scale: 3).gap == 4.0 / 3)
        #expect(tight(5, scale: 2).gap == 1.5)
    }
}
