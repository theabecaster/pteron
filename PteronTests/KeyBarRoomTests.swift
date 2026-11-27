import Testing
import UIKit
@testable import Pteron

/// The key bar on a narrow window: its scrolling keys keep room for one key, so esc shows whole
/// on a 375 pt iPhone with the attach key (`KeyBarPlacement.tightening`), and a bar with that room
/// is as it always was.
@MainActor
struct KeyBarRoomTests {
    /// The folded Duo's vertical bar, on its trailing edge.
    private static let column = CGRect(x: 382, y: 0, width: 84, height: 600)

    private func keyBar(width: CGFloat, attach: Bool, column: CGRect? = nil, rtl: Bool = false,
                        setup: KeyBarSetup? = nil) throws -> (KeyBar, UIWindow) {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let w = UIWindow(windowScene: scene)
        w.frame = CGRect(x: 0, y: 0, width: width, height: 600)
        // The caller puts the setup back (`keepingSetup`), after its checks: the bar follows a change.
        if let setup { Prefs.shared.keyBarSetup = setup }
        let bar = KeyBar()
        if rtl { bar.semanticContentAttribute = .forceRightToLeft }
        bar.frame = CGRect(x: 0, y: 500, width: width, height: KeyBar.barHeight)
        bar.attachAvailable = attach
        bar.barColumn = column
        w.addSubview(bar)
        for _ in 0..<3 { bar.setNeedsLayout(); bar.layoutIfNeeded() }
        return (bar, w)
    }

    /// Runs `body`, then puts back the setup it changed.
    private func keepingSetup(_ body: () throws -> Void) rethrows {
        let saved = Prefs.shared.keyBarSetup
        defer { Prefs.shared.keyBarSetup = saved }
        try body()
    }

    private func frame(_ v: UIView) -> CGRect { v.convert(v.bounds, to: nil) }

    /// The middle capsule's window onto its scrolling keys.
    private func clip(_ bar: KeyBar) throws -> CGRect {
        let scroll = try #require(bar.caps.first?.superview?.superview)
        return frame(try #require(scroll.superview))
    }

    /// Every fixed key whole on the bar, none over another; the first scrolling key's title or
    /// symbol inside the middle capsule's window, which holds at least one key.
    private func expectWhole(_ bar: KeyBar, _ note: String) throws {
        let fixed = (bar.leftCaps + bar.pinnedCaps + bar.rightCaps).filter { !$0.isHidden }.map(frame)
        for (i, f) in fixed.enumerated() {
            #expect(f.minX >= -0.01 && f.maxX <= bar.bounds.width + 0.01, "\(note): \(f) off the bar")
            for g in fixed[(i + 1)...] { #expect(f.intersection(g).width < 0.01, "\(note): \(f) over \(g)") }
        }
        let first = try #require(bar.caps.first)
        let c = try clip(bar), k = frame(first)
        #expect(c.width >= min(KeyCap.minWidth, k.width) - 0.01, "\(note): \(c.width) pt for the scrolling keys")
        let rtl = bar.effectiveUserInterfaceLayoutDirection == .rightToLeft
        if rtl {
            #expect(k.minX + KeyCap.margin >= c.minX - 0.01, "\(note): \(first.key) at \(k), window \(c)")
        } else {
            #expect(k.maxX - KeyCap.margin <= c.maxX + 0.01, "\(note): \(first.key) at \(k), window \(c)")
        }
        if let sr = bar.pinnedCaps.first, bar.pinnedCaps.count > 1 {
            #expect(frame(sr).width >= KeyBarPlacement.minTarget - 0.01, "\(note): Shift-Return \(frame(sr).width) pt")
        }
    }

    @Test(arguments: [false, true])
    func escShowsWholeAt375WithAttach(rtl: Bool) throws {
        let (bar, w) = try keyBar(width: 375, attach: true, rtl: rtl)
        defer { w.isHidden = true }
        #expect(bar.caps.first?.key == "esc")
        // 26 pt was left for esc (45.5 pt): 8 from the four spaces, then 6 from Shift-Return.
        #expect(bar.tightening == KeyBarPlacement.Tightening(gap: 2, shiftReturn: 6))
        try expectWhole(bar, "375 rtl=\(rtl)")
        #expect(abs(try clip(bar).width - KeyCap.minWidth) < 0.01)
    }

    @Test func withoutAttach375IsAsItWas() throws {
        let (bar, w) = try keyBar(width: 375, attach: false)
        defer { w.isHidden = true }
        #expect(bar.tightening == .none)
        try expectWhole(bar, "375 no attach")
    }

    @Test(arguments: [390, 393, 402, 414, 430, 440, 475, 667, 678, 744, 874, 951, 1024] as [CGFloat])
    func aBarWithRoomIsAsItAlwaysWas(width: CGFloat) throws {
        for attach in [false, true] {
            let (bar, w) = try keyBar(width: width, attach: attach)
            defer { w.isHidden = true }
            #expect(bar.tightening == .none, "\(width) attach=\(attach)")
            #expect(bar.pinnedCaps.allSatisfy { $0.trim == 0 })
            #expect(abs(frame(bar.allCaps[0]).minX - KeyBar.sideInset - KeyBar.ring) < 0.01)
        }
    }

    @Test func theFoldedDuoBesideItsVerticalBarIsAsItWas() throws {
        let (bar, w) = try keyBar(width: 466, attach: true, column: Self.column)
        defer { w.isHidden = true }
        #expect(bar.tightening == .none)
    }

    @Test func aLayoutWithEveryKeyShownTightensAsTheFirstOne() throws {
        try keepingSetup {
            var s = KeyBarSetup.standard
            s.primary = s.primary.map { KeyBarSetup.Key(id: $0.id, shown: true) }
            s.editing = s.editing.map { KeyBarSetup.Key(id: $0.id, shown: true) }
            let (bar, w) = try keyBar(width: 375, attach: true, setup: s)
            defer { w.isHidden = true }
            #expect(bar.caps.count > 20)
            #expect(bar.tightening == KeyBarPlacement.Tightening(gap: 2, shiftReturn: 6))
            try expectWhole(bar, "every key")
        }
    }

    @Test func aLayoutWithoutShiftReturnHasRoom() throws {
        try keepingSetup {
            var s = KeyBarSetup.standard
            s.editing = s.editing.map { KeyBarSetup.Key(id: $0.id, shown: $0.shown && $0.id != KeyBarSetup.shiftReturn) }
            let (bar, w) = try keyBar(width: 375, attach: true, setup: s)
            defer { w.isHidden = true }
            #expect(bar.pinnedCaps.map(\.key) == ["enter"])
            #expect(bar.tightening == .none)
            try expectWhole(bar, "no Shift-Return")
        }
    }

    @Test func aLayoutWithOnlyEscGetsRoomForIt() throws {
        try keepingSetup {
            // esc is the only scrolling key: the bar still makes room for it.
            var s = KeyBarSetup.standard
            s.primary = s.primary.map { KeyBarSetup.Key(id: $0.id, shown: false) }
            s.editing = s.editing.map { KeyBarSetup.Key(id: $0.id, shown: $0.id == KeyBarSetup.shiftReturn) }
            s.groups = s.groups.map { g in var g = g; g.shown = false; return g }
            s.primary[0].shown = true
            let (bar, w) = try keyBar(width: 375, attach: true, setup: s)
            defer { w.isHidden = true }
            #expect(bar.caps.map(\.key) == ["esc"])
            try expectWhole(bar, "esc alone")
        }
    }

    @Test func aWindowNarrowerThanAnyIPhoneKeepsEveryFixedKeyWhole() throws {
        // An iPad's narrowest window, if its bar is ever that narrow: nothing overlaps, and
        // without attach the scrolling keys still have their room.
        let (plain, w1) = try keyBar(width: 320, attach: false)
        defer { w1.isHidden = true }
        try expectWhole(plain, "320")
        let (bar, w2) = try keyBar(width: 320, attach: true)
        defer { w2.isHidden = true }
        let fixed = (bar.leftCaps + bar.pinnedCaps + bar.rightCaps).filter { !$0.isHidden }.map(frame)
        for (i, f) in fixed.enumerated() {
            for g in fixed[(i + 1)...] { #expect(f.intersection(g).width < 0.01, "320 attach: \(f) over \(g)") }
        }
        // Every step taken: the spaces at 2 pt, Shift-Return at 44 pt (on the screen's pixels).
        #expect(bar.tightening.gap == 4)
        let sr = try #require(bar.pinnedCaps.first)
        #expect(abs(frame(sr).width - KeyBarPlacement.minTarget) < 0.5, "\(frame(sr))")
    }
}
