import XCTest
@testable import Pteron

@MainActor
private final class SendSpy: TerminalEngineDelegate {
    var sent: [[UInt8]] = []
    func engineGridChanged(cols: Int, rows: Int) {}
    func engineSend(_ bytes: [UInt8]) { sent.append(bytes) }
}

/// Option on a hardware keyboard: Alt for the shell where the layout has nothing a terminal
/// needs on the key, the layout's character where it does (`GhosttyInputKeymap.optionRole`).
@MainActor
final class GhosttyOptionKeyTests: XCTestCase {
    private typealias Role = GhosttyInputKeymap.OptionRole
    private let option: UIKeyModifierFlags = .alternate
    private let shiftOption: UIKeyModifierFlags = [.alternate, .shift]

    /// One Option press as `UIKey` reports it: what the layout types with Option (`""` for a
    /// dead key) and what the key types alone.
    private struct Press {
        var name: String
        var usage: Int
        var shift = false
        var characters: String
        var own: String
        var role: Role
    }

    // HID usages by US position.
    private let a = 4, b = 5, e = 8, f = 9, l = 15, n = 17
    private let k1 = 30, k2 = 31, k3 = 32, k5 = 34, k6 = 35, k7 = 36, k8 = 37, k9 = 38
    private let minus = 45, leftBracket = 47, rightBracket = 48, backslash = 49, semicolon = 51, quote = 52, grave = 53, period = 55

    private func check(_ language: String, _ presses: [Press], file: StaticString = #filePath, line: UInt = #line) {
        for p in presses {
            let name = "\(language) \(p.name)"
            XCTAssertEqual(GhosttyInputKeymap.optionRole(characters: p.characters, charactersIgnoringModifiers: p.own, layoutLanguage: language),
                           p.role, name, file: file, line: line)
            let route = GhosttyInputKeymap.route(usage: p.usage, flags: p.shift ? shiftOption : option, characters: p.characters,
                                                 charactersIgnoringModifiers: p.own, layoutLanguage: language)
            switch (p.role, route) {
            case (.alt, .encode(let key)):
                // Alt and the key's own character: the encoder makes ESC + character.
                XCTAssertNotEqual(key.mods & GhosttyInputKey.alt, 0, name, file: file, line: line)
                XCTAssertEqual(key.text.lowercased(), p.own.lowercased(), name, file: file, line: line)
            case (.layout, .textInput(let key)):
                // The text system types it (and composes a dead key); the program sees no Alt.
                XCTAssertEqual(key.mods & GhosttyInputKey.alt, 0, name, file: file, line: line)
                XCTAssertEqual(key.text, p.characters, name, file: file, line: line)
            default:
                XCTFail("\(name): \(p.role) but routed \(route)", file: file, line: line)
            }
        }
    }

    func testUSLayoutOptionIsAlt() {
        check("en-US", [
            Press(name: "Option+B", usage: b, characters: "∫", own: "b", role: .alt),
            Press(name: "Option+F", usage: f, characters: "ƒ", own: "f", role: .alt),
            Press(name: "Option+A", usage: a, characters: "å", own: "a", role: .alt),
            Press(name: "Option+L", usage: l, characters: "¬", own: "l", role: .alt),
            Press(name: "Shift+Option+B", usage: b, shift: true, characters: "ı", own: "B", role: .alt),
            // Dead keys on a US layout have no use in a terminal: Alt+E, Alt+N.
            Press(name: "Option+E (dead)", usage: e, characters: "", own: "e", role: .alt),
            Press(name: "Option+N (dead)", usage: n, characters: "", own: "n", role: .alt),
            Press(name: "Option+` (dead)", usage: grave, characters: "", own: "`", role: .alt),
            Press(name: "Option+2", usage: k2, characters: "™", own: "2", role: .alt),
            Press(name: "Option+5", usage: k5, characters: "∞", own: "5", role: .alt),
            // Alt+. and Alt+- are shell commands; ≥ and – are not typed into a terminal.
            Press(name: "Option+.", usage: period, characters: "≥", own: ".", role: .alt),
            Press(name: "Option+-", usage: minus, characters: "–", own: "-", role: .alt),
            Press(name: "Option+\\", usage: backslash, characters: "«", own: "\\", role: .alt),
        ])
        // No language known: as a US layout.
        XCTAssertEqual(GhosttyInputKeymap.optionRole(characters: "∫", charactersIgnoringModifiers: "b", layoutLanguage: nil), .alt)
        XCTAssertEqual(GhosttyInputKeymap.optionRole(characters: "", charactersIgnoringModifiers: "n", layoutLanguage: nil), .alt)
    }

    func testBritishLayoutTypesHashWithOption3() {
        check("en-GB", [
            Press(name: "Option+3", usage: k3, characters: "#", own: "3", role: .layout),
            Press(name: "Option+B", usage: b, characters: "∫", own: "b", role: .alt),
        ])
    }

    func testGermanLayoutTypesItsBracketsAndStillHasAlt() {
        check("de-DE", [
            Press(name: "Option+L", usage: l, characters: "@", own: "l", role: .layout),
            Press(name: "Option+5", usage: k5, characters: "[", own: "5", role: .layout),
            Press(name: "Option+6", usage: k6, characters: "]", own: "6", role: .layout),
            Press(name: "Option+8", usage: k8, characters: "{", own: "8", role: .layout),
            Press(name: "Option+9", usage: k9, characters: "}", own: "9", role: .layout),
            Press(name: "Option+7", usage: k7, characters: "|", own: "7", role: .layout),
            Press(name: "Shift+Option+7", usage: k7, shift: true, characters: "\\", own: "/", role: .layout),
            // `~` is a dead key on Option+N: it composes through the text system.
            Press(name: "Option+N (dead)", usage: n, characters: "", own: "n", role: .layout),
            // Letters that give nothing a terminal needs stay Alt: Alt+B, Alt+F, Alt+A.
            Press(name: "Option+B", usage: b, characters: "∫", own: "b", role: .alt),
            Press(name: "Option+F", usage: f, characters: "ƒ", own: "f", role: .alt),
            Press(name: "Option+A", usage: a, characters: "å", own: "a", role: .alt),
            Press(name: "Option+1", usage: k1, characters: "¡", own: "1", role: .alt),
        ])
    }

    func testFrenchLayoutTypesItsBracketsAndStillHasAlt() {
        check("fr-FR", [
            // The digit row types & é " ' ( … without Shift.
            Press(name: "Option+(", usage: k5, characters: "{", own: "(", role: .layout),
            Press(name: "Shift+Option+(", usage: k5, shift: true, characters: "[", own: "5", role: .layout),
            Press(name: "Option+)", usage: minus, characters: "}", own: ")", role: .layout),
            Press(name: "Shift+Option+)", usage: minus, shift: true, characters: "]", own: "°", role: .layout),
            Press(name: "Shift+Option+L", usage: l, shift: true, characters: "|", own: "L", role: .layout),
            Press(name: "Shift+Option+:", usage: period, shift: true, characters: "\\", own: "/", role: .layout),
            Press(name: "Option+N (dead)", usage: n, characters: "", own: "n", role: .layout),
            Press(name: "Option+B", usage: b, characters: "ß", own: "b", role: .alt),
            Press(name: "Option+F", usage: f, characters: "ƒ", own: "f", role: .alt),
            // A key with no ASCII letter or digit of its own types what the layout says.
            Press(name: "Option+é", usage: k2, characters: "ë", own: "é", role: .layout),
        ])
    }

    func testSpanishLayoutTypesItsBracketsAndStillHasAlt() {
        check("es-ES", [
            Press(name: "Option+2", usage: k2, characters: "@", own: "2", role: .layout),
            Press(name: "Option+1", usage: k1, characters: "|", own: "1", role: .layout),
            Press(name: "Option+3", usage: k3, characters: "#", own: "3", role: .layout),
            Press(name: "Option+º", usage: grave, characters: "\\", own: "º", role: .layout),
            Press(name: "Option+`", usage: leftBracket, characters: "[", own: "`", role: .layout),
            Press(name: "Option++", usage: rightBracket, characters: "]", own: "+", role: .layout),
            Press(name: "Option+´", usage: quote, characters: "{", own: "´", role: .layout),
            Press(name: "Option+ç", usage: backslash, characters: "}", own: "ç", role: .layout),
            // `~` on Option+Ñ, as a character or as a dead key.
            Press(name: "Option+Ñ", usage: semicolon, characters: "~", own: "ñ", role: .layout),
            Press(name: "Option+Ñ (dead)", usage: semicolon, characters: "", own: "ñ", role: .layout),
            Press(name: "Option+B", usage: b, characters: "ß", own: "b", role: .alt),
            Press(name: "Option+F", usage: f, characters: "ƒ", own: "f", role: .alt),
        ])
    }

    func testOptionWithControlOrOnKeysThatDoNotTypeIsAlwaysAlt() {
        // Control+Option, Option+Space, Option+Return and Option+Delete never go to the layout.
        let presses: [(Int, UIKeyModifierFlags, String, String)] = [
            (l, [.alternate, .control], "\u{0c}", "l"), (44, .alternate, "\u{a0}", " "), (40, .alternate, "\r", "\r"),
            (42, .alternate, "\u{8}", "\u{8}"),
        ]
        for (usage, flags, characters, own) in presses {
            guard case .encode(let key) = GhosttyInputKeymap.route(usage: usage, flags: flags, characters: characters,
                                                                   charactersIgnoringModifiers: own, layoutLanguage: "de-DE") else {
                return XCTFail("usage \(usage) was not encoded")
            }
            XCTAssertNotEqual(key.mods & GhosttyInputKey.alt, 0, "usage \(usage)")
        }
        // Without Option nothing changed: a plain key still goes to the text system.
        guard case .textInput = GhosttyInputKeymap.route(usage: l, flags: [], characters: "l", charactersIgnoringModifiers: "l",
                                                         layoutLanguage: "de-DE") else { return XCTFail("plain l") }
    }

    func testTheBytesThatReachTheProgram() {
        let view = GhosttyTerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 240), fontSize: 12, cols: 40, rows: 10)
        let spy = SendSpy()
        view.engineDelegate = spy

        // German: Option+L goes to the text system, which types "@". No ESC.
        view.inputState.layoutLanguage = "de-DE"
        XCTAssertFalse(view.hardwareKeyDown(usage: l, flags: option, characters: "@", charactersIgnoringModifiers: "l"))
        view.insertText("@")
        view.hardwareKeyUp(usage: l)
        XCTAssertEqual(spy.sent, [[0x40]])

        // German: the dead key Option+N, then Space, is "~" from the text system.
        spy.sent = []
        XCTAssertFalse(view.hardwareKeyDown(usage: n, flags: option, characters: "", charactersIgnoringModifiers: "n"))
        view.hardwareKeyUp(usage: n)
        XCTAssertEqual(spy.sent, [], "a dead key sends nothing by itself")
        XCTAssertFalse(view.hardwareKeyDown(usage: 44, flags: [], characters: " ", charactersIgnoringModifiers: " "))
        view.insertText("~")
        view.hardwareKeyUp(usage: 44)
        XCTAssertEqual(spy.sent, [[0x7e]])

        // German: Option+B is still Alt+B.
        spy.sent = []
        XCTAssertTrue(view.hardwareKeyDown(usage: b, flags: option, characters: "∫", charactersIgnoringModifiers: "b"))
        view.hardwareKeyUp(usage: b)
        XCTAssertEqual(spy.sent, [[0x1b, 0x62]])

        // US: Option+L is Alt+L, never "¬".
        spy.sent = []
        view.inputState.layoutLanguage = "en-US"
        XCTAssertTrue(view.hardwareKeyDown(usage: l, flags: option, characters: "¬", charactersIgnoringModifiers: "l"))
        view.hardwareKeyUp(usage: l)
        XCTAssertEqual(spy.sent, [[0x1b, 0x6c]])
    }
}

/// The keyboard edits its shadow text anywhere; the program only deletes before its cursor.
@MainActor
final class GhosttyInputEditTests: XCTestCase {
    private typealias Edit = GhosttyInputEdit

    func testReplacingAnEarlierWordKeepsTheTextAfterIt() {
        // Dictation revises a word in the middle. Deleting only the word's length from the end
        // of the line turned "hello world foo" into "hello worlword".
        var doc = GhosttyInputDocument()
        doc.insert("hello world foo")
        let edit = doc.replace(NSRange(location: 6, length: 5), with: "word")
        XCTAssertEqual(edit, Edit(backspaces: 9, text: "word foo"), "back to the start of the word, then the new word and the tail")
        XCTAssertEqual(doc.text, "hello word foo")
        XCTAssertEqual(doc.programCaret, 14)
        XCTAssertEqual(doc.selected, NSRange(location: 14, length: 0))

        // At the end of the line nothing stands behind the range: as before.
        XCTAssertEqual(doc.replace(NSRange(location: 11, length: 3), with: "bar!"), Edit(backspaces: 3, text: "bar!"))
        XCTAssertEqual(doc.text, "hello word bar!")
    }

    func testAnAutocorrectStyleReplacementOfTheFirstWord() {
        var doc = GhosttyInputDocument()
        doc.insert("teh quick 👍 fox")
        XCTAssertEqual(doc.replace(NSRange(location: 0, length: 3), with: "the"), Edit(backspaces: 15, text: "the quick 👍 fox"))
        XCTAssertEqual(doc.text, "the quick 👍 fox")
        // A replacement of another length.
        XCTAssertEqual(doc.replace(NSRange(location: 4, length: 5), with: "slow"), Edit(backspaces: 11, text: "slow 👍 fox"))
        XCTAssertEqual(doc.text, "the slow 👍 fox")
        XCTAssertEqual(doc.programCaret, doc.length)
    }

    func testTypingWhereTheKeyboardPutItsCaret() {
        var doc = GhosttyInputDocument()
        doc.insert("abc")
        // The keyboard moves its caret without telling the program (no arrow keys were sent).
        doc.select(NSRange(location: 1, length: 0))
        XCTAssertEqual(doc.insert("X"), Edit(backspaces: 2, text: "Xbc"))
        XCTAssertEqual(doc.text, "aXbc")
        XCTAssertEqual(doc.programCaret, 4)
        XCTAssertEqual(doc.selected.location, 2)
        // Delete there: the X goes, and what stood behind it is typed again.
        XCTAssertEqual(doc.deleteBackward(), Edit(backspaces: 3, text: "bc"))
        XCTAssertEqual(doc.text, "abc")
    }

    func testTypingOverASelectionDeletesIt() {
        var doc = GhosttyInputDocument()
        doc.insert("hello")
        doc.select(NSRange(location: 0, length: 5))
        XCTAssertEqual(doc.insert("x"), Edit(backspaces: 5, text: "x"))
        XCTAssertEqual(doc.text, "x")

        doc.reset()
        doc.insert("one two three")
        doc.select(NSRange(location: 4, length: 3))
        XCTAssertEqual(doc.deleteBackward(), Edit(backspaces: 9, text: " three"))
        XCTAssertEqual(doc.text, "one  three")
    }

    func testComposingOverASelectionAndCommittingInTheMiddle() {
        var doc = GhosttyInputDocument()
        doc.insert("abcd")
        doc.select(NSRange(location: 1, length: 2))
        // Composition starts over "bc": that text goes now; the composed text is not sent yet.
        XCTAssertEqual(doc.setMarked("に", selection: NSRange(location: 1, length: 0)), Edit(backspaces: 3, text: "d"))
        XCTAssertEqual(doc.text, "aにd")
        XCTAssertEqual(doc.setMarked("にほ", selection: NSRange(location: 2, length: 0)), Edit())
        XCTAssertEqual(doc.text, "aにほd")
        // The commit lands before the "d" the program already has.
        XCTAssertEqual(doc.insert("日本"), Edit(backspaces: 1, text: "日本d"))
        XCTAssertEqual(doc.text, "a日本d")
        XCTAssertEqual(doc.programCaret, doc.length)

        // Cancelling a composition sends nothing and leaves the program's cursor where it was.
        XCTAssertEqual(doc.setMarked("x", selection: NSRange(location: 1, length: 0)), Edit())
        XCTAssertEqual(doc.setMarked(nil, selection: NSRange(location: 0, length: 0)), Edit())
        XCTAssertEqual(doc.text, "a日本d")
        XCTAssertEqual(doc.programCaret, doc.length)
    }

    func testAfterTheSpaceBarTrackpadMovedTheProgramsCursor() {
        var doc = GhosttyInputDocument()
        doc.insert("abc")
        XCTAssertEqual(doc.moveCaret(by: -1), -1)  // one Left arrow was sent
        XCTAssertEqual(doc.programCaret, 2)
        // A replacement before the cursor: only what stands between is typed again.
        XCTAssertEqual(doc.replace(NSRange(location: 0, length: 1), with: "X"), Edit(backspaces: 2, text: "Xb"))
        XCTAssertEqual(doc.text, "Xbc")
        XCTAssertEqual(doc.programCaret, 2)

        // A replacement that reaches past the cursor: go to its end first.
        doc.reset()
        doc.insert("abc")
        XCTAssertEqual(doc.moveCaret(by: -2), -2)
        XCTAssertEqual(doc.replace(NSRange(location: 1, length: 2), with: "Z"), Edit(move: 2, backspaces: 2, text: "Z"))
        XCTAssertEqual(doc.text, "aZ")
        XCTAssertEqual(doc.programCaret, 2)

        // Past the edge of what was typed the document can't follow.
        XCTAssertEqual(doc.moveCaret(by: 1), 0)
        XCTAssertEqual(doc.moveCaret(by: -5), -2)
    }

    func testDeleteBeforeTheStartOfWhatWasTyped() {
        var doc = GhosttyInputDocument()
        doc.insert("ab")
        doc.select(NSRange(location: 0, length: 0))
        // The keyboard deletes before our text; the program's cursor is two characters on.
        XCTAssertEqual(doc.deleteBackward(), Edit(move: -2, backspaces: 1))
        XCTAssertEqual(doc.programCaret, 0)
    }

    // MARK: The bytes

    private func makeView() -> (GhosttyTerminalView, SendSpy) {
        let view = GhosttyTerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 240), fontSize: 12, cols: 40, rows: 10)
        let spy = SendSpy()
        view.engineDelegate = spy
        return (view, spy)
    }

    private func range(_ view: GhosttyTerminalView, _ location: Int, _ length: Int) -> UITextRange {
        view.textRange(from: view.position(from: view.beginningOfDocument, offset: location)!,
                       to: view.position(from: view.beginningOfDocument, offset: location + length)!)!
    }

    func testTheBytesOfADictationRevision() {
        let (view, spy) = makeView()
        view.insertText("hello world foo")
        spy.sent = []
        view.replace(range(view, 6, 5), withText: "word")
        XCTAssertEqual(spy.sent, [[UInt8](repeating: 0x7f, count: 9) + Array("word foo".utf8)], "one write")
        XCTAssertEqual(view.inputState.document.text, "hello word foo")

        // What the shell's line is afterwards, played back.
        var line = Array("hello world foo".utf8)
        for byte in spy.sent[0] {
            if byte == 0x7f { line.removeLast() } else { line.append(byte) }
        }
        XCTAssertEqual(String(decoding: line, as: UTF8.self), "hello word foo")
    }

    func testTheBytesOfTypingAtAMovedCaretAndOfAReplacementPastTheCursor() {
        let (view, spy) = makeView()
        view.insertText("abc")
        view.selectedTextRange = range(view, 1, 0)
        spy.sent = []
        view.insertText("X")
        XCTAssertEqual(spy.sent, [[0x7f, 0x7f] + Array("Xbc".utf8)])
        view.deleteBackward()
        XCTAssertEqual(spy.sent.last, [0x7f, 0x7f, 0x7f] + Array("bc".utf8))

        // The trackpad moved the program's cursor left twice; then a replacement of "bc".
        let (other, otherSpy) = makeView()
        other.insertText("abc")
        other.beginFloatingCursor(at: CGPoint(x: 100, y: 100))
        other.updateFloatingCursor(at: CGPoint(x: 90, y: 100))
        other.updateFloatingCursor(at: CGPoint(x: 80, y: 100))
        other.endFloatingCursor()
        otherSpy.sent = []
        other.replace(range(other, 1, 2), withText: "Z")
        let right = Array("\u{1b}[C".utf8)
        XCTAssertEqual(otherSpy.sent, [right + right + [0x7f, 0x7f] + Array("Z".utf8)])
    }

    func testTheTrackpadPastWhatWasTypedForgetsTheDocument() {
        let (view, spy) = makeView()
        view.insertText("a")
        spy.sent = []
        view.beginFloatingCursor(at: CGPoint(x: 100, y: 100))
        view.updateFloatingCursor(at: CGPoint(x: 90, y: 100))
        XCTAssertTrue(view.hasText)
        view.updateFloatingCursor(at: CGPoint(x: 80, y: 100))
        XCTAssertFalse(view.hasText, "the cursor left the text the keyboard knows")
        XCTAssertEqual(spy.sent.count, 2, "both arrows were still sent")
    }
}
