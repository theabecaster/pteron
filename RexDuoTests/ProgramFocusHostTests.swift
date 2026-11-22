import RexKit
import XCTest
@testable import RexDuo
@testable import RexKit

/// Stands between a host's engine and the host, and notes every focus, mouse or wheel report
/// the engine made and whether the stream took it.
@MainActor
private final class ReportSpy: TerminalEngineDelegate {
    let host: TerminalHost
    private(set) var reports: [(text: String, taken: Bool)] = []

    init(_ host: TerminalHost) {
        self.host = host
        host.term.engineDelegate = self
    }

    /// The reports the stream took, in order.
    var sent: [String] { reports.filter { $0.taken }.map { $0.text } }

    func engineGridChanged(cols: Int, rows: Int) { host.engineGridChanged(cols: cols, rows: rows) }
    func engineSend(_ bytes: [UInt8]) { host.engineSend(bytes) }

    @discardableResult
    func engineSendReport(_ bytes: [UInt8]) -> Bool {
        let taken = host.engineSendReport(bytes)
        reports.append((String(decoding: bytes, as: UTF8.self), taken))
        return taken
    }

    func engineSendFocusGained(_ bytes: [UInt8], left: @escaping @MainActor () -> Void) -> Bool {
        let taken = host.engineSendFocusGained(bytes, left: left)
        reports.append((String(decoding: bytes, as: UTF8.self), taken))
        return taken
    }
}

/// The focus a program is told about (mode 1004), with real hosts in a window: it follows the
/// front pane and never the keyboard (`PaneFront`, `ProgramFocus`).
@MainActor
final class ProgramFocusHostTests: XCTestCase {
    private static let gained = "\u{1b}[I", lost = "\u{1b}[O"
    private static let asks = "\u{1b}[?1004h"

    private var window: UIWindow!
    private var hardware = false
    private var hosts: [TerminalHost] = []
    private var panesBefore = 0

    override func setUp() async throws {
        panesBefore = GhosttyRenderThread.shared.paneCount
        hardware = false
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first { window.windowScene = scene }
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
    }

    override func tearDown() async throws {
        // Let go at once: a host that only leaves its window holds on to itself until it has
        // stayed away (`TerminalHost.scheduleStop`).
        for host in hosts {
            host.removeFromSuperview()
            host.evict()
        }
        hosts = []
        window.isHidden = true
        window = nil
        // The next test class starts with none of this one's panes left.
        var turns = 0
        while GhosttyRenderThread.shared.paneCount > panesBefore, turns < 1500 {
            turns += 1
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    /// Lets the hops to the main queue run: the hosts' own, and the engine's word that the
    /// program turned focus reports on.
    private func settle() async {
        for _ in 0..<4 {
            await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
        }
    }

    private func pause(_ seconds: TimeInterval) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    /// A host in the window, in the app in front, not the active pane yet. Its program has
    /// written `setup`. Too small to lay out, so the host never starts its stream: what the
    /// stream takes waits in its queue.
    private func makeHost(_ setup: String = ProgramFocusHostTests.asks, shown: Bool = true) async -> (TerminalHost, TerminalStream, ReportSpy) {
        let control = RexControl(address: "", client: ClientInfo(name: "test", version: "0", label: "test"))
        let stream = TerminalStream(control: control, sessionID: "s", blockID: "b")
        let host = TerminalHost(stream: stream, sizing: .mirror, fontSize: 12, theme: ThemeStore.fallback)
        host.hardwareKeyboard = { [unowned self] in self.hardware }
        host.frame = CGRect(x: 0, y: 0, width: 10, height: 10)
        let spy = ReportSpy(host)
        feed(host, setup)
        if shown { window.rootViewController?.view.addSubview(host) }
        host.appActiveChanged(true)
        hosts.append(host)
        await settle()
        return (host, stream, spy)
    }

    private func feed(_ host: TerminalHost, _ text: String) {
        host.term.feed(text: text)
        host.term.core.sync()
    }

    // MARK: The front pane

    func testOnlyTheActivePaneOfASplitHasTheFocus() async {
        let (a, _, aSpy) = await makeHost()
        let (b, _, bSpy) = await makeHost()
        XCTAssertEqual(aSpy.reports.count + bSpy.reports.count, 0, "no pane is the active one yet")
        a.isActive = true
        XCTAssertEqual(aSpy.sent, [Self.gained])
        XCTAssertEqual(bSpy.sent, [])
        // The other pane becomes the active one.
        a.isActive = false
        b.isActive = true
        XCTAssertEqual(aSpy.sent, [Self.gained, Self.lost])
        XCTAssertEqual(bSpy.sent, [Self.gained])
        // Said once each.
        a.refreshProgramFocus()
        b.refreshProgramFocus()
        XCTAssertEqual(aSpy.reports.count, 2)
        XCTAssertEqual(bSpy.reports.count, 1)
    }

    func testAnotherAppInFrontTakesTheFocusAndTheReturnGivesItBack() async {
        let (host, _, spy) = await makeHost()
        host.isActive = true
        host.appActiveChanged(false)
        XCTAssertFalse(host.isFrontPane)
        XCTAssertEqual(spy.sent, [Self.gained, Self.lost])
        // The background that follows says nothing more.
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        XCTAssertEqual(spy.sent, [Self.gained, Self.lost])
        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        XCTAssertEqual(spy.sent, [Self.gained, Self.lost], "not in front yet")
        host.appActiveChanged(true)
        XCTAssertEqual(spy.sent, [Self.gained, Self.lost, Self.gained])
    }

    func testTheAppsOwnNoticesMoveTheFocus() async {
        let (host, _, spy) = await makeHost()
        host.isActive = true
        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        XCTAssertEqual(spy.sent, [Self.gained, Self.lost])
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        XCTAssertEqual(spy.sent, [Self.gained, Self.lost, Self.gained])
        await settle()
    }

    /// The board, a sheet and the palette each take the pane from the front, and with it the
    /// program's right to write the pasteboard, which asks the same question.
    func testACoveredPaneIsNotInFront() async {
        let (host, _, spy) = await makeHost()
        host.isActive = true
        XCTAssertTrue(host.isFrontPane)
        var want = [Self.gained]

        host.setCovered(true)
        XCTAssertFalse(host.isFrontPane, "under the board")
        want.append(Self.lost)
        XCTAssertEqual(spy.sent, want)
        host.setCovered(false)
        want.append(Self.gained)
        XCTAssertEqual(spy.sent, want)

        host.coverChanged(covered: true)
        XCTAssertFalse(host.isFrontPane, "under a sheet")
        want.append(Self.lost)
        XCTAssertEqual(spy.sent, want)
        // UIKit says the same again: no second report.
        host.coverChanged(covered: true)
        XCTAssertEqual(spy.sent, want)
        host.coverChanged(covered: false)
        want.append(Self.gained)
        XCTAssertEqual(spy.sent, want)

        // As `PaneHostView` does it.
        host.underPalette = true
        host.refreshProgramFocus()
        XCTAssertFalse(host.isFrontPane, "under the palette")
        want.append(Self.lost)
        XCTAssertEqual(spy.sent, want)
        host.underPalette = false
        host.refreshProgramFocus()
        want.append(Self.gained)
        XCTAssertEqual(spy.sent, want)
        XCTAssertTrue(host.isFrontPane)
        await settle()
    }

    /// The palette closes onto another pane: the pane that was active under it never hears
    /// that it gained the focus for that moment.
    func testThePaletteClosingOntoAnotherPaneIsOneChange() async {
        let (a, _, aSpy) = await makeHost()
        let (b, _, bSpy) = await makeHost()
        a.isActive = true
        for host in [a, b] {
            host.underPalette = true
            host.refreshProgramFocus()
        }
        XCTAssertEqual(aSpy.sent, [Self.gained, Self.lost])
        // The order of `PaneHostView.apply`: the palette, the active pane, then one word.
        a.underPalette = false
        a.isActive = false
        a.refreshProgramFocus()
        b.underPalette = false
        b.isActive = true
        b.refreshProgramFocus()
        XCTAssertEqual(aSpy.sent, [Self.gained, Self.lost])
        XCTAssertEqual(bSpy.sent, [Self.gained])
    }

    // MARK: The keyboard is not the focus

    func testHidingTheKeyboardSaysNothing() async throws {
        let (host, _, spy) = await makeHost()
        host.isActive = true
        XCTAssertEqual(spy.sent, [Self.gained])
        host.focusKeyboard()
        try XCTSkipUnless(host.term.isFirstResponder, "the test host gave no first responder")
        XCTAssertEqual(spy.reports.count, 1, "the keyboard coming up says nothing")
        // The hide key, with no hardware keyboard: the terminal resigns.
        host.hideKeyboard()
        XCTAssertFalse(host.term.isFirstResponder)
        XCTAssertEqual(spy.reports.count, 1)
        // A tap brings it back.
        host.focusKeyboard()
        XCTAssertTrue(host.term.isFirstResponder)
        XCTAssertEqual(spy.reports.count, 1)
        // A drag into the scrollback while the keyboard covers the pane puts it away.
        host.term.readingHook?()
        XCTAssertTrue(host.userHidKeyboard)
        XCTAssertFalse(host.term.isFirstResponder)
        XCTAssertEqual(spy.reports.count, 1)
        // With a hardware keyboard the hide key leaves the terminal first responder, quietly.
        hardware = true
        host.focusKeyboard()
        host.hideKeyboard()
        XCTAssertTrue(host.keyboardQuiet)
        XCTAssertTrue(host.term.isFirstResponder)
        XCTAssertEqual(spy.reports.count, 1)
        XCTAssertTrue(host.isFrontPane)
        await settle()
        XCTAssertEqual(spy.reports.count, 1)
    }

    // MARK: Off screen

    /// A fold moves the pane through no window for a moment: the program hears nothing. A pane
    /// that stays away loses the focus, and that is said while its stream still takes it.
    func testAPaneOffItsWindowSaysSoOnlyOnceItStayedAway() async {
        let (host, _, spy) = await makeHost()
        host.leaveTiming.settle = 0.05
        host.isActive = true
        XCTAssertEqual(spy.sent, [Self.gained])

        host.removeFromSuperview()
        XCTAssertEqual(spy.reports.count, 1, "not yet")
        // Out of its window for the moment of a fold, the pane is still on screen to its
        // program, whatever else asks meanwhile; the pasteboard is closed to it at once.
        XCTAssertTrue(host.hasProgramFocus)
        XCTAssertFalse(host.isFrontPane)
        host.refreshProgramFocus()
        host.coverChanged(covered: false)
        host.appActiveChanged(true)
        XCTAssertEqual(spy.reports.count, 1, "a fold says nothing")
        window.rootViewController?.view.addSubview(host)
        await pause(0.3)
        XCTAssertEqual(spy.reports.count, 1, "back in time: nothing was said, and nothing is said again")

        host.removeFromSuperview()
        await pause(0.3)
        XCTAssertEqual(spy.reports.count, 2)
        XCTAssertEqual(spy.reports.last?.text, Self.lost)
        XCTAssertEqual(spy.reports.last?.taken, true, "handed to the stream before the pane let go of it")
    }

    /// The report goes to the stream before the stream parks; a parked stream takes nothing.
    func testAPaneThatParksSaysFocusLostBeforeItsStreamParks() async {
        let (host, stream, spy) = await makeHost()
        host.isActive = true
        host.park()
        XCTAssertTrue(host.isParked)
        XCTAssertFalse(host.isFrontPane)
        XCTAssertEqual(spy.reports.count, 2)
        XCTAssertEqual(spy.reports.last?.text, Self.lost)
        XCTAssertEqual(spy.reports.last?.taken, true, "the stream had not parked yet")
        XCTAssertFalse(stream.send(report: Array(Self.lost.utf8)), "after the park nothing is taken")
    }

    /// Back from a park the stream is behind its fence: the report waits for it, and goes once.
    func testAReturningPaneSaysFocusGainedOnceAfterItsFence() async {
        let (host, stream, spy) = await makeHost()
        host.isActive = true
        host.park()
        XCTAssertEqual(spy.sent, [Self.gained, Self.lost])

        host.cameBackOnScreen()
        XCTAssertFalse(host.isParked)
        XCTAssertTrue(stream.isFenced)
        XCTAssertTrue(host.isFrontPane)
        XCTAssertEqual(spy.sent, [Self.gained, Self.lost], "nothing leaves behind the fence")
        await settle()
        XCTAssertEqual(spy.sent, [Self.gained, Self.lost])

        stream.fence.reset()
        XCTAssertEqual(spy.sent, [Self.gained, Self.lost, Self.gained], "once, when the stream is current")
        await settle()
        XCTAssertEqual(spy.sent, [Self.gained, Self.lost, Self.gained])
    }

    // MARK: A tab switch

    /// The tab on screen changes: the old tab's pane leaves its window and the new tab's pane
    /// comes to the front. The old one's program loses the focus then, not half a second later,
    /// so no two programs are told they have it.
    func testATabSwitchTakesTheFocusFromTheOldTabsPaneAtOnce() async {
        let pool = TerminalHostPool()
        let (a, _, aSpy) = await makeHost()
        let (b, _, bSpy) = await makeHost(shown: false)
        pool.add(a, for: TerminalHostPool.Key(server: UUID(), session: "s", block: "a"))
        pool.add(b, for: TerminalHostPool.Key(server: UUID(), session: "s", block: "b"))
        // Each is the active pane of its own tab.
        a.isActive = true
        b.isActive = true
        XCTAssertEqual(aSpy.sent, [Self.gained])
        XCTAssertEqual(bSpy.sent, [])

        // The old tab goes first, then the new one shows.
        a.removeFromSuperview()
        XCTAssertEqual(aSpy.sent, [Self.gained], "it may be a fold")
        window.rootViewController?.view.addSubview(b)
        XCTAssertEqual(bSpy.sent, [Self.gained])
        XCTAssertEqual(aSpy.sent, [Self.gained, Self.lost], "at once, as the other pane came to the front")

        // Back the other way, the new tab showing before the old one goes.
        window.rootViewController?.view.addSubview(a)
        XCTAssertEqual(aSpy.sent, [Self.gained, Self.lost, Self.gained])
        b.removeFromSuperview()
        XCTAssertEqual(bSpy.sent, [Self.gained, Self.lost], "another pane is in front already")
    }

    /// A fold moves both panes of a split through no window. The one that is back first is
    /// not the front pane, so the active one keeps the focus.
    func testAFoldOfASplitSaysNothing() async {
        let pool = TerminalHostPool()
        let (a, _, aSpy) = await makeHost()
        let (b, _, bSpy) = await makeHost()
        pool.add(a, for: TerminalHostPool.Key(server: UUID(), session: "s", block: "a"))
        pool.add(b, for: TerminalHostPool.Key(server: UUID(), session: "s", block: "b"))
        a.isActive = true
        a.removeFromSuperview()
        b.removeFromSuperview()
        window.rootViewController?.view.addSubview(b)
        window.rootViewController?.view.addSubview(a)
        XCTAssertEqual(aSpy.sent, [Self.gained])
        XCTAssertEqual(bSpy.reports.count, 0)
    }

    // MARK: The fence

    /// A report counts as said when the stream takes it; whether it arrived is not known. So
    /// each time the stream is current again, the pane says again where it is.
    func testAPaneSaysWhereItIsAgainEachTimeItsFenceComesDown() async {
        let (host, stream, spy) = await makeHost()
        host.isActive = true
        XCTAssertEqual(spy.sent, [Self.gained])
        stream.stop()
        stream.start()
        XCTAssertTrue(stream.isFenced)
        stream.fence.reset()
        XCTAssertEqual(spy.sent, [Self.gained, Self.gained])

        // A pane that is not in front says that again too.
        host.isActive = false
        XCTAssertEqual(spy.sent, [Self.gained, Self.gained, Self.lost])
        stream.stop()
        stream.start()
        stream.fence.reset()
        XCTAssertEqual(spy.sent, [Self.gained, Self.gained, Self.lost, Self.lost])
    }

    /// A parked stream drops what it had queued, the report that the pane lost the focus with
    /// it. A pane that comes back and is not the front pane says so again.
    func testAPaneBackFromAParkThatIsNotInFrontSaysFocusLostAgain() async {
        let (host, stream, spy) = await makeHost()
        host.isActive = true
        host.park()
        XCTAssertEqual(spy.sent, [Self.gained, Self.lost])
        XCTAssertFalse(stream.hasPendingInput, "the park dropped the queue")
        // Another pane of its split is the active one when it comes back.
        host.isActive = false
        host.cameBackOnScreen()
        XCTAssertTrue(stream.isFenced)
        XCTAssertEqual(spy.sent, [Self.gained, Self.lost])
        stream.fence.reset()
        XCTAssertEqual(spy.sent, [Self.gained, Self.lost, Self.lost])
    }

    // MARK: Mode 1004

    func testAProgramThatTurnsFocusReportsOnInTheFrontPaneIsToldSo() async {
        let (host, _, spy) = await makeHost("")
        host.isActive = true
        XCTAssertEqual(spy.reports.count, 0, "it has not asked")
        feed(host, Self.asks)
        await settle()
        XCTAssertEqual(spy.sent, [Self.gained])
        // Asking again for what is on already is no news.
        feed(host, Self.asks)
        await settle()
        XCTAssertEqual(spy.sent, [Self.gained])
        // Off, and on again: another program, or the same one starting over.
        feed(host, "\u{1b}[?1004l")
        feed(host, Self.asks)
        await settle()
        XCTAssertEqual(spy.sent, [Self.gained, Self.gained])
    }

    func testAProgramThatTurnsFocusReportsOnInAnotherPaneIsToldNothing() async {
        let (host, _, spy) = await makeHost("")
        feed(host, Self.asks)
        await settle()
        XCTAssertEqual(spy.reports.count, 0)
        // It hears when its pane comes to the front.
        host.isActive = true
        XCTAssertEqual(spy.sent, [Self.gained])
    }

    func testAProgramThatNeverAskedIsToldNothing() async {
        let (host, stream, spy) = await makeHost("")
        host.leaveTiming.settle = 0.05
        host.isActive = true
        host.appActiveChanged(false)
        host.appActiveChanged(true)
        host.setCovered(true)
        host.setCovered(false)
        host.coverChanged(covered: true)
        host.coverChanged(covered: false)
        host.isActive = false
        host.isActive = true
        stream.start()
        stream.fence.reset()
        host.park()
        host.cameBackOnScreen()
        stream.fence.reset()
        host.removeFromSuperview()
        await pause(0.3)
        XCTAssertEqual(spy.reports.count, 0)
        XCTAssertFalse(stream.hasPendingInput)
    }
}
