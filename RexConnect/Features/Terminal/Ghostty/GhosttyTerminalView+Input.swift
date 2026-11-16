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

    /// Encodes key events and sends them as one write, after `backspaces` Backspace keys.
    func sendTyped(_ keys: [GhosttyInputKey], backspaces: Int = 0) {
        var bytes: [UInt8] = []
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

// MARK: TerminalKeyTarget, paste

extension GhosttyTerminalView {
    func sendKeyUp() { sendKey(GHOSTTY_KEY_ARROW_UP) }
    func sendKeyDown() { sendKey(GHOSTTY_KEY_ARROW_DOWN) }
    func sendKeyLeft() { sendKey(GHOSTTY_KEY_ARROW_LEFT) }
    func sendKeyRight() { sendKey(GHOSTTY_KEY_ARROW_RIGHT) }
    func sendKeyHome() { sendKey(GHOSTTY_KEY_HOME) }
    func sendKeyEnd() { sendKey(GHOSTTY_KEY_END) }

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
}

// MARK: First responder

extension GhosttyTerminalView {
    override var canBecomeFirstResponder: Bool { true }

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

    /// The solid or hollow cursor, and the program's focus report if it asked for one. A focus
    /// report isn't typing: it doesn't scroll the view.
    private func focusChanged(_ focused: Bool) {
        renderer.setFocused(focused)
        let report = core.input.focusReport(gained: focused)
        if !report.isEmpty { engineDelegate?.engineSend(report) }
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
    /// Like SwiftTerm: true while the shadow document has text. Delete still arrives when it is
    /// empty, and then sends one Backspace.
    var hasText: Bool { !inputState.document.isEmpty }

    /// Text from the system keyboard, an input method's commit, dictation, or a hardware key
    /// that went through the text system.
    func insertText(_ text: String) {
        editInputDocument { $0.insert(text) }
        // The shadow only needs the line being typed.
        if text == "\n" || inputState.document.length > 4096 { resetInputDocument() }

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
        sendTyped(keys)
    }

    func deleteBackward() {
        let backspaces = editInputDocument { $0.deleteBackward() }
        guard backspaces > 0 else { return }
        var key = GhosttyInputKey(GHOSTTY_KEY_BACKSPACE)
        if let pending = takePending(for: key) {
            key = pending.key
            inputState.down[pending.usage] = key
        }
        key.mods |= takeOneShotModifiers()
        sendTyped([key], backspaces: backspaces - 1)
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
        let route = GhosttyInputKeymap.route(usage: usage, flags: flags, characters: characters,
                                             charactersIgnoringModifiers: charactersIgnoringModifiers)
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

    /// Like SwiftTerm: plain Page Up and Page Down scroll the scrollback, unless the program
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
        if inputState.repeatUsage == usage { stopKeyRepeat() }
        if inputState.pending?.usage == usage { inputState.pending = nil }
        guard var k = inputState.down.removeValue(forKey: usage) else { return }
        // Empty unless the program asked the Kitty protocol for release events.
        k.action = .release
        let bytes = core.input.encode(k)
        if !bytes.isEmpty { engineDelegate?.engineSend(bytes) }
    }

    // Keys that type repeat through the text system. Keys encoded here repeat on a timer, with
    // SwiftTerm's delay and rate; only the latest key repeats.

    private func startKeyRepeat(usage: Int, key: GhosttyInputKey) {
        stopKeyRepeat()
        var again = key
        again.action = .repeatPress
        inputState.repeatUsage = usage
        let timer = Timer(fire: Date(timeIntervalSinceNow: 0.4), interval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard self.isFirstResponder, self.window != nil else { return self.stopKeyRepeat() }
                self.sendTyped([again])
            }
        }
        inputState.repeatTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopKeyRepeat() {
        inputState.repeatTimer?.invalidate()
        inputState.repeatTimer = nil
        inputState.repeatUsage = nil
    }
}
