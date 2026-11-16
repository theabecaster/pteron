import XCTest
@testable import RexConnect

/// The Ghostty engine's input, scrolling and selection working as one: what one part does to
/// another, as TerminalHost, the key bar and the hardware keymap drive them through the seam.
@MainActor
final class GhosttyIntegrationTests: XCTestCase {
    private final class Sink: TerminalEngineDelegate {
        var sent: [[UInt8]] = []
        func engineGridChanged(cols: Int, rows: Int) {}
        func engineSend(_ bytes: [UInt8]) { sent.append(bytes) }
    }

    private func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

    /// A view with its grid filling its bounds, `count` lines printed and one frame's state applied.
    private func make(_ count: Int, cols: Int = 40, rows: Int = 10, setup: String = "") -> (GhosttyTerminalView, Sink) {
        let view = GhosttyTerminalView(frame: .zero, fontSize: 12, cols: cols, rows: rows)
        let cell = view.cellSize
        view.frame = CGRect(x: 0, y: 0, width: CGFloat(cols) * cell.width, height: CGFloat(rows) * cell.height)
        view.layoutIfNeeded()
        let sink = Sink()
        view.engineDelegate = sink
        if count > 0 { view.feed(text: (1...count).map { "\($0) line\r\n" }.joined()) }
        view.feed(text: setup)
        frame(view)
        return (view, sink)
    }

    /// Runs one frame the way the render thread would, and hands its state to the scroller.
    private func frame(_ view: GhosttyTerminalView) {
        view.core.sync()
        _ = view.renderer.frame.update(core: view.core)
        view.scroller.apply(view.core.scroll.snapshot)
    }

    private func scrollUp(_ view: GhosttyTerminalView, to row: CGFloat = 20) {
        view.scroller.setOffset(row * view.cellSize.height, animated: false)
        frame(view)
        XCTAssertFalse(view.core.scroll.snapshot.active)
    }

    // MARK: Input returns a scrolled-back view to the bottom

    /// Everything SwiftTerm's `send(data:)` carries jumps to the bottom there (`ensureCaretIsVisible`):
    /// typed text, Backspace, the key bar's keys and raw bytes, `send(txt:)`, a paste, hardware keys.
    func testEveryKindOfInputJumpsToTheBottomThroughTheScroller() {
        let inputs: [(String, (GhosttyTerminalView) -> Void)] = [
            ("insertText", { $0.insertText("a") }),
            ("return", { $0.insertText("\n") }),
            ("deleteBackward", { $0.deleteBackward() }),
            ("key bar arrow", { $0.sendKeyUp() }),
            ("key bar home", { $0.sendKeyHome() }),
            ("key bar bytes", { $0.send(data: [0x1b][...]) }),
            ("send(txt:)", { $0.send(txt: "ls\r") }),
            ("paste", { $0.pasteText("pasted") }),
            ("hardware arrow", { _ = $0.hardwareKeyDown(usage: 82, flags: [], characters: "UIKeyInputUpArrow", charactersIgnoringModifiers: "UIKeyInputUpArrow") }),
            ("hardware ctrl+c", { _ = $0.hardwareKeyDown(usage: 6, flags: .control, characters: "\u{3}", charactersIgnoringModifiers: "c") }),
        ]
        for (name, input) in inputs {
            let (view, sink) = make(100)
            scrollUp(view)
            let calls = view.core.scroll.viewportCalls
            input(view)
            XCTAssertEqual(sink.sent.count, 1, name)
            frame(view)
            let s = view.core.scroll.snapshot
            XCTAssertTrue(s.active, "\(name) returns to the bottom")
            XCTAssertEqual(view.core.scroll.viewportCalls, calls + 1, "\(name): one scroll, made by the scroll state in the frame")
            XCTAssertEqual(view.scroller.surface.contentOffset.y, CGFloat(s.maxRow) * view.cellSize.height, accuracy: 0.01,
                           "\(name): the scroll surface is at the bottom too")
            view.hardwareKeyUp(usage: 82)
            view.hardwareKeyUp(usage: 6)
        }
    }

    func testInputAtTheBottomAsksForNoScroll() {
        let (view, _) = make(100)
        let calls = view.core.scroll.viewportCalls
        XCTAssertFalse(view.core.scroll.hasPending)
        view.insertText("a")
        view.pasteText("b")
        view.sendKeyUp()
        XCTAssertFalse(view.core.scroll.hasPending, "nothing to do at the bottom: typing costs the render thread nothing")
        frame(view)
        XCTAssertEqual(view.core.scroll.viewportCalls, calls)
    }

    /// SwiftTerm sends mouse and focus reports without `ensureCaretIsVisible`: the view stays.
    func testMouseAndFocusReportsLeaveAScrolledUpViewWhereItIs() throws {
        let (view, sink) = make(100, setup: "\u{1b}[?1003h\u{1b}[?1006h\u{1b}[?1004h")
        let cell = view.cellSize
        view.scroller.jump(.lines(-4))
        frame(view)
        XCTAssertFalse(view.core.scroll.snapshot.active)
        // On a row of the live screen (the top four rows show scrollback).
        let point = CGPoint(x: cell.width * 2.5, y: cell.height * 6.5)
        XCTAssertFalse(view.scroller.forwardTap(at: point).isEmpty)
        var accumulator = GhosttyWheelAccumulator()
        XCTAssertFalse(view.scroller.forwardWheel(distance: cell.height * 2, at: point, accumulator: &accumulator).isEmpty)
        XCTAssertFalse(view.scroller.forwardMotion(at: CGPoint(x: cell.width * 8.5, y: cell.height * 7.5), buttonHeld: false).isEmpty)
        XCTAssertEqual(sink.sent.count, 3)
        XCTAssertFalse(view.core.scroll.hasPending)
        frame(view)
        XCTAssertFalse(view.core.scroll.snapshot.active, "mouse reports are not typing")

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first { window.windowScene = scene }
        window.isHidden = false
        defer { window.isHidden = true }
        window.addSubview(view)
        try XCTSkipUnless(view.becomeFirstResponder(), "the test host gave no first responder")
        XCTAssertEqual(sink.sent.last, bytes("\u{1b}[I"))
        XCTAssertTrue(view.resignFirstResponder())
        XCTAssertEqual(sink.sent.last, bytes("\u{1b}[O"))
        XCTAssertFalse(view.core.scroll.hasPending, "focus reports are not typing either")
        view.removeFromSuperview()
    }

    // MARK: Key-driven scrolling

    /// Hardware Page Up and Page Down go through the seam's `scrollPage`, which moves the scroll
    /// surface with the viewport.
    func testHardwarePageKeysScrollTheSurface() {
        let (view, sink) = make(100)
        let cell = view.cellSize.height
        XCTAssertTrue(view.hardwareKeyDown(usage: 75, flags: [], characters: "UIKeyInputPageUp", charactersIgnoringModifiers: "UIKeyInputPageUp"))
        frame(view)
        XCTAssertEqual(view.core.scroll.snapshot.offset, 81)
        XCTAssertEqual(view.scroller.surface.contentOffset.y, 81 * cell, accuracy: 0.01)
        view.hardwareKeyUp(usage: 75)
        XCTAssertTrue(view.hardwareKeyDown(usage: 78, flags: [], characters: "UIKeyInputPageDown", charactersIgnoringModifiers: "UIKeyInputPageDown"))
        frame(view)
        XCTAssertTrue(view.core.scroll.snapshot.active)
        XCTAssertEqual(view.scroller.surface.contentOffset.y, 91 * cell, accuracy: 0.01)
        XCTAssertEqual(sink.sent, [], "the program hears nothing of a local scroll")
        view.hardwareKeyUp(usage: 78)

        // On an alternate screen the program gets the key (there is nothing to scroll), encoded
        // under its modes.
        view.feed(text: "\u{1b}[?1049h")
        frame(view)
        view.scrollPage(up: true)
        XCTAssertEqual(sink.sent, [bytes("\u{1b}[5~")])
        view.feed(text: "\u{1b}[>1u")
        frame(view)
        view.scrollPage(up: false)
        XCTAssertEqual(sink.sent.last, bytes("\u{1b}[6~"), "Kitty disambiguate leaves Page Down as it is")
    }

    func testScrollToPromptMovesTheSurfaceBetweenShellPrompts() {
        let (view, _) = make(0)
        var text = ""
        for i in 1...6 {
            text += "\u{1b}]133;A\u{7}prompt\(i)$ \u{1b}]133;B\u{7}cmd\r\n\u{1b}]133;C\u{7}"
            text += (1...12).map { "out \(i).\($0)\r\n" }.joined()
            text += "\u{1b}]133;D\u{7}"
        }
        view.feed(text: text)
        frame(view)
        XCTAssertTrue(view.core.scroll.snapshot.active)
        let cell = view.cellSize.height
        view.scrollToPrompt(next: false)
        frame(view)
        let first = view.core.scroll.snapshot
        XCTAssertFalse(first.active)
        XCTAssertTrue(view.core.rowText(0).hasPrefix("prompt"), "a prompt row is at the top: \(view.core.rowText(0))")
        XCTAssertEqual(view.scroller.surface.contentOffset.y, CGFloat(first.offset) * cell, accuracy: 0.01)
        view.scrollToPrompt(next: false)
        frame(view)
        let second = view.core.scroll.snapshot
        XCTAssertLessThan(second.offset, first.offset)
        XCTAssertTrue(view.core.rowText(0).hasPrefix("prompt"))
        view.scrollToPrompt(next: true)
        frame(view)
        XCTAssertEqual(view.core.scroll.snapshot.offset, first.offset)
        XCTAssertEqual(view.scroller.surface.contentOffset.y, CGFloat(first.offset) * cell, accuracy: 0.01)
    }

    // MARK: Gestures, as TerminalHost arbitrates them

    /// Every pan the engine has asks `panGate`, where the host refuses pans while it selects;
    /// that includes the host's own pointer-drag pan, which sits on the engine view.
    func testEveryPanOfTheEngineAsksThePanGate() {
        let (view, _) = make(100, setup: "\u{1b}[?1000h")
        let scroller = view.scroller
        let hostPan = UIPanGestureRecognizer()
        view.addGestureRecognizer(hostPan)
        var asked: [UIPanGestureRecognizer] = []
        view.panGate = { asked.append($0); return false }
        XCTAssertFalse(view.gestureRecognizerShouldBegin(hostPan))
        XCTAssertFalse(scroller.surface.gestureRecognizerShouldBegin(scroller.surface.panGestureRecognizer))
        XCTAssertFalse(scroller.surface.gestureRecognizerShouldBegin(scroller.programPan))
        for scroll in scroller.pointerScrolls { XCTAssertFalse(scroller.surface.gestureRecognizerShouldBegin(scroll)) }
        XCTAssertEqual(asked.count, 5)
        XCTAssertTrue(asked.contains { $0 === hostPan })
        // Recognizers that aren't the view's own are not its business.
        let foreign = UIPanGestureRecognizer()
        UIView().addGestureRecognizer(foreign)
        XCTAssertTrue(view.gestureRecognizerShouldBegin(foreign))
        XCTAssertEqual(asked.count, 5)
        view.panGate = { _ in true }
        XCTAssertTrue(view.gestureRecognizerShouldBegin(hostPan))
        // None of the engine's pans selects.
        for pan in [scroller.surface.panGestureRecognizer, scroller.programPan] + scroller.pointerScrolls {
            XCTAssertFalse(view.isBuiltInSelectionPan(pan))
        }
    }

    /// What the host relies on when it sets up its gestures (`TerminalHost.setupGestures`).
    func testTheEnginesRecognizersAreTheShapeTheHostExpects() {
        let (view, _) = make(10)
        let scroller = view.scroller
        let direct = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        // The host limits the scroll pan to fingers; the wheel-drag pan is already.
        view.scrollPanRecognizer?.allowedTouchTypes = direct
        XCTAssertEqual(scroller.programPan.allowedTouchTypes, direct, "a mouse drag selects; it never reports a wheel")
        XCTAssertEqual(scroller.programPan.maximumNumberOfTouches, 1)
        // The host lets through, unasked, pans without touches (trackpad and wheel scrolls).
        XCTAssertTrue(scroller.pointerScrolls.allSatisfy { $0.allowedTouchTypes.isEmpty })
        // The long press is on the view, with no target until the host gives it one.
        XCTAssertTrue(view.selectionPressRecognizer?.view === view)
        XCTAssertTrue(scroller.tap.view === scroller.surface)
    }

    /// With mouse tracking on, a long press still selects (the host's rule for both engines):
    /// the engine's tap doesn't fire for the lifted press, and no click is sent.
    func testALiftedLongPressIsNotAClickForATrackingProgram() {
        let (view, sink) = make(5, setup: "\u{1b}[?1000h\u{1b}[?1006h")
        XCTAssertTrue(view.scroller.shouldBegin(view.scroller.tap))
        view.beginSelection(at: CGPoint(x: view.cellSize.width * 0.5, y: view.cellSize.height * 0.5), word: true)
        view.endSelectionDrag()
        XCTAssertEqual(view.selectedText, "1")
        XCTAssertEqual(sink.sent, [], "selecting sends the program nothing")
    }

    // MARK: Cursor

    /// Solid with the keyboard, hollow without it or off screen (SwiftTerm's caret follows the
    /// first responder the same way).
    func testTheCursorIsSolidOnlyWhileTheViewIsFirstResponderInAWindow() throws {
        let view = GhosttyTerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 240), fontSize: 12, cols: 40, rows: 10)
        let renderer = view.renderer
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first { window.windowScene = scene }
        window.isHidden = false
        defer {
            view.removeFromSuperview()
            window.isHidden = true
        }
        window.addSubview(view)
        XCTAssertFalse(renderer.isFocused, "in a window, not first responder: hollow")
        try XCTSkipUnless(view.becomeFirstResponder(), "the test host gave no first responder")
        XCTAssertTrue(renderer.isFocused)
        XCTAssertTrue(view.resignFirstResponder())
        XCTAssertFalse(renderer.isFocused)
        XCTAssertTrue(view.becomeFirstResponder())
        XCTAssertTrue(renderer.isFocused)
        // Leaving the window gives up the keyboard, and with it the solid cursor.
        view.removeFromSuperview()
        XCTAssertFalse(renderer.isFocused)
        XCTAssertFalse(view.isFirstResponder)
    }

    /// The blink timer exists only while `wantsBlink` is true for some pane: the terminal asked
    /// for a blinking cursor, it is visible, and the pane is on screen with the keyboard.
    func testTheCursorBlinksOnlyWhenTheTerminalSaysSoAndThePaneIsFocusedAndVisible() {
        let (view, _) = make(3)
        let renderer = view.renderer
        // Not in a window, so no thread draws this renderer: the test runs its frames.
        renderer.setVisible(true)
        renderer.setFocused(true)
        frame(view)
        XCTAssertFalse(renderer.wantsBlink, "a steady cursor never starts the blink timer")
        view.feed(text: "\u{1b}[1 q")  // DECSCUSR: blinking block
        frame(view)
        XCTAssertTrue(renderer.wantsBlink)
        renderer.setFocused(false)
        XCTAssertFalse(renderer.wantsBlink, "an unfocused pane doesn't blink")
        renderer.setFocused(true)
        renderer.setVisible(false)
        XCTAssertFalse(renderer.wantsBlink, "nor does one that is off screen or in the background")
        renderer.setVisible(true)
        XCTAssertTrue(renderer.wantsBlink)
        view.feed(text: "\u{1b}[2 q")  // steady block
        frame(view)
        XCTAssertFalse(renderer.wantsBlink)
        view.feed(text: "\u{1b}[1 q\u{1b}[?25l")  // blinking, but hidden
        frame(view)
        XCTAssertFalse(renderer.wantsBlink)
        // Scrolled away from the cursor: nothing to blink.
        view.feed(text: "\u{1b}[?25h" + (1...60).map { "\($0)\r\n" }.joined())
        frame(view)
        XCTAssertTrue(renderer.wantsBlink)
        view.scroller.jump(.top)
        frame(view)
        XCTAssertFalse(renderer.wantsBlink)
    }
}
