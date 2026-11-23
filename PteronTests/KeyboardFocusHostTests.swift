import RexKit
import XCTest
@testable import Pteron

/// Who has the keyboard, with real hosts in a window: at most one terminal is first responder,
/// and it is the active pane's.
@MainActor
final class KeyboardFocusHostTests: XCTestCase {
    private var window: UIWindow!
    private var hardware = true

    override func setUp() async throws {
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first { window.windowScene = scene }
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        try XCTSkipUnless(UIApplication.shared.applicationState == .active, "the test host is not in the foreground")
    }

    override func tearDown() async throws {
        window.isHidden = true
        window = nil
    }

    private func makeHost() -> TerminalHost {
        let control = RexControl(address: "", client: ClientInfo(name: "test", version: "0", label: "test"))
        let host = TerminalHost(stream: TerminalStream(control: control, sessionID: "s", blockID: "b"), sizing: .mirror,
                                fontSize: 12, theme: ThemeStore.fallback)
        host.hardwareKeyboard = { [unowned self] in self.hardware }
        // Too small to lay out, so the host never starts its stream.
        host.frame = CGRect(x: 0, y: 0, width: 10, height: 10)
        window.rootViewController?.view.addSubview(host)
        return host
    }

    /// Lets the hosts' hops to the main queue run (two deep for a pane that gives up the keyboard).
    private func settle() async {
        for _ in 0..<4 {
            await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
        }
    }

    /// The first responders among the hosts' terminals.
    private func holders(_ hosts: [TerminalHost]) -> [Int] {
        hosts.indices.filter { hosts[$0].term.isFirstResponder }
    }

    func testTheReviewedDefect() async throws {
        // Split layout; the hide key on pane B; tap pane A; the pane.focus shortcut to B.
        // B showed as active but the keys still went to A.
        let a = makeHost(), b = makeHost()
        b.isActive = true
        await settle()
        try XCTSkipUnless(b.term.isFirstResponder, "the test host gave no first responder")
        b.hideKeyboard()
        XCTAssertTrue(b.userHidKeyboard)

        // Tap A (keyboard not up there): it focuses and becomes the active pane.
        XCTAssertEqual(a.tap(at: CGPoint(x: 2, y: 2), shift: false, keyboardUp: false, hadSelection: false), .focus(clearsSelection: false))
        b.isActive = false
        a.isActive = true
        await settle()
        XCTAssertEqual(holders([a, b]), [0])

        // The shortcut makes B active again.
        a.isActive = false
        b.isActive = true
        await settle()
        XCTAssertEqual(holders([a, b]), [1], "the keyboard follows the active pane, hidden there or not")
        // And the software keyboard stays hidden on B: no key bar, an empty input view.
        XCTAssertTrue(b.keyboardQuiet)
        XCTAssertNil(b.term.inputAccessoryView)
        XCTAssertNotNil(b.term.inputView)
        XCTAssertTrue(b.userHidKeyboard)

        // A tap on B shows it again.
        _ = b.tap(at: CGPoint(x: 2, y: 2), shift: false, keyboardUp: false, hadSelection: false)
        XCTAssertFalse(b.keyboardQuiet)
        XCTAssertNotNil(b.term.inputAccessoryView)
        XCTAssertNil(b.term.inputView)
        XCTAssertFalse(b.userHidKeyboard)
        XCTAssertTrue(b.term.isFirstResponder)
    }

    func testAtMostOneTerminalHoldsTheKeyboardAndItIsTheActivePanes() async throws {
        let hosts = [makeHost(), makeHost(), makeHost()]
        hosts[0].isActive = true
        await settle()
        try XCTSkipUnless(hosts[0].term.isFirstResponder, "the test host gave no first responder")
        // Every order SwiftUI may apply a pane switch in: the old pane first, or the new one.
        let switches: [(from: Int, to: Int, oldFirst: Bool)] = [(0, 1, true), (1, 2, false), (2, 0, true), (0, 2, false), (2, 1, true)]
        for s in switches {
            if s.oldFirst {
                hosts[s.from].isActive = false
                hosts[s.to].isActive = true
            } else {
                hosts[s.to].isActive = true
                hosts[s.from].isActive = false
            }
            await settle()
            XCTAssertEqual(holders(hosts), [s.to], "\(s)")
        }
    }

    func testAPaneThatStopsBeingActiveGivesTheKeyboardUpEvenWhenNoPaneTakesIt() async throws {
        let a = makeHost(), b = makeHost()
        a.isActive = true
        await settle()
        try XCTSkipUnless(a.term.isFirstResponder, "the test host gave no first responder")
        // B becomes active while it is off screen (its tab isn't shown): it can't take the keyboard.
        b.removeFromSuperview()
        a.isActive = false
        b.isActive = true
        await settle()
        XCTAssertEqual(holders([a, b]), [], "the pane that was left must not keep typing")
    }

    func testTheHideKeyWithAHardwareKeyboardKeepsTheKeysAndHidesTheBar() async throws {
        let a = makeHost()
        a.isActive = true
        await settle()
        try XCTSkipUnless(a.term.isFirstResponder, "the test host gave no first responder")
        XCTAssertNotNil(a.term.inputAccessoryView)
        a.hideKeyboard()
        XCTAssertTrue(a.term.isFirstResponder, "a hardware keyboard still types into the active pane")
        XCTAssertTrue(a.keyboardQuiet)
        XCTAssertNil(a.term.inputAccessoryView)

        // Whatever frees the keyboard later (the app active again, a keyboard connecting) never
        // brings the software keyboard back.
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        await settle()
        XCTAssertTrue(a.keyboardQuiet)
        XCTAssertTrue(a.term.isFirstResponder)
    }

    func testTheHideKeyWithoutAHardwareKeyboardResignsAndStaysDown() async throws {
        hardware = false
        let a = makeHost()
        a.isActive = true
        a.focusKeyboard()
        try XCTSkipUnless(a.term.isFirstResponder, "the test host gave no first responder")
        a.hideKeyboard()
        XCTAssertFalse(a.term.isFirstResponder)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        await settle()
        XCTAssertFalse(a.term.isFirstResponder, "nothing brings a hidden keyboard back but a tap")

        // A hardware keyboard connects: its keys go to the active pane, and still nothing shows.
        hardware = true
        NotificationCenter.default.post(name: .GCKeyboardDidConnect, object: nil)
        await settle()
        XCTAssertTrue(a.term.isFirstResponder)
        XCTAssertTrue(a.keyboardQuiet)
        XCTAssertNil(a.term.inputAccessoryView)
    }

    func testACoveredPaneGivesUpTheKeyboardAndTakesItBack() async throws {
        hardware = false
        let a = makeHost()
        a.isActive = true
        a.focusKeyboard()
        try XCTSkipUnless(a.term.isFirstResponder, "the test host gave no first responder")

        // A sheet, an alert or a menu went up over the pane (UIKit dims its tint).
        a.coverChanged(covered: true)
        XCTAssertFalse(a.term.isFirstResponder, "nothing types into a pane behind a sheet")
        await settle()
        XCTAssertFalse(a.term.isFirstResponder)

        // The cover goes: the pane has the keyboard again, without a hardware keyboard too.
        a.coverChanged(covered: false)
        await settle()
        XCTAssertTrue(a.term.isFirstResponder)

        // A pane that had no keyboard takes none when a cover goes.
        let b = makeHost()
        b.coverChanged(covered: true)
        b.coverChanged(covered: false)
        await settle()
        XCTAssertFalse(b.term.isFirstResponder)
    }

    func testTheTintDimmingOfASheetIsWhatCoversAPane() async throws {
        let a = makeHost()
        a.isActive = true
        await settle()
        try XCTSkipUnless(a.term.isFirstResponder, "the test host gave no first responder")
        // What UIKit does to the views under a presentation.
        let root = try XCTUnwrap(window.rootViewController?.view)
        root.tintAdjustmentMode = .dimmed
        XCTAssertEqual(a.tintAdjustmentMode, .dimmed)
        XCTAssertFalse(a.term.isFirstResponder)
        root.tintAdjustmentMode = .automatic
        await settle()
        XCTAssertTrue(a.term.isFirstResponder)
    }
}
