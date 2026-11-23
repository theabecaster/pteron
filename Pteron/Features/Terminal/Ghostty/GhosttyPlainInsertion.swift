/// Decides whether text from the keyboard is one plain key: a character typed at the program's
/// cursor, with nothing composed, selected, replaced or dictated.
///
/// A plain key goes to the program before the keyboard is told that the text changed
/// (`GhosttyTerminalView.insertText`): the keyboard takes milliseconds over that, and the key
/// would wait for it. Everything else keeps the other order, the keyboard first.
struct GhosttyPlainInsertion: Equatable {
    /// The longest shadow document a plain key leaves. Past it the document is reset, which
    /// tells the keyboard again.
    static let longestLine = 4096

    /// An input method was composing when the text came.
    var composing: Bool
    /// UTF-16 units the keyboard had selected: the text would replace them.
    var selected: Int

    init(composing: Bool, selected: Int) {
        self.composing = composing
        self.selected = selected
    }

    /// The document as it is before the text goes in.
    init(before document: GhosttyInputDocument) {
        self.init(composing: document.isComposing, selected: document.selected.length)
    }

    /// True when `text`, which made `edit` and left `after`, is one plain key. `dictation` is
    /// asked last, and only when everything else says yes.
    func holds(_ text: String, edit: GhosttyInputEdit, after: GhosttyInputDocument, dictation: @autoclosure () -> Bool) -> Bool {
        guard !composing, selected == 0, !after.isComposing else { return false }
        // One character: a word or more at once is a paste, dictation, a swipe or a suggestion.
        guard !text.isEmpty, text.index(after: text.startIndex) == text.endIndex, text != "\n" else { return false }
        // Typed at the program's cursor: nothing to move to, delete or type again.
        guard edit.move == 0, edit.backspaces == 0, edit.text == text else { return false }
        guard after.length <= Self.longestLine else { return false }
        return !dictation()
    }
}
