import UIKit
import GhosttyVt

/// What the program must get so that its line matches an edit of the shadow document: move its
/// cursor, delete before it, then type.
struct GhosttyInputEdit: Equatable {
    /// Arrow keys first: negative is Left, positive Right, in characters.
    var move = 0
    /// Backspace keys, after the move.
    var backspaces = 0
    /// Text typed last. It can be longer than what the keyboard inserted: text that stood between
    /// the edit and the program's cursor was deleted on the way and is typed again.
    var text = ""

    var isEmpty: Bool { move == 0 && backspaces == 0 && text.isEmpty }
}

/// The text the keyboard believes it is editing.
///
/// A terminal has no document, but iOS's input methods, dictation and the space-bar trackpad need
/// one (`UITextInput`): marked text to compose in, a range to replace when dictation revises a
/// phrase, a caret to move. This is a shadow of what was typed since the last Return, as the
/// SwiftTerm engine keeps. Offsets are UTF-16, as `UITextInput` counts.
///
/// The keyboard edits anywhere in this text, but the program only deletes before its own cursor.
/// So the document also knows where the program's cursor is in the text (`programCaret`), and
/// every change returns the keys that make the same change there (`GhosttyInputEdit`): Backspace
/// from the program's cursor back to the start of the edit, the new text, then the text that was
/// deleted on the way.
struct GhosttyInputDocument: Equatable {
    private(set) var text = ""
    /// The caret (length 0) or the keyboard's selection.
    private(set) var selected = NSRange(location: 0, length: 0)
    /// Text an input method is still composing. It has not been sent to the program.
    private(set) var marked: NSRange?
    /// Where the program's cursor is in `text`. Never inside the marked text.
    private(set) var programCaret = 0

    var length: Int { (text as NSString).length }
    var isEmpty: Bool { text.isEmpty }
    var isComposing: Bool { marked != nil }

    /// `r` cut to the document and moved off the middle of a character.
    func clamped(_ r: NSRange) -> NSRange {
        let n = length
        let start = max(0, min(r.location, n)), end = max(start, min(r.location + r.length, n))
        guard start < end else { return NSRange(location: start, length: 0) }
        let s = text as NSString
        let a = s.rangeOfComposedCharacterSequence(at: start).location
        let b = NSMaxRange(s.rangeOfComposedCharacterSequence(at: end - 1))
        return NSRange(location: a, length: b - a)
    }

    func substring(_ r: NSRange) -> String {
        (text as NSString).substring(with: clamped(r))
    }

    private func slice(_ from: Int, _ to: Int) -> String {
        to > from ? (text as NSString).substring(with: NSRange(location: from, length: to - from)) : ""
    }

    mutating func reset() {
        self = GhosttyInputDocument()
    }

    mutating func select(_ r: NSRange) {
        selected = clamped(r)
    }

    private mutating func splice(_ r: NSRange, _ s: String) {
        text = (text as NSString).replacingCharacters(in: r, with: s)
    }

    /// Replaces sent text `r` (clamped, no marked text in the document) with `s`, and returns the
    /// keys that do the same on the program's line. The program's cursor ends where it was in
    /// the text: after what stood behind the edit, or right after `s` if it had to move there.
    private mutating func change(_ r: NSRange, to s: String) -> GhosttyInputEdit {
        var edit = GhosttyInputEdit()
        let n = (s as NSString).length
        let end = NSMaxRange(r)
        if programCaret >= end {
            // Delete back to the start of the edit, taking the text behind it too, and type
            // that text again after the new one.
            let tail = slice(end, programCaret)
            edit.backspaces = slice(r.location, programCaret).count
            edit.text = s + tail
            programCaret += n - r.length
        } else {
            // The program's cursor is before the end of the edit (the space-bar trackpad moved
            // it): go to the end first.
            edit.move = slice(programCaret, end).count
            edit.backspaces = slice(r.location, end).count
            edit.text = s
            programCaret = r.location + n
        }
        splice(r, s)
        return edit
    }

    /// Takes the marked text out. It never reached the program.
    private mutating func dropMarked() {
        guard let m = marked.map(clamped) else { return }
        splice(m, "")
        marked = nil
        if programCaret >= NSMaxRange(m) { programCaret -= m.length } else if programCaret > m.location { programCaret = m.location }
        selected = NSRange(location: m.location, length: 0)
    }

    /// Typed or committed text: replaces the marked text, else the selection. The caret ends after it.
    @discardableResult
    mutating func insert(_ s: String) -> GhosttyInputEdit {
        dropMarked()
        let r = clamped(selected)
        let edit = change(r, to: s)
        selected = NSRange(location: r.location + (s as NSString).length, length: 0)
        return edit
    }

    /// An input method's text in progress. `selection` is relative to `s`. Composing sends
    /// nothing, unless it starts over a selection of sent text: that text goes.
    @discardableResult
    mutating func setMarked(_ s: String?, selection: NSRange) -> GhosttyInputEdit {
        var edit = GhosttyInputEdit()
        if marked == nil {
            let sel = clamped(selected)
            if sel.length > 0 { edit = change(sel, to: "") }
            selected = NSRange(location: sel.location, length: 0)
        } else {
            dropMarked()
        }
        let at = selected.location
        let new = s ?? ""
        let n = (new as NSString).length
        guard n > 0 else { return edit }
        splice(NSRange(location: at, length: 0), new)
        // The program's cursor stays before the composed text, or keeps its place behind it.
        if programCaret > at { programCaret += n }
        marked = NSRange(location: at, length: n)
        let start = max(0, min(selection.location, n)), len = max(0, min(selection.length, n - start))
        selected = clamped(NSRange(location: at + start, length: len))
        return edit
    }

    /// Ends composition and returns the composed text, which the caller commits with `insert`.
    /// The marked range stays until then, so the commit replaces it.
    func markedText() -> String? {
        marked.map { substring($0) }
    }

    /// The keyboard's delete key.
    mutating func deleteBackward() -> GhosttyInputEdit {
        if marked != nil {
            // Composed text never reached the program: drop it here only.
            dropMarked()
            return GhosttyInputEdit()
        }
        let sel = clamped(selected)
        if sel.length > 0 {
            let edit = change(sel, to: "")
            selected = NSRange(location: sel.location, length: 0)
            return edit
        }
        guard sel.location > 0 else {
            // Nothing of ours before the caret (after a paste, a Return, a prompt that was already
            // there): the program still has something to delete, before the start of this text.
            let edit = GhosttyInputEdit(move: -slice(0, programCaret).count, backspaces: 1)
            programCaret = 0
            return edit
        }
        let r = (text as NSString).rangeOfComposedCharacterSequence(at: sel.location - 1)
        let edit = change(r, to: "")
        selected = NSRange(location: r.location, length: 0)
        return edit
    }

    /// The system replaces text that was already sent (dictation revising a phrase, a correction
    /// picked from the keyboard's bar).
    mutating func replace(_ range: NSRange, with s: String) -> GhosttyInputEdit {
        dropMarked()
        let r = clamped(range)
        let edit = change(r, to: s)
        let n = (s as NSString).length
        if NSMaxRange(r) <= selected.location {
            selected = clamped(NSRange(location: selected.location - r.length + n, length: selected.length))
        } else if r.location < NSMaxRange(selected) {
            selected = NSRange(location: r.location + n, length: 0)
        }
        return edit
    }

    /// Moves the caret by whole characters (the space-bar trackpad), and the program's cursor
    /// with it: the caller sends one arrow key per character asked for. Returns how far the
    /// program's cursor went in the text; less than asked means it left what was typed, where
    /// the document no longer knows the line.
    @discardableResult
    mutating func moveCaret(by characters: Int) -> Int {
        selected = NSRange(location: offset(clamped(selected).location, movedBy: characters).at, length: 0)
        let program = offset(programCaret, movedBy: characters)
        programCaret = program.at
        return program.moved
    }

    private func offset(_ from: Int, movedBy characters: Int) -> (at: Int, moved: Int) {
        let s = text as NSString
        var at = max(0, min(from, s.length))
        var left = characters
        while left < 0, at > 0 {
            at = s.rangeOfComposedCharacterSequence(at: at - 1).location
            left += 1
        }
        while left > 0, at < s.length {
            at = NSMaxRange(s.rangeOfComposedCharacterSequence(at: at))
            left -= 1
        }
        return (at, characters - left)
    }
}

final class GhosttyTextPosition: UITextPosition {
    let offset: Int
    init(_ offset: Int) {
        self.offset = offset
        super.init()
    }
}

final class GhosttyTextRange: UITextRange {
    let range: NSRange
    init(_ range: NSRange) {
        self.range = range
        super.init()
    }
    override var start: UITextPosition { GhosttyTextPosition(range.location) }
    override var end: UITextPosition { GhosttyTextPosition(NSMaxRange(range)) }
    override var isEmpty: Bool { range.length == 0 }
}

/// Keyboard state of one Ghostty view.
@MainActor
final class GhosttyInputState {
    var document = GhosttyInputDocument()
    /// A hardware key handed to the text system, until its text comes back (`Route.textInput`).
    var pending: (usage: Int, key: GhosttyInputKey)?
    /// Hardware keys whose press was encoded, by HID usage, for their release (the Kitty
    /// protocol can report it).
    var down: [Int: GhosttyInputKey] = [:]
    /// Repeats the held key that was encoded here (`KeyRepeater`).
    var keyRepeat = KeyRepeater()
    /// The hardware keyboard's language, for what Option means (`GhosttyInputKeymap.optionRole`).
    /// Nil: the view's input mode says. Tests set it.
    var layoutLanguage: String?
    /// Last point of a space-bar trackpad drag.
    var floatingCursor: CGPoint?
}

// MARK: UITextInput

/// Full `UITextInput`, not just `UIKeyInput`, because the SwiftTerm engine has it and these need
/// it: input methods that compose (Chinese, Japanese, Korean, and dead keys on a hardware
/// keyboard), dictation, and the space-bar trackpad. Like SwiftTerm, marked text is not drawn in
/// the terminal: the keyboard's candidate bar shows it, and it is sent when committed.
extension GhosttyTerminalView: UITextInput {
    private var document: GhosttyInputDocument { inputState.document }

    /// Changes the shadow document and tells the keyboard, as SwiftTerm does around every edit.
    func editInputDocument<R>(_ body: (inout GhosttyInputDocument) -> R) -> R {
        inputDelegate?.selectionWillChange(self)
        inputDelegate?.textWillChange(self)
        let r = body(&inputState.document)
        inputDelegate?.textDidChange(self)
        inputDelegate?.selectionDidChange(self)
        return r
    }

    /// Forgets what was typed: the line it shadowed is gone (Return) or was edited some other way.
    func resetInputDocument() {
        guard !document.isEmpty || document.isComposing else { return }
        editInputDocument { $0.reset() }
    }

    private func nsRange(_ r: UITextRange) -> NSRange? {
        if let r = r as? GhosttyTextRange { return r.range }
        guard let a = r.start as? GhosttyTextPosition, let b = r.end as? GhosttyTextPosition else { return nil }
        return NSRange(location: min(a.offset, b.offset), length: abs(b.offset - a.offset))
    }

    // Text

    func text(in range: UITextRange) -> String? {
        nsRange(range).map { document.substring($0) }
    }

    func replace(_ range: UITextRange, withText text: String) {
        guard let r = nsRange(range), !document.isComposing else { return }
        sendEdit(editInputDocument { $0.replace(r, with: text) })
    }

    var selectedTextRange: UITextRange? {
        get { GhosttyTextRange(document.selected) }
        set {
            guard let newValue, let r = nsRange(newValue), document.clamped(r) != document.selected else { return }
            inputDelegate?.selectionWillChange(self)
            inputState.document.select(r)
            inputDelegate?.selectionDidChange(self)
        }
    }

    var markedTextRange: UITextRange? { document.marked.map { GhosttyTextRange($0) } }

    func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        sendEdit(editInputDocument { $0.setMarked(markedText, selection: selectedRange) })
    }

    func unmarkText() {
        guard let composed = document.markedText() else { return }
        if composed.isEmpty {
            sendEdit(editInputDocument { $0.setMarked(nil, selection: NSRange(location: 0, length: 0)) })
        } else {
            insertText(composed)
        }
    }

    // Positions

    var beginningOfDocument: UITextPosition { GhosttyTextPosition(0) }
    var endOfDocument: UITextPosition { GhosttyTextPosition(document.length) }

    func textRange(from fromPosition: UITextPosition, to toPosition: UITextPosition) -> UITextRange? {
        guard let a = fromPosition as? GhosttyTextPosition, let b = toPosition as? GhosttyTextPosition else { return nil }
        return GhosttyTextRange(document.clamped(NSRange(location: min(a.offset, b.offset), length: abs(b.offset - a.offset))))
    }

    func position(from position: UITextPosition, offset: Int) -> UITextPosition? {
        guard let p = position as? GhosttyTextPosition else { return nil }
        let to = p.offset + offset
        guard to >= 0, to <= document.length else { return nil }
        return GhosttyTextPosition(document.clamped(NSRange(location: to, length: 0)).location)
    }

    func position(from position: UITextPosition, in direction: UITextLayoutDirection, offset: Int) -> UITextPosition? {
        let forward = direction == .right || direction == .down
        return self.position(from: position, offset: forward ? offset : -offset)
    }

    func compare(_ position: UITextPosition, to other: UITextPosition) -> ComparisonResult {
        guard let a = position as? GhosttyTextPosition, let b = other as? GhosttyTextPosition else { return .orderedSame }
        return a.offset < b.offset ? .orderedAscending : a.offset > b.offset ? .orderedDescending : .orderedSame
    }

    func offset(from: UITextPosition, to toPosition: UITextPosition) -> Int {
        guard let a = from as? GhosttyTextPosition, let b = toPosition as? GhosttyTextPosition else { return 0 }
        return b.offset - a.offset
    }

    func position(within range: UITextRange, farthestIn direction: UITextLayoutDirection) -> UITextPosition? {
        direction == .left || direction == .up ? range.start : range.end
    }

    func characterRange(byExtending position: UITextPosition, in direction: UITextLayoutDirection) -> UITextRange? {
        guard let p = position as? GhosttyTextPosition else { return nil }
        if direction == .left || direction == .up { return GhosttyTextRange(NSRange(location: 0, length: p.offset)) }
        return GhosttyTextRange(NSRange(location: p.offset, length: max(0, document.length - p.offset)))
    }

    func baseWritingDirection(for position: UITextPosition, in direction: UITextStorageDirection) -> NSWritingDirection { .leftToRight }
    func setBaseWritingDirection(_ writingDirection: NSWritingDirection, for range: UITextRange) {}

    // Geometry. The document is one line at the terminal's cursor.

    /// Where the keyboard should think the caret is. Only an input method's candidate window
    /// (hardware keyboard) uses the exact place, so the terminal is asked for its cursor only
    /// while composing; that read takes the terminal lock.
    private var inputCaretRect: CGRect {
        let cell = cellSize
        guard document.isComposing else {
            return CGRect(x: 0, y: max(0, bounds.maxY - cell.height), width: cell.width, height: cell.height)
        }
        let c = core.cursorPosition
        return CGRect(x: CGFloat(c.x) * cell.width, y: CGFloat(c.y) * cell.height, width: cell.width, height: cell.height)
    }

    func firstRect(for range: UITextRange) -> CGRect { inputCaretRect }
    func caretRect(for position: UITextPosition) -> CGRect { inputCaretRect }
    func selectionRects(for range: UITextRange) -> [UITextSelectionRect] { [] }
    func closestPosition(to point: CGPoint) -> UITextPosition? { GhosttyTextPosition(document.selected.location) }

    func closestPosition(to point: CGPoint, within range: UITextRange) -> UITextPosition? { range.start }

    func characterRange(at point: CGPoint) -> UITextRange? {
        GhosttyTextRange(NSRange(location: 0, length: document.length))
    }

    var textInputView: UIView { self }

    // Dictation

    func insertDictationResult(_ dictationResult: [UIDictationPhrase]) {
        let text = dictationResult.map(\.text).joined()
        if !text.isEmpty { insertText(text) }
    }

    func dictationRecordingDidEnd() {}
    func dictationRecognitionFailed() {}

    // The space-bar trackpad: a horizontal drag sends Left and Right; on the alternate screen a
    // vertical drag sends Up and Down. Same distances as SwiftTerm.

    func beginFloatingCursor(at point: CGPoint) {
        inputState.floatingCursor = point
    }

    func updateFloatingCursor(at point: CGPoint) {
        guard let last = inputState.floatingCursor else { return }
        let dx = last.x - point.x, dy = last.y - point.y
        if abs(dx) > 5 {
            // Keep the shadow caret with the program's, so a later delete removes the right character.
            // Past either end of what was typed the shadow no longer mirrors the line: forget it.
            if editInputDocument({ $0.moveCaret(by: dx > 0 ? -1 : 1) }) == 0 { resetInputDocument() }
            sendTyped([GhosttyInputKey(dx > 0 ? GHOSTTY_KEY_ARROW_LEFT : GHOSTTY_KEY_ARROW_RIGHT)])
            inputState.floatingCursor = point
        }
        if abs(dy) > 2, core.input.modes.alternateScreen {
            sendTyped([GhosttyInputKey(dy > 0 ? GHOSTTY_KEY_ARROW_UP : GHOSTTY_KEY_ARROW_DOWN)])
            inputState.floatingCursor = point
        }
    }

    func endFloatingCursor() {
        inputState.floatingCursor = nil
    }
}
