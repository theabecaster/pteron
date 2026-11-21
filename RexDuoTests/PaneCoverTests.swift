import RexKit
import XCTest
@testable import RexDuo

/// A pane under the agent board (`covered`): it draws nothing, takes no key and claims no size.
/// And a pane that was never covered is as it always was.
@MainActor
final class PaneCoverTests: XCTestCase {
    private var window: UIWindow!
    private var hardware = true

    private final class Sink: TerminalEngineDelegate {
        var sent: [[UInt8]] = []
        func engineGridChanged(cols: Int, rows: Int) {}
        func engineSend(_ bytes: [UInt8]) { sent.append(bytes) }
    }

    private final class Transport: FitClaimTransport {
        var calls: [String] = []
        func own() async -> FitClaimAnswer { calls.append("own"); return .done }
        func resize(cols: Int, rows: Int) async -> FitClaimAnswer { calls.append("resize \(cols)x\(rows)"); return .done }
        func disown() async { calls.append("disown") }
        func whenConnected(_ body: @escaping @MainActor () -> Void) {}
    }

    override func setUp() async throws {
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first { window.windowScene = scene }
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
    }

    override func tearDown() async throws {
        window.isHidden = true
        window = nil
    }

    private func settle(_ turns: Int = 4) async {
        for _ in 0..<turns {
            await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
        }
    }

    private func makeView() -> (GhosttyTerminalView, Sink) {
        let view = GhosttyTerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 240), fontSize: 12, cols: 40, rows: 10)
        let sink = Sink()
        view.engineDelegate = sink
        return (view, sink)
    }

    private func makeHost(sizing: SizingMode = .mirror, claim: FitClaim? = nil, small: Bool = true) -> TerminalHost {
        let control = RexControl(address: "", client: ClientInfo(name: "test", version: "0", label: "test"))
        let host = TerminalHost(stream: TerminalStream(control: control, sessionID: "s", blockID: "b"), sizing: sizing,
                                fontSize: 12, theme: ThemeStore.fallback, claim: claim)
        host.hardwareKeyboard = { [unowned self] in self.hardware }
        // Too small to lay out, unless the test is about the layout.
        host.frame = small ? CGRect(x: 0, y: 0, width: 10, height: 10) : CGRect(x: 0, y: 0, width: 300, height: 400)
        window.rootViewController?.view.addSubview(host)
        return host
    }

    // MARK: Never covered: as before

    /// The flag is off unless someone turns it on, and then whether a pane draws depends on
    /// its window alone, as it always did.
    func testAPaneIsNotCoveredUnlessToldAndDrawsByItsWindowAlone() {
        let (view, _) = makeView()
        XCTAssertFalse(view.covered)
        XCTAssertFalse(view.renderer.isVisible.load(ordering: .relaxed), "off window: not drawn")
        window.rootViewController?.view.addSubview(view)
        XCTAssertTrue(view.renderer.isVisible.load(ordering: .relaxed), "in a window: drawn")
        XCTAssertFalse(view.covered)
        view.removeFromSuperview()
        XCTAssertFalse(view.renderer.isVisible.load(ordering: .relaxed))
        XCTAssertTrue(view.canBecomeFirstResponder)

        let host = makeHost()
        XCTAssertFalse(host.covered)
        XCTAssertFalse(host.term.covered)
        XCTAssertTrue(host.term.renderer.isVisible.load(ordering: .relaxed))
        XCTAssertFalse(TerminalHostPool().covered)
    }

    /// Setting the flag to the value it has changes nothing: no visibility call, no keyboard move.
    func testUncoveringAPaneThatWasNeverCoveredDoesNothing() async {
        let host = makeHost()
        host.isActive = true
        await settle()
        let held = host.term.isFirstResponder
        let hidden = host.userHidKeyboard
        host.setCovered(false)
        TerminalHostPool().setCovered(false)
        await settle()
        XCTAssertEqual(host.term.isFirstResponder, held)
        XCTAssertEqual(host.userHidKeyboard, hidden)
        XCTAssertTrue(host.term.renderer.isVisible.load(ordering: .relaxed))
    }

    func testAnUncoveredFitPaneClaimsItsSizeAsBefore() async {
        let transport = Transport()
        let host = makeHost(sizing: .fit, claim: FitClaim(transport: transport, settle: {}), small: false)
        host.layoutIfNeeded()
        await settle(8)
        XCTAssertEqual(transport.calls.first, "own")
        XCTAssertEqual(transport.calls.filter { $0.hasPrefix("resize") }.count, 1)
    }

    // MARK: Covered

    func testACoveredPaneStopsDrawingAndDrawsAgainWhenUncovered() {
        let (view, _) = makeView()
        window.rootViewController?.view.addSubview(view)
        view.covered = true
        XCTAssertFalse(view.renderer.isVisible.load(ordering: .relaxed))
        view.covered = false
        XCTAssertTrue(view.renderer.isVisible.load(ordering: .relaxed))
        // Off window it stays undrawn whatever the flag says.
        view.removeFromSuperview()
        view.covered = true
        view.covered = false
        XCTAssertFalse(view.renderer.isVisible.load(ordering: .relaxed))
    }

    func testACoveredPaneTakesNoKeyOfAnyKind() {
        let (view, sink) = makeView()
        window.rootViewController?.view.addSubview(view)
        var commandKeys: [String] = []
        view.commandKeyHook = { commandKeys.append($0) }
        view.covered = true
        XCTAssertFalse(view.canBecomeFirstResponder)
        XCTAssertFalse(view.becomeFirstResponder())
        view.insertText("a")
        view.deleteBackward()
        // An arrow key (usage 0x52), which an uncovered pane encodes itself.
        XCTAssertFalse(view.hardwareKeyDown(usage: 0x52, flags: [], characters: "", charactersIgnoringModifiers: ""))
        // The key bar's cmd: the next key would go to the keymap.
        view.commandModifier = true
        view.insertText("d")
        view.deleteBackward()
        XCTAssertTrue(sink.sent.isEmpty, "nothing reaches the program")
        XCTAssertTrue(commandKeys.isEmpty, "nothing reaches the keymap")

        // Uncovered, the same keys work again.
        view.covered = false
        view.insertText("d")
        XCTAssertEqual(commandKeys, ["d"])
        view.commandModifier = false
        view.insertText("a")
        XCTAssertEqual(sink.sent.count, 1)
        XCTAssertTrue(view.hardwareKeyDown(usage: 0x52, flags: [], characters: "", charactersIgnoringModifiers: ""))
    }

    func testACoveredHostRunsNoShortcutFromTheKeyBar() throws {
        let host = makeHost()
        host.keymap = KeymapStore(control: RexControl(address: "", client: ClientInfo(name: "test", version: "0", label: "test")))
        var commands: [RexCommand] = []
        host.onCommand = { commands.append($0) }
        let press = try XCTUnwrap(KeyInput.press(typing: "d", mods: .cmd))
        try XCTSkipUnless(host.keyBarShortcut(press, isRepeat: false), "the default keymap binds no cmd+d")
        let before = commands.count
        XCTAssertGreaterThan(before, 0)
        host.setCovered(true)
        XCTAssertFalse(host.keyBarShortcut(press, isRepeat: false))
        XCTAssertEqual(commands.count, before)
        host.setCovered(false)
        XCTAssertTrue(host.keyBarShortcut(press, isRepeat: false))
    }

    /// A pane that kept a hardware keyboard under the board runs no ⌘ shortcut either: UIKit
    /// fires those from the responder chain, not through the pane's key presses.
    func testACoveredHostRunsNoHardwareCommandShortcut() throws {
        let host = makeHost()
        host.keymap = KeymapStore(control: RexControl(address: "", client: ClientInfo(name: "test", version: "0", label: "test")))
        var commands: [RexCommand] = []
        host.onCommand = { commands.append($0) }
        let shortcut = host.keyCommands?.first { ($0.propertyList as? String)?.hasPrefix("edit:") == false }
        let command = try XCTUnwrap(shortcut, "the default keymap binds no ⌘ shortcut")
        let action = try XCTUnwrap(command.action)
        host.perform(action, with: command)
        let before = commands.count
        try XCTSkipUnless(before > 0, "the first ⌘ shortcut runs no command here")
        host.setCovered(true)
        host.perform(action, with: command)
        XCTAssertEqual(commands.count, before)
        host.setCovered(false)
        host.perform(action, with: command)
        XCTAssertEqual(commands.count, before + 1)
    }

    func testACoveredHostGivesUpTheKeyboardAndCannotTakeIt() async throws {
        try XCTSkipUnless(UIApplication.shared.applicationState == .active, "the test host is not in the foreground")
        let host = makeHost()
        host.isActive = true
        await settle()
        try XCTSkipUnless(host.term.isFirstResponder, "the test host gave no first responder")

        host.setCovered(true)
        XCTAssertTrue(host.covered)
        XCTAssertTrue(host.term.covered)
        XCTAssertFalse(host.term.isFirstResponder)
        XCTAssertFalse(host.term.renderer.isVisible.load(ordering: .relaxed))
        // Everything that makes a pane look for the keyboard: none of it takes it under the board.
        host.isActive = false
        host.isActive = true
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        host.coverChanged(covered: false)
        host.focusKeyboard()
        await settle()
        XCTAssertFalse(host.term.isFirstResponder)

        // With a hardware keyboard the pane has the keyboard again afterwards, as it had it.
        host.setCovered(false)
        await settle()
        XCTAssertTrue(host.term.isFirstResponder)
        XCTAssertTrue(host.term.renderer.isVisible.load(ordering: .relaxed))
    }

    func testASoftwareKeyboardStaysDownAfterTheBoard() async throws {
        try XCTSkipUnless(UIApplication.shared.applicationState == .active, "the test host is not in the foreground")
        hardware = false
        let host = makeHost()
        host.isActive = true
        host.focusKeyboard()
        await settle()
        try XCTSkipUnless(host.term.isFirstResponder, "the test host gave no first responder")
        host.setCovered(true)
        XCTAssertTrue(host.userHidKeyboard, "as after the hide key")
        host.setCovered(false)
        await settle()
        XCTAssertFalse(host.term.isFirstResponder)
    }

    func testASoftwareKeyboardShownBesideAHardwareOneStaysDownToo() async throws {
        try XCTSkipUnless(UIApplication.shared.applicationState == .active, "the test host is not in the foreground")
        let host = makeHost()
        host.isActive = true
        await settle()
        try XCTSkipUnless(host.term.isFirstResponder, "the test host gave no first responder")
        host.setCovered(true, softwareKeyboard: true)
        XCTAssertTrue(host.userHidKeyboard)
        host.setCovered(false)
        await settle()
        // Nothing shows again by itself. The next time the pane looks for the keyboard (the
        // app active again, a pane switch) it takes the hardware keyboard quietly.
        XCTAssertFalse(host.term.isFirstResponder)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        await settle()
        XCTAssertTrue(host.term.isFirstResponder)
        XCTAssertTrue(host.keyboardQuiet)
    }

    /// A pane that holds a hardware keyboard with nothing on screen keeps it under the board, so
    /// nothing moves when the board comes or goes; its keys are dropped meanwhile.
    func testAQuietHolderKeepsTheKeyboardButTakesNoKey() async throws {
        try XCTSkipUnless(UIApplication.shared.applicationState == .active, "the test host is not in the foreground")
        let host = makeHost()
        let sink = Sink()
        host.isActive = true
        await settle()
        try XCTSkipUnless(host.term.isFirstResponder, "the test host gave no first responder")
        host.hideKeyboard()
        XCTAssertTrue(host.keyboardQuiet)
        XCTAssertTrue(host.term.isFirstResponder)
        host.setCovered(true)
        XCTAssertTrue(host.term.isFirstResponder)
        host.term.engineDelegate = sink
        host.term.insertText("x")
        XCTAssertFalse(host.term.hardwareKeyDown(usage: 0x52, flags: [], characters: "", charactersIgnoringModifiers: ""))
        XCTAssertTrue(sink.sent.isEmpty)
        host.setCovered(false)
        await settle()
        XCTAssertTrue(host.term.isFirstResponder)
        XCTAssertTrue(host.keyboardQuiet)
        host.term.insertText("x")
        XCTAssertEqual(sink.sent.count, 1)
    }

    /// Under the board nothing is owned, resized or given back, whatever the layout does.
    func testACoveredFitPaneClaimsNothing() async {
        let transport = Transport()
        let host = makeHost(sizing: .fit, claim: FitClaim(transport: transport, settle: {}), small: false)
        host.layoutIfNeeded()
        await settle(8)
        let before = transport.calls
        XCTAssertEqual(before.filter { $0.hasPrefix("resize") }.count, 1)

        host.setCovered(true)
        // The room changes under the board: a key bar goes, the phone turns.
        host.frame = CGRect(x: 0, y: 0, width: 300, height: 480)
        host.layoutIfNeeded()
        host.frame = CGRect(x: 0, y: 0, width: 380, height: 300)
        host.layoutIfNeeded()
        await settle(8)
        XCTAssertEqual(transport.calls, before, "no own, resize or disown while covered")

        // Back at the size it had: uncovering sends nothing either.
        host.frame = CGRect(x: 0, y: 0, width: 300, height: 400)
        host.layoutIfNeeded()
        host.setCovered(false)
        try? await Task.sleep(nanoseconds: UInt64((TerminalHost.uncoverSettle + 0.2) * 1_000_000_000))
        await settle(8)
        XCTAssertEqual(transport.calls, before, "the same size as before the board: nothing to claim")
    }

    /// A pane made under the board waits: it claims its size only once the board has gone.
    func testAPaneFirstLaidOutUnderTheBoardClaimsOnlyWhenUncovered() async {
        let transport = Transport()
        let host = makeHost(sizing: .fit, claim: FitClaim(transport: transport, settle: {}), small: false)
        host.setCovered(true)
        host.layoutIfNeeded()
        await settle(8)
        XCTAssertTrue(transport.calls.isEmpty)
        host.setCovered(false)
        host.layoutIfNeeded()
        await settle(8)
        XCTAssertEqual(transport.calls.first, "own")
        XCTAssertEqual(transport.calls.filter { $0.hasPrefix("resize") }.count, 1)
    }

    func testThePoolCoversTheHostsItHasAndTheOnesAddedLater() {
        let pool = TerminalHostPool()
        let a = makeHost(), b = makeHost()
        pool.add(a, for: .init(server: UUID(), session: "s", block: "a"))
        pool.setCovered(true)
        XCTAssertTrue(a.covered)
        pool.add(b, for: .init(server: UUID(), session: "s", block: "b"))
        XCTAssertTrue(b.covered, "a pane made under the board is covered from the start")
        pool.setCovered(false)
        XCTAssertFalse(a.covered)
        XCTAssertFalse(b.covered)
    }
}
