import Foundation
import GhosttyVt

/// One key event as libghostty-vt's key encoder takes it (`ghostty/vt/key/event.h`).
struct GhosttyInputKey: Equatable, Sendable {
    enum Action: Sendable { case press, release, repeatPress }

    /// The physical key, a `GhosttyKey` raw value. `GhosttyInputKey.unidentified` for pure text.
    var key: UInt32
    /// `GHOSTTY_MODS_*` bits.
    var mods: GhosttyMods = 0
    /// Modifiers the layout used up to make `text` (shift for "A" or "!").
    var consumedMods: GhosttyMods = 0
    /// What the key types before ctrl or alt change it. Never a C0 control character.
    var text = ""
    /// The key's character without shift, or 0.
    var unshifted: UInt32 = 0
    var action = Action.press
    /// True while an input method composes (marked text): only modifier keys encode.
    var composing = false

    static let unidentified = GHOSTTY_KEY_UNIDENTIFIED.rawValue
    static let shift = GhosttyMods(GHOSTTY_MODS_SHIFT)
    static let ctrl = GhosttyMods(GHOSTTY_MODS_CTRL)
    static let alt = GhosttyMods(GHOSTTY_MODS_ALT)
    static let superKey = GhosttyMods(GHOSTTY_MODS_SUPER)
    static let capsLock = GhosttyMods(GHOSTTY_MODS_CAPS_LOCK)
    /// The modifiers that change what a key means (not lock keys, not left/right).
    static let bindingMods = shift | ctrl | alt | superKey

    init(_ key: GhosttyKey, mods: GhosttyMods = 0, text: String = "", unshifted: UInt32 = 0) {
        self.key = key.rawValue
        self.mods = mods
        self.text = text
        self.unshifted = unshifted
    }
}

/// The terminal modes that shape input, copied from the terminal so the main thread never waits
/// for the terminal lock to type.
///
/// Why a copy: upstream says to sync an encoder "after you write to the terminal, or right before
/// you encode" (guides/input.md, "Following the terminal's modes"). Syncing right before encoding
/// needs `termLock` on the main thread, and the feed queue holds that lock for a whole slice of
/// output (up to `GhosttyCore.sliceSize` bytes), then takes it again at once; `os_unfair_lock`
/// is not fair, so a key press during a burst could wait for many slices. So the feed queue
/// syncs after each write instead (`sync(from:)`, called by GhosttyCore with `termLock` held),
/// and typing takes only this object's own lock, which is held for a few loads and stores.
///
/// A key encoder is its own handle, independent of the terminal (conventions.md, "Threads"), so
/// encoding outside `termLock` is allowed as long as the encoder itself is never used from two
/// threads at once. `lock` sees to that.
///
/// `@unchecked Sendable`: every property is guarded by `lock`.
final class GhosttyInputMirror: @unchecked Sendable {
    struct Modes: Equatable, Sendable {
        /// Mode 2004.
        var bracketedPaste = false
        /// Mode 1004.
        var focusEvents = false
        /// Mode 1 (DECCKM).
        var cursorKeyApplication = false
        /// Kitty keyboard flags of the active screen; 0 is the legacy encoding.
        var kittyFlags: UInt8 = 0
        var alternateScreen = false
    }

    private let lock = GhosttyLock()
    private var encoder: GhosttyKeyEncoder?
    private var event: GhosttyKeyEvent?
    private var current = Modes()

    init() {
        ghostty_key_encoder_new(nil, &encoder)
        ghostty_key_event_new(nil, &event)
        applyOptionAsAlt()
    }

    deinit {
        ghostty_key_event_free(event)
        ghostty_key_encoder_free(encoder)
    }

    /// Option is Alt, as `optionAsMetaKey = true` on the SwiftTerm engine. On the iOS slices the
    /// legacy Alt prefix ignores this option but the modifyOtherKeys path honors it
    /// (`input/key_encode.zig`), so it must be TRUE for Alt to behave one way.
    private func applyOptionAsAlt() {
        var alt = GHOSTTY_OPTION_AS_ALT_TRUE
        ghostty_key_encoder_set(encoder, GHOSTTY_KEY_ENCODER_OPT_MACOS_OPTION_AS_ALT, &alt)
    }

    /// Copies the terminal's modes. The caller holds the terminal lock (GhosttyCore, after every
    /// change to the terminal that can change a mode).
    func sync(from t: GhosttyTerminal) {
        func mode(_ n: UInt16) -> Bool {
            var m = GhosttyTerminalModeConfig(mode: ghostty_mode_new(n, false), value: false)
            return ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_MODE, &m) == GHOSTTY_SUCCESS && m.value
        }
        var next = Modes(bracketedPaste: mode(2004), focusEvents: mode(1004), cursorKeyApplication: mode(1))
        ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_KITTY_KEYBOARD_FLAGS, &next.kittyFlags)
        var screen = GHOSTTY_TERMINAL_SCREEN_PRIMARY
        ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &screen)
        next.alternateScreen = screen == GHOSTTY_TERMINAL_SCREEN_ALTERNATE

        lock.lock()
        // Replaces every encoder option: cursor and keypad application modes, backarrow mode,
        // keypad-with-numlock, alt-esc-prefix, modifyOtherKeys 2 and the Kitty flags. It also
        // resets option-as-alt, which is ours to set again (guides/input.md).
        ghostty_key_encoder_set_from_terminal(encoder, t)
        applyOptionAsAlt()
        current = next
        lock.unlock()
    }

    var modes: Modes {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    // MARK: Keys

    /// The bytes a key sends under the terminal's current modes. Empty when it sends nothing
    /// (a lone modifier, a release without the Kitty protocol, a key pressed while composing).
    func encode(_ key: GhosttyInputKey) -> [UInt8] {
        lock.lock()
        defer { lock.unlock() }
        let bytes = encodeLocked(key)
        if current.kittyFlags == 0, let alias = Self.legacyAlias(of: key, encoded: bytes) {
            return encodeLocked(alias)
        }
        return bytes
    }

    /// Legacy terminals have no Ctrl+I, Ctrl+M or Ctrl+[ of their own: they are Tab, Enter and
    /// Escape, and shells and editors rely on it (Ctrl+[ leaves insert mode in vi). Ghostty's
    /// legacy encoder follows "fixterms" and sends `CSI <char> ; 5 u` for exactly these three
    /// (`input/key_encode.zig`, `ctrlSeq`: "purposely NOT handled here"), which programs that
    /// never asked for an extended keyboard protocol print as text. The SwiftTerm engine sends
    /// 0x09, 0x0D and 0x1B. To keep that, in legacy mode only, such a press is encoded again as
    /// the key it stands for, so the bytes still come from the encoder. With the Kitty protocol
    /// on, or modifyOtherKeys 2 (which encodes them as `CSI 27 ; 5 ; <char> ~`), nothing changes.
    private static func legacyAlias(of key: GhosttyInputKey, encoded: [UInt8]) -> GhosttyInputKey? {
        guard key.mods & GhosttyInputKey.bindingMods == GhosttyInputKey.ctrl, key.action != .release else { return nil }
        let aliases: [(UInt32, GhosttyKey)] = [(0x69, GHOSTTY_KEY_TAB), (0x6d, GHOSTTY_KEY_ENTER), (0x5b, GHOSTTY_KEY_ESCAPE)]
        for (char, standsFor) in aliases where encoded == Array("\u{1b}[\(char);5u".utf8) {
            var alias = GhosttyInputKey(standsFor)
            alias.action = key.action
            return alias
        }
        return nil
    }

    private func encodeLocked(_ key: GhosttyInputKey) -> [UInt8] {
        guard let encoder, let event else { return [] }
        let action: GhosttyKeyAction
        switch key.action {
        case .press: action = GHOSTTY_KEY_ACTION_PRESS
        case .release: action = GHOSTTY_KEY_ACTION_RELEASE
        case .repeatPress: action = GHOSTTY_KEY_ACTION_REPEAT
        }
        ghostty_key_event_set_action(event, action)
        if ghostty_key_event_set_key(event, GhosttyKey(rawValue: key.key)) != GHOSTTY_SUCCESS {
            ghostty_key_event_set_key(event, GHOSTTY_KEY_UNIDENTIFIED)
        }
        ghostty_key_event_set_mods(event, key.mods)
        ghostty_key_event_set_consumed_mods(event, key.consumedMods)
        ghostty_key_event_set_composing(event, key.composing)
        ghostty_key_event_set_unshifted_codepoint(event, key.unshifted)

        var text = key.text
        return text.withUTF8 { utf8 -> [UInt8] in
            // The event borrows the text (key/event.h: "does not copy"): encode inside this
            // closure, then clear it.
            ghostty_key_event_set_utf8(event, GhosttyString(ptr: utf8.baseAddress, len: utf8.count))
            defer { ghostty_key_event_set_utf8(event, GhosttyString(ptr: nil, len: 0)) }
            var out = [UInt8](repeating: 0, count: 128)
            var n = 0
            var result = ghostty_key_encoder_encode(encoder, event, &out, out.count, &n)
            if result == GHOSTTY_OUT_OF_SPACE {
                // `n` is the size needed; what's in the buffer is to be discarded.
                out = [UInt8](repeating: 0, count: n)
                result = ghostty_key_encoder_encode(encoder, event, &out, out.count, &n)
            }
            guard result == GHOSTTY_SUCCESS, n > 0 else { return [] }
            out.removeSubrange(n...)
            return out
        }
    }

    // MARK: Paste

    /// The bytes a paste of `text` sends: wrapped in `ESC [ 200 ~ … ESC [ 201 ~` when the program
    /// asked for bracketed paste (mode 2004), newlines turned into carriage returns otherwise,
    /// unsafe control bytes replaced with spaces either way.
    ///
    /// This is `ghostty_paste_encode`, "the encoder ghostty_terminal_paste() uses for a text
    /// paste" (paste.h). `ghostty_terminal_paste` itself can't be used: it writes through the
    /// write-pty callback, and this client installs none, because that callback also carries the
    /// terminal's answers to queries, which the server's terminal already sends. The pieces it
    /// adds don't apply here: Kitty paste events need a clipboard-read callback (not installed),
    /// and its refusal of text that could run a command is for a confirmation dialog the app
    /// doesn't have. The SwiftTerm engine pastes such text too (`pasteText` retries a refused
    /// paste with `allowUnsafe`), so this pastes like `allow_unsafe = true`.
    func paste(_ text: String) -> [UInt8] {
        guard !text.isEmpty else { return [] }
        let bracketed = modes.bracketedPaste
        // The encoder changes its input in place.
        var data = text.utf8.map { CChar(bitPattern: $0) }
        var need = 0
        let probe = ghostty_paste_encode(&data, data.count, bracketed, nil, 0, &need)
        guard probe == GHOSTTY_OUT_OF_SPACE, need > 0 else { return [] }
        var out = [UInt8](repeating: 0, count: need)
        var written = 0
        guard ghostty_paste_encode(&data, data.count, bracketed, &out, out.count, &written) == GHOSTTY_SUCCESS else { return [] }
        out.removeSubrange(written...)
        return out
    }

    // MARK: Focus

    /// `CSI I` or `CSI O`, if the program asked for focus reports (mode 1004); empty otherwise.
    /// `ghostty_focus_encode` doesn't look at the terminal: "it's up to you to check the mode
    /// first" (guides/input.md).
    func focusReport(gained: Bool) -> [UInt8] {
        guard modes.focusEvents else { return [] }
        var out = [UInt8](repeating: 0, count: 8)
        var n = 0
        guard ghostty_focus_encode(gained ? GHOSTTY_FOCUS_GAINED : GHOSTTY_FOCUS_LOST, &out, out.count, &n) == GHOSTTY_SUCCESS else { return [] }
        out.removeSubrange(n...)
        return out
    }
}

extension GhosttyCore {
    /// Shows live output again if the view is scrolled into history. The library never does this
    /// by itself (paste.h: "The viewport is not scrolled; that is up to you, as for key input");
    /// Ghostty does it on every keystroke. Runs on the feed queue so typing doesn't wait for the
    /// terminal lock.
    func followOutput() {
        enqueue { [self] in
            let moved = withTerminal { t -> Bool in
                var following = true
                ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_VIEWPORT_ACTIVE, &following)
                if following { return false }
                var bottom = GhosttyTerminalScrollViewport()
                bottom.tag = GHOSTTY_TERMINAL_SCROLL_VIEWPORT_BOTTOM
                ghostty_terminal_scroll_viewport(t, bottom)
                return true
            } ?? false
            if moved { onDirty?() }
        }
    }
}
