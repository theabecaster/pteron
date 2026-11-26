import RexKit
import UIKit

/// Compose (docs/terminal.md, Compose): the key bar's ✎ opens a card with a plain text field above
/// the keys, for one pane. Its field takes the keyboard inside the displayed key bar, as find's
/// accessory field does: the same input view, the key bar as its accessory, so the keyboard stays
/// where it is. Send writes the message through the pane's one input queue, behind the catch-up
/// fence, and clears the field. Compose stays open for the pane until ✎ or the handle closes it;
/// whenever the pane's keyboard comes up meanwhile, the field takes it.
extension TerminalHost {
    /// Called once from `init`.
    func setUpCompose() {
        let card = keyBar.compose
        card.onSend = { [weak self] in self?.sendCompose() }
        card.onClose = { [weak self] in self?.closeCompose() }
        card.onChange = { [weak self] text in self?.composeSlot.text = text }
        card.takesModifiedKey = { [weak self] text in self?.keyBar.typedInCompose(text) ?? false }
        card.attachMenu = { [weak self] in self?.files?.menu() ?? UIMenu() }
        keyBar.onCompose = { [weak self] in self?.toggleCompose() }
        // The keyboard takes the bar's new height (compose's card) from a reload of its responder.
        keyBar.onHeightChange = { [weak self] in
            guard let self else { return }
            if self.composeHoldsKeyboard {
                self.keyBar.compose.field.reloadInputViews()
            } else if self.term.isFirstResponder, self.term.inputAccessoryView === self.keyBar {
                self.term.reloadInputViews()
            }
        }
        keyBar.onPalette = { [weak self] in self?.onCommand?(.goTo(.commands)) }
        let nc = NotificationCenter.default
        for name in [UITextView.textDidBeginEditingNotification, UITextView.textDidEndEditingNotification] {
            nc.addObserver(self, selector: #selector(composeFocusChanged), name: name, object: card.field)
        }
        // A message dropped by the fence soon after it was sent comes back into an empty field.
        // A stream with no notice of its own for the fence says it as any other (`onActionFailed`).
        let say = stream.onFenceNotice
        stream.onFenceNotice = { [weak self] notice in
            guard let self else { return }
            self.composeInputDropped()
            if let say { say(notice) } else { self.stream.onActionFailed?(notice) }
        }
    }

    /// Compose's field has the keyboard.
    var composeHoldsKeyboard: Bool { keyBar.compose.field.isFirstResponder }

    /// The slot changed (a new host takes a pane's slot): the bar shows it as it is.
    func applyComposeSlot() {
        keyBar.compose.show(text: composeSlot.text)
        if composeSlot.open { keyBar.compose.placeholder = composePlaceholder() }
        keyBar.composeOpen = composeSlot.open
        term.composeOpen = composeSlot.open
    }

    /// ✎.
    func toggleCompose() {
        composeSlot.open ? closeCompose() : openCompose()
    }

    /// Opens compose for this pane and gives its field the keyboard.
    func openCompose() {
        guard !covered, !composeSlot.open else { return }
        composeSlot.open = true
        applyComposeSlot()
        keyBar.layoutIfNeeded()
        focusCompose()
    }

    /// Closes compose; the terminal takes the keyboard back from the field, in the same key
    /// bar, so the keyboard stays. The draft stays for the next time.
    func closeCompose() {
        guard composeSlot.open else { return }
        composeSlot.open = false
        keyBar.cancelWhenInWindow()
        yieldComposeToTerminal()
        keyBar.composeOpen = false
        term.composeOpen = false
        keyBar.compose.field.inputAccessoryView = nil
    }

    /// The field takes the keyboard from the terminal inside the key bar on screen, as find's
    /// accessory field does: the terminal's input view, the key bar as its accessory, and the
    /// key bar stays the terminal's accessory for whatever gives the terminal the keyboard next.
    func focusCompose() {
        guard composeSlot.open, !composeHoldsKeyboard, !covered, isActive, term.isFirstResponder, !keyboardQuiet,
              term.inputAccessoryView === keyBar, keyBar.window != nil else { return }
        keyBar.compose.placeholder = composePlaceholder()
        let field = keyBar.compose.field
        field.inputView = term.inputView
        field.inputAccessoryView = keyBar
        _ = field.becomeFirstResponder()
        refreshBarHidesKeyboard()
    }

    /// The terminal took the keyboard while compose is open: the field takes it once the key
    /// bar is in the keyboard's window.
    func refocusComposeSoon() {
        guard composeSlot.open, !keyboardQuiet else { return }
        keyBar.whenInWindow { [weak self] in self?.focusCompose() }
    }

    /// The terminal takes the keyboard back from compose's field, at once and with the same
    /// input views: nothing on screen moves. Every path that puts the keyboard away or hands it
    /// on (the hide key, a cover, a pane switch, find) starts here and then deals with the
    /// terminal as it always did; the field gets the keyboard back when the terminal next does.
    func yieldComposeToTerminal() {
        guard composeHoldsKeyboard else { return }
        composeYielding = true
        defer { composeYielding = false }
        setKeyboardQuiet(false)
        if !term.becomeFirstResponder() { _ = keyBar.compose.field.resignFirstResponder() }
    }

    @objc private func composeFocusChanged() { refreshBarHidesKeyboard() }

    /// "Message Claude Code ~/pteron".
    func composePlaceholder() -> String {
        let c = composeContext?()
        return ComposePlaceholder.text(agent: c?.agent, program: c?.program, pwd: c?.pwd)
    }

    /// Send: the whole message as the program takes a paste (bracketed when it asked for it),
    /// then Return as a write of its own, through the one input queue and behind the catch-up
    /// fence. A multi-line message to a program that takes no bracketed paste would run each
    /// line, so it is asked about first, as such a paste is (`PasteConfirmation`).
    func sendCompose() {
        let field = keyBar.compose.field
        // An input method's composition is part of the message as it stands.
        if field.markedTextRange != nil { field.unmarkText() }
        let text: String = field.text
        guard !text.isEmpty, !covered else { return }
        let deliver: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            let bytes = self.term.messageBytes(text)
            guard !bytes.isEmpty else { return }
            // Behind the fence the message is held; if the fence drops it, it comes back.
            if self.stream.isFenced {
                self.lastComposeSend = (text, CACurrentMediaTime())
                self.stream.whenCurrent { [weak self] in self?.lastComposeSend = nil }
            }
            self.composeWrite(bytes, [0x0d])
            self.keyBar.consumedModifiers()
            // Cleared once it went: a message still waiting for its confirmation stays.
            self.composeSlot.text = ""
            self.keyBar.compose.show(text: "")
        }
        guard term.pasteNeedsConfirmation(text) else { return deliver() }
        let answer: @MainActor (Bool) -> Void = { yes in if yes { deliver() } }
        if let confirmPaste {
            confirmPaste(text, answer)
        } else {
            TerminalPrompt.ask(over: self, title: PasteConfirmation.title(text), message: PasteConfirmation.message(text),
                               confirm: "Paste", answer: answer)
        }
    }

    /// How soon after a send a dropped input puts the message back.
    static let composeRestoreWindow: CFTimeInterval = 10

    /// The stream dropped input (the fence's notice): a message sent behind the fence, which
    /// hasn't come down since, never left. It comes back into compose's field if that is empty,
    /// so it is not lost.
    func composeInputDropped() {
        guard let last = lastComposeSend, CACurrentMediaTime() - last.at < Self.composeRestoreWindow else { return }
        lastComposeSend = nil
        guard composeSlot.text.isEmpty else { return }
        composeSlot.text = last.text
        keyBar.compose.show(text: last.text)
    }
}
