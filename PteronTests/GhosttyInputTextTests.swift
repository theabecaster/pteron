import XCTest
@testable import Pteron

@MainActor
private final class SendSpy: TerminalEngineDelegate {
    var sent: [[UInt8]] = []
    func engineGridChanged(cols: Int, rows: Int) {}
    func engineSend(_ bytes: [UInt8]) { sent.append(bytes) }
}

/// Text from the system keyboard: how it becomes key events, and the `UITextInput` shadow
/// document behind input methods, dictation and the space-bar trackpad.
@MainActor
final class GhosttyInputTextTests: XCTestCase {
    private typealias P = GhosttyInputProbe

    private func typed(_ core: GhosttyCore, _ text: String) -> [UInt8] {
        GhosttyInputKeymap.typed(text).flatMap { core.input.encode($0) }
    }

    // MARK: Typed text → key events

    func testTypedTextIsSentAsIsInLegacyModes() {
        for setup in ["", P.cursorKeys, P.keypadApplication, P.bracketedPaste] {
            let core = P.core(setup)
            // Every ASCII byte: typing it sends it. A line feed is the Return key.
            for byte in UInt8(0)..<128 {
                let text = String(UnicodeScalar(byte))
                XCTAssertEqual(typed(core, text), byte == 0x0a ? [0x0d] : [byte], "byte \(byte)")
            }
            for text in ["hello world", "é", "日本語", "😀👍", "👨‍👩‍👧", "e\u{301}", "tab\tsep", "esc\u{1b}[A", "a\u{03}b"] {
                XCTAssertEqual(typed(core, text), P.bytes(text), text.debugDescription)
            }
            // CR LF is one Return.
            XCTAssertEqual(typed(core, "a\r\nb\nc\rd"), P.bytes("a\rb\rc\rd"))
        }
    }

    func testTypedTextNamesItsKeys() {
        // One event per ASCII character, with the US key that types it; other text travels whole.
        let keys = GhosttyInputKeymap.typed("aA1! é日本\n")
        XCTAssertEqual(keys.map(\.text), ["a", "A", "1", "!", " ", "é日本", ""])
        XCTAssertEqual(keys.map(\.unshifted), [0x61, 0x61, 0x31, 0x31, 0x20, 0, 0])
        XCTAssertEqual(keys[0].key, keys[1].key)
        XCTAssertEqual(keys[2].key, keys[3].key)
        XCTAssertEqual(keys[5].key, GhosttyInputKey.unidentified)
        XCTAssertNotEqual(keys[6].key, GhosttyInputKey.unidentified)
        XCTAssertTrue(keys.allSatisfy { $0.mods == 0 && $0.action == .press })
        XCTAssertEqual(GhosttyInputKeymap.typed(""), [])
        // Control characters are never text for the encoder; function-key code points are dropped.
        XCTAssertTrue(GhosttyInputKeymap.typed("\u{03}\u{1b}\t\r\u{7f}\u{F700}").allSatisfy { $0.text.isEmpty || $0.text == "c" })
        XCTAssertEqual(GhosttyInputKeymap.typed("\u{F700}\u{F72C}"), [])
    }

    func testTypedTextUnderKittyProtocol() {
        let one = P.core(P.kittyDisambiguate)
        XCTAssertEqual(typed(one, "hi\r"), P.bytes("hi\r"))
        XCTAssertEqual(typed(one, "\u{1b}"), P.bytes("\u{1b}[27u"))
        XCTAssertEqual(typed(one, "\u{03}"), P.bytes("\u{1b}[99;5u"))
        let all = P.core(P.kittyAll)
        XCTAssertEqual(typed(all, "aA"), P.bytes("\u{1b}[97;;97u\u{1b}[97;;65u"))
        XCTAssertEqual(typed(all, "\r"), P.bytes("\u{1b}[13u"))
        XCTAssertEqual(typed(all, "\t"), P.bytes("\u{1b}[9u"))
        XCTAssertEqual(typed(all, "\u{7f}"), P.bytes("\u{1b}[127u"))
        // Text no key types is sent as text.
        XCTAssertEqual(typed(all, "日本"), P.bytes("日本"))
    }

    func testModifiersOnTypedText() {
        func with(_ mods: UInt16, _ core: GhosttyCore, _ text: String) -> [UInt8] {
            var keys = GhosttyInputKeymap.typed(text)
            keys[0].mods |= mods
            return keys.flatMap { core.input.encode($0) }
        }
        let legacy = P.core()
        XCTAssertEqual(with(GhosttyInputKey.ctrl, legacy, "c"), [0x03])
        // An uppercase letter from the screen keyboard is still that letter's control character.
        XCTAssertEqual(with(GhosttyInputKey.ctrl, legacy, "C"), [0x03])
        XCTAssertEqual(with(GhosttyInputKey.ctrl, legacy, "["), [0x1b])
        XCTAssertEqual(with(GhosttyInputKey.ctrl, legacy, "i"), [0x09])
        XCTAssertEqual(with(GhosttyInputKey.ctrl, legacy, " "), [0x00])
        XCTAssertEqual(with(GhosttyInputKey.alt, legacy, "b"), P.bytes("\u{1b}b"))
        XCTAssertEqual(with(GhosttyInputKey.alt, legacy, "é"), P.bytes("\u{1b}é"))
        XCTAssertEqual(with(GhosttyInputKey.alt, legacy, "\n"), P.bytes("\u{1b}\r"))
        XCTAssertEqual(with(GhosttyInputKey.alt | GhosttyInputKey.ctrl, legacy, "c"), P.bytes("\u{1b}\u{03}"))
        // Only the first key of longer text takes them.
        XCTAssertEqual(with(GhosttyInputKey.ctrl, legacy, "ab"), [0x01, 0x62])

        let kitty = P.core(P.kittyDisambiguate)
        XCTAssertEqual(with(GhosttyInputKey.ctrl, kitty, "c"), P.bytes("\u{1b}[99;5u"))
        XCTAssertEqual(with(GhosttyInputKey.ctrl, kitty, "é"), P.bytes("\u{1b}[233;5u"))
        XCTAssertEqual(with(GhosttyInputKey.alt, kitty, "\n"), P.bytes("\u{1b}[13;3u"))
    }

    // MARK: Paste encoder

    func testPasteEncoding() {
        let plain = P.core().input, bracketed = P.core(P.bracketedPaste).input
        XCTAssertFalse(P.core().input.modes.bracketedPaste)
        XCTAssertTrue(P.core(P.bracketedPaste).input.modes.bracketedPaste)
        XCTAssertEqual(plain.paste("hello"), P.bytes("hello"))
        XCTAssertEqual(bracketed.paste("hello"), P.bytes("\u{1b}[200~hello\u{1b}[201~"))
        // Unbracketed: every newline is a carriage return. Bracketed: the text is kept.
        XCTAssertEqual(plain.paste("a\nb\r\nc"), P.bytes("a\rb\r\rc"))
        XCTAssertEqual(bracketed.paste("a\nb\r\nc"), P.bytes("\u{1b}[200~a\nb\r\nc\u{1b}[201~"))
        // Unsafe control bytes become spaces; tabs stay.
        XCTAssertEqual(plain.paste("x\u{1b}[201~\u{0}\u{7f}\u{3}\ty"), P.bytes("x [201~   \ty"))
        XCTAssertEqual(bracketed.paste("x\u{1b}[201~y"), P.bytes("\u{1b}[200~x [201~y\u{1b}[201~"))
        XCTAssertEqual(plain.paste("日本語 😀"), P.bytes("日本語 😀"))
        XCTAssertEqual(plain.paste(""), [])
        XCTAssertEqual(bracketed.paste(""), [])
        // Long text: the encoder is asked for the size first.
        let long = String(repeating: "0123456789abcdef", count: 4096)
        XCTAssertEqual(bracketed.paste(long), P.bytes("\u{1b}[200~" + long + "\u{1b}[201~"))
    }

    // MARK: Shadow document

    func testDocumentInsertAndDelete() {
        var doc = GhosttyInputDocument()
        XCTAssertTrue(doc.isEmpty)
        // Nothing of ours to delete: the program still gets a Backspace.
        XCTAssertEqual(doc.deleteBackward().backspaces, 1)
        doc.insert("ab")
        doc.insert("👍")
        doc.insert("e\u{301}")
        XCTAssertEqual(doc.text, "ab👍e\u{301}")
        XCTAssertEqual(doc.selected, NSRange(location: 6, length: 0))
        // One Backspace per character, whatever its length in UTF-16.
        XCTAssertEqual(doc.deleteBackward().backspaces, 1)
        XCTAssertEqual(doc.text, "ab👍")
        XCTAssertEqual(doc.deleteBackward().backspaces, 1)
        XCTAssertEqual(doc.text, "ab")
        doc.select(NSRange(location: 0, length: 2))
        XCTAssertEqual(doc.deleteBackward().backspaces, 2)
        XCTAssertTrue(doc.isEmpty)
        XCTAssertEqual(doc.selected, NSRange(location: 0, length: 0))
    }

    func testDocumentMarkedText() {
        var doc = GhosttyInputDocument()
        doc.insert("go ")
        doc.setMarked("に", selection: NSRange(location: 1, length: 0))
        XCTAssertTrue(doc.isComposing)
        XCTAssertEqual(doc.marked, NSRange(location: 3, length: 1))
        doc.setMarked("にほ", selection: NSRange(location: 2, length: 0))
        XCTAssertEqual(doc.text, "go にほ")
        XCTAssertEqual(doc.markedText(), "にほ")
        XCTAssertEqual(doc.selected, NSRange(location: 5, length: 0))
        // Committing replaces the marked text.
        doc.insert("日本")
        XCTAssertEqual(doc.text, "go 日本")
        XCTAssertFalse(doc.isComposing)
        XCTAssertEqual(doc.selected, NSRange(location: 5, length: 0))

        // Deleting marked text is the input method's business: no Backspace for the program.
        doc.setMarked("x", selection: NSRange(location: 1, length: 0))
        XCTAssertEqual(doc.deleteBackward().backspaces, 0)
        XCTAssertEqual(doc.text, "go 日本")
        XCTAssertFalse(doc.isComposing)
        // Clearing it.
        doc.setMarked("y", selection: NSRange(location: 1, length: 0))
        doc.setMarked(nil, selection: NSRange(location: 0, length: 0))
        XCTAssertEqual(doc.text, "go 日本")
        XCTAssertNil(doc.marked)
    }

    func testDocumentReplaceAndCaret() {
        var doc = GhosttyInputDocument()
        doc.insert("hello word")
        // Dictation revises the last word: four characters go, five come.
        XCTAssertEqual(doc.replace(NSRange(location: 6, length: 4), with: "world"), GhosttyInputEdit(backspaces: 4, text: "world"))
        XCTAssertEqual(doc.text, "hello world")
        XCTAssertEqual(doc.selected, NSRange(location: 11, length: 0))
        // Ranges are cut to the document and never split a character.
        XCTAssertEqual(doc.clamped(NSRange(location: 9, length: 50)), NSRange(location: 9, length: 2))
        XCTAssertEqual(doc.substring(NSRange(location: 0, length: 5)), "hello")
        doc.reset()
        doc.insert("a👍b")
        XCTAssertEqual(doc.clamped(NSRange(location: 2, length: 1)), NSRange(location: 1, length: 2))
        doc.moveCaret(by: -1)
        XCTAssertEqual(doc.selected.location, 3)
        doc.moveCaret(by: -1)
        XCTAssertEqual(doc.selected.location, 1)
        doc.moveCaret(by: -5)
        XCTAssertEqual(doc.selected.location, 0)
        doc.moveCaret(by: 2)
        XCTAssertEqual(doc.selected.location, 3)
        doc.moveCaret(by: 9)
        XCTAssertEqual(doc.selected.location, 4)
    }

    // MARK: UITextInput on the view

    private func makeView(_ setup: String = "") -> (GhosttyTerminalView, SendSpy) {
        let view = GhosttyTerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 240), fontSize: 12, cols: 40, rows: 10)
        let spy = SendSpy()
        view.engineDelegate = spy
        view.feed(text: setup)
        view.core.sync()
        return (view, spy)
    }

    func testMarkedTextIsSentOnlyWhenCommitted() {
        let (view, spy) = makeView()
        XCTAssertFalse(view.hasText)
        view.setMarkedText("n", selectedRange: NSRange(location: 1, length: 0))
        view.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0))
        view.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0))
        XCTAssertEqual(spy.sent, [], "composing sends nothing")
        XCTAssertNotNil(view.markedTextRange)
        XCTAssertEqual(view.markedTextRange.flatMap { view.text(in: $0) }, "にほん")
        XCTAssertTrue(view.hasText)

        // While composing, hardware keys belong to the input method.
        for spelling in ["escape", "up", "tab", "enter", "backspace"] {
            let p = P.press(spelling)!
            XCTAssertFalse(view.hardwareKeyDown(usage: p.usage, flags: p.flags, characters: p.characters,
                                                charactersIgnoringModifiers: p.ignoringModifiers), spelling)
            view.hardwareKeyUp(usage: p.usage)
        }
        XCTAssertEqual(spy.sent, [])

        view.insertText("日本")
        XCTAssertNil(view.markedTextRange)
        XCTAssertEqual(spy.sent, [P.bytes("日本")])

        // unmarkText commits what was composed.
        view.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0))
        view.unmarkText()
        XCTAssertNil(view.markedTextRange)
        XCTAssertEqual(spy.sent, [P.bytes("日本"), P.bytes("か")])
        XCTAssertEqual(view.inputState.document.text, "日本か")

        // Return ends the line the keyboard was editing.
        view.insertText("\n")
        XCTAssertFalse(view.hasText)
        XCTAssertEqual(spy.sent.last, [0x0d])
    }

    func testDictationAndReplace() {
        let (view, spy) = makeView()
        view.insertText("hello word")
        spy.sent = []
        let range = view.textRange(from: view.position(from: view.beginningOfDocument, offset: 6)!, to: view.endOfDocument)!
        XCTAssertEqual(view.text(in: range), "word")
        view.replace(range, withText: "world")
        // Four Backspaces take "word" off the program's line, then the new text, in one write.
        XCTAssertEqual(spy.sent, [[0x7f, 0x7f, 0x7f, 0x7f] + P.bytes("world")])
        XCTAssertEqual(view.inputState.document.text, "hello world")

        // DECBKM applies to those Backspaces too.
        let (bs, bsSpy) = makeView(P.backarrow)
        bs.insertText("ab")
        bsSpy.sent = []
        bs.replace(bs.textRange(from: bs.beginningOfDocument, to: bs.endOfDocument)!, withText: "c")
        XCTAssertEqual(bsSpy.sent, [[0x08, 0x08, 0x63]])

        view.insertDictationResult([])
        XCTAssertEqual(spy.sent.count, 1)
    }

    func testDeleteBackwardSendsOneBackspacePerCharacter() {
        let (view, spy) = makeView()
        view.insertText("ab👍")
        spy.sent = []
        view.deleteBackward()
        XCTAssertEqual(spy.sent, [[0x7f]])
        view.selectedTextRange = view.textRange(from: view.beginningOfDocument, to: view.endOfDocument)
        view.deleteBackward()
        XCTAssertEqual(spy.sent, [[0x7f], [0x7f, 0x7f]])
        // An empty document still deletes: the prompt has text the keyboard never saw.
        XCTAssertFalse(view.hasText)
        view.deleteBackward()
        XCTAssertEqual(spy.sent.count, 3)
        XCTAssertEqual(spy.sent.last, [0x7f])
    }

    func testOtherInputForgetsTheShadowDocument() {
        let (view, _) = makeView()
        let resets: [(String, (GhosttyTerminalView) -> Void)] = [
            ("arrow", { $0.sendKeyLeft() }), ("raw bytes", { $0.send(data: [0x15][...]) }), ("paste", { $0.pasteText("x") }),
            ("typed", { $0.send(txt: "y") }), ("return", { $0.insertText("\n") }),
        ]
        for (name, action) in resets {
            view.insertText("abc")
            XCTAssertTrue(view.hasText)
            action(view)
            XCTAssertFalse(view.hasText, name)
        }
    }

    func testSpaceBarTrackpadSendsArrows() {
        let (view, spy) = makeView(P.cursorKeys)
        view.insertText("abc")
        spy.sent = []
        view.beginFloatingCursor(at: CGPoint(x: 100, y: 100))
        view.updateFloatingCursor(at: CGPoint(x: 97, y: 100))
        XCTAssertEqual(spy.sent, [], "small moves send nothing")
        view.updateFloatingCursor(at: CGPoint(x: 90, y: 100))
        view.updateFloatingCursor(at: CGPoint(x: 80, y: 100))
        view.updateFloatingCursor(at: CGPoint(x: 90, y: 100))
        // The cursor mode applies; a vertical drag does nothing on the main screen.
        XCTAssertEqual(spy.sent, [P.bytes("\u{1b}OD"), P.bytes("\u{1b}OD"), P.bytes("\u{1b}OC")])
        XCTAssertEqual(view.inputState.document.selected.location, 2)
        view.updateFloatingCursor(at: CGPoint(x: 90, y: 60))
        XCTAssertEqual(spy.sent.count, 3)
        view.endFloatingCursor()
        view.updateFloatingCursor(at: CGPoint(x: 0, y: 0))
        XCTAssertEqual(spy.sent.count, 3)

        // On the alternate screen it also moves up and down.
        let (alt, altSpy) = makeView("\u{1b}[?1049h")
        alt.beginFloatingCursor(at: CGPoint(x: 100, y: 100))
        alt.updateFloatingCursor(at: CGPoint(x: 100, y: 90))
        alt.updateFloatingCursor(at: CGPoint(x: 100, y: 99))
        XCTAssertEqual(altSpy.sent, [P.bytes("\u{1b}[A"), P.bytes("\u{1b}[B")])
    }

    func testTextInputPositions() {
        let (view, _) = makeView()
        view.insertText("abc")
        XCTAssertEqual(view.offset(from: view.beginningOfDocument, to: view.endOfDocument), 3)
        XCTAssertNil(view.position(from: view.endOfDocument, offset: 1))
        XCTAssertNil(view.position(from: view.beginningOfDocument, offset: -1))
        let middle = view.position(from: view.beginningOfDocument, offset: 1)!
        XCTAssertEqual(view.compare(middle, to: view.endOfDocument), .orderedAscending)
        XCTAssertEqual(view.compare(view.endOfDocument, to: middle), .orderedDescending)
        XCTAssertEqual(view.compare(middle, to: middle), .orderedSame)
        XCTAssertEqual(view.text(in: view.textRange(from: middle, to: view.endOfDocument)!), "bc")
        XCTAssertEqual(view.selectedTextRange.map { view.offset(from: view.beginningOfDocument, to: $0.start) }, 3)
        XCTAssertNil(view.markedTextRange)
        XCTAssertTrue(view.textInputView === view)
        XCTAssertGreaterThan(view.caretRect(for: view.endOfDocument).height, 0)
        XCTAssertNotNil(view.tokenizer.rangeEnclosingPosition(middle, with: .word, inDirection: .storage(.forward)))
    }
}
