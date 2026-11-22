import UIKit
import GhosttyVt

// Input for the Ghostty engine: the system keyboard, hardware keys, the key bar's modifiers and
// paste. Every key becomes a libghostty-vt key event and is encoded under the terminal's current
// modes (`core.input`, GhosttyCore+Input.swift); nothing here knows what bytes a key sends.
// Stored state lives in the "Input" block of GhosttyTerminalView.swift; the `UITextInput` side
// (marked text, dictation, the space-bar trackpad) is in GhosttyInputText.swift.

// MARK: Sending

extension GhosttyTerminalView {
    /// Bytes for the program from something the user did. Typing shows live output again.
    private func sendInput(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        engineDelegate?.engineSend(bytes)
        // The scroller owns the viewport: it jumps to the bottom if the view is scrolled up.
        scrollToBottomForInput()
    }

    /// Takes the key bar's one-shot ctrl / alt for the key being typed and tells the bar.
    private func takeOneShotModifiers() -> GhosttyMods {
        var mods: GhosttyMods = 0
        if controlModifier {
            mods |= GhosttyInputKey.ctrl
            controlModifier = false
            NotificationCenter.default.post(name: .terminalEngineControlModifierReset, object: self)
        }
        if metaModifier {
            mods |= GhosttyInputKey.alt
            metaModifier = false
            NotificationCenter.default.post(name: .terminalEngineMetaModifierReset, object: self)
        }
        return mods
    }

    /// Sends what an edit of the shadow document means for the program's line, as one write.
    func sendEdit(_ edit: GhosttyInputEdit) {
        guard !edit.isEmpty else { return }
        sendTyped(GhosttyInputKeymap.typed(edit.text), backspaces: edit.backspaces, move: edit.move)
    }

    /// Encodes key events and sends them as one write, after `move` arrow keys (negative: Left)
    /// and `backspaces` Backspace keys.
    func sendTyped(_ keys: [GhosttyInputKey], backspaces: Int = 0, move: Int = 0) {
        var bytes: [UInt8] = []
        if move != 0 {
            let one = core.input.encode(GhosttyInputKey(move < 0 ? GHOSTTY_KEY_ARROW_LEFT : GHOSTTY_KEY_ARROW_RIGHT))
            for _ in 0..<abs(move) { bytes += one }
        }
        if backspaces > 0 {
            let one = core.input.encode(GhosttyInputKey(GHOSTTY_KEY_BACKSPACE))
            for _ in 0..<backspaces { bytes += one }
        }
        for key in keys { bytes += core.input.encode(key) }
        sendInput(bytes)
    }

    /// A key that isn't text: the line the shadow document mirrors is no longer what was typed.
    private func sendKey(_ key: GhosttyKey) {
        resetInputDocument()
        sendTyped([GhosttyInputKey(key)])
    }
}

// MARK: Key bar keys, raw sends, paste

extension GhosttyTerminalView {
    func sendKeyUp() { sendKey(GHOSTTY_KEY_ARROW_UP) }
    func sendKeyDown() { sendKey(GHOSTTY_KEY_ARROW_DOWN) }
    func sendKeyLeft() { sendKey(GHOSTTY_KEY_ARROW_LEFT) }
    func sendKeyRight() { sendKey(GHOSTTY_KEY_ARROW_RIGHT) }
    func sendKeyHome() { sendKey(GHOSTTY_KEY_HOME) }
    func sendKeyEnd() { sendKey(GHOSTTY_KEY_END) }

    /// The key bar's held Return: Shift-Return with its ctrl and alt, encoded under the program's
    /// modes as a hardware Shift-Return is, so a program can tell it from Return.
    func sendShiftReturn(ctrl: Bool, alt: Bool) {
        var mods = GhosttyInputKey.shift
        if ctrl { mods |= GhosttyInputKey.ctrl }
        if alt { mods |= GhosttyInputKey.alt }
        resetInputDocument()
        sendTyped([GhosttyInputKey(GHOSTTY_KEY_ENTER, mods: mods)])
    }

    /// An input method is composing: marked text the program hasn't got yet.
    var isComposing: Bool { inputState.document.isComposing }

    /// Types the composition as it stands and ends it, as the system keyboard's return does.
    func commitComposition() { unmarkText() }

    /// Bytes someone else encoded (the key bar's keys, key bindings).
    func send(data: ArraySlice<UInt8>) {
        resetInputDocument()
        sendInput(Array(data))
    }

    /// Types `txt`, as the system keyboard would without the key bar's modifiers.
    func send(txt: String) {
        resetInputDocument()
        sendTyped(GhosttyInputKeymap.typed(txt))
    }

    func pasteText(_ s: String) {
        resetInputDocument()
        sendInput(core.input.paste(s))
    }

    /// True when pasting `s` now could run a command (a line end, outside bracketed paste): the
    /// host asks the user first.
    func pasteNeedsConfirmation(_ s: String) -> Bool { core.input.pasteNeedsConfirmation(s) }

    /// Who may let the program write the pasteboard (OSC 52): asked on the main actor for each
    /// write; a refused write is dropped.
    func setProgramClipboardGate(_ gate: @escaping @MainActor () -> Bool) { core.clipboard.setGate(gate) }
}

// MARK: First responder

extension GhosttyTerminalView {
    /// Not under a cover (the agent board): a covered pane takes no keyboard.
    override var canBecomeFirstResponder: Bool { !covered }

    override func becomeFirstResponder() -> Bool {
        let was = isFirstResponder
        let ok = super.becomeFirstResponder()
        if ok, !was { focusChanged(true) }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let was = isFirstResponder
        let ok = super.resignFirstResponder()
        if ok, was {
            stopKeyRepeat()
            inputState.pending = nil
            inputState.down.removeAll()
            focusChanged(false)
        }
        return ok
    }

    /// The keyboard came or went: the solid or hollow cursor. The program is told nothing: its
    /// focus follows the front pane, not the keyboard (`setProgramFocus`).
    private func focusChanged(_ focused: Bool) {
        renderer.setFocused(focused)
        keyboardFocusHook?(focused)
    }

    /// The host says whether this is the front pane (`PaneFront`): the program's focus.
    func setProgramFocus(_ front: Bool) {
        if programFocus.set(front: front) { sayFocus(.changed) }
    }

    /// Tells the program whether its pane is in front, if it asked for focus reports and one is
    /// due at this moment (`ProgramFocus.due`). A report that could not leave (the stream was
    /// catching up) is made up for by the next call: the host calls this when the stream is
    /// current again. A focus report isn't typing: it doesn't scroll the view.
    func sayFocus(_ moment: ProgramFocus.Moment) {
        guard let gained = programFocus.due(at: moment) else { return }
        let report = core.input.focusReport(gained: gained)
        guard !report.isEmpty else {
            // A program that doesn't ask is told nothing, now or later for this change.
            programFocus.told(gained)
            return
        }
        guard engineDelegate?.engineSendReport(report) ?? false else { return }
        programFocus.told(gained)
        // A click waits out the program's activation window after this (`sendClickToProgram`).
        if gained { programFocus.gainedSent(at: CACurrentMediaTime()) }
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        // The solid cursor needs the keyboard, and the keyboard needs a window: a pane that never
        // had the keyboard, or is off screen, draws the hollow cursor.
        renderer.setFocused(newWindow != nil && isFirstResponder)
        if newWindow == nil { stopKeyRepeat() }
    }

    // A terminal takes what is typed as is.
    var autocapitalizationType: UITextAutocapitalizationType { get { .none } set {} }
    var autocorrectionType: UITextAutocorrectionType { get { .no } set {} }
    var spellCheckingType: UITextSpellCheckingType { get { .no } set {} }
    var smartQuotesType: UITextSmartQuotesType { get { .no } set {} }
    var smartDashesType: UITextSmartDashesType { get { .no } set {} }
    var smartInsertDeleteType: UITextSmartInsertDeleteType { get { .no } set {} }
    var inlinePredictionType: UITextInlinePredictionType { get { .no } set {} }
    var keyboardType: UIKeyboardType { get { .default } set {} }
    var returnKeyType: UIReturnKeyType { get { .default } set {} }
    var enablesReturnKeyAutomatically: Bool { get { false } set {} }
    var isSecureTextEntry: Bool { get { false } set {} }
}

// MARK: System keyboard

extension GhosttyTerminalView {
    /// True while the shadow document has text. Delete still arrives when it is
    /// empty, and then sends one Backspace.
    var hasText: Bool { !inputState.document.isEmpty }

    /// Text from the system keyboard, an input method's commit, dictation, or a hardware key
    /// that went through the text system.
    func insertText(_ text: String) {
        guard !covered else { return }
        if takeCommandKey(text) { return }
        // Return ends the line: nothing on it is edited any more.
        if text == "\n" { resetInputDocument() }
        let edit = text == "\n" ? GhosttyInputEdit(text: text) : editInputDocument { $0.insert(text) }
        // The shadow only needs the line being typed.
        if inputState.document.length > 4096 { resetInputDocument() }
        guard edit.move == 0, edit.backspaces == 0, edit.text == text else {
            // The keyboard put the text somewhere other than the program's cursor (a caret it
            // moved, a selection it replaced): the program's line is edited to match.
            inputState.pending = nil
            _ = takeOneShotModifiers()
            return sendEdit(edit)
        }

        var keys = GhosttyInputKeymap.typed(text)
        guard !keys.isEmpty else { return }
        if keys.count == 1, let pending = takePending(for: keys[0]) {
            // The hardware key that typed this: its physical key and shift, the text iOS made of it.
            var key = pending.key
            key.text = keys[0].text
            if key.text.isEmpty { key.consumedMods = 0 }
            keys[0] = key
            inputState.down[pending.usage] = key
        }
        keys[0].mods |= takeOneShotModifiers()
        keys[0] = legacyControl(keys[0])
        sendTyped(keys)
    }

    /// The key bar's ctrl with Return or Tab from the system keyboard, for a program that asked
    /// for no keyboard protocol: the plain key. Ctrl+M and Ctrl+I already are Return and Tab
    /// there, while the encoder's `CSI 27 ; 5 ; 13 ~` would show up as text in a shell.
    /// A hardware Ctrl+Return stays what Ghostty sends.
    private func legacyControl(_ key: GhosttyInputKey) -> GhosttyInputKey {
        guard key.mods & GhosttyInputKey.ctrl != 0, key.key == GHOSTTY_KEY_ENTER.rawValue || key.key == GHOSTTY_KEY_TAB.rawValue,
              core.input.modes.kittyFlags == 0 else { return key }
        var plain = key
        plain.mods &= ~GhosttyInputKey.ctrl
        return plain
    }

    func deleteBackward() {
        guard !covered else { return }
        if takeCommandKey("\u{7f}") { return }
        let edit = editInputDocument { $0.deleteBackward() }
        guard edit.move == 0, edit.text.isEmpty else {
            // Not at the program's cursor: go there, delete, and type again what stood behind.
            inputState.pending = nil
            return sendEdit(edit)
        }
        let backspaces = edit.backspaces
        guard backspaces > 0 else { return }
        var key = GhosttyInputKey(GHOSTTY_KEY_BACKSPACE)
        if let pending = takePending(for: key) {
            key = pending.key
            inputState.down[pending.usage] = key
        }
        key.mods |= takeOneShotModifiers()
        sendTyped([key], backspaces: backspaces - 1)
    }

    /// With the key bar's ⌘ on, a key is a shortcut, never text: nothing is typed, the shadow
    /// document stays as it is, and the key bar gets the key. True when it took the key. An input
    /// method's composition is left to finish as usual: its commit and edits are text, not a key.
    private func takeCommandKey(_ text: String) -> Bool {
        guard commandModifier, !inputState.document.isComposing else { return false }
        inputState.pending = nil
        commandKeyHook?(text)
        return true
    }

    /// The hardware key waiting for this text, if it is the one that typed it.
    private func takePending(for typed: GhosttyInputKey) -> (usage: Int, key: GhosttyInputKey)? {
        guard let pending = inputState.pending else { return nil }
        let named = [GHOSTTY_KEY_ENTER.rawValue, GHOSTTY_KEY_BACKSPACE.rawValue]
        let matches: Bool
        if named.contains(typed.key) || named.contains(pending.key.key) {
            matches = typed.key == pending.key.key
        } else {
            // One character from one key. Anything longer is an input method's or dictation's.
            matches = typed.text.unicodeScalars.count == 1
        }
        guard matches else { return nil }
        inputState.pending = nil
        return pending
    }
}

// MARK: Hardware keyboard

extension GhosttyTerminalView {
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        // Covered: no key is this pane's, bound or not. They go on up the responder chain.
        guard !covered else { return super.pressesBegan(presses, with: event) }
        var rest = Set<UIPress>()
        for press in presses {
            guard let key = press.key else {
                rest.insert(press)
                continue
            }
            // The app's keymap first: a bound key never reaches the program or the text system.
            if let hook = keyHook, hook(key) { continue }
            let handled = hardwareKeyDown(usage: key.keyCode.rawValue, flags: key.modifierFlags, characters: key.characters,
                                          charactersIgnoringModifiers: key.charactersIgnoringModifiers)
            if !handled { rest.insert(press) }
        }
        // Keys that type go on to the text system and come back as `insertText`; Command
        // shortcuts go on to the app's key commands.
        if !rest.isEmpty { super.pressesBegan(rest, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        hardwareKeysUp(presses)
        super.pressesEnded(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        hardwareKeysUp(presses)
        super.pressesCancelled(presses, with: event)
    }

    /// A hardware key went down. True if it was handled here and must not go on to the text
    /// system. Takes `UIKey`'s properties, since a `UIKey` can't be made in a test.
    func hardwareKeyDown(usage: Int, flags: UIKeyModifierFlags, characters: String, charactersIgnoringModifiers: String) -> Bool {
        guard !covered else { return false }
        let route = GhosttyInputKeymap.route(usage: usage, flags: flags, characters: characters,
                                             charactersIgnoringModifiers: charactersIgnoringModifiers,
                                             layoutLanguage: inputState.layoutLanguage ?? textInputMode?.primaryLanguage)
        let composing = inputState.document.isComposing
        switch route {
        case .system:
            return false
        case .modifier(var k):
            k.composing = composing
            let bytes = core.input.encode(k)
            if !bytes.isEmpty { engineDelegate?.engineSend(bytes) }
            inputState.down[usage] = k
            return false
        case .textInput(let k):
            // While an input method composes, Return and Delete are its own.
            inputState.pending = composing ? nil : (usage, k)
            return false
        case .encode(var k):
            // Escape, arrows and Tab also belong to an input method while it composes.
            if composing { return false }
            if scrollsLocally(k) {
                scrollPage(up: k.key == GHOSTTY_KEY_PAGE_UP.rawValue)
                return true
            }
            k.mods |= takeOneShotModifiers()
            resetInputDocument()
            sendTyped([k])
            inputState.down[usage] = k
            startKeyRepeat(usage: usage, key: k)
            return true
        }
    }

    /// Plain Page Up and Page Down scroll the scrollback, unless the program
    /// took the cursor keys (DECCKM), as full-screen programs do.
    private func scrollsLocally(_ k: GhosttyInputKey) -> Bool {
        guard k.key == GHOSTTY_KEY_PAGE_UP.rawValue || k.key == GHOSTTY_KEY_PAGE_DOWN.rawValue else { return false }
        return k.mods & GhosttyInputKey.bindingMods == 0 && !core.input.modes.cursorKeyApplication
    }

    private func hardwareKeysUp(_ presses: Set<UIPress>) {
        for press in presses {
            if let usage = press.key?.keyCode.rawValue { hardwareKeyUp(usage: usage) }
        }
    }

    func hardwareKeyUp(usage: Int) {
        inputState.keyRepeat.released(usage: usage)
        if inputState.pending?.usage == usage { inputState.pending = nil }
        guard var k = inputState.down.removeValue(forKey: usage) else { return }
        // Empty unless the program asked the Kitty protocol for release events.
        k.action = .release
        let bytes = core.input.encode(k)
        if !bytes.isEmpty { engineDelegate?.engineSend(bytes) }
    }

    // Keys that type repeat through the text system. Keys encoded here repeat through
    // `KeyRepeater` (`Timing.program`); only the latest key repeats. The repeater
    // ends by itself when the key comes up, the app leaves the foreground, a keyboard goes away
    // or its limit is reached; this view ends it when it stops being first responder or leaves
    // its window.

    private func startKeyRepeat(usage: Int, key: GhosttyInputKey) {
        var again = key
        again.action = .repeatPress
        inputState.keyRepeat.start(usage: usage, while: { [weak self] in self?.mayRepeatKeys ?? false }) { [weak self] in
            self?.sendTyped([again])
        }
    }

    /// A held key repeats only into the terminal that has the keyboard, on screen, in the
    /// foreground.
    private var mayRepeatKeys: Bool {
        isFirstResponder && window != nil && UIApplication.shared.applicationState == .active
    }

    func stopKeyRepeat() {
        inputState.keyRepeat.stop()
    }
}
