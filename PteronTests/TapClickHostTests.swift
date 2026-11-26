import RexKit
import XCTest
@testable import Pteron
@_spi(Bench) @testable import RexKit

/// The click of a tap, through a whole pane on a live stream: when it leaves, what waits for
/// it, and how it keeps clear of the report that the pane gained the focus.
@MainActor
final class TapClickHostTests: XCTestCase {
    /// Holds the link's answer to a write until the test lets it pass.
    @MainActor private final class Answers {
        private var waiting: [CheckedContinuation<Void, Never>] = []
        var held = false
        var count: Int { waiting.count }

        func sleep(_ d: Duration) async {
            guard held else { return }
            await withCheckedContinuation { waiting.append($0) }
        }

        func pass() {
            held = false
            let all = waiting
            waiting = []
            for w in all { w.resume() }
        }
    }

    @MainActor private struct Pane {
        let host: TerminalHost
        let stream: TerminalStream
        let link: ScriptedEchoLink
        let answers: Answers
        /// Everything written, as one string per write.
        var written: [String] { link.written }
    }

    private static let mouse = "\u{1b}[?1000h\u{1b}[?1006h"
    private static let asks = "\u{1b}[?1004h"
    private static let gained = "\u{1b}[I"

    private var window: UIWindow!
    private var hardware = false
    private var panes: [Pane] = []
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
        for p in panes {
            p.answers.pass()
            p.host.removeFromSuperview()
            p.host.evict()
        }
        panes = []
        window.isHidden = true
        window = nil
        // The next test class starts with none of this one's panes left.
        var turns = 0
        while GhosttyRenderThread.shared.paneCount > panesBefore, turns < 1500 {
            turns += 1
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    private func wait(_ what: String, _ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<2500 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("timed out waiting for \(what)", file: file, line: line)
    }

    private func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    /// A live pane in the window: the tab's active pane, in the app in front, its program
    /// having written `setup`. Too small to lay out, so the host starts nothing by itself; its
    /// engine view has a grid of 40 by 10 to tap on.
    private func pane(_ setup: String) async -> Pane {
        let answers = Answers()
        let link = ScriptedEchoLink(writeDelay: .milliseconds(1)) { await answers.sleep($0) }
        let control = RexControl(address: "", client: ClientInfo(name: "test", version: "0", label: "test"))
        let stream = link.stream(control: control, sessionID: "s", blockID: "b", echoGate: nil)
        let host = TerminalHost(stream: stream, sizing: .mirror, fontSize: 12, theme: ThemeStore.fallback)
        host.hardwareKeyboard = { [unowned self] in self.hardware }
        // The keyboard that waits for a click comes only if the answer took at most 2 s, and a
        // busy machine can take longer: here it waits as long as the test does. The limit has
        // its own test, with a limit of its own.
        host.clickKeyboardLimit = 60
        host.frame = CGRect(x: 0, y: 0, width: 10, height: 10)
        window.rootViewController?.view.addSubview(host)
        host.appActiveChanged(true)
        host.isActive = true
        let p = Pane(host: host, stream: stream, link: link, answers: answers)
        panes.append(p)
        stream.start()
        await wait("the stream to be live with its fence down") { link.isOpen && !stream.isFenced }
        host.term.setGrid(cols: 40, rows: 10, force: true)
        let cell = host.term.cellSize
        host.term.frame = CGRect(x: 0, y: 0, width: cell.width * 40, height: cell.height * 10)
        host.term.layoutIfNeeded()
        link.deliver(Array(setup.utf8))
        await wait("the program's modes") { host.term.core.sync(); return host.term.sendsTapsToProgram }
        frame(host)
        return p
    }

    private func frame(_ host: TerminalHost) {
        let view = host.term
        view.core.sync()
        _ = view.renderer.frame.update(core: view.core)
        view.scroller.apply(view.core.scroll.snapshot)
    }

    private func isClick(_ text: String) -> Bool { text.hasPrefix("\u{1b}[<0;") && text.hasSuffix("m") }
    private func clicks(_ p: Pane) -> Int { p.written.filter(isClick).count }

    /// Whether the test host gives a first responder at all; the keyboard is left down.
    private func keyboardWorks(_ p: Pane) -> Bool {
        p.host.focusKeyboard()
        guard p.host.term.isFirstResponder else { return false }
        _ = p.host.term.resignFirstResponder()
        return !p.host.term.isFirstResponder
    }

    // MARK: The keyboard follows the click

    /// The keyboard resizes a fitted pane on the alternate screen, and the server does not
    /// order that resize with the click's write. So nothing raises the keyboard while the
    /// click's write is out.
    func testTheKeyboardComesUpOnlyAfterTheClicksWriteWasAnswered() async throws {
        let p = await pane(Self.mouse + "menu")
        try XCTSkipUnless(keyboardWorks(p), "the test host gave no first responder")
        p.answers.held = true
        XCTAssertEqual(p.host.tap(at: CGPoint(x: 20, y: 20), shift: false, keyboardUp: false, hadSelection: false),
                       .programClickThenKeyboard)
        await wait("the click's write to be out") { p.written.count == 1 && p.answers.count == 1 }
        XCTAssertTrue(isClick(p.written[0]), "press and release, as one write")
        XCTAssertTrue(p.written[0].contains("M\u{1b}[<0;"))
        // Out and not answered: the keyboard stays down, however long that takes.
        await pause(0.3)
        XCTAssertFalse(p.host.term.isFirstResponder)
        p.answers.pass()
        await wait("the keyboard") { p.host.term.isFirstResponder }
        XCTAssertFalse(p.host.keyboardQuiet)
        XCTAssertEqual(p.written.count, 1, "the click went once")
    }

    /// Behind the fence the click is dropped, as every report is. The tap still brings the
    /// keyboard, at once: no tap is a dead one.
    func testAFencedClickIsDroppedAndTheTapStillBringsTheKeyboard() async throws {
        let p = await pane(Self.mouse + "menu")
        try XCTSkipUnless(keyboardWorks(p), "the test host gave no first responder")
        p.stream.restart()
        XCTAssertTrue(p.stream.isFenced)
        XCTAssertEqual(p.host.tap(at: CGPoint(x: 20, y: 20), shift: false, keyboardUp: false, hadSelection: false),
                       .programClickThenKeyboard)
        XCTAssertTrue(p.host.term.isFirstResponder, "at once")
        XCTAssertFalse(p.stream.hasPendingInput, "not sent and not held")
        await wait("the stream to be current again") { !p.stream.isFenced }
        await pause(0.2)
        XCTAssertEqual(clicks(p), 0, "and never sent later")
    }

    /// The pane stopped being the active one while its click was out: the keyboard is not
    /// raised for a pane the user left.
    func testTheKeyboardIsNotRaisedForAPaneThatStoppedBeingActive() async throws {
        let p = await pane(Self.mouse + "menu")
        try XCTSkipUnless(keyboardWorks(p), "the test host gave no first responder")
        p.answers.held = true
        _ = p.host.tap(at: CGPoint(x: 20, y: 20), shift: false, keyboardUp: false, hadSelection: false)
        await wait("the click's write to be out") { p.answers.count == 1 }
        p.host.isActive = false
        p.answers.pass()
        await wait("the write's answer") { !p.stream.hasPendingInput }
        await pause(0.1)
        XCTAssertFalse(p.host.term.isFirstResponder)
    }

    /// With a hardware keyboard the hide key leaves the terminal first responder with nothing
    /// showing. The next tap clicks, and then the key bar is back.
    func testWithAHardwareKeyboardTheFirstTapAfterHideClicksAndBringsTheKeyBarBack() async throws {
        let p = await pane(Self.mouse + "menu")
        try XCTSkipUnless(keyboardWorks(p), "the test host gave no first responder")
        hardware = true
        p.host.focusKeyboard()
        p.host.hideKeyboard()
        XCTAssertTrue(p.host.keyboardQuiet)
        XCTAssertEqual(p.host.tap(at: CGPoint(x: 20, y: 20), shift: false, keyboardUp: false, hadSelection: false),
                       .programClickThenKeyboard)
        XCTAssertTrue(p.host.keyboardQuiet, "not before the click is with the program")
        await wait("the click and then the key bar") { self.clicks(p) == 1 && !p.host.keyboardQuiet }
        XCTAssertTrue(p.host.term.isFirstResponder)
        XCTAssertFalse(p.host.userHidKeyboard)
    }

    /// The answer came, but the pane is no longer where a keyboard belongs: the palette or a
    /// sheet lies over it by now.
    func testTheKeyboardIsNotRaisedUnderAPaletteOrASheetThatOpenedMeanwhile() async throws {
        for cover in ["palette", "sheet"] {
            let p = await pane(Self.mouse + "menu")
            try XCTSkipUnless(keyboardWorks(p), "the test host gave no first responder")
            p.answers.held = true
            _ = p.host.tap(at: CGPoint(x: 20, y: 20), shift: false, keyboardUp: false, hadSelection: false)
            await wait("the click's write to be out") { p.answers.count == 1 }
            if cover == "palette" {
                p.host.underPalette = true
                p.host.refreshProgramFocus()
            } else {
                p.host.coverChanged(covered: true)
            }
            p.answers.pass()
            await wait("the write's answer") { !p.stream.hasPendingInput }
            await pause(0.1)
            XCTAssertFalse(p.host.term.isFirstResponder, cover)
        }
    }

    /// The user did something else to the pane while the click was out (the hide key, another
    /// touch): the keyboard that waited for the click is not theirs to get any more.
    func testTheKeyboardIsNotRaisedWhenTheUserDidSomethingElseMeanwhile() async throws {
        let p = await pane(Self.mouse + "menu")
        try XCTSkipUnless(keyboardWorks(p), "the test host gave no first responder")
        p.answers.held = true
        _ = p.host.tap(at: CGPoint(x: 20, y: 20), shift: false, keyboardUp: false, hadSelection: false)
        await wait("the click's write to be out") { p.answers.count == 1 }
        p.host.hideKeyboard()
        p.answers.pass()
        await wait("the write's answer") { !p.stream.hasPendingInput }
        await pause(0.1)
        XCTAssertFalse(p.host.term.isFirstResponder)
    }

    /// An answer that comes long after the tap (a connection that hung and came back) raises
    /// nothing: the user is no longer waiting for that tap's keyboard.
    func testTheKeyboardIsNotRaisedForAnAnswerThatCameTooLate() async throws {
        let p = await pane(Self.mouse + "menu")
        try XCTSkipUnless(keyboardWorks(p), "the test host gave no first responder")
        p.host.clickKeyboardLimit = 0.2
        p.answers.held = true
        _ = p.host.tap(at: CGPoint(x: 20, y: 20), shift: false, keyboardUp: false, hadSelection: false)
        await wait("the click's write to be out") { p.answers.count == 1 }
        await pause(0.4)
        p.answers.pass()
        await wait("the write's answer") { !p.stream.hasPendingInput }
        await pause(0.1)
        XCTAssertFalse(p.host.term.isFirstResponder)
        XCTAssertEqual(clicks(p), 1, "the click itself went")
    }

    // MARK: Never right after the report that the focus was gained

    /// A click that waits does so in the queue, from the moment of the tap: keys typed while
    /// it waits go out behind it, never ahead.
    func testKeysTypedWhileAClickWaitsStayBehindIt() async {
        let p = await pane(Self.mouse + Self.asks)
        await wait("the report that the pane is in front") { p.written.last == Self.gained }
        let before = p.written.count
        XCTAssertEqual(p.host.tap(at: CGPoint(x: 20, y: 20), shift: false, keyboardUp: true, hadSelection: false), .programClick)
        p.host.term.insertText("x")
        p.host.term.insertText("y")
        await pause(0.2)
        XCTAssertEqual(p.written.count, before, "nothing overtakes the click that waits")
        await wait("the click and then the keys") { p.written.joined().hasSuffix("xy") }
        let after = Array(p.written[before...])
        XCTAssertEqual(after.count, 2, "the click, then the keys in one write")
        XCTAssertTrue(isClick(after[0]))
        XCTAssertEqual(after[1], "xy")
    }

    /// On a slow link the report waits in the queue behind a write that is out. The program's
    /// window runs from the moment the report leaves, not from when it was queued, and the
    /// click is never in the report's write.
    func testOnASlowLinkTheClickWaitsFromTheMomentTheReportLeft() async {
        let p = await pane(Self.mouse + Self.asks)
        await wait("the report that the pane is in front") { p.written.last == Self.gained }
        await pause(ProgramFocus.activationWindow + 0.1)
        // A key's write is out, and its answer is slow.
        p.answers.held = true
        p.host.term.insertText("a")
        await wait("the key's write to be out") { p.written.last == "a" && p.answers.count == 1 }
        // The stream catches up: the report is queued behind the key. Then a tap, at once.
        p.host.streamFence(false, screen: true)
        XCTAssertEqual(p.host.tap(at: CGPoint(x: 20, y: 20), shift: false, keyboardUp: true, hadSelection: false), .programClick)
        // Longer than the window: were it timed from the queueing, the click would go at once.
        await pause(ProgramFocus.activationWindow + 0.2)
        XCTAssertEqual(p.written.last, "a", "the report has not left yet")
        p.answers.pass()
        await wait("the report to leave") { p.written.last == Self.gained }
        let left = CACurrentMediaTime()
        await pause(0.2)
        XCTAssertEqual(p.written.last, Self.gained, "the click waits out the window from here")
        await wait("the click") { self.isClick(p.written.last ?? "") }
        XCTAssertGreaterThanOrEqual(CACurrentMediaTime() - left, 0.4)
        XCTAssertEqual(Array(p.written.suffix(3)).map { self.isClick($0) ? "click" : $0 }, ["a", Self.gained, "click"],
                       "each a write of its own")
    }

    /// The program stopped tracking the mouse while a click waited (it exited to a shell): the
    /// click's bytes are not typed into whatever reads the terminal now.
    func testAClickThatWaitedIsDroppedWhenTheProgramNoLongerTracksTheMouse() async {
        let p = await pane(Self.mouse + Self.asks)
        await wait("the report that the pane is in front") { p.written.last == Self.gained }
        XCTAssertEqual(p.host.tap(at: CGPoint(x: 20, y: 20), shift: false, keyboardUp: true, hadSelection: false), .programClick)
        p.link.deliver(Array("\u{1b}[?1000l\u{1b}[?1006l$ ".utf8))
        await wait("the program to be gone") { p.host.term.core.sync(); return !p.host.term.sendsTapsToProgram }
        await pause(ProgramFocus.activationWindow + 0.3)
        XCTAssertEqual(clicks(p), 0)
        XCTAssertEqual(p.written.last, Self.gained)
    }

    /// The pane left the front while a click waited: the click is dropped.
    func testAClickThatWaitedIsDroppedWhenThePaneLeftTheFront() async {
        let p = await pane(Self.mouse + Self.asks)
        await wait("the report that the pane is in front") { p.written.last == Self.gained }
        XCTAssertEqual(p.host.tap(at: CGPoint(x: 20, y: 20), shift: false, keyboardUp: true, hadSelection: false), .programClick)
        p.host.isActive = false
        await wait("the report that the pane left the front") { p.written.last == "\u{1b}[O" }
        await pause(0.2)
        XCTAssertEqual(clicks(p), 0)
    }

    /// A program told that it gained the focus may take a press in the next 0.4 s for the
    /// click that brought the focus, and drop it. A stream that is current again says where
    /// the pane is; a tap right after that still clicks, once, when that time has passed.
    func testATapRightAfterTheStreamIsCurrentAgainClicksOnceTheWindowHasPassed() async {
        let p = await pane(Self.mouse + Self.asks)
        await wait("the report that the pane is in front") { p.written.last == Self.gained }
        // Past the first report's window.
        await pause(ProgramFocus.activationWindow + 0.1)
        // The stream caught up again (a reconnect): the pane says again that it is in front.
        let before = p.written.count
        p.host.streamFence(false, screen: true)
        await wait("the report, again") { p.written.count == before + 1 && p.written.last == Self.gained }
        let told = p.host.term.programFocus.gainedAt ?? 0
        XCTAssertEqual(p.host.tap(at: CGPoint(x: 20, y: 20), shift: false, keyboardUp: true, hadSelection: false), .programClick)
        await pause(0.2)
        XCTAssertEqual(clicks(p), 0, "not while the program may take it for the click that brought the focus")
        await wait("the click") { self.clicks(p) == 1 }
        XCTAssertGreaterThanOrEqual(CACurrentMediaTime() - told, 0.4)
        XCTAssertTrue(isClick(p.written.last ?? ""), "the click is the last thing sent, behind the report")
        await pause(0.3)
        XCTAssertEqual(clicks(p), 1, "once")
        // Later taps go at once.
        XCTAssertEqual(p.host.tap(at: CGPoint(x: 200, y: 100), shift: false, keyboardUp: true, hadSelection: false), .programClick)
        await wait("the second click, with no wait") { self.clicks(p) == 2 }
    }

    /// The same for the tap that also raises the keyboard: the click waits, and the keyboard
    /// waits for the click.
    func testTheKeyboardDownTapWaitsOutTheWindowTooAndThenRaisesTheKeyboard() async throws {
        let p = await pane(Self.mouse + Self.asks)
        try XCTSkipUnless(keyboardWorks(p), "the test host gave no first responder")
        await wait("the report that the pane is in front") { p.written.last == Self.gained }
        await pause(ProgramFocus.activationWindow + 0.1)
        p.host.streamFence(false, screen: true)
        await wait("the report, again") { p.written.filter { $0 == Self.gained }.count == 2 }
        XCTAssertEqual(p.host.tap(at: CGPoint(x: 20, y: 20), shift: false, keyboardUp: false, hadSelection: false),
                       .programClickThenKeyboard)
        await pause(0.2)
        XCTAssertEqual(clicks(p), 0)
        XCTAssertFalse(p.host.term.isFirstResponder)
        await wait("the click and then the keyboard") { self.clicks(p) == 1 && p.host.term.isFirstResponder }
    }

    /// The stream caught up once more while a click waited: the screen it was made on may be
    /// gone, and it would follow a new report. It is dropped.
    func testAClickThatWaitedIsDroppedWhenTheStreamCaughtUpAgainMeanwhile() async {
        let p = await pane(Self.mouse + Self.asks)
        await wait("the report that the pane is in front") { p.written.last == Self.gained }
        XCTAssertEqual(p.host.tap(at: CGPoint(x: 20, y: 20), shift: false, keyboardUp: true, hadSelection: false), .programClick)
        await pause(0.1)
        p.host.streamFence(false, screen: true)
        await wait("the report, again") { p.written.filter { $0 == Self.gained }.count == 2 }
        await pause(ProgramFocus.activationWindow + 0.3)
        XCTAssertEqual(clicks(p), 0)
        XCTAssertEqual(p.written.last, Self.gained)
    }

    /// A program that asked for no focus reports is told nothing, so its clicks never wait.
    func testAClickInAProgramThatAskedForNoFocusReportsNeverWaits() async {
        let p = await pane(Self.mouse)
        p.host.streamFence(false, screen: true)
        XCTAssertNil(p.host.term.programFocus.gainedAt)
        XCTAssertEqual(p.host.tap(at: CGPoint(x: 20, y: 20), shift: false, keyboardUp: true, hadSelection: false), .programClick)
        await wait("the click") { self.clicks(p) == 1 }
        XCTAssertEqual(p.written.count, 1)
    }
}
