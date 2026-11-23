import RexKit
import XCTest
@testable import Pteron

@MainActor
private final class SendSpy: TerminalEngineDelegate {
    var sent: [[UInt8]] = []
    var all: [UInt8] { sent.flatMap { $0 } }
    func engineGridChanged(cols: Int, rows: Int) {}
    func engineSend(_ bytes: [UInt8]) { sent.append(bytes) }
}

/// Counts the modifier-reset notifications; with `relock`, sets ctrl again as the key bar does for a locked key.
@MainActor
private final class ResetCounts: NSObject {
    var control = 0, meta = 0
    weak var relock: GhosttyTerminalView?

    @objc func controlReset() {
        control += 1
        relock?.controlModifier = true
    }

    @objc func metaReset() { meta += 1 }
}

/// The terminal view's input: what the key bar's keys, the system keyboard, a paste and a raw
/// send put on the wire, in the modes that change it.
@MainActor
final class GhosttyInputViewTests: XCTestCase {
    private typealias P = GhosttyInputProbe

    private func makeGhostty(_ setup: String = "") -> (GhosttyTerminalView, SendSpy) {
        let view = GhosttyTerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 240), fontSize: 12, cols: 40, rows: 10)
        let spy = SendSpy()
        view.engineDelegate = spy
        view.feed(text: setup)
        view.core.sync()
        return (view, spy)
    }

    /// Runs `action` on a fresh view in the mode `setup` sets and checks what it sends.
    private func assertSends(_ setup: String, _ what: String, _ want: [UInt8], file: StaticString = #filePath, line: UInt = #line,
                             _ action: (GhosttyTerminalView) -> Void) {
        let (view, spy) = makeGhostty(setup)
        action(view)
        XCTAssertEqual(spy.all, want, "\(what): sent \(P.show(spy.all)), want \(P.show(want))", file: file, line: line)
    }

    // MARK: The legacy encoding every shell and editor expects

    func testCursorKeysInBothCursorModes() {
        let keys: [(String, String, (GhosttyTerminalView) -> Void)] = [
            ("up", "A", { $0.sendKeyUp() }), ("down", "B", { $0.sendKeyDown() }), ("left", "D", { $0.sendKeyLeft() }),
            ("right", "C", { $0.sendKeyRight() }), ("home", "H", { $0.sendKeyHome() }), ("end", "F", { $0.sendKeyEnd() }),
        ]
        for (mode, setup, lead) in [("normal", "", "\u{1b}["), ("DECCKM", P.cursorKeys, "\u{1b}O")] {
            for (name, final, action) in keys { assertSends(setup, "\(mode) \(name)", P.bytes(lead + final), action) }
        }
        let (g, spy) = makeGhostty(P.cursorKeys)
        g.sendKeyUp()
        g.sendKeyEnd()
        XCTAssertEqual(spy.sent, [P.bytes("\u{1b}OA"), P.bytes("\u{1b}OF")])
    }

    func testTypedTextIsSentAsItsBytesInEveryMode() {
        for (mode, setup) in [("normal", ""), ("DECCKM", P.cursorKeys), ("DECBKM", P.backarrow), ("bracketed", P.bracketedPaste)] {
            for text in ["a", "A", "~", " ", "é", "日本語", "😀", "👨‍👩‍👧", "e\u{301}", "ls -la"] {
                assertSends(setup, "\(mode) insertText \(text.debugDescription)", P.bytes(text)) { $0.insertText(text) }
            }
            // A line feed from the keyboard is the Return key.
            assertSends(setup, "\(mode) insertText \\n", [0x0d]) { $0.insertText("\n") }
            // DECBKM really changes Backspace.
            assertSends(setup, "\(mode) deleteBackward", [mode == "DECBKM" ? 0x08 : 0x7f]) { $0.deleteBackward() }
        }
    }

    func testOneShotControlSendsTheControlCharacter() {
        // Every character a legacy terminal has a control character for.
        var table: [(String, UInt8)] = Array("abcdefghijklmnopqrstuvwxyz").map { (String($0), $0.asciiValue! - 0x60) }
        table += [("A", 0x01), ("C", 0x03), ("Z", 0x1a), ("[", 0x1b), ("\\", 0x1c), ("]", 0x1d), ("^", 0x1e), ("_", 0x1f),
                  ("@", 0x00), (" ", 0x00), ("/", 0x1f), ("?", 0x7f),
                  ("2", 0x00), ("3", 0x1b), ("4", 0x1c), ("5", 0x1d), ("6", 0x1e), ("7", 0x1f), ("8", 0x7f)]
        for (text, byte) in table {
            assertSends("", "ctrl + \(text.debugDescription)", [byte]) {
                $0.controlModifier = true
                $0.insertText(text)
            }
        }
    }

    func testOneShotMetaSendsEscapeThenTheText() {
        for text in ["b", "B", ".", "1", " ", "é", "日本"] {
            assertSends("", "alt + \(text.debugDescription)", [0x1b] + P.bytes(text)) {
                $0.metaModifier = true
                $0.insertText(text)
            }
        }
    }

    func testPasteInBothPasteModes() {
        // In both modes the bytes that could end a bracket or act as a key (ESC, NUL, DEL, ^C)
        // are replaced by spaces. Without bracketed paste a line end is what Return sends.
        let plain: [(String, String)] = [
            ("hello", "hello"), ("two words", "two words"), ("a\nb", "a\rb"), ("a\r\nb\n", "a\r\rb\r"),
            ("x\u{1b}[201~y", "x [201~y"), ("tab\there", "tab\there"), ("nul\u{0}\u{7f}\u{3}z", "nul   z"),
            ("日本語 😀", "日本語 😀"),
        ]
        for (text, want) in plain { assertSends("", "plain paste \(text.debugDescription)", P.bytes(want)) { $0.pasteText(text) } }
        // Bracketed: the text between the two marks, line ends as they are.
        let bracketed: [(String, String)] = [
            ("hello", "hello"), ("two words", "two words"), ("a\nb", "a\nb"), ("a\r\nb\n", "a\r\nb\n"),
            ("x\u{1b}[201~y", "x [201~y"), ("tab\there", "tab\there"), ("nul\u{0}\u{7f}\u{3}z", "nul   z"),
            ("日本語 😀", "日本語 😀"),
        ]
        for (text, want) in bracketed {
            assertSends(P.bracketedPaste, "bracketed paste \(text.debugDescription)", P.bytes("\u{1b}[200~" + want + "\u{1b}[201~")) {
                $0.pasteText(text)
            }
        }
    }

    func testRawSendsGoOutUnchanged() {
        assertSends("", "send(data:)", [0x1b, 0x5b, 0x41, 0x03]) { $0.send(data: [0x1b, 0x5b, 0x41, 0x03][...]) }
        // Text for the program, as a debug launch types it. In legacy mode typing it is the same bytes.
        for text in ["ls -la\r", "echo hi\r", "q", "\u{03}", "\u{1b}", "x\ty"] {
            assertSends("", "send(txt:) \(text.debugDescription)", P.bytes(text)) { $0.send(txt: text) }
            assertSends(P.cursorKeys, "DECCKM send(txt:) \(text.debugDescription)", P.bytes(text)) { $0.send(txt: text) }
        }
    }

    // MARK: Paste

    func testPasteIsBracketedOnlyWhenTheProgramAsked() {
        let (plain, plainSpy) = makeGhostty()
        plain.pasteText("echo one\necho two")
        // Without bracketed paste a newline is what Return sends.
        XCTAssertEqual(plainSpy.sent, [P.bytes("echo one\recho two")])

        let (bracketed, spy) = makeGhostty(P.bracketedPaste)
        bracketed.pasteText("echo one\necho two")
        XCTAssertEqual(spy.sent, [P.bytes("\u{1b}[200~echo one\necho two\u{1b}[201~")])
        // Text can't close the bracket itself, and control bytes don't get through.
        spy.sent = []
        bracketed.pasteText("a\u{1b}[201~rm -rf\u{03}")
        XCTAssertEqual(spy.sent, [P.bytes("\u{1b}[200~a [201~rm -rf \u{1b}[201~")])
        spy.sent = []
        bracketed.pasteText("")
        XCTAssertEqual(spy.sent, [])

        // The program turns it off again.
        bracketed.feed(text: "\u{1b}[?2004l")
        bracketed.core.sync()
        bracketed.pasteText("x\ny")
        XCTAssertEqual(spy.sent, [P.bytes("x\ry")])
    }

    // MARK: Key bar modifiers

    func testOneShotModifiersClearAndNotify() {
        let (view, spy) = makeGhostty()
        // Observers the way the key bar adds them: for this view only. A second pair counts every post.
        let counts = ResetCounts(), all = ResetCounts()
        let nc = NotificationCenter.default
        nc.addObserver(counts, selector: #selector(ResetCounts.controlReset), name: .terminalEngineControlModifierReset, object: view)
        nc.addObserver(counts, selector: #selector(ResetCounts.metaReset), name: .terminalEngineMetaModifierReset, object: view)
        nc.addObserver(all, selector: #selector(ResetCounts.controlReset), name: .terminalEngineControlModifierReset, object: nil)
        nc.addObserver(all, selector: #selector(ResetCounts.metaReset), name: .terminalEngineMetaModifierReset, object: nil)
        defer {
            nc.removeObserver(counts)
            nc.removeObserver(all)
        }

        // No flag, no notification.
        view.insertText("c")
        XCTAssertEqual([counts.control, counts.meta], [0, 0])

        view.controlModifier = true
        view.insertText("c")
        XCTAssertEqual(spy.sent.last, [0x03])
        XCTAssertFalse(view.controlModifier)
        XCTAssertEqual([counts.control, counts.meta], [1, 0])
        // One shot: the next key is plain.
        view.insertText("c")
        XCTAssertEqual(spy.sent.last, P.bytes("c"))
        XCTAssertEqual(counts.control, 1)

        view.metaModifier = true
        view.insertText("b")
        XCTAssertEqual(spy.sent.last, P.bytes("\u{1b}b"))
        XCTAssertFalse(view.metaModifier)
        XCTAssertEqual([counts.control, counts.meta], [1, 1])

        // Both at once, and on Backspace and Return too.
        view.controlModifier = true
        view.metaModifier = true
        view.insertText("c")
        XCTAssertEqual(spy.sent.last, P.bytes("\u{1b}\u{03}"))
        XCTAssertEqual([counts.control, counts.meta], [2, 2])
        view.metaModifier = true
        view.deleteBackward()
        XCTAssertEqual(spy.sent.last, P.bytes("\u{1b}\u{7f}"))
        view.metaModifier = true
        view.insertText("\n")
        XCTAssertEqual(spy.sent.last, P.bytes("\u{1b}\r"))
        XCTAssertEqual(counts.meta, 4)

        // The bar's own keys don't use the flags: it applies its modifiers itself.
        view.controlModifier = true
        view.sendKeyUp()
        view.send(data: [0x61][...])
        XCTAssertTrue(view.controlModifier)
        XCTAssertEqual(counts.control, 2)
        // Every post named the view that used the flag.
        XCTAssertEqual([all.control, all.meta], [counts.control, counts.meta])
    }

    func testLockedModifierCanBeSetAgainFromTheNotification() {
        // What the key bar does for a locked ctrl: set the flag again when told it was used.
        let (view, spy) = makeGhostty()
        let lock = ResetCounts()
        lock.relock = view
        NotificationCenter.default.addObserver(lock, selector: #selector(ResetCounts.controlReset),
                                               name: .terminalEngineControlModifierReset, object: view)
        defer { NotificationCenter.default.removeObserver(lock) }
        view.controlModifier = true
        view.insertText("a")
        view.insertText("e")
        XCTAssertEqual(spy.sent, [[0x01], [0x05]])
        XCTAssertTrue(view.controlModifier)
    }

    // MARK: Kitty protocol through the view

    func testSystemKeyboardUnderKittyProtocol() {
        let (one, oneSpy) = makeGhostty(P.kittyDisambiguate)
        one.insertText("a")
        one.insertText("\n")
        one.deleteBackward()
        one.controlModifier = true
        one.insertText("c")
        XCTAssertEqual(oneSpy.sent, [P.bytes("a"), P.bytes("\r"), [0x7f], P.bytes("\u{1b}[99;5u")])

        let (all, allSpy) = makeGhostty(P.kittyAll)
        all.insertText("a")
        all.insertText("\n")
        all.deleteBackward()
        all.insertText("日本")
        XCTAssertEqual(allSpy.sent, [P.bytes("\u{1b}[97;;97u"), P.bytes("\u{1b}[13u"), P.bytes("\u{1b}[127u"), P.bytes("日本")])
        allSpy.sent = []
        all.sendKeyUp()
        all.send(txt: "ok\r")
        XCTAssertEqual(allSpy.sent, [P.bytes("\u{1b}[1;1:1A"), P.bytes("\u{1b}[111;;111u\u{1b}[107;;107u\u{1b}[13u")])
    }

    // MARK: Hardware keys

    private func down(_ view: GhosttyTerminalView, _ spelling: String, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        guard let chord = P.press(spelling) else {
            XCTFail("bad chord \(spelling)", file: file, line: line)
            return false
        }
        return view.hardwareKeyDown(usage: chord.usage, flags: chord.flags, characters: chord.characters,
                                    charactersIgnoringModifiers: chord.ignoringModifiers)
    }

    private func up(_ view: GhosttyTerminalView, _ key: String) {
        if let usage = P.usage(key) { view.hardwareKeyUp(usage: usage) }
    }

    func testHardwareKeysAreEncodedOrLeftToTheTextSystem() {
        let (view, spy) = makeGhostty()
        // Encoded here: the press is consumed.
        XCTAssertTrue(down(view, "ctrl+c"))
        XCTAssertTrue(down(view, "up"))
        XCTAssertTrue(down(view, "alt+b"))
        XCTAssertTrue(down(view, "shift+tab"))
        XCTAssertTrue(down(view, "escape"))
        XCTAssertTrue(down(view, "ctrl+left"))
        XCTAssertEqual(spy.sent, [[0x03], P.bytes("\u{1b}[A"), P.bytes("\u{1b}b"), P.bytes("\u{1b}[Z"), [0x1b], P.bytes("\u{1b}[1;5D")])
        for key in ["c", "up", "b", "tab", "escape", "left"] { up(view, key) }

        // A key that types: nothing is sent until the text system hands the text back.
        spy.sent = []
        XCTAssertFalse(down(view, "a"))
        XCTAssertEqual(spy.sent, [])
        view.insertText("a")
        up(view, "a")
        XCTAssertFalse(down(view, "shift+a"))
        view.insertText("A")
        up(view, "a")
        XCTAssertFalse(down(view, "enter"))
        view.insertText("\n")
        up(view, "enter")
        XCTAssertFalse(down(view, "backspace"))
        view.deleteBackward()
        up(view, "backspace")
        XCTAssertEqual(spy.sent, [P.bytes("a"), P.bytes("A"), P.bytes("\r"), [0x7f]])

        // Command shortcuts are not ours.
        spy.sent = []
        XCTAssertFalse(down(view, "cmd+c"))
        XCTAssertFalse(down(view, "cmd+up"))
        XCTAssertEqual(spy.sent, [])
        XCTAssertNil(view.inputState.pending)
    }

    func testHardwareTextKeysCarryTheirKeyUnderKittyProtocol() {
        let (view, spy) = makeGhostty(P.kittyAll)
        XCTAssertFalse(down(view, "shift+a"))
        view.insertText("A")
        XCTAssertEqual(spy.sent.last, P.bytes("\u{1b}[97:65;2;65u"))
        up(view, "a")
        XCTAssertEqual(spy.sent.last, P.bytes("\u{1b}[97:65;2:3u"))

        // Shift+Return keeps its shift, which `insertText("\n")` alone can't tell.
        XCTAssertFalse(down(view, "shift+enter"))
        view.insertText("\n")
        XCTAssertEqual(spy.sent.last, P.bytes("\u{1b}[13;2u"))
        up(view, "enter")
        XCTAssertEqual(spy.sent.last, P.bytes("\u{1b}[13;2:3u"))

        XCTAssertFalse(down(view, "backspace"))
        view.deleteBackward()
        XCTAssertEqual(spy.sent.last, P.bytes("\u{1b}[127u"))
        up(view, "backspace")
        XCTAssertEqual(spy.sent.last, P.bytes("\u{1b}[127;1:3u"))

        // A key encoded here reports its release too; a release with no press reports nothing.
        spy.sent = []
        XCTAssertTrue(down(view, "up"))
        up(view, "up")
        up(view, "up")
        XCTAssertEqual(spy.sent, [P.bytes("\u{1b}[1;1:1A"), P.bytes("\u{1b}[1;1:3A")])

        // Legacy mode: releases send nothing.
        let (legacy, legacySpy) = makeGhostty()
        XCTAssertTrue(down(legacy, "up"))
        up(legacy, "up")
        XCTAssertFalse(down(legacy, "shift+enter"))
        legacy.insertText("\n")
        up(legacy, "enter")
        XCTAssertEqual(legacySpy.sent, [P.bytes("\u{1b}[A"), P.bytes("\u{1b}[27;2;13~")])
    }

    func testTextThatIsNotFromThePendingKeyIgnoresIt() {
        let (view, spy) = makeGhostty(P.kittyAll)
        // An input method commits several characters while a key is down: plain text, not that key.
        XCTAssertFalse(down(view, "shift+a"))
        view.insertText("日本")
        XCTAssertEqual(spy.sent, [P.bytes("日本")])
        // Return doesn't take a letter's event, and a released key leaves nothing behind.
        view.insertText("\n")
        XCTAssertEqual(spy.sent.last, P.bytes("\u{1b}[13u"))
        up(view, "a")
        XCTAssertNil(view.inputState.pending)
        view.insertText("a")
        XCTAssertEqual(spy.sent.last, P.bytes("\u{1b}[97;;97u"))
    }

    func testPageKeysScrollLocallyUnlessTheProgramTookTheCursorKeys() {
        let (shell, shellSpy) = makeGhostty()
        XCTAssertTrue(down(shell, "pageup"))
        XCTAssertTrue(down(shell, "pagedown"))
        XCTAssertEqual(shellSpy.sent, [], "plain Page Up / Down scroll the scrollback")
        XCTAssertTrue(down(shell, "shift+pageup"))
        XCTAssertEqual(shellSpy.sent, [P.bytes("\u{1b}[5;2~")])

        let (app, appSpy) = makeGhostty(P.cursorKeys)
        XCTAssertTrue(down(app, "pageup"))
        XCTAssertTrue(down(app, "pagedown"))
        XCTAssertEqual(appSpy.sent, [P.bytes("\u{1b}[5~"), P.bytes("\u{1b}[6~")])
    }

    func testHeldKeyRepeatsUntilReleased() async throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first { window.windowScene = scene }
        let (view, spy) = makeGhostty(P.kittyAll)
        window.addSubview(view)
        window.isHidden = false
        defer { window.isHidden = true }
        try XCTSkipUnless(view.becomeFirstResponder(), "the test host gave no first responder")
        spy.sent = []

        XCTAssertTrue(down(view, "up"))
        try await Task.sleep(nanoseconds: 750_000_000)
        up(view, "up")
        let held = spy.sent
        // Press, repeats after 0.4 s every 0.1 s, release.
        XCTAssertEqual(held.first, P.bytes("\u{1b}[1;1:1A"))
        XCTAssertEqual(held.last, P.bytes("\u{1b}[1;1:3A"))
        let repeats = held.dropFirst().dropLast()
        XCTAssertGreaterThanOrEqual(repeats.count, 2)
        XCTAssertTrue(repeats.allSatisfy { $0 == P.bytes("\u{1b}[1;1:2A") })

        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(spy.sent.count, held.count, "nothing repeats after the release")

        // Losing the keyboard stops a repeat too.
        XCTAssertTrue(down(view, "down"))
        _ = view.resignFirstResponder()
        let after = spy.sent.count
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(spy.sent.count, after)
    }

    // MARK: Focus

    /// The program's focus is the front pane's (`ProgramFocus`), which the host says; the
    /// keyboard coming and going says nothing.
    func testFocusReportsFollowTheFrontPaneAndOnlyWhenTheProgramAsked() {
        let (quiet, quietSpy) = makeGhostty()
        quiet.setProgramFocus(true)
        quiet.setProgramFocus(false)
        XCTAssertEqual(quietSpy.sent, [], "no focus reports without mode 1004")

        let (view, spy) = makeGhostty(P.focusEvents)
        view.setProgramFocus(true)
        XCTAssertEqual(spy.sent, [P.bytes("\u{1b}[I")])
        // Already in front: no second report.
        view.setProgramFocus(true)
        XCTAssertEqual(spy.sent.count, 1)
        view.setProgramFocus(false)
        XCTAssertEqual(spy.sent, [P.bytes("\u{1b}[I"), P.bytes("\u{1b}[O")])

        // The program turns reports off again.
        view.feed(text: "\u{1b}[?1004l")
        view.core.sync()
        view.setProgramFocus(true)
        view.setProgramFocus(false)
        XCTAssertEqual(spy.sent.count, 2)
    }

    func testTheKeyboardComingAndGoingSendsNoFocusReport() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first { window.windowScene = scene }
        window.isHidden = false
        defer { window.isHidden = true }

        let (view, spy) = makeGhostty(P.focusEvents)
        window.addSubview(view)
        defer { view.removeFromSuperview() }
        view.setProgramFocus(true)
        XCTAssertEqual(spy.sent, [P.bytes("\u{1b}[I")])
        try XCTSkipUnless(view.becomeFirstResponder(), "the test host gave no first responder")
        XCTAssertTrue(view.resignFirstResponder())
        XCTAssertTrue(view.becomeFirstResponder())
        XCTAssertTrue(view.resignFirstResponder())
        XCTAssertEqual(spy.sent, [P.bytes("\u{1b}[I")], "the keyboard is not the program's focus")
    }

    func testFocusReportBytes() {
        XCTAssertEqual(P.core().input.focusReport(gained: true), [])
        XCTAssertEqual(P.core().input.focusReport(gained: false), [])
        let core = P.core(P.focusEvents)
        XCTAssertEqual(core.input.focusReport(gained: true), P.bytes("\u{1b}[I"))
        XCTAssertEqual(core.input.focusReport(gained: false), P.bytes("\u{1b}[O"))
    }

    // MARK: Keyboard traits

    func testKeyboardTraits() {
        let (view, _) = makeGhostty()
        XCTAssertEqual(view.autocorrectionType, .no)
        XCTAssertEqual(view.autocapitalizationType, UITextAutocapitalizationType.none)
        XCTAssertEqual(view.spellCheckingType, .no)
        XCTAssertEqual(view.smartQuotesType, .no)
        XCTAssertEqual(view.smartDashesType, .no)
        XCTAssertEqual(view.smartInsertDeleteType, .no)
        XCTAssertEqual(view.inlinePredictionType, .no)
        XCTAssertFalse(view.isSecureTextEntry)
        var theme = ThemeStore.fallback
        theme.appearance = "dark"
        view.apply(theme: theme)
        XCTAssertEqual(view.keyboardAppearance, .dark)
        theme.appearance = "light"
        view.apply(theme: theme)
        XCTAssertEqual(view.keyboardAppearance, .light)

        // The host's accessory and input views are what the keyboard shows.
        let bar = UIView(), keys = UIView()
        view.inputAccessoryView = bar
        view.inputView = keys
        XCTAssertTrue(view.inputAccessoryView === bar)
        XCTAssertTrue(view.inputView === keys)
    }
}
