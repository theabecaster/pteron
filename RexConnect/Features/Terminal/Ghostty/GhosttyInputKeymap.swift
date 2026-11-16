import UIKit
import GhosttyVt

/// Turns what iOS reports (hardware key presses, text from the system keyboard) into the key
/// events libghostty-vt's encoder takes. Pure: no view, no terminal.
enum GhosttyInputKeymap {
    // MARK: Physical keys

    /// A key that types a character on a US layout.
    private struct Printable {
        let usage: Int
        let key: GhosttyKey
        let plain: Unicode.Scalar
        let shifted: Unicode.Scalar
    }

    private static let printables: [Printable] = {
        var out: [Printable] = []
        for (i, c) in "abcdefghijklmnopqrstuvwxyz".unicodeScalars.enumerated() {
            let upper = Unicode.Scalar(c.value - 0x20)!
            out.append(Printable(usage: 4 + i, key: GhosttyKey(rawValue: GHOSTTY_KEY_A.rawValue + UInt32(i)), plain: c, shifted: upper))
        }
        // HID order is 1…9, 0; the enum's is 0…9.
        let digits = Array("1234567890".unicodeScalars), symbols = Array("!@#$%^&*()".unicodeScalars)
        for i in 0..<10 {
            let n = UInt32((i + 1) % 10)
            out.append(Printable(usage: 30 + i, key: GhosttyKey(rawValue: GHOSTTY_KEY_DIGIT_0.rawValue + n), plain: digits[i], shifted: symbols[i]))
        }
        let punctuation: [(Int, GhosttyKey, Unicode.Scalar, Unicode.Scalar)] = [
            (45, GHOSTTY_KEY_MINUS, "-", "_"), (46, GHOSTTY_KEY_EQUAL, "=", "+"),
            (47, GHOSTTY_KEY_BRACKET_LEFT, "[", "{"), (48, GHOSTTY_KEY_BRACKET_RIGHT, "]", "}"),
            (49, GHOSTTY_KEY_BACKSLASH, "\\", "|"), (51, GHOSTTY_KEY_SEMICOLON, ";", ":"),
            (52, GHOSTTY_KEY_QUOTE, "'", "\""), (53, GHOSTTY_KEY_BACKQUOTE, "`", "~"),
            (54, GHOSTTY_KEY_COMMA, ",", "<"), (55, GHOSTTY_KEY_PERIOD, ".", ">"),
            (56, GHOSTTY_KEY_SLASH, "/", "?"),
        ]
        for (usage, key, plain, shifted) in punctuation {
            out.append(Printable(usage: usage, key: key, plain: plain, shifted: shifted))
        }
        return out
    }()

    private static let printableByUsage = Dictionary(uniqueKeysWithValues: printables.map { ($0.usage, $0) })

    /// Character → the key that types it on a US layout, and that key's unshifted character.
    private static let printableByScalar: [Unicode.Scalar: Printable] = {
        var out: [Unicode.Scalar: Printable] = [:]
        for p in printables {
            out[p.plain] = p
            out[p.shifted] = p
        }
        return out
    }()

    /// Keys that type through the text system but have no US character of their own.
    private static let otherTextKeys: [Int: GhosttyKey] = [
        50: GHOSTTY_KEY_BACKSLASH,  // non-US # and ~ (W3C code "Backslash")
        100: GHOSTTY_KEY_INTL_BACKSLASH, 135: GHOSTTY_KEY_INTL_RO, 137: GHOSTTY_KEY_INTL_YEN,
    ]

    private static let enter = 40, backspace = 42, space = 44

    /// Keys that never type text.
    private static let functionKeys: [Int: GhosttyKey] = {
        var t: [Int: GhosttyKey] = [
            41: GHOSTTY_KEY_ESCAPE, 43: GHOSTTY_KEY_TAB,
            70: GHOSTTY_KEY_PRINT_SCREEN, 71: GHOSTTY_KEY_SCROLL_LOCK, 72: GHOSTTY_KEY_PAUSE,
            73: GHOSTTY_KEY_INSERT, 74: GHOSTTY_KEY_HOME, 75: GHOSTTY_KEY_PAGE_UP, 76: GHOSTTY_KEY_DELETE,
            77: GHOSTTY_KEY_END, 78: GHOSTTY_KEY_PAGE_DOWN, 79: GHOSTTY_KEY_ARROW_RIGHT,
            80: GHOSTTY_KEY_ARROW_LEFT, 81: GHOSTTY_KEY_ARROW_DOWN, 82: GHOSTTY_KEY_ARROW_UP,
            83: GHOSTTY_KEY_NUM_LOCK, 101: GHOSTTY_KEY_CONTEXT_MENU, 117: GHOSTTY_KEY_HELP,
        ]
        for i in 0..<12 { t[58 + i] = GhosttyKey(rawValue: GHOSTTY_KEY_F1.rawValue + UInt32(i)) }
        for i in 0..<12 { t[104 + i] = GhosttyKey(rawValue: GHOSTTY_KEY_F13.rawValue + UInt32(i)) }
        return t
    }()

    /// The numeric keypad. Apple keyboards have no Num Lock: these always type their character.
    private static let keypadKeys: [Int: GhosttyKey] = {
        var t: [Int: GhosttyKey] = [
            84: GHOSTTY_KEY_NUMPAD_DIVIDE, 85: GHOSTTY_KEY_NUMPAD_MULTIPLY, 86: GHOSTTY_KEY_NUMPAD_SUBTRACT,
            87: GHOSTTY_KEY_NUMPAD_ADD, 88: GHOSTTY_KEY_NUMPAD_ENTER, 98: GHOSTTY_KEY_NUMPAD_0,
            99: GHOSTTY_KEY_NUMPAD_DECIMAL, 103: GHOSTTY_KEY_NUMPAD_EQUAL, 133: GHOSTTY_KEY_NUMPAD_COMMA,
        ]
        for i in 0..<9 { t[89 + i] = GhosttyKey(rawValue: GHOSTTY_KEY_NUMPAD_1.rawValue + UInt32(i)) }
        return t
    }()

    private static let modifierKeys: [Int: GhosttyKey] = [
        57: GHOSTTY_KEY_CAPS_LOCK,
        224: GHOSTTY_KEY_CONTROL_LEFT, 225: GHOSTTY_KEY_SHIFT_LEFT, 226: GHOSTTY_KEY_ALT_LEFT, 227: GHOSTTY_KEY_META_LEFT,
        228: GHOSTTY_KEY_CONTROL_RIGHT, 229: GHOSTTY_KEY_SHIFT_RIGHT, 230: GHOSTTY_KEY_ALT_RIGHT, 231: GHOSTTY_KEY_META_RIGHT,
    ]

    /// The physical key for a HID usage, or nil if libghostty-vt has no name for it.
    static func key(forUsage usage: Int) -> GhosttyKey? {
        if let p = printableByUsage[usage] { return p.key }
        switch usage {
        case enter: return GHOSTTY_KEY_ENTER
        case backspace: return GHOSTTY_KEY_BACKSPACE
        case space: return GHOSTTY_KEY_SPACE
        default: return functionKeys[usage] ?? keypadKeys[usage] ?? modifierKeys[usage] ?? otherTextKeys[usage]
        }
    }

    static func mods(_ f: UIKeyModifierFlags) -> GhosttyMods {
        var m: GhosttyMods = 0
        if f.contains(.shift) { m |= GhosttyInputKey.shift }
        if f.contains(.control) { m |= GhosttyInputKey.ctrl }
        // Option is Alt (Meta), as on the SwiftTerm engine.
        if f.contains(.alternate) { m |= GhosttyInputKey.alt }
        if f.contains(.command) { m |= GhosttyInputKey.superKey }
        if f.contains(.alphaShift) { m |= GhosttyInputKey.capsLock }
        return m
    }

    // MARK: Hardware presses

    /// Where a hardware key press goes.
    enum Route: Equatable {
        /// Not ours: Command shortcuts and keys we have no name for. The app and the system get it.
        case system
        /// A modifier key by itself. Encoded (only the Kitty protocol reports it) and still given to the system.
        case modifier(GhosttyInputKey)
        /// Encoded and sent now: function keys, the keypad, and any key held with Control or Option.
        case encode(GhosttyInputKey)
        /// A key that types. It goes to the text system, so layouts, dead keys and input methods
        /// work, and comes back through `insertText` or `deleteBackward`, where this event gives
        /// the text its physical key and modifiers.
        case textInput(GhosttyInputKey)
    }

    /// Routes a hardware key press. The arguments are `UIKey`'s properties (a `UIKey` can't be
    /// made in a test).
    /// What Option does to a key that types.
    enum OptionRole: Equatable {
        /// Alt (Meta): the program gets Alt and the key, as with "Option as Alt" on a Mac.
        case alt
        /// Part of the layout: the key types what the layout says, through the text system, so
        /// dead keys compose. The program sees the character and no Alt.
        case layout
    }

    /// Decides what Option (held without Control or Command) does to a key that types.
    ///
    /// Shells use Alt+letter and Alt+punctuation as commands (Alt+B, Alt+F, Alt+.), and a US
    /// layout puts characters nobody types into a terminal on the same keys (∫, ƒ, ≥). German,
    /// French and Spanish layouts need Option for `@ [ ] { } | \ ~`. In order:
    ///
    /// 1. Option makes a printable ASCII character other than the key's own: the layout's
    ///    character (German Option+L is `@`, Spanish Option+2 is `@`, British Option+3 is `#`).
    /// 2. An English layout: Alt, whatever else the key would type (å, ≥) and for its dead keys
    ///    (Option+E, Option+N), which have no use in a terminal there.
    /// 3. Another layout, on a key whose own character is an ASCII letter or digit: a dead key
    ///    composes (German and French Option+N, then Space, is `~`); any other character
    ///    (German Option+A, å) is Alt.
    /// 4. Another layout, on any other key (punctuation, ñ, ç): the layout's character or dead
    ///    key (Spanish Option+Ñ is `~`, Option+º is `\`), and Alt only where Option changes nothing.
    ///
    /// `characters` and `charactersIgnoringModifiers` are `UIKey`'s; `layoutLanguage` is the
    /// keyboard's language (`UITextInputMode.primaryLanguage`), English when unknown.
    static func optionRole(characters: String, charactersIgnoringModifiers: String, layoutLanguage: String?) -> OptionRole {
        let typed = printable(characters), own = printable(charactersIgnoringModifiers)
        if typed.unicodeScalars.count == 1, let s = typed.unicodeScalars.first, (0x21...0x7e).contains(s.value),
           typed.lowercased() != own.lowercased() { return .layout }
        let language = (layoutLanguage ?? "en").lowercased()
        if language == "en" || language.hasPrefix("en-") || language.hasPrefix("en_") { return .alt }
        // A dead key reports no character.
        let dead = typed.isEmpty
        if own.unicodeScalars.count == 1, let s = own.unicodeScalars.first, s.isASCII, s.properties.isAlphabetic || (0x30...0x39).contains(s.value) {
            return dead ? .layout : .alt
        }
        return dead || typed != own ? .layout : .alt
    }

    static func route(usage: Int, flags: UIKeyModifierFlags, characters: String, charactersIgnoringModifiers: String,
                      layoutLanguage: String? = nil) -> Route {
        var m = mods(flags)
        if let key = modifierKeys[usage] { return .modifier(GhosttyInputKey(key, mods: m)) }
        // Command shortcuts belong to the app (key commands) and the system.
        if flags.contains(.command) { return .system }
        if let key = functionKeys[usage] { return .encode(GhosttyInputKey(key, mods: m)) }
        if let key = keypadKeys[usage] {
            var e = GhosttyInputKey(key, mods: m, text: usage == 88 ? "" : printable(characters))
            if flags.contains(.shift), !e.text.isEmpty { e.consumedMods = GhosttyInputKey.shift }
            return .encode(e)
        }

        var direct = flags.contains(.control) || flags.contains(.alternate)
        var e: GhosttyInputKey
        switch usage {
        case enter: e = GhosttyInputKey(GHOSTTY_KEY_ENTER, mods: m)
        case backspace: e = GhosttyInputKey(GHOSTTY_KEY_BACKSPACE, mods: m)
        default:
            let p = printableByUsage[usage]
            guard let key = usage == space ? GHOSTTY_KEY_SPACE : p?.key ?? otherTextKeys[usage] else { return .system }
            // Option alone may belong to the layout (`optionRole`). Then the key types like any
            // other, and the program sees no Alt. Space is always Alt+Space, never a no-break space.
            if flags.contains(.alternate), !flags.contains(.control), usage != space,
               optionRole(characters: characters, charactersIgnoringModifiers: charactersIgnoringModifiers,
                          layoutLanguage: layoutLanguage) == .layout {
                direct = false
                m &= ~GhosttyInputKey.alt
            }
            // The text before Control or Option change it (key/event.h). With Control, `characters`
            // is a control character; with Option, a composed one (∫ for Option+B).
            var text = printable(direct ? charactersIgnoringModifiers : characters)
            let shift = flags.contains(.shift)
            if direct, shift, let p, text == String(p.plain) { text = String(p.shifted) }
            e = GhosttyInputKey(key, mods: m, text: text, unshifted: unshifted(of: text, shift: shift, usKey: p))
            if shift, !text.isEmpty { e.consumedMods = GhosttyInputKey.shift }
        }
        return direct ? .encode(e) : .textInput(e)
    }

    /// The character the key types without shift: from the text when that tells (a letter, or no
    /// shift held), else the US layout's.
    private static func unshifted(of text: String, shift: Bool, usKey: Printable?) -> UInt32 {
        guard text.unicodeScalars.count == 1, let s = text.unicodeScalars.first else { return usKey?.plain.value ?? 0 }
        let lower = text.lowercased().unicodeScalars
        if lower.count == 1, let l = lower.first, l != s { return l.value }
        if !shift { return s.value }
        return usKey?.plain.value ?? s.value
    }

    /// `text` if it is something a key types; empty for control characters, the private-use
    /// function key code points and UIKit's names for special keys ("UIKeyInputUpArrow").
    private static func printable(_ text: String) -> String {
        guard !text.isEmpty, !text.hasPrefix("UIKeyInput") else { return "" }
        for s in text.unicodeScalars where isControl(s) || (0xF700...0xF8FF).contains(s.value) { return "" }
        return text
    }

    private static func isControl(_ s: Unicode.Scalar) -> Bool { s.value < 0x20 || s.value == 0x7f }

    // MARK: Typed text

    /// The key events for text typed on the system keyboard (or `send(txt:)`), in order.
    ///
    /// Printable text becomes text events; one ASCII character also names its key, so the Kitty
    /// protocol can report it. Control characters are never passed as text (key/event.h): a
    /// newline is the Enter key, a tab the Tab key, and so on, so the encoder decides the bytes.
    static func typed(_ text: String) -> [GhosttyInputKey] {
        var out: [GhosttyInputKey] = []
        var run = ""
        func flush() {
            guard !run.isEmpty else { return }
            out.append(textKey(run))
            run = ""
        }
        // By character, so a letter and its combining marks, or an emoji sequence, stay together.
        for character in text {
            let scalars = character.unicodeScalars
            if character == "\r\n" {  // one Character in Swift, and one Enter
                flush()
                out.append(GhosttyInputKey(GHOSTTY_KEY_ENTER))
            } else if scalars.count == 1, let s = scalars.first, isControl(s) {
                flush()
                if let key = controlKey(s) { out.append(key) }
            } else if scalars.contains(where: { isControl($0) || (0xF700...0xF8FF).contains($0.value) }) {
                continue  // not text a key types
            } else if scalars.count == 1, character.isASCII {
                // One event per ASCII character, so each can name its key.
                flush()
                out.append(textKey(String(character)))
            } else {
                run.append(character)
            }
        }
        flush()
        return out
    }

    private static func textKey(_ text: String) -> GhosttyInputKey {
        if text == " " { return GhosttyInputKey(GHOSTTY_KEY_SPACE, text: text, unshifted: 0x20) }
        guard text.unicodeScalars.count == 1, let s = text.unicodeScalars.first else {
            return GhosttyInputKey(GHOSTTY_KEY_UNIDENTIFIED, text: text)
        }
        if let p = printableByScalar[s] { return GhosttyInputKey(p.key, text: text, unshifted: p.plain.value) }
        // No US key types it (é, я): still one character, so it can carry ctrl or alt.
        let lower = text.lowercased().unicodeScalars
        return GhosttyInputKey(GHOSTTY_KEY_UNIDENTIFIED, text: text, unshifted: lower.count == 1 ? lower.first!.value : s.value)
    }

    /// The key press a typed control character stands for.
    private static func controlKey(_ s: Unicode.Scalar) -> GhosttyInputKey? {
        switch s.value {
        case 0x0a, 0x0d: return GhosttyInputKey(GHOSTTY_KEY_ENTER)
        case 0x09: return GhosttyInputKey(GHOSTTY_KEY_TAB)
        case 0x1b: return GhosttyInputKey(GHOSTTY_KEY_ESCAPE)
        case 0x7f: return GhosttyInputKey(GHOSTTY_KEY_BACKSPACE)
        case 0x00: return GhosttyInputKey(GHOSTTY_KEY_SPACE, mods: GhosttyInputKey.ctrl, text: " ", unshifted: 0x20)
        case 0x01...0x1a:
            // Control + letter.
            guard let letter = Unicode.Scalar(s.value + 0x60), let p = printableByScalar[letter] else { return nil }
            return GhosttyInputKey(p.key, mods: GhosttyInputKey.ctrl, text: String(letter), unshifted: letter.value)
        case 0x1c...0x1f:
            // Control + \ ] ^ _
            guard let symbol = Unicode.Scalar(s.value + 0x40), let p = printableByScalar[symbol] else { return nil }
            return GhosttyInputKey(p.key, mods: GhosttyInputKey.ctrl, text: String(symbol), unshifted: p.plain.value)
        default: return nil
        }
    }
}
