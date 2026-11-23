import CoreGraphics
import Testing
import UIKit
@testable import Pteron

/// The root's keyboard padding, from frames alone (`KeyboardInset`).
struct KeyboardInsetTests {
    /// iPhone 17 portrait: 402 × 874, 34 pt home indicator inset.
    private let phone = CGRect(x: 0, y: 0, width: 402, height: 874)

    private func pad(_ kb: CGRect, view: CGRect? = nil, window: CGRect? = nil, safe: CGFloat = 34) -> CGFloat {
        KeyboardInset.padding(keyboard: kb, view: view ?? phone, window: window ?? phone, windowSafeBottom: safe)
    }

    @Test func keyboardWithKeyBarTakesItsHeightLessTheHomeIndicator() {
        // Keyboard and key bar, as the simulator reports them.
        #expect(pad(CGRect(x: 0, y: 523, width: 402, height: 351)) == 317)
    }

    /// The bug: after a pane swipe the keyboard was reported for a moment with both panes' key bars
    /// (401 pt), and the root kept that much room. The room follows the frame given, so the
    /// settled report puts it back to one key bar.
    @Test func theSettledFrameDecidesNotAMomentaryOne() {
        let momentary = pad(CGRect(x: 0, y: 473, width: 402, height: 401))
        let settled = pad(CGRect(x: 0, y: 523, width: 402, height: 351))
        #expect(momentary == 367)
        #expect(settled == 317)
        #expect(momentary - settled == 50)
    }

    @Test func hiddenOrFloatingKeyboardTakesNothing() {
        #expect(pad(CGRect(x: 0, y: 874, width: 402, height: 351)) == 0)  // below the window
        #expect(pad(.zero) == 0)  // floating: iOS reports no frame
        #expect(pad(.null) == 0)  // nothing reported yet
        #expect(pad(CGRect(x: 40, y: 300, width: 320, height: 260)) == 0)  // undocked, mid-window
    }

    @Test func keyBarAloneAboveTheHomeIndicatorTakesTheDifference() {
        // Hardware keyboard: only the key bar, 50 pt over the 34 pt inset.
        #expect(pad(CGRect(x: 0, y: 824, width: 402, height: 50)) == 16)
        // Shorter than the inset: the safe area already keeps clear of it.
        #expect(pad(CGRect(x: 0, y: 850, width: 402, height: 24)) == 0)
    }

    @Test func folded() {
        // Folded iPhone Duo: 466 × 678, the system's vertical bar beside the root.
        let w = CGRect(x: 0, y: 0, width: 466, height: 678)
        #expect(pad(CGRect(x: 0, y: 363, width: 466, height: 315), view: w, window: w) == 281)
    }

    @Test func rootAboveTheWindowsBottomGetsOnlyWhatReachesIt() {
        // A root that ends 100 pt above the window's bottom: the home indicator inset doesn't reach
        // it, and the keyboard covers only its last 251 pt.
        let view = CGRect(x: 0, y: 0, width: 402, height: 774)
        #expect(pad(CGRect(x: 0, y: 523, width: 402, height: 351), view: view) == 251)
        // Entirely above the keyboard: nothing.
        let short = CGRect(x: 0, y: 0, width: 402, height: 500)
        #expect(pad(CGRect(x: 0, y: 523, width: 402, height: 351), view: short) == 0)
    }

    @Test func keyboardBesideTheRootTakesNothing() {
        let view = CGRect(x: 0, y: 0, width: 300, height: 874)
        #expect(pad(CGRect(x: 320, y: 523, width: 402, height: 351), view: view) == 0)
    }

    @Test func neverMoreThanTheRoot() {
        let view = CGRect(x: 0, y: 600, width: 402, height: 274)
        #expect(pad(CGRect(x: 0, y: 523, width: 402, height: 351), view: view, safe: 0) == 274)
    }
}

/// The key bar's top as a floor while the keyboard is up (`KeyboardInset.padding(…keyBar:…)`).
struct KeyBarFloorTests {
    private let phone = CGRect(x: 0, y: 0, width: 402, height: 874)
    /// The keyboard with the key bar, as reported, and the same keyboard reported without it.
    private let withBar = CGRect(x: 0, y: 523, width: 402, height: 351)
    private let withoutBar = CGRect(x: 0, y: 577, width: 402, height: 297)
    private let bar = CGRect(x: 0, y: 523, width: 402, height: 54)

    private func pad(_ kb: CGRect, bar: CGRect?, hiding: Bool = false, view: CGRect? = nil, window: CGRect? = nil,
                     safe: CGFloat = 34) -> CGFloat {
        KeyboardInset.padding(keyboard: kb, keyBar: bar, hiding: hiding, view: view ?? phone, window: window ?? phone,
                              windowSafeBottom: safe)
    }

    /// The bug: an input-mode switch or a hand-back reported the keyboard last without the bar,
    /// and the pane ran 54 pt too tall, behind the bar.
    @Test func aReportWithoutTheBarKeepsClearOfTheBar() {
        #expect(pad(withoutBar, bar: nil) == 263, "the keyboard's frame alone: one bar short")
        #expect(pad(withoutBar, bar: bar) == 317)
        #expect(pad(withBar, bar: bar) == 317, "with it, nothing changes")
    }

    @Test func aTallerReportStillWins() {
        // Both panes' key bars for a moment: the keyboard's frame is the larger, as before.
        #expect(pad(CGRect(x: 0, y: 473, width: 402, height: 401), bar: bar) == 367)
    }

    @Test func hidingTheKeyboardsFrameRules() {
        // The bar's frame from before the hide is ignored: the pane never runs short on the way down.
        #expect(pad(CGRect(x: 0, y: 874, width: 402, height: 351), bar: bar) == 0)
        #expect(pad(withoutBar, bar: bar, hiding: true) == 263)
        #expect(pad(.null, bar: bar) == 0)
        #expect(pad(.zero, bar: bar) == 0, "floating: no frame, no floor")
    }

    @Test func thePalettesKeyboardHasNoBar() {
        // The palette's field and find take the keyboard without the key bar: its frame rules.
        #expect(pad(withoutBar, bar: nil) == 263)
    }

    @Test func aBarTheKeyboardDoesntReachIsNotThisOne() {
        // Laid out before the keyboard placed it, at the top of its window.
        #expect(pad(withoutBar, bar: CGRect(x: 0, y: 0, width: 402, height: 54)) == 263)
        // Below the root.
        let short = CGRect(x: 0, y: 0, width: 402, height: 500)
        #expect(pad(withoutBar, bar: bar, view: short) == 0)
        // Beside the root: Split View or the other side of the Duo's fold.
        let left = CGRect(x: 0, y: 0, width: 300, height: 874)
        let wide = CGRect(x: 0, y: 0, width: 1000, height: 874)
        #expect(pad(CGRect(x: 0, y: 577, width: 1000, height: 297), bar: CGRect(x: 320, y: 523, width: 680, height: 54),
                    view: left, window: wide) == 263)
    }

    @Test func hardwareKeyboardBarAlone() {
        // Only the accessory, reported as it is: its 54 pt less the home indicator.
        let alone = CGRect(x: 0, y: 820, width: 402, height: 54)
        #expect(pad(alone, bar: alone) == 20)
        // Reported once without it: an empty keyboard, no floor.
        #expect(pad(CGRect(x: 0, y: 874, width: 402, height: 0), bar: alone) == 0)
    }

    @Test func foldedDuo() {
        let w = CGRect(x: 0, y: 0, width: 466, height: 678)
        #expect(pad(CGRect(x: 0, y: 417, width: 466, height: 261), bar: CGRect(x: 0, y: 363, width: 466, height: 54),
                    view: w, window: w) == 281)
    }
}

/// The probe: a sequence of reports, the key bar coming and going, the settle and the palette's
/// hold.
@MainActor
struct KeyboardInsetProbeTests {
    private let phone = CGRect(x: 0, y: 0, width: 402, height: 874)
    private let withBar = CGRect(x: 0, y: 523, width: 402, height: 351)
    private let withoutBar = CGRect(x: 0, y: 577, width: 402, height: 297)

    @MainActor
    private struct Rig {
        let window: UIWindow
        let keyboardWindow: UIWindow
        let probe: KeyboardInsetReader.Probe
        let bar: UIView
        var safe: CGFloat { window.safeAreaInsets.bottom }
        func close() {
            window.isHidden = true
            keyboardWindow.isHidden = true
        }
    }

    /// The root's window, and a second window where the key bar sits, as the keyboard's does.
    private func rig() throws -> Rig {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        try #require(scene != nil, "no window scene in the test host")
        let window = UIWindow(frame: phone)
        window.windowScene = scene
        window.isHidden = false
        let probe = KeyboardInsetReader.Probe(frame: window.bounds)
        window.addSubview(probe)
        let keyboardWindow = UIWindow(frame: phone)
        keyboardWindow.windowScene = scene
        keyboardWindow.isHidden = false
        let bar = UIView(frame: CGRect(x: 0, y: 523, width: 402, height: 54))
        return Rig(window: window, keyboardWindow: keyboardWindow, probe: probe, bar: bar)
    }

    private func expected(_ kb: CGRect, _ r: Rig) -> CGFloat {
        KeyboardInset.padding(keyboard: kb, view: phone, window: phone, windowSafeBottom: r.safe)
    }

    @Test func willWithTheBarThenDidWithoutItKeepsTheBar() throws {
        let r = try rig()
        defer { r.close() }
        var got: [CGFloat] = []
        r.probe.onChange = { got.append($0) }
        r.keyboardWindow.addSubview(r.bar)
        r.probe.keyBarMoved(r.bar)
        r.probe.keyboard(withBar, name: UIResponder.keyboardWillChangeFrameNotification)
        r.probe.keyboard(withoutBar, name: UIResponder.keyboardDidChangeFrameNotification)
        r.probe.settled()
        #expect(got.last == expected(withBar, r))
        #expect(expected(withBar, r) - expected(withoutBar, r) == 54)
        #expect(got.filter { $0 == expected(withoutBar, r) }.isEmpty, "never one bar short")
    }

    @Test func withoutTheBarInAWindowTheKeyboardsFrameRules() throws {
        // The palette's field: the key bar left the keyboard.
        let r = try rig()
        defer { r.close() }
        r.keyboardWindow.addSubview(r.bar)
        r.probe.keyBarMoved(r.bar)
        r.bar.removeFromSuperview()
        r.probe.keyBarMoved(r.bar)
        r.probe.keyboard(withoutBar, name: UIResponder.keyboardDidChangeFrameNotification)
        #expect(r.probe.padding() == expected(withoutBar, r))
        // Another pane's bar leaving doesn't clear the one in the keyboard.
        r.keyboardWindow.addSubview(r.bar)
        r.probe.keyBarMoved(r.bar)
        r.probe.keyBarMoved(UIView())
        #expect(r.probe.padding() == expected(withBar, r))
        // A hidden bar is no floor.
        r.bar.isHidden = true
        r.probe.keyBarMoved(r.bar)
        #expect(r.probe.padding() == expected(withoutBar, r))
    }

    @Test func theHideSequenceGoesStraightDown() throws {
        let r = try rig()
        defer { r.close() }
        var got: [CGFloat] = []
        r.probe.onChange = { got.append($0) }
        r.keyboardWindow.addSubview(r.bar)
        r.probe.keyBarMoved(r.bar)
        r.probe.keyboard(withBar, name: UIResponder.keyboardWillChangeFrameNotification)
        // The bar is still in its window, where it was: the hide ignores it.
        r.probe.keyboard(withoutBar, name: UIResponder.keyboardWillHideNotification)
        r.probe.keyboard(CGRect(x: 0, y: 874, width: 402, height: 351), name: UIResponder.keyboardWillChangeFrameNotification)
        r.probe.keyboard(CGRect(x: 0, y: 874, width: 402, height: 351), name: UIResponder.keyboardDidHideNotification)
        #expect(got == [expected(withBar, r), expected(withoutBar, r), 0])
    }

    @Test func noFeedbackLoop() throws {
        // Each report lays the root out again and the bar reports itself: one report per change.
        let r = try rig()
        defer { r.close() }
        let probe = r.probe, bar = r.bar
        r.probe.onChange = { _ in
            probe.setNeedsLayout()
            probe.layoutIfNeeded()
            probe.keyBarMoved(bar)
        }
        r.keyboardWindow.addSubview(r.bar)
        r.probe.keyBarMoved(r.bar)
        let before = r.probe.reports
        for _ in 0..<5 {
            r.probe.keyboard(withBar, name: UIResponder.keyboardWillChangeFrameNotification)
            r.probe.keyboard(withoutBar, name: UIResponder.keyboardDidChangeFrameNotification)
            r.probe.settled()
        }
        #expect(r.probe.reports - before == 1)
    }

    @Test func thePalettesHoldEndsWithAFreshMeasure() throws {
        let r = try rig()
        defer { r.close() }
        let hold = PadHold()
        var applied: [CGFloat] = []
        var got: [CGFloat] = []
        hold.apply[.pad] = { applied.append($0) }
        let probe = r.probe
        probe.onChange = { v in if !hold.offer(.pad, v) { got.append(v) } }
        hold.remeasure[.pad] = { [weak probe] in probe?.remeasure() }
        r.keyboardWindow.addSubview(r.bar)
        probe.keyBarMoved(r.bar)
        probe.keyboard(withBar, name: UIResponder.keyboardWillChangeFrameNotification)
        let start = got
        hold.begin()
        // The hand-back reports the keyboard without the bar first; the hold keeps that aside.
        r.bar.removeFromSuperview()
        probe.keyBarMoved(r.bar)
        probe.keyboard(withoutBar, name: UIResponder.keyboardDidChangeFrameNotification)
        r.keyboardWindow.addSubview(r.bar)
        probe.keyBarMoved(r.bar)
        hold.endNow()
        #expect(applied.isEmpty, "the kept value isn't applied")
        #expect(got == start + [expected(withBar, r)], "the live measure is, even though it didn't change")
        #expect(!hold.active)
    }

    @Test func theKeyBarReportsOnlyAChange() throws {
        let r = try rig()
        defer { r.close() }
        let bar = KeyBar()
        bar.frame = CGRect(x: 0, y: 523, width: 402, height: KeyBar.barHeight)
        r.keyboardWindow.addSubview(bar)
        let added = bar.frameReports
        #expect(added >= 1, "coming into a window")
        for _ in 0..<5 {
            bar.setNeedsLayout()
            bar.layoutIfNeeded()
        }
        #expect(bar.frameReports == added, "the same frame: no report")
        bar.frame.origin.y += 0.5
        bar.setNeedsLayout()
        bar.layoutIfNeeded()
        #expect(bar.frameReports == added, "under a point")
        bar.frame.origin.y += 2
        bar.setNeedsLayout()
        bar.layoutIfNeeded()
        #expect(bar.frameReports == added + 1)
        bar.isHidden = true
        #expect(bar.frameReports == added + 2)
        bar.removeFromSuperview()
        #expect(bar.frameReports == added + 3)
    }
}
