import CoreGraphics
import Testing
@testable import Pteron

/// Which corner insets are the window controls, and how far a bar moves for them
/// (`WindowControls`). The insets are the root's, as the iOS 27.2 simulators report them.
struct WindowControlsTests {
    @Test func aWindowWithControls() {
        // iPad Pro 13-inch, a window smaller than the screen, under the status bar and below it.
        #expect(WindowControls.region(topLeading: CGSize(width: 66, height: 75), topTrailing: .zero, verticalBar: false)
                == CGSize(width: 66, height: 75))
        #expect(WindowControls.region(topLeading: CGSize(width: 66, height: 53), topTrailing: CGSize(width: 22, height: 22),
                                      verticalBar: false) == CGSize(width: 66, height: 53))
    }

    /// The screen's and the window's rounded corners are the same at both top corners: no controls.
    @Test func cornersAloneAreNotControls() {
        // iPad Pro 13-inch full screen, iPhone 17 portrait.
        #expect(WindowControls.region(topLeading: .zero, topTrailing: .zero, verticalBar: false) == .zero)
        // iPad mini full screen.
        #expect(WindowControls.region(topLeading: CGSize(width: 15, height: 15), topTrailing: CGSize(width: 15, height: 15),
                                      verticalBar: false) == .zero)
    }

    /// The Duo's vertical bar makes the top corners differ, on either side: still no controls.
    @Test func theDuosBarIsNotControls() {
        // Folded, bar on the right.
        #expect(WindowControls.region(topLeading: CGSize(width: 8, height: 8), topTrailing: CGSize(width: 84, height: 174),
                                      verticalBar: true) == .zero)
        // Folded on its side, bar on the left.
        #expect(WindowControls.region(topLeading: CGSize(width: 84, height: 174), topTrailing: CGSize(width: 8, height: 8),
                                      verticalBar: true) == .zero)
    }

    @Test func aBarMovesByWhatOfTheControlsItReaches() {
        let controls = CGSize(width: 66, height: 53)
        // At the window's edge: all of them.
        #expect(WindowControls.clearance(controls: controls, barMinX: 0) == 66)
        // Beside the inline sidebar: none.
        #expect(WindowControls.clearance(controls: controls, barMinX: 261) == 0)
        // Part way, while the sidebar slides: the rest.
        #expect(WindowControls.clearance(controls: controls, barMinX: 40) == 26)
        // No controls: nothing, wherever the bar is.
        #expect(WindowControls.clearance(controls: .zero, barMinX: 0) == 0)
    }
}
