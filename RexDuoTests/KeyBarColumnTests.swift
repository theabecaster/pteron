import Testing
import UIKit
@testable import RexDuo

/// The outer screen's vertical bar column in window (and screen) coordinates: in portrait, on the
/// trailing edge, and on its side with the bar on the left.
private let trailingColumn = CGRect(x: 382, y: 0, width: 84, height: 600)
private let leadingColumn = CGRect(x: 0, y: 0, width: 84, height: 600)

/// The key bar and the find bar beside the system's vertical bar: no hide key of the key bar's own,
/// nothing of either bar in the vertical bar's column, so that bar keeps its taps, and one Hide
/// Keyboard for VoiceOver. Without a vertical bar, the key bar is the one it always was.
@MainActor
struct KeyBarColumnTests {
    /// A window at the screen's origin, so its coordinates are the screen's, as the column's are.
    private func window(width: CGFloat) throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let w = UIWindow(windowScene: scene)
        w.frame = CGRect(x: 0, y: 0, width: width, height: 600)
        return w
    }

    private func settle(_ view: UIView, caps: [KeyCap] = []) {
        for _ in 0..<3 {
            view.setNeedsLayout()
            view.layoutIfNeeded()
            for cap in caps { cap.superview?.superview?.layoutIfNeeded() }
        }
    }

    /// A key bar along the bottom of a window `width` wide.
    private func keyBar(width: CGFloat, column: CGRect?, rtl: Bool = false, attach: Bool = false) throws -> (KeyBar, UIWindow) {
        let w = try window(width: width)
        let bar = KeyBar()
        if rtl { bar.semanticContentAttribute = .forceRightToLeft }
        bar.frame = CGRect(x: 0, y: 500, width: width, height: KeyBar.barHeight)
        bar.attachAvailable = attach
        bar.barColumn = column
        w.addSubview(bar)
        settle(bar, caps: bar.caps + bar.pinnedCaps)
        return (bar, w)
    }

    /// Every view under `root` that shows something or is a control, with the part of it a touch
    /// can reach (inside every ancestor's bounds), in window coordinates. Clear containers, which
    /// draw nothing of their own (UIKit's input view content, the find bar's content), only hold
    /// what is listed; the bars' `hitTest` keeps the column's touches from them.
    private func shown(under root: UIView) -> [(view: UIView, frame: CGRect)] {
        var out: [(view: UIView, frame: CGRect)] = []
        func draws(_ v: UIView) -> Bool {
            // UIKit's own content view of a clear input view: empty, and behind the bar's hitTest.
            if NSStringFromClass(type(of: v)) == "_UIInputViewContent" { return false }
            if v.subviews.isEmpty || v is UIControl || v is UIVisualEffectView { return true }
            guard let bg = v.backgroundColor else { return false }
            return bg.cgColor.alpha > 0.01
        }
        func walk(_ v: UIView, _ clip: CGRect) {
            for s in v.subviews where !s.isHidden && s.alpha > 0.01 {
                let r = s.convert(s.bounds, to: nil).intersection(clip)
                guard !r.isNull, !r.isEmpty else { continue }
                if draws(s) { out.append((s, r)) }
                walk(s, r)
            }
        }
        walk(root, root.convert(root.bounds, to: nil))
        return out
    }

    private func hideKeyboardElements(_ root: UIView) -> Int {
        shown(under: root).filter { $0.view.isAccessibilityElement && $0.view.accessibilityLabel == "Hide Keyboard" }.count
    }

    private func returnKey(_ bar: KeyBar) throws -> CGRect {
        let cap = try #require(bar.pinnedCaps.last)
        return cap.convert(cap.bounds, to: nil)
    }

    @Test(arguments: [(466, trailingColumn, false), (678, leadingColumn, false),
                      (466, trailingColumn, true), (678, leadingColumn, true)] as [(CGFloat, CGRect, Bool)])
    func nothingOfTheKeyBarIsInTheColumn(width: CGFloat, column: CGRect, rtl: Bool) throws {
        let (bar, w) = try keyBar(width: width, column: column, rtl: rtl, attach: true)
        defer { w.isHidden = true }
        let views = shown(under: bar)
        #expect(!views.isEmpty)
        for (v, r) in views {
            #expect(!r.intersects(column), "\(type(of: v)) at \(r) is in the vertical bar's column \(column)")
        }
        // The column's touches are the vertical bar's; the keys' are the keys'.
        #expect(bar.hitTest(bar.convert(CGPoint(x: column.midX, y: 527), from: nil), with: nil) == nil)
        let ret = try returnKey(bar)
        #expect(bar.hitTest(bar.convert(CGPoint(x: ret.midX, y: ret.midY), from: nil), with: nil) != nil)
    }

    @Test func theKeysEndSixPointsShortOfTheColumn() throws {
        // Return closes the capsule, its ring inside the capsule's end, 6 pt short of the column.
        let (bar, w) = try keyBar(width: 466, column: trailingColumn)
        defer { w.isHidden = true }
        let ret = try returnKey(bar)
        #expect(abs(ret.maxX - (trailingColumn.minX - KeyBar.sideInset - KeyBar.ring)) < 0.5, "\(ret)")
    }

    @Test func oneHideKeyboardForVoiceOver() throws {
        // Beside the vertical bar the key bar has none: the vertical bar's item is the one
        // (`HideKeyboardItemHostTests`).
        let (beside, w1) = try keyBar(width: 466, column: trailingColumn)
        defer { w1.isHidden = true }
        #expect(beside.hidesInVerticalBar)
        #expect(hideKeyboardElements(beside) == 0)
        // Without a vertical bar, the key bar's own hide key is the one.
        let (alone, w2) = try keyBar(width: 402, column: nil)
        defer { w2.isHidden = true }
        #expect(!alone.hidesInVerticalBar)
        #expect(hideKeyboardElements(alone) == 1)
    }

    @Test(arguments: [(402, false), (874, false), (402, true)] as [(CGFloat, Bool)])
    func withoutAVerticalBarTheHideKeyIsWhereItAlwaysWas(width: CGFloat, rtl: Bool) throws {
        let (bar, w) = try keyBar(width: width, column: nil, rtl: rtl)
        defer { w.isHidden = true }
        let h = KeyBar.keyHeight + 2 * KeyBar.ring
        let hide = try #require(shown(under: bar).first { $0.view.accessibilityLabel == "Hide Keyboard" }).frame
        if rtl {
            // At the leading (left) end, its touch running to the bar's edge.
            #expect(hide.minX == 0)
            #expect(hide.maxX == KeyBar.sideInset + h + KeyBar.hideGap / 2)
        } else {
            // At the trailing end from half the gap past the capsule to the bar's edge, with
            // Return closing the capsule before it.
            #expect(hide.maxX == width)
            #expect(hide.minX == width - KeyBar.sideInset - h - KeyBar.hideGap / 2)
            let ret = try returnKey(bar)
            #expect(abs(ret.maxX - (width - KeyBar.sideInset - h - KeyBar.hideGap - KeyBar.ring)) < 0.5, "\(ret)")
        }
    }

    @Test func aColumnThatGoesBringsTheHideKeyBack() throws {
        // A rotation or a fold from a posture with the bar to one without, and back.
        let (bar, w) = try keyBar(width: 466, column: trailingColumn)
        defer { w.isHidden = true }
        #expect(hideKeyboardElements(bar) == 0)
        bar.barColumn = nil
        settle(bar, caps: bar.caps + bar.pinnedCaps)
        #expect(hideKeyboardElements(bar) == 1)
        bar.barColumn = trailingColumn
        settle(bar, caps: bar.caps + bar.pinnedCaps)
        #expect(hideKeyboardElements(bar) == 0)
    }

    @Test(arguments: [(466, trailingColumn), (678, leadingColumn)] as [(CGFloat, CGRect)])
    func theFindBarKeepsDoneAndStaysOutOfTheColumn(width: CGFloat, column: CGRect) throws {
        let w = try window(width: width)
        defer { w.isHidden = true }
        let bar = FindAccessoryBar()
        bar.frame = CGRect(x: 0, y: 500, width: width, height: KeyBar.barHeight)
        bar.barColumn = column
        w.addSubview(bar)
        settle(bar)
        let views = shown(under: bar)
        #expect(views.contains { $0.view === bar.content.doneButton }, "Done stays: it closes find")
        for (v, r) in views {
            #expect(!r.intersects(column), "\(type(of: v)) at \(r) is in the vertical bar's column \(column)")
        }
        #expect(bar.hitTest(bar.convert(CGPoint(x: column.midX, y: 527), from: nil), with: nil) == nil)
    }

    /// Every posture with a vertical crease and the vertical bar on its trailing edge: with the
    /// bar's column given, the pinned keys stay clear of the crease and of the column.
    @Test func pinnedKeysStayOffTheCreaseBesideTheColumn() throws {
        let barred = DuoSimulation.postures.filter { p in
            guard let d = p.division?.frame else { return false }
            return d.height > 0 && d.width < 100 && p.safeArea.trailing > 0
        }
        #expect(!barred.isEmpty)
        for p in barred {
            let column = CGRect(x: p.size.width - p.safeArea.trailing, y: 0, width: p.safeArea.trailing, height: 600)
            let (bar, w) = try keyBar(width: p.size.width, column: column, attach: true)
            defer { w.isHidden = true }
            let fold = p.division!.frame.insetBy(dx: -KeyBarPlacement.creaseClearance, dy: 0)
            #expect(bar.pinnedCaps.count == 2)
            for cap in bar.pinnedCaps {
                let f = cap.convert(cap.bounds, to: nil)
                #expect(f.maxX <= fold.minX || f.minX >= fold.maxX, "\(p.name): \(f) on \(fold)")
                #expect(f.maxX <= column.minX - KeyBar.sideInset, "\(p.name): \(f) in \(column)")
            }
        }
    }
}
