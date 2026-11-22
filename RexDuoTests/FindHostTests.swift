import RexKit
import XCTest
@testable import RexDuo

/// Find in real hosts in a window: who holds the keyboard, and that nothing find does resizes the
/// pane on the Mac (a FitClaim spy with a forced layout between steps).
@MainActor
final class FindHostTests: XCTestCase {
    private var window: UIWindow!
    private var hardware = true
    private var panes = PaneBaseline()

    private final class Transport: FitClaimTransport {
        var calls: [String] = []
        var resizes: [String] { calls.filter { $0.hasPrefix("resize") } }
        func own() async -> FitClaimAnswer { calls.append("own"); return .done }
        func resize(cols: Int, rows: Int) async -> FitClaimAnswer { calls.append("resize \(cols)x\(rows)"); return .done }
        func disown() async { calls.append("disown") }
        func whenConnected(_ body: @escaping @MainActor () -> Void) {}
    }

    override func setUp() async throws {
        panes = PaneBaseline()
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 700))
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first { window.windowScene = scene }
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        try XCTSkipUnless(UIApplication.shared.applicationState == .active, "the test host is not in the foreground")
    }

    override func tearDown() async throws {
        UIResponder.rexCurrentFirstResponder()?.resignFirstResponder()
        // UIKit keeps the last responder whose input views it showed until another takes the
        // keyboard: hand it to a throwaway field and let go, so the hosts can go.
        let scratch = UITextField()
        window.addSubview(scratch)
        scratch.becomeFirstResponder()
        scratch.resignFirstResponder()
        scratch.removeFromSuperview()
        for v in window.rootViewController?.view.subviews ?? [] {
            (v as? TerminalHost)?.stop()
            v.removeFromSuperview()
        }
        window.isHidden = true
        window = nil
        // Let the hosts go before the next test class counts the render thread's panes.
        let gone = await panes.cleared()
        XCTAssertTrue(gone, "LEAKCHECK \(name): \(panes.left) panes left")
    }

    private func settle(_ turns: Int = 6) async {
        for _ in 0..<turns {
            await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
        }
    }

    /// Waits up to `seconds` for `condition`, a main-queue turn at a time.
    private func eventually(_ seconds: Double = 2, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    private func makeHost(sizing: SizingMode = .mirror, claim: FitClaim? = nil, small: Bool = true) -> TerminalHost {
        let control = RexControl(address: "", client: ClientInfo(name: "test", version: "0", label: "test"))
        let host = TerminalHost(stream: TerminalStream(control: control, sessionID: "s", blockID: "b"), sizing: sizing,
                                fontSize: 12, theme: ThemeStore.fallback, claim: claim)
        host.hardwareKeyboard = { [unowned self] in self.hardware }
        host.keymap = KeymapStore(control: control)
        host.frame = small ? CGRect(x: 0, y: 0, width: 10, height: 10) : CGRect(x: 0, y: 0, width: 360, height: 500)
        window.rootViewController?.view.addSubview(host)
        return host
    }

    /// Forces a layout of the host, as one during a keyboard animation would.
    private func forceLayout(_ host: TerminalHost) {
        host.setNeedsLayout()
        host.layoutIfNeeded()
    }

    // MARK: Memory

    func testANewPaneHasNoFindAndClosingFreesWhatOpeningMade() async throws {
        let host = makeHost()
        XCTAssertNil(host.finder)
        XCTAssertNil(host.term.core.find)
        XCTAssertFalse(host.term.renderer.hasHighlightBuffers)
        host.term.feed(text: "an error here\r\n")
        host.openFind(text: "error", focus: false)
        let find = try XCTUnwrap(host.term.core.find)
        let made = await eventually { find.hasHandle && host.term.findResult.total == 1 }
        XCTAssertTrue(made)
        host.closeFind()
        let freed = await eventually { !find.hasHandle && !host.term.findResult.open }
        XCTAssertTrue(freed)
        XCTAssertFalse(host.findOpen)
    }

    func testStoppingThePaneClosesFind() async {
        let host = makeHost()
        host.openFind(text: "x", focus: false)
        host.stop()
        XCTAssertFalse(host.findOpen)
        let freed = await eventually { host.term.core.find?.hasHandle == false }
        XCTAssertTrue(freed)
    }

    // MARK: Keys

    func testWithFindClosedNextAndPreviousDoNothing() async {
        let host = makeHost()
        host.performFind(.next)
        host.performFind(.previous)
        await settle()
        XCTAssertNil(host.finder, "nothing made")
        XCTAssertNil(host.term.core.find)
    }

    func testWhileTheOverlayFieldEditsTheKeyCommandsAreTheAllowlist() async throws {
        let host = makeHost()
        host.isActive = true
        await settle()
        try XCTSkipUnless(host.term.isFirstResponder, "the test host gave no first responder")
        let before = Set((host.keyCommands ?? []).compactMap { $0.propertyList as? String })
        XCTAssertTrue(before.contains("edit:paste"))
        XCTAssertTrue(before.contains("cmd+backspace"), "⌘⌫ sends ctrl-u to the shell")
        // Quiet (path C): the field in the pane takes the keyboard.
        host.hideKeyboard()
        host.performFind(.open)
        let editing = await eventually { host.findFieldHoldingKeyboard == .overlay }
        XCTAssertTrue(editing)
        let during = Set((host.keyCommands ?? []).compactMap { $0.propertyList as? String })
        XCTAssertFalse(during.contains("edit:paste"), "⌘V is the field's")
        XCTAssertFalse(during.contains("edit:copy"))
        XCTAssertFalse(during.contains("cmd+backspace"))
        XCTAssertFalse(during.contains("shift+cmd+right"), "⇧⌘→ selects in the field, it splits no pane")
        XCTAssertTrue(during.contains("cmd+t"), "app commands stay")
        XCTAssertTrue(during.contains("cmd+g"), "find keys stay")
        XCTAssertTrue(during.contains("cmd+w"))
        // ⌘F while the field edits selects its text.
        let field = try XCTUnwrap(host.finder?.overlay.content.field)
        field.text = "abc"
        field.selectedTextRange = field.textRange(from: field.endOfDocument, to: field.endOfDocument)
        host.performFind(.open)
        XCTAssertEqual(field.offset(from: field.beginningOfDocument, to: field.selectedTextRange!.start), 0)
        XCTAssertEqual(field.offset(from: field.beginningOfDocument, to: field.selectedTextRange!.end), 3)
        // Escape with text: back to the terminal, quietly as before; the bar stays.
        host.findFieldEscape(field)
        XCTAssertTrue(host.term.isFirstResponder)
        XCTAssertTrue(host.keyboardQuiet)
        XCTAssertTrue(host.findOpen)
        XCTAssertFalse(host.finder!.overlay.isHidden)
        let after = Set((host.keyCommands ?? []).compactMap { $0.propertyList as? String })
        XCTAssertEqual(after, before, "the terminal's keys are back")
        // Escape on an empty field closes.
        field.text = ""
        host.performFind(.open)
        _ = await eventually { host.findFieldHoldingKeyboard != nil }
        host.findFieldEscape(field)
        XCTAssertFalse(host.findOpen)
    }

    // MARK: No resize

    /// Every path, every step: open, type, Escape, focus the field again, Done, with a layout
    /// forced between them. Fit mode on a pane that already has its size never sends another.
    func testNothingFindDoesResizesThePane() async throws {
        for alternate in [false, true] {
            for path in ["shown", "quiet", "none-hardware", "none-software"] {
                let transport = Transport()
                let host = makeHost(sizing: .fit, claim: FitClaim(transport: transport, settle: {}), small: false)
                hardware = path != "none-software"
                if alternate { host.term.feed(text: "\u{1b}[?1049h") }
                host.layoutIfNeeded()
                await settle(10)
                let start = transport.resizes.count
                XCTAssertLessThanOrEqual(start, 1)
                host.isActive = true
                await settle()
                switch path {
                case "quiet": host.hideKeyboard()
                case "none-hardware", "none-software": _ = host.term.resignFirstResponder()
                default: host.focusKeyboard()
                }
                await settle()
                let steps: [(String, () -> Void)] = [
                    ("open", { host.performFind(.open) }),
                    ("type", { host.findBar(host.finder!.overlay.content, changed: "error", committed: true) }),
                    ("escape", {
                        if let place = host.findFieldHoldingKeyboard {
                            let field = place == .accessory ? host.finder!.accessory.content.field : host.finder!.overlay.content.field
                            field.text = "error"
                            host.findFieldEscape(field)
                        }
                    }),
                    ("focus", { _ = host.findBarShouldEdit(host.finder!.overlay.content) }),
                    ("done", { host.findBarDone(host.finder!.overlay.content) }),
                ]
                for (name, step) in steps {
                    step()
                    forceLayout(host)
                    await settle(8)
                    forceLayout(host)
                    await settle(8)
                    XCTAssertEqual(transport.resizes.count, start, "\(path) alternate=\(alternate) after \(name): \(transport.calls)")
                }
                XCTAssertNil(host.findHold, "no hold outlives find")
                // A fit pane started its stream: stop it, as a closed pane is.
                host.stop()
                host.removeFromSuperview()
                await settle()
            }
        }
        hardware = true
    }

    /// A request still settling is superseded by the claimed size when a layout finds that size
    /// again, under find's hold as without one (a layout on the way, as a fold passes through): it
    /// never lands later.
    func testUnderTheHoldALayoutReRequestsTheClaimedSizeWhileARequestSettles() async {
        for withHold in [true, false] {
            let transport = Transport()
            var gates: [CheckedContinuation<Void, Never>] = []
            let claim = FitClaim(transport: transport) { await withCheckedContinuation { gates.append($0) } }
            let host = makeHost(sizing: .fit, claim: claim, small: false)
            host.layoutIfNeeded()
            // The first request settles and lands: the pane has its size, on the server too.
            _ = await eventually { !gates.isEmpty }
            gates.removeFirst().resume()
            _ = await eventually { transport.resizes.count == 1 }
            let first = transport.resizes
            guard let wanted = claim.wanted else { return XCTFail("nothing claimed") }
            host.streamResized(cols: wanted.cols, rows: wanted.rows, owner: nil)
            if withHold {
                host.openFind(text: "", focus: false)
                host.finder?.hold = wanted
                host.finder?.holdWidth = host.bounds.width
            }
            // Another size is asked for (a layout mid-animation) and settles slowly.
            claim.request(cols: wanted.cols, rows: wanted.rows - 3)
            _ = await eventually { gates.count == 1 }
            host.relayoutAfterHold()
            host.layoutIfNeeded()
            await settle()
            XCTAssertEqual(gates.count, 2, withHold ? "the held size is asked for again" : "the claimed size is asked for again")
            for g in gates { g.resume() }
            gates = []
            await settle(10)
            XCTAssertEqual(transport.resizes, first, "the settling size never went out")
            host.closeFind(giveBack: false)
            host.stop()
            host.removeFromSuperview()
        }
    }

    func testAFontChangeAndTheWidthEndTheHold() async throws {
        let host = makeHost(sizing: .fit, claim: FitClaim(transport: Transport(), settle: {}), small: false)
        host.layoutIfNeeded()
        await settle(10)
        let f = host.finder ?? {
            host.openFind(text: "", focus: false)
            return host.finder!
        }()
        f.hold = (80, 24)
        f.holdWidth = host.bounds.width
        host.setFontSize(14)
        XCTAssertNil(host.findHold)
        f.hold = (80, 24)
        f.holdWidth = host.bounds.width
        host.frame.size.width -= 40
        host.layoutIfNeeded()
        XCTAssertNil(host.findHold)
        f.hold = (80, 24)
        host.setSizing(.mirror)
        XCTAssertNil(host.findHold)
        f.hold = (80, 24)
        host.closeFind()
        XCTAssertNil(host.findHold)
    }

    /// The hold is taken for a hand-over, but the field never edits (find closes before the bar
    /// shows, or the terminal loses the keyboard first): the hold goes with it.
    func testAHoldWhoseFieldNeverEditsIsReleased() async throws {
        hardware = false
        let transport = Transport()
        let host = makeHost(sizing: .fit, claim: FitClaim(transport: transport, settle: {}), small: false)
        host.layoutIfNeeded()
        await settle(10)
        let resizes = transport.resizes.count
        // Keyboard down, no hardware keyboard (path E): the hold is taken at once.
        host.isActive = true
        await settle()
        _ = host.term.resignFirstResponder()
        host.openFind(text: "", focus: true)
        let held = host.findHold != nil
        // Closed before the bar reached the keyboard's window.
        host.closeFind()
        XCTAssertNil(host.findHold, "closing releases the hold")
        await settle(10)
        XCTAssertNil(host.findFieldHoldingKeyboard, "the cancelled hand-over never ran")
        // Taken again, and the terminal loses the keyboard before the bar shows.
        _ = await eventually(3) { host.finder?.accessory.window == nil }
        host.openFind(text: "", focus: true)
        XCTAssertTrue(host.finder!.accessory.handOverPending, "the bar isn't in the keyboard's window yet")
        _ = host.term.resignFirstResponder()
        XCTAssertNil(host.findHold, "a hand-over that didn't happen releases the hold")
        XCTAssertNil(host.findFieldHoldingKeyboard)
        XCTAssertFalse(host.finder!.accessory.handOverPending)
        XCTAssertTrue(held || !host.fitted, "the hold was taken")
        forceLayout(host)
        await settle(10)
        XCTAssertEqual(transport.resizes.count, resizes, "no new size went out")
        hardware = true
    }

    func testTheDeferralKeepsTheHoldUntilItClearsAndTheFieldDecides() async throws {
        let host = makeHost(sizing: .fit, claim: FitClaim(transport: Transport(), settle: {}), small: false)
        host.openFind(text: "", focus: false)
        let f = try XCTUnwrap(host.finder)
        f.hold = (80, 24)
        FitHoldDeferral.set(true, in: window)
        host.releaseFitHold(deferrable: true)
        XCTAssertNotNil(host.findHold, "a palette over the field keeps the hold")
        XCTAssertTrue(f.releasePending)
        host.releaseFitHold(deferrable: false)
        XCTAssertNil(host.findHold, "a close is never deferred")
        f.hold = (80, 24)
        host.releaseFitHold(deferrable: true)
        FitHoldDeferral.set(false, in: window)
        XCTAssertNil(host.findHold, "cleared with the field not editing: the release runs")
        XCTAssertFalse(FitHoldDeferral.isSet(in: window))
    }

    // MARK: Focus

    func testThePanesOwnFieldKeepsTheKeyboardAndAnotherPaneTakesIt() async throws {
        let a = makeHost(), b = makeHost()
        a.isActive = true
        await settle()
        try XCTSkipUnless(a.term.isFirstResponder, "the test host gave no first responder")
        a.hideKeyboard()
        a.performFind(.open)
        let editing = await eventually { a.findFieldHoldingKeyboard == .overlay }
        XCTAssertTrue(editing)
        // The moments the keyboard may be free don't take it from the pane's own field.
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.post(name: UIWindow.didBecomeKeyNotification, object: nil)
        await settle()
        XCTAssertEqual(a.findFieldHoldingKeyboard, .overlay)
        // B becomes active: it takes the keyboard from A's field; A's bar stays open.
        a.isActive = false
        b.isActive = true
        await settle()
        XCTAssertTrue(b.term.isFirstResponder)
        XCTAssertNil(a.findFieldHoldingKeyboard)
        XCTAssertTrue(a.findOpen)
    }

    func testTheBoardCoversAFieldWithAHardwareKeyboardAndGivesItBack() async throws {
        let host = makeHost()
        host.isActive = true
        await settle()
        try XCTSkipUnless(host.term.isFirstResponder, "the test host gave no first responder")
        host.hideKeyboard()
        host.performFind(.open)
        _ = await eventually { host.findFieldHoldingKeyboard == .overlay }
        host.setCovered(true)
        XCTAssertNil(host.findFieldHoldingKeyboard, "covered, the field takes no key")
        XCTAssertTrue(host.finder!.overlay.isHidden, "no bar over the board")
        host.setCovered(false)
        await settle()
        XCTAssertFalse(host.finder!.overlay.isHidden)
        XCTAssertTrue(host.findOpen)
    }

    // MARK: Menus

    func testTheEditMenuWithoutASelectionIsAsBefore() {
        let host = makeHost()
        let menu = host.editMenuInteraction(UIEditMenuInteraction(delegate: nil),
                                            menuFor: UIEditMenuConfiguration(identifier: nil, sourcePoint: .zero), suggestedActions: [])
        let titles = menu?.children.compactMap { ($0 as? UIAction)?.title } ?? []
        XCTAssertFalse(titles.contains("Find Selection"))
        XCTAssertEqual(titles.last, "Select All")
    }

    func testFindSelectionOffersOnlyAOneRowSelection() async {
        let host = makeHost()
        host.term.feed(text: "hello world\r\nsecond line")
        host.term.core.sync()
        host.term.selectAllText()
        let all = host.editMenuInteraction(UIEditMenuInteraction(delegate: nil),
                                           menuFor: UIEditMenuConfiguration(identifier: nil, sourcePoint: .zero), suggestedActions: [])
        XCTAssertFalse(all?.children.contains { ($0 as? UIAction)?.title == "Find Selection" } ?? true, "two rows: not offered")
    }
}
