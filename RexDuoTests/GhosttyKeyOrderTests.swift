import RexKit
import XCTest
@testable import RexDuo

/// Records, in one list, what the terminal view tells the keyboard about its text and what it
/// sends to the program.
@MainActor
final class KeyOrderLog: NSObject, UITextInputDelegate, TerminalEngineDelegate {
    enum Event: Equatable {
        case selectionWill, textWill, textDid, selectionDid
        case send([UInt8])
    }

    var events: [Event] = []
    /// Runs when bytes are sent, and when the keyboard is told that the text changed.
    var onSend: (() -> Void)?
    var onTextDid: (() -> Void)?

    static func send(_ text: String) -> Event { .send(Array(text.utf8)) }
    /// A plain key: asked, sent, told.
    static func keyFirst(_ bytes: [UInt8]) -> [Event] { [.selectionWill, .textWill, .send(bytes), .textDid, .selectionDid] }
    /// Everything else: asked, told, sent.
    static func keyboardFirst(_ bytes: [UInt8]) -> [Event] { [.selectionWill, .textWill, .textDid, .selectionDid, .send(bytes)] }

    func selectionWillChange(_ textInput: (any UITextInput)?) { events.append(.selectionWill) }
    func textWillChange(_ textInput: (any UITextInput)?) { events.append(.textWill) }
    func selectionDidChange(_ textInput: (any UITextInput)?) { events.append(.selectionDid) }
    func textDidChange(_ textInput: (any UITextInput)?) {
        events.append(.textDid)
        onTextDid?()
    }

    @available(iOS 18.4, *)
    func conversationContext(_ context: UIConversationContext?, didChange textInput: (any UITextInput)?) {}

    func engineGridChanged(cols: Int, rows: Int) {}
    func engineSend(_ bytes: [UInt8]) {
        events.append(.send(bytes))
        onSend?()
    }
}

/// A phrase as dictation hands it over.
@MainActor
private final class Phrase: UIDictationPhrase {
    private let said: String
    init(_ said: String) {
        self.said = said
        super.init()
    }
    override var text: String { said }
}

/// Which keyboard text is one plain key (`GhosttyPlainInsertion`).
@MainActor
final class GhosttyPlainInsertionTests: XCTestCase {
    private typealias Edit = GhosttyInputEdit

    /// Puts `text` into `doc` as the view does and says whether it was a plain key.
    private func plain(_ text: String, into doc: inout GhosttyInputDocument, dictation: Bool = false) -> Bool {
        let before = GhosttyPlainInsertion(before: doc)
        let edit = doc.insert(text)
        return before.holds(text, edit: edit, after: doc, dictation: dictation)
    }

    func testOneCharacterAtTheProgramsCursorIsPlain() {
        var doc = GhosttyInputDocument()
        for text in ["a", " ", "é", "e\u{301}", "日", "😀", "👨‍👩‍👧"] {
            XCTAssertTrue(plain(text, into: &doc), text.debugDescription)
        }
        XCTAssertEqual(doc.text, "a ée\u{301}日😀👨‍👩‍👧")
    }

    func testMoreThanOneCharacterIsNotPlain() {
        var doc = GhosttyInputDocument()
        for text in ["ls", "hello world", "日本", "😀😀", ""] {
            XCTAssertFalse(plain(text, into: &doc), text.debugDescription)
        }
        XCTAssertFalse(plain("\n", into: &doc), "Return is not text on the line")
    }

    func testTextThatEndsOrFollowsACompositionIsNotPlain() {
        var doc = GhosttyInputDocument()
        doc.setMarked("か", selection: NSRange(location: 1, length: 0))
        XCTAssertFalse(plain("可", into: &doc), "an input method's commit")
        XCTAssertFalse(doc.isComposing)
        XCTAssertTrue(plain("a", into: &doc), "the next key is plain again")
        // Marked text left after the edit: asked of the document, whatever made it.
        var composing = GhosttyInputDocument()
        composing.setMarked("n", selection: NSRange(location: 1, length: 0))
        let key = GhosttyPlainInsertion(composing: false, selected: 0)
        XCTAssertFalse(key.holds("a", edit: Edit(text: "a"), after: composing, dictation: false))
    }

    func testTextOverASelectionOrAwayFromTheProgramsCursorIsNotPlain() {
        var doc = GhosttyInputDocument()
        doc.insert("word")
        doc.select(NSRange(location: 0, length: 4))
        XCTAssertFalse(plain("w", into: &doc), "it replaces what was selected")
        // The keyboard moved its caret: the program's line is edited, not typed at.
        var moved = GhosttyInputDocument()
        moved.insert("ab")
        moved.select(NSRange(location: 1, length: 0))
        XCTAssertFalse(plain("x", into: &moved))
        XCTAssertEqual(moved.text, "axb")
    }

    func testDictationIsNotPlainAndIsAskedLast() {
        var doc = GhosttyInputDocument()
        XCTAssertFalse(plain("a", into: &doc, dictation: true))
        // Text that is not plain anyway never asks.
        var asked = 0
        func dictation() -> Bool {
            asked += 1
            return false
        }
        let before = GhosttyPlainInsertion(before: doc)
        let edit = doc.insert("two words")
        XCTAssertFalse(before.holds("two words", edit: edit, after: doc, dictation: dictation()))
        XCTAssertEqual(asked, 0)
        let again = GhosttyPlainInsertion(before: doc)
        let key = doc.insert("b")
        XCTAssertTrue(again.holds("b", edit: key, after: doc, dictation: dictation()))
        XCTAssertEqual(asked, 1)
    }

    func testAKeyThatFillsTheShadowDocumentIsNotPlain() {
        var doc = GhosttyInputDocument()
        doc.insert(String(repeating: "a", count: GhosttyPlainInsertion.longestLine - 1))
        XCTAssertTrue(plain("b", into: &doc), "the last key that fits")
        XCTAssertFalse(plain("c", into: &doc), "the document is reset after this one, which tells the keyboard")
    }
}

/// The order of two things around text from the keyboard: the send to the program, and the
/// keyboard being told that the text changed (`textDidChange`, `selectionDidChange`). One plain
/// key is sent first; everything else tells the keyboard first. Each test names the order it
/// proves.
@MainActor
final class GhosttyKeyOrderTests: XCTestCase {
    private typealias P = GhosttyInputProbe
    private typealias Log = KeyOrderLog

    private func makeView(_ setup: String = "") -> (GhosttyTerminalView, KeyOrderLog) {
        let view = GhosttyTerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 240), fontSize: 12, cols: 40, rows: 10)
        let log = KeyOrderLog()
        view.engineDelegate = log
        view.inputDelegate = log
        view.feed(text: setup)
        view.core.sync()
        return (view, log)
    }

    private func down(_ view: GhosttyTerminalView, _ spelling: String) -> Bool {
        guard let p = P.press(spelling) else {
            XCTFail("bad chord \(spelling)")
            return false
        }
        return view.hardwareKeyDown(usage: p.usage, flags: p.flags, characters: p.characters, charactersIgnoringModifiers: p.ignoringModifiers)
    }

    /// Order: will-change calls, the document's edit, the send, did-change calls.
    func testAPlainKeyIsSentBeforeTheKeyboardIsTold() {
        let (view, log) = makeView()
        var documentAtSend: String?
        log.onSend = { documentAtSend = view.inputState.document.text }
        view.insertText("a")
        XCTAssertEqual(log.events, Log.keyFirst(P.bytes("a")))
        XCTAssertEqual(documentAtSend, "a", "the shadow document has the key when it is sent")
        log.events = []
        view.insertText("b")
        XCTAssertEqual(log.events, Log.keyFirst(P.bytes("b")), "and so has every key after it")
        XCTAssertEqual(documentAtSend, "ab")
    }

    /// Order: did-change calls, then the send, for a composition's updates (which send
    /// nothing), its commit by `insertText`, and its commit by `unmarkText`.
    func testAJapaneseCompositionTellsTheKeyboardFirst() {
        let (view, log) = makeView()
        view.setMarkedText("n", selectedRange: NSRange(location: 1, length: 0))
        view.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0))
        view.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0))
        let asked: [Log.Event] = [.selectionWill, .textWill, .textDid, .selectionDid]
        XCTAssertEqual(log.events, asked + asked + asked, "composing sends nothing")
        log.events = []
        view.insertText("日本")
        XCTAssertEqual(log.events, Log.keyboardFirst(P.bytes("日本")))

        // A commit of one character is still a commit.
        view.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0))
        log.events = []
        view.insertText("可")
        XCTAssertEqual(log.events, Log.keyboardFirst(P.bytes("可")))

        view.setMarkedText("き", selectedRange: NSRange(location: 1, length: 0))
        log.events = []
        view.unmarkText()
        XCTAssertEqual(log.events, Log.keyboardFirst(P.bytes("き")))

        // The key after the composition is plain again.
        log.events = []
        view.insertText("a")
        XCTAssertEqual(log.events, Log.keyFirst(P.bytes("a")))
    }

    /// Order: did-change calls, then the send, for a dictated phrase of any length, and for a
    /// single character while the keyboard is in its dictation mode.
    func testDictationTellsTheKeyboardFirst() {
        let (view, log) = makeView()
        view.insertDictationResult([Phrase("list "), Phrase("files")])
        XCTAssertEqual(log.events, Log.keyboardFirst(P.bytes("list files")))
        log.events = []
        view.insertDictationResult([Phrase("a")])
        XCTAssertEqual(log.events, Log.keyboardFirst(P.bytes("a")), "one character, but dictated")
        XCTAssertFalse(view.inputState.dictating)

        log.events = []
        view.inputState.layoutLanguage = "dictation"
        view.insertText("b")
        XCTAssertEqual(log.events, Log.keyboardFirst(P.bytes("b")))
        view.inputState.layoutLanguage = nil
        log.events = []
        view.insertText("c")
        XCTAssertEqual(log.events, Log.keyFirst(P.bytes("c")), "dictation over: a key is plain again")
    }

    /// The keyboard's input mode is read once, not for every key, and again after the mode
    /// changes or the keyboard comes or goes.
    func testTheInputModeIsReadOncePerMode() {
        let (view, _) = makeView()
        func read() -> Bool {
            if case .some = view.inputState.modeLanguage { return true }
            return false
        }
        XCTAssertFalse(read(), "not read before a key needs it")
        view.insertText("a")
        XCTAssertTrue(read(), "read for the first plain key, and kept")
        view.insertText("two words")
        XCTAssertTrue(read())
        NotificationCenter.default.post(name: UITextInputMode.currentInputModeDidChangeNotification, object: nil)
        XCTAssertFalse(read(), "a new mode is read again")
    }

    /// Order: did-change calls, then the send, when the keyboard replaces sent text
    /// (`replace(_:withText:)`), types over its selection, or puts in more than one character.
    func testAReplacementTellsTheKeyboardFirst() {
        let (view, log) = makeView()
        view.insertText("hello word")
        XCTAssertEqual(log.events, Log.keyboardFirst(P.bytes("hello word")), "a word at once is a suggestion or a paste")
        log.events = []
        let range = view.textRange(from: view.position(from: view.beginningOfDocument, offset: 6)!, to: view.endOfDocument)!
        view.replace(range, withText: "world")
        XCTAssertEqual(log.events, Log.keyboardFirst([0x7f, 0x7f, 0x7f, 0x7f] + P.bytes("world")))

        // One character over a selection: the selection goes first.
        view.selectedTextRange = view.textRange(from: view.position(from: view.beginningOfDocument, offset: 6)!, to: view.endOfDocument)
        log.events = []
        view.insertText("w")
        XCTAssertEqual(log.events, Log.keyboardFirst([0x7f, 0x7f, 0x7f, 0x7f, 0x7f] + P.bytes("w")))
        XCTAssertEqual(view.inputState.document.text, "hello w")
    }

    /// Order: the send, then did-change calls, for one emoji, one joined emoji and one wide
    /// character: each is one character from one key.
    func testAnEmojiOrAWideCharacterIsAPlainKey() {
        let (view, log) = makeView()
        for text in ["😀", "👨‍👩‍👧", "日", "é"] {
            log.events = []
            view.insertText(text)
            XCTAssertEqual(log.events, Log.keyFirst(P.bytes(text)), text.debugDescription)
        }
    }

    /// Order: did-change calls, then the send, for Backspace.
    func testBackspaceTellsTheKeyboardFirst() {
        let (view, log) = makeView()
        view.insertText("a")
        log.events = []
        view.deleteBackward()
        XCTAssertEqual(log.events, Log.keyboardFirst([0x7f]))
        // With nothing of ours left the program still gets one.
        log.events = []
        view.deleteBackward()
        XCTAssertEqual(log.events, Log.keyboardFirst([0x7f]))
    }

    /// Order: did-change calls (the shadow document's reset), then the send, for the key bar's
    /// own keys and raw sends. A letter typed after the bar's one-shot ctrl is a plain key: the
    /// send, with the modifier, then did-change calls.
    func testTheKeyBarsKeysTellTheKeyboardFirstAndItsModifierRidesAPlainKey() {
        let (view, log) = makeView()
        view.insertText("a")
        log.events = []
        view.sendKeyLeft()
        XCTAssertEqual(log.events, Log.keyboardFirst(P.bytes("\u{1b}[D")))
        view.insertText("b")
        log.events = []
        view.send(data: [0x09][...])
        XCTAssertEqual(log.events, Log.keyboardFirst([0x09]))
        // Nothing typed since: there is nothing to tell the keyboard.
        log.events = []
        view.sendKeyUp()
        XCTAssertEqual(log.events, [Log.send("\u{1b}[A")])

        log.events = []
        view.controlModifier = true
        view.insertText("c")
        XCTAssertEqual(log.events, Log.keyFirst([0x03]))
        XCTAssertFalse(view.controlModifier, "the one-shot modifier was taken with the key")
    }

    /// Order: the send, then did-change calls, for a hardware key that types (it comes back
    /// through the text system, and is sent as that key); did-change calls, then the send, for
    /// a hardware key encoded here (an arrow).
    func testAHardwareKeyThatTypesIsAPlainKey() {
        let (view, log) = makeView(P.kittyAll)
        XCTAssertFalse(down(view, "shift+a"))
        XCTAssertEqual(log.events, [], "handed to the text system")
        view.insertText("A")
        XCTAssertEqual(log.events, Log.keyFirst(P.bytes("\u{1b}[97:65;2;65u")), "sent first, as the key that typed it")
        XCTAssertNil(view.inputState.pending)

        log.events = []
        XCTAssertTrue(down(view, "up"))
        XCTAssertEqual(log.events, Log.keyboardFirst(P.bytes("\u{1b}[1;1:1A")))
        if let usage = P.usage("up") { view.hardwareKeyUp(usage: usage) }
    }

    /// Order: a Return tells the keyboard first (the line it edited is over), then is sent;
    /// with nothing typed there is nothing to tell.
    func testReturnTellsTheKeyboardFirst() {
        let (view, log) = makeView()
        view.insertText("a")
        log.events = []
        view.insertText("\n")
        XCTAssertEqual(log.events, Log.keyboardFirst([0x0d]))
        log.events = []
        view.insertText("\n")
        XCTAssertEqual(log.events, [.send([0x0d])])
    }
}
