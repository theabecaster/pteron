import UIKit
import RexKit

/// Converts hardware key presses to Rex's key spellings and back to terminal bytes.
enum KeyInput {
    /// A physical key: its W3C code, and what it is called in a binding on a US layout
    /// (a named key such as `enter`, or the unshifted character).
    struct Info {
        let code: String
        let name: String
        /// The character with shift, for keys that type one.
        let shifted: String?
    }

    private static let table: [Int: Info] = {
        var t: [Int: Info] = [:]
        let letters = Array("abcdefghijklmnopqrstuvwxyz")
        for (i, c) in letters.enumerated() {
            t[4 + i] = Info(code: "Key\(c.uppercased())", name: String(c), shifted: c.uppercased())
        }
        let digits = Array("1234567890"), shiftedDigits = Array("!@#$%^&*()")
        for i in 0..<10 {
            t[30 + i] = Info(code: "Digit\(digits[i])", name: String(digits[i]), shifted: String(shiftedDigits[i]))
        }
        let named: [(Int, String, String)] = [
            (40, "Enter", "enter"), (41, "Escape", "escape"), (42, "Backspace", "backspace"), (43, "Tab", "tab"),
            (44, "Space", "space"), (57, "CapsLock", "caps_lock"),
            (73, "Insert", "insert"), (74, "Home", "home"), (75, "PageUp", "pageup"), (76, "Delete", "delete"),
            (77, "End", "end"), (78, "PageDown", "pagedown"), (79, "ArrowRight", "right"), (80, "ArrowLeft", "left"),
            (81, "ArrowDown", "down"), (82, "ArrowUp", "up"), (88, "NumpadEnter", "enter"),
        ]
        for (u, code, name) in named { t[u] = Info(code: code, name: name, shifted: nil) }
        let punct: [(Int, String, String, String)] = [
            (45, "Minus", "-", "_"), (46, "Equal", "=", "+"), (47, "BracketLeft", "[", "{"), (48, "BracketRight", "]", "}"),
            (49, "Backslash", "\\", "|"), (51, "Semicolon", ";", ":"), (52, "Quote", "'", "\""), (53, "Backquote", "`", "~"),
            (54, "Comma", ",", "<"), (55, "Period", ".", ">"), (56, "Slash", "/", "?"), (100, "IntlBackslash", "§", "±"),
        ]
        for (u, code, c, s) in punct { t[u] = Info(code: code, name: c, shifted: s) }
        for i in 0..<12 { t[58 + i] = Info(code: "F\(i + 1)", name: "f\(i + 1)", shifted: nil) }
        for i in 0..<12 { t[104 + i] = Info(code: "F\(i + 13)", name: "f\(i + 13)", shifted: nil) }
        return t
    }()

    static func info(_ usage: UIKeyboardHIDUsage) -> Info? { table[usage.rawValue] }

    /// The US name of the key with this W3C code (`Slash` → `/`).
    static func name(forCode code: String) -> String? { table.values.first { $0.code == code }?.name }

    static func mods(_ f: UIKeyModifierFlags) -> KeyMods {
        var m: KeyMods = []
        if f.contains(.shift) { m.insert(.shift) }
        if f.contains(.control) { m.insert(.ctrl) }
        if f.contains(.alternate) { m.insert(.alt) }
        if f.contains(.command) { m.insert(.cmd) }
        return m
    }

    static func isModifierKey(_ u: UIKeyboardHIDUsage) -> Bool {
        (224...231).contains(u.rawValue)
    }

    /// What a hardware key press reports (`UIKey`'s properties; a `UIKey` can't be made in a test).
    struct Press {
        var usage: Int
        var flags: UIKeyModifierFlags
        /// What the key types with its modifiers.
        var characters: String
        var charactersIgnoringModifiers: String
    }

    /// The spellings a press can match: by what the key types (following the layout), then by position.
    @MainActor static func chords(for key: UIKey) -> [KeyChord] { chordTiers(for: key)[0] }

    @MainActor static func chordTiers(for key: UIKey) -> [[KeyChord]] {
        chordTiers(Press(usage: key.keyCode.rawValue, flags: key.modifierFlags, characters: key.characters,
                         charactersIgnoringModifiers: key.charactersIgnoringModifiers))
    }

    /// The spellings a press can match, in tiers: a later tier is tried only when no binding matches
    /// an earlier one, so it can never take a key from a binding that names it.
    /// 1. What the key types without modifiers (with shift held: the key's US name), and its position (`[Slash]`).
    /// 2. The character typed with shift, without the shift: on a Spanish or German keyboard `/` is
    ///    shift+7, so `cmd+/` arrives as shift+cmd+7. Like the Mac, a binding names the character.
    /// 3. The key's US name, when what it types can't be spelled in a binding at all (`ñ`, `ß`, `é`).
    ///    Never for a key that types an ASCII character: on AZERTY the key at US `a` types `q`, and
    ///    cmd+Q must not run cmd+A's binding.
    static func chordTiers(_ p: Press) -> [[KeyChord]] {
        let m = mods(p.flags)
        let info = table[p.usage]
        var first: [KeyChord] = []
        var typed = ""
        if let info, info.shifted == nil {
            first.append(KeyChord(mods: m, key: info.name))  // named key
        } else {
            // Bindings match unshifted keys: with shift held, use the key's own character.
            var c = p.charactersIgnoringModifiers.lowercased()
            typed = c
            // Option may still compose a character (∫ for alt+b); bind by the key's own letter then.
            let composed = m.contains(.alt) && !(c.unicodeScalars.first?.isASCII ?? false)
            if m.contains(.shift) || c.count != 1 || composed { c = info?.name ?? c }
            if !c.isEmpty { first.append(KeyChord(mods: m, key: c)) }
        }
        if let info { first.append(KeyChord(mods: m, key: "[\(info.code)]")) }
        var tiers = [first]
        guard let info, info.shifted != nil else { return tiers }

        // 2. A symbol that needs shift on this layout.
        if m.contains(.shift), !m.contains(.alt), isSymbol(p.characters) {
            let c = KeyChord(mods: m.subtracting(.shift), key: p.characters)
            if !first.contains(c) { tiers.append([c]) }
        }
        // 3. A key that types nothing a binding can name.
        if !m.contains(.shift), !m.contains(.alt), !(typed.unicodeScalars.first?.isASCII ?? false) {
            let c = KeyChord(mods: m, key: info.name)
            if !first.contains(c) { tiers.append([c]) }
        }
        return tiers
    }

    /// One printable ASCII character that is neither a letter nor a digit nor a space.
    private static func isSymbol(_ s: String) -> Bool {
        guard s.unicodeScalars.count == 1, let u = s.unicodeScalars.first, u.isASCII, u.value > 0x20, u.value < 0x7f else { return false }
        return !CharacterSet.alphanumerics.contains(u)
    }

    // MARK: Key commands

    /// The UIKeyCommand input for a chord, and whether it names a physical key.
    static func commandInput(_ c: KeyChord) -> String? {
        var k = c.key
        if c.isPhysical {
            let code = String(k.dropFirst().dropLast())
            guard let info = table.values.first(where: { $0.code == code }) else { return nil }
            k = info.name
        }
        switch k {
        case "enter": return "\r"
        case "tab": return "\t"
        case "backspace": return "\u{8}"
        case "escape": return UIKeyCommand.inputEscape
        case "space": return " "
        case "delete": return UIKeyCommand.inputDelete
        case "home": return UIKeyCommand.inputHome
        case "end": return UIKeyCommand.inputEnd
        case "pageup": return UIKeyCommand.inputPageUp
        case "pagedown": return UIKeyCommand.inputPageDown
        case "left": return UIKeyCommand.inputLeftArrow
        case "right": return UIKeyCommand.inputRightArrow
        case "up": return UIKeyCommand.inputUpArrow
        case "down": return UIKeyCommand.inputDownArrow
        case "insert", "caps_lock": return nil
        default:
            if k.count > 1, k.hasPrefix("f"), let n = Int(k.dropFirst()), (1...12).contains(n) {
                let fs = [UIKeyCommand.f1, UIKeyCommand.f2, UIKeyCommand.f3, UIKeyCommand.f4, UIKeyCommand.f5, UIKeyCommand.f6,
                          UIKeyCommand.f7, UIKeyCommand.f8, UIKeyCommand.f9, UIKeyCommand.f10, UIKeyCommand.f11, UIKeyCommand.f12]
                return fs[n - 1]
            }
            return k.count == 1 ? k : nil
        }
    }

    static func flags(_ m: KeyMods) -> UIKeyModifierFlags {
        var f: UIKeyModifierFlags = []
        if m.contains(.shift) { f.insert(.shift) }
        if m.contains(.ctrl) { f.insert(.control) }
        if m.contains(.alt) { f.insert(.alternate) }
        if m.contains(.cmd) { f.insert(.command) }
        return f
    }

    // MARK: Bytes

    /// The bytes a terminal key sends (`pane.send_key`), xterm-style.
    static func bytes(_ c: KeyChord) -> [UInt8]? {
        let esc: UInt8 = 0x1b
        var k = c.key
        if c.isPhysical {
            let code = String(k.dropFirst().dropLast())
            guard let info = table.values.first(where: { $0.code == code }) else { return nil }
            k = info.name
        }
        let m = c.mods
        // CSI modifier parameter for cursor and function keys.
        let param = 1 + (m.contains(.shift) ? 1 : 0) + (m.contains(.alt) ? 2 : 0) + (m.contains(.ctrl) ? 4 : 0)
        func csi(_ final: String) -> [UInt8] {
            param > 1 ? Array("\u{1b}[1;\(param)\(final)".utf8) : Array("\u{1b}[\(final)".utf8)
        }
        func tilde(_ n: Int) -> [UInt8] {
            param > 1 ? Array("\u{1b}[\(n);\(param)~".utf8) : Array("\u{1b}[\(n)~".utf8)
        }
        var out: [UInt8]
        var altPrefix = m.contains(.alt)
        switch k {
        case "enter": out = [13]
        case "tab": out = m.contains(.shift) ? Array("\u{1b}[Z".utf8) : [9]
        case "backspace": out = m.contains(.ctrl) ? [8] : [0x7f]
        case "escape": out = [esc]
        case "space": out = m.contains(.ctrl) ? [0] : [32]
        case "up": out = csi("A"); altPrefix = false
        case "down": out = csi("B"); altPrefix = false
        case "right": out = csi("C"); altPrefix = false
        case "left": out = csi("D"); altPrefix = false
        case "home": out = csi("H"); altPrefix = false
        case "end": out = csi("F"); altPrefix = false
        case "insert": out = tilde(2); altPrefix = false
        case "delete": out = tilde(3); altPrefix = false
        case "pageup": out = tilde(5); altPrefix = false
        case "pagedown": out = tilde(6); altPrefix = false
        case "f1", "f2", "f3", "f4":
            let f = ["f1": "P", "f2": "Q", "f3": "R", "f4": "S"][k]!
            out = param > 1 ? Array("\u{1b}[1;\(param)\(f)".utf8) : Array("\u{1b}O\(f)".utf8)
            altPrefix = false
        default:
            if k.hasPrefix("f"), let n = Int(k.dropFirst()), (5...12).contains(n) {
                let codes = [5: 15, 6: 17, 7: 18, 8: 19, 9: 20, 10: 21, 11: 23, 12: 24]
                out = tilde(codes[n]!)
                altPrefix = false
                break
            }
            guard k.count == 1 else { return nil }
            var ch = k
            if m.contains(.shift) {
                ch = table.values.first(where: { $0.name == k })?.shifted ?? k.uppercased()
            }
            if m.contains(.ctrl), let a = ch.unicodeScalars.first, ch.unicodeScalars.count == 1 {
                let v = a.value
                switch a {
                case "a"..."z": out = [UInt8(v - 96)]
                case "A"..."Z": out = [UInt8(v - 64)]
                case "@", " ", "2": out = [0]
                case "[", "3": out = [27]
                case "\\", "4": out = [28]
                case "]", "5": out = [29]
                case "^", "6": out = [30]
                case "_", "-", "7", "/": out = [31]
                case "8", "?": out = [0x7f]
                default: out = Array(ch.utf8)
                }
            } else {
                out = Array(ch.utf8)
            }
        }
        return altPrefix ? [esc] + out : out
    }

    // MARK: client.key

    /// A key event for `client.key` (keys bound to a Lua function).
    @MainActor static func clientKeyEvent(_ key: UIKey, action: String = "press") -> JSONObject {
        let f = key.modifierFlags
        var mods: [String] = []
        if f.contains(.shift) { mods.append("shift") }
        if f.contains(.control) { mods.append("ctrl") }
        if f.contains(.alternate) { mods.append("alt") }
        if f.contains(.command) { mods.append("super") }
        if f.contains(.alphaShift) { mods.append("caps_lock") }
        let info = info(key.keyCode)
        let unshifted = info.flatMap { $0.shifted == nil ? nil : $0.name.unicodeScalars.first?.value } ?? 0
        let text = f.contains(.command) || f.contains(.control) ? "" : key.characters
        return [
            "key": info.map { snake($0.code) } ?? "unidentified",
            "mods": mods.joined(separator: "+"),
            "consumed_mods": f.contains(.shift) && !text.isEmpty ? "shift" : "",
            "text": text,
            "unshifted_codepoint": Int(unshifted),
            "composing": false,
            "action": action,
        ]
    }

    /// `KeyA` → `key_a`, `ArrowLeft` → `arrow_left`, `Digit1` → `digit_1`, `F5` → `f5`.
    static func snake(_ code: String) -> String {
        var out = ""
        var prev: Character?
        for ch in code {
            if let p = prev, p.isLowercase, ch.isUppercase || ch.isNumber { out.append("_") }
            out.append(contentsOf: ch.lowercased())
            prev = ch
        }
        return out
    }
}
