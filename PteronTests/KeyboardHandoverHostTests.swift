import RexKit
import XCTest
@testable import Pteron

/// The keyboard across a tab switch, with real hosts in a window: the old tab's pane leaves the
/// window and the new tab's pane enters it, in either order, as SwiftUI swaps them.
@MainActor
final class KeyboardHandoverHostTests: XCTestCase {
    private var window: UIWindow!
    private var hardware = false
    private var pool: TerminalHostPool!
    private var hosts: [TerminalHost] = []
    private var panes = PaneBaseline()
    /// Every change of a terminal's hold on the keyboard, in order: the pane's block and
    /// whether it gained it.
    private var changes: [String] = []

    override func setUp() async throws {
        panes = PaneBaseline()
        hardware = false
        changes = []
        pool = TerminalHostPool()
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
        for host in hosts {
            host.removeFromSuperview()
            host.evict()
        }
        hosts = []
        pool = nil
        window.isHidden = true
        window = nil
        let gone = await panes.cleared()
        XCTAssertTrue(gone, "LEAKCHECK \(name): \(panes.left) panes left")
    }

    private var root: UIView { window.rootViewController!.view }

    private func key(_ block: String) -> TerminalHostPool.Key {
        TerminalHostPool.Key(server: Self.server, session: "s", block: block)
    }

    private static let server = UUID()

    /// A pane of the pool, the active pane of its own tab, not in the window yet. Too small to
    /// lay out, so it never starts its stream.
    private func makeHost(_ block: String, sizing: SizingMode = .mirror, claim: FitClaim? = nil,
                          size: CGSize = CGSize(width: 10, height: 10)) -> TerminalHost {
        let control = RexControl(address: "", client: ClientInfo(name: "test", version: "0", label: "test"))
        let host = TerminalHost(stream: TerminalStream(control: control, sessionID: "s", blockID: block), sizing: sizing,
                                fontSize: 12, theme: ThemeStore.fallback, claim: claim)
        host.hardwareKeyboard = { [unowned self] in self.hardware }
        host.frame = CGRect(origin: .zero, size: size)
        let before = host.term.keyboardFocusHook
        host.term.keyboardFocusHook = { [unowned self] focused in
            self.changes.append("\(block) \(focused ? "gained" : "lost")")
            before?(focused)
        }
        pool.add(host, for: key(block))
        host.isActive = true
        hosts.append(host)
        return host
    }

    /// Lets the hosts' hops to the main queue run.
    private func settle(_ turns: Int = 6) async {
        for _ in 0..<turns {
            await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
        }
    }

    /// The blocks of the panes whose terminal is first responder.
    private var holders: [String] {
        hosts.filter { $0.term.isFirstResponder }.map { $0.stream.blockID }
    }

    /// Pane a on screen with the keyboard, as a tap gave it, and pane b waiting off screen.
    private func twoTabs() async throws -> (a: TerminalHost, b: TerminalHost) {
        let a = makeHost("a"), b = makeHost("b")
        root.addSubview(a)
        a.focusKeyboard()
        await settle()
        try XCTSkipUnless(a.term.isFirstResponder, "the test host gave no first responder")
        changes = []
        return (a, b)
    }

    // MARK: No hardware keyboard: as before

    /// The new tab's pane enters the window, then the old one leaves it, in one turn.
    func testATabSwitchWithoutAHardwareKeyboardDropsTheKeyboard() async throws {
        let (a, b) = try await twoTabs()
        root.addSubview(b)
        XCTAssertEqual(holders, ["a"], "nothing is taken as the pane arrives")
        a.removeFromSuperview()
        XCTAssertEqual(holders, [])
        await settle()
        XCTAssertEqual(holders, [], "a switch never raises the software keyboard")
        XCTAssertEqual(changes, ["a lost"])
        XCTAssertFalse(b.keyboardUp)
    }

    /// The old tab's pane leaves first.
    func testATabSwitchWithoutAHardwareKeyboardDropsTheKeyboardWhenTheOldPaneGoesFirst() async throws {
        let (a, b) = try await twoTabs()
        a.removeFromSuperview()
        root.addSubview(b)
        XCTAssertEqual(holders, [])
        await settle()
        XCTAssertEqual(holders, [])
        XCTAssertEqual(changes, ["a lost"])
        XCTAssertFalse(b.keyboardUp)
    }

    /// The old pane stays for a turn or more (a transition): the keyboard follows the pane
    /// that came, a turn later, hardware or not.
    func testWithoutAHardwareKeyboardAPaneBesideTheOldOneTakesItATurnLater() async throws {
        let (_, _) = try await twoTabs()
        root.addSubview(hosts[1])
        XCTAssertEqual(holders, ["a"], "nothing is taken as the pane arrives")
        await settle()
        XCTAssertEqual(holders, ["b"])
        XCTAssertEqual(changes, ["a lost", "b gained"])
    }
}
