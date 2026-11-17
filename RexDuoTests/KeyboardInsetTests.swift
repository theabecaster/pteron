import CoreGraphics
import Testing
@testable import RexDuo

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
