import UIKit

/// Who held a pane's keyboard before an app surface took it (find's field, later the palette, the
/// file browser, the share sheet), so the surface can give it back exactly: shown, quiet, to
/// nobody, or to the pane's own find field.
enum KeyboardRecord: Equatable {
    /// The pane's terminal, first responder, with the system keyboard and the key bar.
    case shown
    /// The terminal, first responder with the empty input view: hardware keys, nothing shown.
    case quiet
    /// Nobody in the pane (the keyboard was down).
    case none
    /// The pane's find field: in the keyboard's accessory slot, or in the pane (`accessory` false).
    case ownFindField(accessory: Bool)

    /// What the pane holds now.
    @MainActor
    static func capture(_ host: TerminalHost) -> KeyboardRecord {
        if let field = host.findFieldHoldingKeyboard { return .ownFindField(accessory: field == .accessory) }
        guard host.term.isFirstResponder else { return .none }
        return host.keyboardQuiet ? .quiet : .shown
    }
}

extension TerminalHost {
    /// Gives the keyboard back as `record` says. A find field gets it back through the same
    /// hand-over find uses (never through the terminal). Nothing happens when the right responder
    /// already holds it, so a cover that already gave it back costs no second frame change.
    /// `quiet` overrides whether the terminal shows its keyboard (`.shown` / `.quiet`).
    func retakeKeyboard(_ record: KeyboardRecord, quiet: Bool? = nil) {
        guard record != KeyboardRecord.capture(self) || quiet.map({ $0 != keyboardQuiet }) == true else { return }
        switch record {
        case .shown, .quiet:
            let q = quiet ?? (record == .quiet)
            setKeyboardQuiet(q)
            if !term.isFirstResponder { _ = term.becomeFirstResponder() }
        case .none:
            resignFindField()
            // A field in the terminal's accessory slot that resigns gives first responder back
            // to the terminal (UIKit's own rule for input accessories): resign that too.
            if term.isFirstResponder { _ = term.resignFirstResponder() }
        case .ownFindField:
            focusFindField()
        }
    }
}
