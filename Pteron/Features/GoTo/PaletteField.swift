import SwiftUI
import UIKit

/// The palette's search field. ↑ ↓ Esc and Tab are its own (no menu item lacks ⌘ or ⌃, so none
/// collide); Return is taken in `textFieldShouldReturn`, which UIKit doesn't call while Return
/// commits marked text. While an input method composes, the field declares no key commands at
/// all, so every key reaches the text system. The palette's own ⌘ and ⌃ keys arrive as menu
/// items (`AppShortcutCommands`); only an ⌥ or function-key binding to a palette action is
/// resolved here.
final class PaletteField: UITextField, UITextFieldDelegate {
    var onText: (String) -> Void = { _ in }
    var onReturn: () -> Void = {}
    var onEscape: () -> Void = {}
    var onMove: (Int) -> Void = { _ in }
    var onBackspaceEmpty: () -> Void = {}
    /// The palette scope an ⌥ or function-key press runs, from the keymap; nil for others.
    var paletteKey: (KeyInput.Press) -> GoToScope? = { _ in nil }
    var onScope: (GoToScope) -> Void = { _ in }
    /// Take the keyboard as soon as the field is on screen.
    var focusOnAppear = true
    private var tookFocus = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        autocorrectionType = .no
        autocapitalizationType = .none
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        spellCheckingType = .no
        inlinePredictionType = .no
        writingToolsBehavior = .none
        returnKeyType = .go
        enablesReturnKeyAutomatically = false
        clearButtonMode = .never
        borderStyle = .none
        backgroundColor = .clear
        inputAssistantItem.leadingBarButtonGroups = []
        inputAssistantItem.trailingBarButtonGroups = []
        addTarget(self, action: #selector(edited), for: .editingChanged)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// An input method is composing: Return, Escape and the arrows belong to it.
    var composing: Bool { markedTextRange != nil }

    override var keyCommands: [UIKeyCommand]? {
        // UIKit asks again for every press, so this follows composition as it starts and ends.
        guard !composing else { return [] }
        func key(_ input: String, _ action: Selector, repeats: Bool = false) -> UIKeyCommand {
            let c = UIKeyCommand(input: input, modifierFlags: [], action: action)
            c.wantsPriorityOverSystemBehavior = true
            c.repeatBehavior = repeats ? .repeatable : .nonRepeatable
            return c
        }
        return [key(UIKeyCommand.inputUpArrow, #selector(up), repeats: true),
                key(UIKeyCommand.inputDownArrow, #selector(down), repeats: true),
                key(UIKeyCommand.inputEscape, #selector(escape)),
                key("\t", #selector(down))]
    }

    @objc private func up() { onMove(-1) }
    @objc private func down() { onMove(1) }
    @objc private func escape() { onEscape() }

    @objc private func edited() {
        // Ranking runs on committed text only.
        guard !composing else { return }
        onText(text ?? "")
    }

    override func unmarkText() {
        super.unmarkText()
        onText(text ?? "")
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        onReturn()
        return false
    }

    override func deleteBackward() {
        if (text ?? "").isEmpty, !composing { onBackspaceEmpty() }
        super.deleteBackward()
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard !composing else { return super.pressesBegan(presses, with: event) }
        var rest = Set<UIPress>()
        for press in presses {
            guard let key = press.key else { rest.insert(press); continue }
            let mods = key.modifierFlags.intersection([.control, .alternate, .command])
            let function = (58...69).contains(key.keyCode.rawValue) || (104...115).contains(key.keyCode.rawValue)
            // ⌘ and ⌃ keys are menu items; here only ⌥ (without them) and function keys.
            if mods == .alternate || (function && !mods.contains(.command) && !mods.contains(.control)),
               let scope = paletteKey(KeyInput.Press(key)) {
                onScope(scope)
                continue
            }
            rest.insert(press)
        }
        if !rest.isEmpty { super.pressesBegan(rest, with: event) }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, focusOnAppear, !tookFocus else { return }
        tookFocus = true
        _ = becomeFirstResponder()
    }

    /// Shows `text` without reporting it as typed.
    func show(_ text: String) {
        guard self.text != text else { return }
        self.text = text
    }
}

/// `PaletteField` in SwiftUI.
struct PaletteFieldView: UIViewRepresentable {
    let model: GoToModel
    let placeholder: String
    let font: UIFont
    let color: UIColor
    let placeholderColor: UIColor
    let paletteKey: (KeyInput.Press) -> GoToScope?
    let onScope: (GoToScope) -> Void

    func makeUIView(context: Context) -> PaletteField {
        let f = PaletteField(frame: .zero)
        f.setContentHuggingPriority(.defaultLow, for: .horizontal)
        f.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        f.accessibilityLabel = "Search"
        context.coordinator.version = model.fieldVersion
        if model.fieldVersion > 0 { f.show(model.fieldText) }
        model.field = f
        wire(f)
        return f
    }

    func updateUIView(_ f: PaletteField, context: Context) {
        wire(f)
        f.font = font
        f.textColor = color
        f.attributedPlaceholder = NSAttributedString(string: placeholder, attributes: [.foregroundColor: placeholderColor, .font: font])
        if context.coordinator.version != model.fieldVersion {
            context.coordinator.version = model.fieldVersion
            f.show(model.fieldText)
        }
    }

    private func wire(_ f: PaletteField) {
        let m = model
        f.onText = { [weak m] in m?.setQuery($0) }
        f.onReturn = { [weak m] in m?.submit() }
        f.onEscape = { [weak m] in m?.dismiss() }
        f.onMove = { [weak m] in m?.move(by: $0) }
        f.onBackspaceEmpty = { [weak m] in m?.backspaceOnEmpty() }
        f.paletteKey = paletteKey
        f.onScope = onScope
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var version = 0
    }
}
