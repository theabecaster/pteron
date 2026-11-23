import UIKit

/// What a find field reports to its pane.
@MainActor
protocol FindFieldOwner: AnyObject {
    /// ⇧Return: the previous (newer) match.
    func findFieldShiftReturn(_ field: FindField)
    /// Escape: back to the terminal with text, close with none.
    func findFieldEscape(_ field: FindField)
    /// A find chord from the keymap (⌘F, ⌘G, ⇧⌘G), in the keyboard's window, outside the
    /// pane's responder chain.
    func findField(_ field: FindField, perform action: AppAction)
}

/// The find bar's text field. Its traits are the terminal's (GhosttyTerminalView+Input.swift), so
/// moving the keyboard from the terminal to the field changes nothing about the keyboard: same
/// keys, same suggestion bar (none), same return key, same appearance.
final class FindField: UITextField {
    weak var owner: (any FindFieldOwner)?
    /// The keymap's find chords, for a field in the keyboard's window (`FindAccessoryBar`), where
    /// the pane's own key commands don't reach. Set by the pane; it follows the keymap.
    var findCommands: () -> [UIKeyCommand] = { [] }

    override init(frame: CGRect) {
        super.init(frame: frame)
        autocapitalizationType = .none
        autocorrectionType = .no
        spellCheckingType = .no
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        inlinePredictionType = .no
        keyboardType = .default
        returnKeyType = .default
        enablesReturnKeyAutomatically = false
        isSecureTextEntry = false
        // A text field picks its own Writing Tools default; the terminal has none.
        writingToolsBehavior = .none
        // No shortcut bar above the keyboard (iPad): the terminal shows none either.
        inputAssistantItem.leadingBarButtonGroups = []
        inputAssistantItem.trailingBarButtonGroups = []
        clearButtonMode = .never
        borderStyle = .none
        backgroundColor = .clear
        accessibilityLabel = "Find in Pane"
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Composition (an input method) is under way: Return and Escape belong to it.
    var composing: Bool { markedTextRange != nil }

    override var keyCommands: [UIKeyCommand]? {
        let escape = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(escapePressed))
        escape.wantsPriorityOverSystemBehavior = true
        return (super.keyCommands ?? []) + findCommands() + [escape]
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        // While composing, Escape goes on to the input method.
        if action == #selector(escapePressed) { return !composing }
        return super.canPerformAction(action, withSender: sender)
    }

    @objc private func escapePressed() {
        owner?.findFieldEscape(self)
    }

    @objc func findChordFired(_ sender: UIKeyCommand) {
        guard let spelling = sender.propertyList as? String, let chord = KeyChord(spelling: spelling),
              let action = findAction(chord) else { return }
        owner?.findField(self, perform: action)
    }

    /// Set by the pane: the action a chord in `findCommands` runs.
    var findAction: (KeyChord) -> AppAction? = { _ in nil }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard !composing else { return super.pressesBegan(presses, with: event) }
        var rest = Set<UIPress>()
        for press in presses {
            guard let key = press.key else { rest.insert(press); continue }
            let mods = key.modifierFlags.intersection([.shift, .control, .alternate, .command])
            if key.keyCode == .keyboardReturnOrEnter, mods == .shift {
                owner?.findFieldShiftReturn(self)
                continue
            }
            if key.keyCode == .keyboardEscape, mods.isEmpty {
                owner?.findFieldEscape(self)
                continue
            }
            rest.insert(press)
        }
        if !rest.isEmpty { super.pressesBegan(rest, with: event) }
    }
}
