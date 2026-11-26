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
        if data.count == 1, let byte = data.first, (0x21...0x7e).contains(byte), !inputState.document.isComposing {
            // One printable key of the bar (`/`, `-`, `~`, `|`) is text, as the keyboard's own
            // would be: the shadow keeps it, so the keyboard reads `src/` before the next word
            // rather than a line that starts there (`TypingAids.keepsTyped`).
            let typed = String(UnicodeScalar(byte))
            let edit = editInputDocument { $0.insert(typed) }
            if edit == GhosttyInputEdit(text: typed) { return sendInput(Array(data)) }
            return sendEdit(edit)
        }
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

    /// Compose's message as the program takes a paste: bracketed when it asked for bracketed
    /// paste, so an agent takes it whole and the Return after it as Return. The view returns to
    /// the newest line, as for any input; the caller writes the bytes (`TerminalHost.sendCompose`).
    func messageBytes(_ s: String) -> [UInt8] {
        resetInputDocument()
        let bytes = core.input.paste(s)
        if !bytes.isEmpty { scrollToBottomForInput() }
        return bytes
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
        if !was { typingAidsAsKeyboardArrives() }
        let ok = super.becomeFirstResponder()
        if ok, !was {
            inputState.modeLanguage = nil
            focusChanged(true)
        }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let was = isFirstResponder
        let ok = super.resignFirstResponder()
        if ok, was {
            stopKeyRepeat()
            inputState.pending = nil
            inputState.down.removeAll()
            inputState.modeLanguage = nil
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
        guard let engineDelegate else { return }
        guard gained else {
            if engineDelegate.engineSendReport(report) { programFocus.told(false) }
            return
        }
        // A write of its own, never joined with a click, and timed from the moment it leaves:
        // a click waits out the program's activation window after that (`sendClickToProgram`).
        programFocus.gainedHanded(at: CACurrentMediaTime())
        let taken = engineDelegate.engineSendFocusGained(report) { [weak self] in
            self?.programFocus.gainedLeft(at: CACurrentMediaTime())
        }
        if taken { programFocus.told(true) } else { programFocus.gainedDropped() }
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        // The solid cursor needs the keyboard, and the keyboard needs a window: a pane that never
        // had the keyboard, or is off screen, draws the hollow cursor.
        renderer.setFocused(newWindow != nil && isFirstResponder)
        if newWindow == nil { stopKeyRepeat() }
    }

    // A terminal takes what is typed as is, except for corrections in an agent's prompt (`TypingAids`).
    var autocapitalizationType: UITextAutocapitalizationType { get { .none } set {} }
    var autocorrectionType: UITextAutocorrectionType { get { typingAids.autocorrection } set {} }
    var spellCheckingType: UITextSpellCheckingType { get { typingAids.spellChecking } set {} }
    var smartQuotesType: UITextSmartQuotesType { get { .no } set {} }
    var smartDashesType: UITextSmartDashesType { get { .no } set {} }
    var smartInsertDeleteType: UITextSmartInsertDeleteType { get { .no } set {} }
    var inlinePredictionType: UITextInlinePredictionType { get { .no } set {} }
    var keyboardType: UIKeyboardType { get { .default } set {} }
    var returnKeyType: UIReturnKeyType { get { .default } set {} }
    var enablesReturnKeyAutomatically: Bool { get { false } set {} }
    var isSecureTextEntry: Bool { get { false } set {} }
}

// MARK: Typing aids

extension GhosttyTerminalView {
    #if DEBUG
    /// `-typingAids prose|raw` (Debug builds, testing): every pane's aids, whatever its program.
    static let forcedTypingAids: TypingAids? = switch UserDefaults.standard.string(forKey: "typingAids") {
    case "prose": .prose
    case "raw": .raw
    default: nil
    }
    #endif

    /// The aids the pane's program asks for now (`TypingAids`). The keyboard reads the traits
    /// only as it comes up: from no keyboard, or from the host's quiet hold (`takeTypingAids`).
    /// So a change never reaches it while someone types, and the suggestion bar the aids bring
    /// never comes or goes under a pane on screen: it is 27 pt tall on an iPhone, and the
    /// keyboard snaps to its new height without animation, which would move the key bar and
    /// resize the panes on the computer. Until then the pane's want only holds corrections back
    /// (`replace(_:withText:)`).
    func wantTypingAids(_ aids: TypingAids) {
        #if DEBUG
        let aids = Self.forcedTypingAids ?? aids
        #endif
        wantedTypingAids = aids
        if !isFirstResponder { typingAids = aids }
    }

    /// The keyboard is coming up for this view: it gets the aids asked for. The host calls this
    /// before it shows the system keyboard after a quiet hold.
    func takeTypingAids() {
        typingAids = wantedTypingAids
    }

    /// This view is about to become first responder. From another pane's terminal, whose
    /// keyboard is up, or from compose's field, it keeps that keyboard's aids, so a switch between an agent and a shell
    /// neither moves the keyboard nor resizes a pane; otherwise the keyboard comes up and reads
    /// this pane's own.
    private func typingAidsAsKeyboardArrives() {
        if let other = window.flatMap(Self.keyboardHolder(in:)), other !== self, other.inputView == nil {
            typingAids = other.typingAids
        } else if composeOpen || UIResponder.rexCurrentFirstResponder() is ComposeField {
            // Compose's field, a plain text field with its suggestion bar, has the keyboard or
            // takes it next: the terminal brings up that keyboard, so it never changes height.
            typingAids = .prose
        } else {
            takeTypingAids()
        }
    }

    /// The terminal in `view` that has the keyboard. Asked only as a terminal takes the keyboard.
    private static func keyboardHolder(in view: UIView) -> GhosttyTerminalView? {
        if let terminal = view as? GhosttyTerminalView, terminal.isFirstResponder { return terminal }
        for sub in view.subviews {
            if let found = keyboardHolder(in: sub) { return found }
        }
        return nil
    }
}

// MARK: System keyboard

extension GhosttyTerminalView {
    /// True while the shadow document has text. Delete still arrives when it is
    /// empty, and then sends one Backspace.
    var hasText: Bool { !inputState.document.isEmpty }

    /// Text from the system keyboard, an input method's commit, dictation, or a hardware key
    /// that went through the text system.
    ///
    /// One plain key (`GhosttyPlainInsertion`) is sent before the keyboard is told that the
    /// text changed; anything else after, as every other edit of the shadow document is.
    func insertText(_ text: String) {
        guard !covered else { return }
        if takeCommandKey(text) { return }
        if text == "\n" {
            // Return ends the line: nothing on it is edited any more.
            resetInputDocument()
            return sendKeyboardText(text)
        }
        let before = GhosttyPlainInsertion(before: inputState.document)
        inputDelegate?.selectionWillChange(self)
        inputDelegate?.textWillChange(self)
        let edit = inputState.document.insert(text)
        let plain = before.holds(text, edit: edit, after: inputState.document, dictation: isDictating)
        if plain { sendKeyboardText(text) }
        inputDelegate?.textDidChange(self)
        inputDelegate?.selectionDidChange(self)
        if plain { return }
        // The shadow only needs the line being typed.
        if inputState.document.length > GhosttyPlainInsertion.longestLine { resetInputDocument() }
        guard edit.move == 0, edit.backspaces == 0, edit.text == text else {
            // The keyboard put the text somewhere other than the program's cursor (a caret it
            // moved, a selection it replaced): the program's line is edited to match.
            inputState.pending = nil
            _ = takeOneShotModifiers()
            return sendEdit(edit)
        }
        sendKeyboardText(text)
    }

    /// Dictation is putting text in: its own call, or the keyboard is in its dictation mode.
    var isDictating: Bool {
        inputState.dictating || (inputState.layoutLanguage ?? modeLanguage) == "dictation"
    }

    /// The language of the keyboard's input mode, read once per mode (`GhosttyInputState.modeLanguage`).
    private var modeLanguage: String? {
        if let known = inputState.modeLanguage { return known }
        let language = textInputMode?.primaryLanguage
        inputState.modeLanguage = .some(language)
        return language
    }

    /// Sends text typed at the program's cursor as keys: the hardware key that typed it if one
    /// is waiting, with the key bar's one-shot ctrl and alt.
    private func sendKeyboardText(_ text: String) {
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
