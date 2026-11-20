import RexKit
import SwiftUI
import Testing
import UIKit
import XCTest
@testable import RexDuo

/// Lets the item's hop to the main queue run.
@MainActor
private func turns(_ n: Int = 3) async {
    for _ in 0..<n {
        await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
    }
}

/// The vertical bar's Hide Keyboard item (`HideKeyboardItem`): which pane it is for, when that
/// shows, and the keyboard's animation it comes and goes with.
@MainActor
struct HideKeyboardItemTests {
    private let a = TerminalHostPool.Key(server: UUID(), session: "s", block: "a")
    private let b = TerminalHostPool.Key(server: UUID(), session: "s", block: "b")

    @Test func itShowsForThePaneWhoseKeyBarIsUpOneTurnLater() async {
        let item = HideKeyboardItem()
        item.set(a, shown: true)
        #expect(item.pane == nil, "published a turn later, with the keyboard's notification in")
        await turns()
        #expect(item.pane == a)
        item.set(a, shown: false)
        await turns()
        #expect(item.pane == nil)
    }

    @Test func aPaneSwitchInEitherOrderEndsOnTheNewPane() async {
        let item = HideKeyboardItem()
        item.set(a, shown: true)
        await turns()
        // The new pane takes the keyboard first, then the old one says it lost it.
        item.set(b, shown: true)
        item.set(a, shown: false)
        await turns()
        #expect(item.pane == b)
        // The old pane first.
        item.set(b, shown: false)
        item.set(a, shown: true)
        await turns()
        #expect(item.pane == a)
    }

    @Test func aPaneThatNeverHadItTakesNothingAway() async {
        let item = HideKeyboardItem()
        item.set(a, shown: true)
        item.set(b, shown: false)
        await turns()
        #expect(item.pane == a)
    }

    @Test func theBarOrdersItsItemsByTheItem() async {
        // What the tab's toolbar asks `TabActions` for: Hide Keyboard last, below Pane Actions,
        // only for the pane that has the item; All Tabs first again once it goes.
        let item = HideKeyboardItem()
        func bar(_ pane: TerminalHostPool.Key) -> [TabAction] {
            TabActions.verticalBar(zoomed: false, hidesKeyboard: item.pane == pane)
        }
        #expect(bar(a) == [.allTabs, .paneActions])
        item.set(a, shown: true)
        await turns()
        #expect(bar(a) == [.paneActions, .hideKeyboard])
        #expect(bar(b) == [.allTabs, .paneActions], "another pane's bar has no item")
        item.set(a, shown: false)
        await turns()
        #expect(bar(a) == [.allTabs, .paneActions])
    }

    @Test func itMovesWithTheKeyboardsOwnAnimation() {
        // The keyboard's own curve (7) is a spring; the named curves are themselves.
        #expect(HideKeyboardItem.animation(duration: 0.25, curve: 7) == HideKeyboardItem.keyboardSpring)
        #expect(HideKeyboardItem.animation(duration: 0.3, curve: UIView.AnimationCurve.easeInOut.rawValue)
            == .easeInOut(duration: 0.3))
        #expect(HideKeyboardItem.animation(duration: 0.3, curve: UIView.AnimationCurve.linear.rawValue)
            == .linear(duration: 0.3))
        // No duration (a rotation): no animation.
        #expect(HideKeyboardItem.animation(duration: 0, curve: 7) == nil)
    }
}

/// The host's side, with real hosts in a window: the key bar is up with its hide key in the
/// vertical bar exactly while the item shows, there is one Hide Keyboard in every state, and the
/// item hides the keyboard as the key bar's hide key does, with a hardware keyboard too.
@MainActor
final class HideKeyboardItemHostTests: XCTestCase {
    private var window: UIWindow!
    private var hardware = true
    private var pool: TerminalHostPool!
    private let key = TerminalHostPool.Key(server: UUID(), session: "s", block: "b")
    /// The folded outer screen's column, in screen coordinates.
    private let column = CGRect(x: 382, y: 0, width: 84, height: 678)

    override func setUp() async throws {
        pool = TerminalHostPool()
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first { window.windowScene = scene }
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        try XCTSkipUnless(UIApplication.shared.applicationState == .active, "the test host is not in the foreground")
    }

    override func tearDown() async throws {
        window.isHidden = true
        window = nil
        pool = nil
    }

    private func makeHost(column: CGRect?) -> TerminalHost {
        let control = RexControl(address: "", client: ClientInfo(name: "test", version: "0", label: "test"))
        let host = TerminalHost(stream: TerminalStream(control: control, sessionID: "s", blockID: "b"), sizing: .mirror,
                                fontSize: 12, theme: ThemeStore.fallback)
        host.hardwareKeyboard = { [unowned self] in self.hardware }
        // Too small to lay out, so the host never starts its stream.
        host.frame = CGRect(x: 0, y: 0, width: 10, height: 10)
        host.setKeyBarSurroundings(barColumn: column, crease: nil)
        window.rootViewController?.view.addSubview(host)
        pool.add(host, for: key)
        return host
    }

    private func settle() async {
        await turns(4)
    }

    /// The Hide Keyboard elements VoiceOver finds: the key bar's own while it shows, and the
    /// vertical bar's item while the pool has it for this pane.
    private func hideKeyboardElements(_ host: TerminalHost) -> Int {
        let bar = host.keyBar
        bar.setNeedsLayout()
        bar.layoutIfNeeded()
        let keyBarShows = host.term.isFirstResponder && host.term.inputAccessoryView === bar
        let own = keyBarShows ? bar.subviews.filter { !$0.isHidden && $0.isAccessibilityElement && $0.accessibilityLabel == "Hide Keyboard" }.count : 0
        return own + (pool.hideKeyboard.pane == key ? 1 : 0)
    }

    func testWithAHardwareKeyboardTheItemShowsWithTheBarAloneAndQuietsIt() async throws {
        let host = makeHost(column: column)
        host.isActive = true
        await settle()
        try XCTSkipUnless(host.term.isFirstResponder, "the test host gave no first responder")
        XCTAssertTrue(host.barHidesKeyboard, "the key bar shows alone for the hardware keyboard")
        XCTAssertEqual(pool.hideKeyboard.pane, key)
        XCTAssertEqual(hideKeyboardElements(host), 1)

        // The item's action.
        pool.host(for: key)?.hideKeyboard()
        XCTAssertTrue(host.term.isFirstResponder, "a hardware keyboard still types into the pane")
        XCTAssertTrue(host.keyboardQuiet)
        XCTAssertFalse(host.barHidesKeyboard)
        await settle()
        XCTAssertNil(pool.hideKeyboard.pane, "the item leaves with the bar")
        XCTAssertEqual(hideKeyboardElements(host), 0)

        // A tap brings the bar and the item back.
        host.focusKeyboard()
        await settle()
        XCTAssertTrue(host.barHidesKeyboard)
        XCTAssertEqual(pool.hideKeyboard.pane, key)
    }

    func testWithTheSoftwareKeyboardTheItemResignsAndGoes() async throws {
        hardware = false
        let host = makeHost(column: column)
        host.isActive = true
        host.focusKeyboard()
        await settle()
        try XCTSkipUnless(host.term.isFirstResponder, "the test host gave no first responder")
        XCTAssertEqual(pool.hideKeyboard.pane, key)
        XCTAssertEqual(hideKeyboardElements(host), 1)
        pool.host(for: key)?.hideKeyboard()
        XCTAssertFalse(host.term.isFirstResponder)
        XCTAssertTrue(host.userHidKeyboard)
        await settle()
        XCTAssertNil(pool.hideKeyboard.pane)
        XCTAssertEqual(hideKeyboardElements(host), 0)
    }

    func testWithoutAVerticalBarTheKeyBarKeepsItsHideKeyAndNoItemShows() async throws {
        let host = makeHost(column: nil)
        host.isActive = true
        await settle()
        try XCTSkipUnless(host.term.isFirstResponder, "the test host gave no first responder")
        XCTAssertFalse(host.barHidesKeyboard)
        XCTAssertNil(pool.hideKeyboard.pane)
        XCTAssertEqual(hideKeyboardElements(host), 1, "the key bar's own")
    }

    func testTheItemFollowsTheColumnThroughARotation() async throws {
        let host = makeHost(column: column)
        host.isActive = true
        await settle()
        try XCTSkipUnless(host.term.isFirstResponder, "the test host gave no first responder")
        XCTAssertEqual(pool.hideKeyboard.pane, key)
        // To a posture with no vertical bar (unfolded portrait): the key bar's hide key is back.
        host.setKeyBarSurroundings(barColumn: nil, crease: nil)
        await settle()
        XCTAssertNil(pool.hideKeyboard.pane)
        XCTAssertEqual(hideKeyboardElements(host), 1)
        // And back.
        host.setKeyBarSurroundings(barColumn: column, crease: nil)
        await settle()
        XCTAssertEqual(pool.hideKeyboard.pane, key)
        XCTAssertEqual(hideKeyboardElements(host), 1)
    }

    func testAnotherAccessoryInTheKeyBarsPlaceTakesTheItem() async throws {
        // Find's bar in the accessory slot: Done is its control, not Hide Keyboard.
        let host = makeHost(column: column)
        host.isActive = true
        await settle()
        try XCTSkipUnless(host.term.isFirstResponder, "the test host gave no first responder")
        let other = UIView()
        host.term.inputAccessoryView = other
        XCTAssertFalse(host.barHidesKeyboard)
        host.term.inputAccessoryView = host.keyBar
        XCTAssertTrue(host.barHidesKeyboard)
    }

    func testAStoppedPaneTakesTheItemWithIt() async throws {
        let host = makeHost(column: column)
        host.isActive = true
        await settle()
        try XCTSkipUnless(host.term.isFirstResponder, "the test host gave no first responder")
        XCTAssertEqual(pool.hideKeyboard.pane, key)
        host.onStopped?()
        await settle()
        XCTAssertNil(pool.hideKeyboard.pane)
    }
}
