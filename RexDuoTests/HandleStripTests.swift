import RexKit
import SwiftUI
import XCTest
@testable import RexDuo

/// A split's handle in a SwiftUI canvas: its strip takes no touch, marks the handle's reach over
/// the panes on either side, and is no business of a pane drawn over it.
@MainActor
final class HandleStripTests: XCTestCase {
    private struct Wrap: UIViewRepresentable {
        let view: UIView
        func makeUIView(context: Context) -> UIView { view }
        func updateUIView(_ v: UIView, context: Context) {}
    }

    /// Two panes side by side in a 300 × 300 canvas, split at 50 %, with the split's handle, and
    /// optionally a floating pane over the middle.
    private struct Canvas: View {
        let left: UIView, right: UIView
        var float: UIView?
        let strips: HandleStrips
        var body: some View {
            ZStack(alignment: .topLeading) {
                Wrap(view: left).frame(width: 150, height: 300)
                Wrap(view: right).frame(width: 150, height: 300).offset(x: 150)
                SplitHandle(split: (id: "s", direction: "horizontal", ratio: 0.5, rect: CGRect(x: 0, y: 0, width: 1, height: 1),
                                    beforeFirst: "a", afterFirst: "b"),
                            canvas: CGSize(width: 300, height: 300), theme: ThemeStore.fallback, onCommit: { _ in })
                if let float {
                    Wrap(view: float).frame(width: 100, height: 100).offset(x: 100, y: 100)
                }
            }
            .frame(width: 300, height: 300, alignment: .topLeading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .ignoresSafeArea()
            .environment(\.handleStrips, strips)
        }
    }

    private var window: UIWindow?
    private var strips: HandleStrips!

    override func setUp() async throws {
        strips = HandleStrips()
    }

    override func tearDown() async throws {
        window?.isHidden = true
        window = nil
        strips = nil
    }

    private func pane() -> UIView {
        let v = UIView()
        v.backgroundColor = .gray
        v.addGestureRecognizer(UITapGestureRecognizer())
        return v
    }

    /// The canvas in a window, laid out; the divider's middle in window coordinates.
    private func host(left: UIView, right: UIView, float: UIView? = nil) async throws -> CGPoint {
        let w = Hosted.window(Canvas(left: left, right: right, float: float, strips: strips), size: CGSize(width: 300, height: 300))
        window = w
        w.layoutIfNeeded()
        var strip: HandleStripView?
        _ = await Hosted.settle {
            strip = Hosted.views(HandleStripView.self, in: w).first { $0.bounds.width > 0 && $0.window != nil }
            return strip != nil && left.bounds.width > 0
        }
        let s = try XCTUnwrap(strip, "the handle marks its strip")
        return s.convert(CGPoint(x: s.bounds.midX, y: s.bounds.midY), to: w)
    }

    func testTheStripTakesNoTouch() async throws {
        let left = pane(), right = pane()
        let divider = try await host(left: left, right: right)
        let w = try XCTUnwrap(window)
        for dx: CGFloat in [-15, 0, 15] {
            let hit = w.hitTest(CGPoint(x: divider.x + dx, y: divider.y), with: nil)
            XCTAssertFalse(hit is HandleStripView, "a touch \(dx) pt from the divider is not the strip's")
        }
        XCTAssertTrue(w.hitTest(CGPoint(x: divider.x - 60, y: divider.y), with: nil)?.isDescendant(of: left) == true)
        XCTAssertTrue(w.hitTest(CGPoint(x: divider.x + 60, y: divider.y), with: nil)?.isDescendant(of: right) == true)
    }

    func testTheStripMarksTheHandlesReachOverBothPanes() async throws {
        let left = pane(), right = pane()
        let divider = try await host(left: left, right: right)
        let l = try XCTUnwrap(strips.strip(at: CGPoint(x: divider.x - 15, y: divider.y), over: left), "over the left pane")
        XCTAssertTrue(l.sideways, "a side-by-side split drags sideways")
        XCTAssertNotNil(strips.strip(at: CGPoint(x: divider.x + 15, y: divider.y), over: right), "over the right pane")
        // Past the handle's reach the pane is the pane's.
        XCTAssertNil(strips.strip(at: CGPoint(x: divider.x - 60, y: divider.y), over: left))
        XCTAssertNil(strips.strip(at: CGPoint(x: divider.x + 60, y: divider.y), over: right))
    }

    func testAStripUnderAPaneIsNotItsBusiness() async throws {
        let left = pane(), right = pane(), float = pane()
        let divider = try await host(left: left, right: right, float: float)
        XCTAssertNotNil(strips.strip(at: CGPoint(x: divider.x - 15, y: divider.y + 120), over: left))
        XCTAssertNil(strips.strip(at: CGPoint(x: divider.x, y: divider.y), over: float),
                     "a floating window over the divider keeps its touches")
    }
}

/// The pane's side, with real terminal hosts: inside a handle's strip the pane's taps and drags
/// wait for its grip, which starts only on a drag across the strip, so that drag is the
/// handle's alone (no tap, no focus, no keyboard). A tap, a double tap, a long press and a drag
/// along the strip stay the pane's, and outside the strips nothing waits.
@MainActor
final class HandleStripHostTests: XCTestCase {
    private var window: UIWindow!
    private var strips: HandleStrips!

    override func setUp() async throws {
        strips = HandleStrips()
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first { window.windowScene = scene }
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
    }

    override func tearDown() async throws {
        window.isHidden = true
        window = nil
        strips = nil
    }

    private var root: UIView { window.rootViewController!.view }

    /// A pane at `origin`. Too small to lay out, so the host never starts its stream.
    private func makeHost(at origin: CGPoint) -> TerminalHost {
        let control = RexControl(address: "", client: ClientInfo(name: "test", version: "0", label: "test"))
        let host = TerminalHost(stream: TerminalStream(control: control, sessionID: "s", blockID: "b"), sizing: .mirror,
                                fontSize: 12, theme: ThemeStore.fallback)
        host.hardwareKeyboard = { false }
        host.frame = CGRect(origin: origin, size: CGSize(width: 10, height: 10))
        host.handleStrips = strips
        root.addSubview(host)
        return host
    }

    /// A handle's strip at `frame`, over everything added before it.
    @discardableResult
    private func makeStrip(_ frame: CGRect, sideways: Bool = true, shape: AnyShape? = nil, below: Bool = false) -> HandleStripView {
        let v = HandleStripView()
        v.frame = frame
        v.sideways = sideways
        v.shape = shape
        if below { root.insertSubview(v, at: 0) } else { root.addSubview(v) }
        v.strips = strips
        return v
    }

    /// The pane's recognizers that matter here.
    private func recognizers(_ h: TerminalHost) -> (tap: UIGestureRecognizer, scroll: UIGestureRecognizer, press: UIGestureRecognizer) {
        (h.tapGR, h.term.scrollPanRecognizer, h.term.selectionPress)
    }

    private func waits(_ h: TerminalHost, _ other: UIGestureRecognizer) -> Bool {
        h.gestureRecognizer(h.gripPan, shouldBeRequiredToFailBy: other)
    }

    func testInTheStripTheTapAndScrollWaitForTheGrip() {
        let a = makeHost(at: CGPoint(x: 0, y: 0)), b = makeHost(at: CGPoint(x: 20, y: 0))
        makeStrip(CGRect(x: 5, y: 0, width: 20, height: 10))
        for (host, point) in [(a, CGPoint(x: 8, y: 5)), (b, CGPoint(x: 22, y: 5))] {
            XCTAssertNotNil(host.noteGripTouch(at: point), "the touch starts in the strip")
            let r = recognizers(host)
            XCTAssertTrue(waits(host, r.tap), "a drag across the strip is no tap: no focus, no keyboard")
            XCTAssertTrue(waits(host, r.scroll), "and no scroll")
            // A long press never waits: a held finger doesn't start the grip.
            XCTAssertFalse(waits(host, r.press), "long-press select stays the pane's")
            XCTAssertFalse(host.gestureRecognizer(host.gripPan, shouldRecognizeSimultaneouslyWith: r.tap))
        }
    }

    func testOutsideTheStripsNothingWaits() {
        let a = makeHost(at: CGPoint(x: 0, y: 0))
        makeStrip(CGRect(x: 5, y: 0, width: 20, height: 10))
        XCTAssertNil(a.noteGripTouch(at: CGPoint(x: 2, y: 5)))
        let r = recognizers(a)
        XCTAssertFalse(waits(a, r.tap))
        XCTAssertFalse(waits(a, r.scroll), "a scroll that starts outside the strip scrolls at once")
        // A pane without strips (outside the app's layout) is as before.
        let c = makeHost(at: CGPoint(x: 100, y: 0))
        c.handleStrips = nil
        XCTAssertNil(c.noteGripTouch(at: CGPoint(x: 102, y: 5)))
        XCTAssertFalse(waits(c, c.tapGR))
    }

    func testOnlyADragAcrossTheStripIsTheHandles() {
        // A finger that hasn't moved (a tap, each tap of a double tap, a long press) never
        // starts the grip, so the pane's tap fires as soon as the finger lifts.
        XCTAssertFalse(HandleStrips.claims(dx: 0, dy: 0, sideways: true))
        XCTAssertFalse(HandleStrips.claims(dx: 0, dy: 0, sideways: false))
        // Side by side: sideways is the handle's, up and down is the pane's scroll.
        XCTAssertTrue(HandleStrips.claims(dx: 12, dy: 3, sideways: true))
        XCTAssertFalse(HandleStrips.claims(dx: 3, dy: 12, sideways: true))
        // Stacked: the other way round.
        XCTAssertTrue(HandleStrips.claims(dx: -2, dy: -14, sideways: false))
        XCTAssertFalse(HandleStrips.claims(dx: 14, dy: 2, sideways: false))
    }

    func testTheGripRunsBesideTheHandlesOwnDrag() {
        let a = makeHost(at: CGPoint(x: 0, y: 0))
        // The handle's drag lives outside the pane (SwiftUI's, on the hosting view).
        let handleDrag = UIPanGestureRecognizer()
        root.addGestureRecognizer(handleDrag)
        XCTAssertTrue(a.gestureRecognizer(a.gripPan, shouldRecognizeSimultaneouslyWith: handleDrag),
                      "the grip never stops the resize itself")
        XCTAssertFalse(waits(a, handleDrag))
    }

    func testAStripUnderThePaneIsNotItsBusiness() {
        let a = makeHost(at: CGPoint(x: 0, y: 0))
        makeStrip(CGRect(x: 5, y: 0, width: 20, height: 10), below: true)
        XCTAssertNil(a.noteGripTouch(at: CGPoint(x: 8, y: 5)), "a strip drawn under the pane")
        XCTAssertFalse(waits(a, a.tapGR))
    }

    func testTheSidebarHandleOverTheTabsLeftPane() {
        // The sidebar's edge at x = 0, its handle reaching 22 pt either side: a 16 pt strip
        // along the edge (10 pt over the tab) and the 88 pt grip in the middle.
        // The tab first, then the sidebar's handle over it, as `SidebarSplit` draws them.
        let byGrip = makeHost(at: CGPoint(x: 0, y: 95))
        let byEdge = makeHost(at: CGPoint(x: 0, y: 5))
        let shape = AnyShape(HandleShape(reach: 22, grip: 88))
        let strip = makeStrip(CGRect(x: -22, y: 0, width: 44, height: 200), sideways: true, shape: shape)
        // In the grip, 15 pt into the pane: a sideways drag resizes the sidebar and doesn't focus the pane.
        XCTAssertTrue(byGrip.noteGripTouch(at: CGPoint(x: 15, y: 100)) === strip)
        XCTAssertTrue(waits(byGrip, byGrip.tapGR), "a drag on the sidebar's handle doesn't focus the tab's left pane")
        XCTAssertTrue(waits(byGrip, byGrip.term.scrollPanRecognizer))
        // On the edge strip, within 10 pt of the edge.
        XCTAssertTrue(byEdge.noteGripTouch(at: CGPoint(x: 8, y: 10)) === strip)
        // Past the edge strip and away from the grip, the pane has its touches.
        XCTAssertNil(byEdge.noteGripTouch(at: CGPoint(x: 12, y: 10)))
        XCTAssertFalse(waits(byEdge, byEdge.tapGR))
    }
}
