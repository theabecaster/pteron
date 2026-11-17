import QuartzCore
import RexKit
import XCTest
@testable import RexDuo

/// Helpers shared by the Ghostty input tests.
@MainActor
enum GhosttyInputProbe {
    static let esc = "\u{1b}"

    // Sequences a program sends to change how keys are encoded.
    static let cursorKeys = "\u{1b}[?1h"
    static let backarrow = "\u{1b}[?67h"
    static let kittyDisambiguate = "\u{1b}[>1u"
    static let kittyAll = "\u{1b}[>31u"
    static let modifyOtherKeys2 = "\u{1b}[>4;2m"
    /// Application keypad. Ghostty ignores DECKPAM while mode 1035 is on (its default), as xterm does.
    static let keypadApplication = "\u{1b}[?1035l\u{1b}="
    static let bracketedPaste = "\u{1b}[?2004h"
    static let focusEvents = "\u{1b}[?1004h"

    /// A terminal that has seen `setup`.
    nonisolated static func core(_ setup: String = "") -> GhosttyCore {
        let core = GhosttyCore(cols: 80, rows: 24)
        core.feed(Array(setup.utf8))
        core.sync()
        return core
    }

    /// The HID usage of a key by its name in a `KeyChord` ("a", "enter", "f5") or its W3C code ("[BracketLeft]").
    static func usage(_ key: String) -> Int? {
        let code = key.hasPrefix("[") && key.count > 2 ? String(key.dropFirst().dropLast()) : nil
        for u in 0..<232 {
            guard let raw = UIKeyboardHIDUsage(rawValue: u), let info = KeyInput.info(raw) else { continue }
            if let code { if info.code == code { return u } } else if info.name == key { return u }
        }
        return nil
    }

    /// A `KeyChord` spelling as the `UIKey` properties a US keyboard reports for it.
    static func press(_ spelling: String) -> (usage: Int, flags: UIKeyModifierFlags, characters: String, ignoringModifiers: String)? {
        guard let chord = KeyChord(spelling: spelling), let u = usage(chord.key),
              let raw = UIKeyboardHIDUsage(rawValue: u), let info = KeyInput.info(raw) else { return nil }
        var characters = "UIKeyInputUpArrow", ignoringModifiers = "UIKeyInputUpArrow"
        if let shifted = info.shifted {
            ignoringModifiers = chord.mods.contains(.shift) ? shifted : info.name
            // What iOS reports: a control character with Control, a composed one with Option.
            characters = chord.mods.contains(.ctrl) ? "\u{3}" : chord.mods.contains(.alt) ? "∫" : ignoringModifiers
        } else if info.name == "space" {
            characters = " "
            ignoringModifiers = " "
        } else if info.name == "enter" {
            characters = "\r"
            ignoringModifiers = "\r"
        }
        return (u, KeyInput.flags(chord.mods), characters, ignoringModifiers)
    }

    /// Routes a hardware press spelled as a `KeyChord`.
    static func route(_ spelling: String) -> GhosttyInputKeymap.Route? {
        guard let p = press(spelling) else { return nil }
        return GhosttyInputKeymap.route(usage: p.usage, flags: p.flags, characters: p.characters,
                                        charactersIgnoringModifiers: p.ignoringModifiers)
    }

    /// The key event a hardware press makes, however it is routed.
    static func key(_ spelling: String) -> GhosttyInputKey? {
        switch route(spelling) {
        case .encode(let k)?, .textInput(let k)?, .modifier(let k)?: return k
        case .system?, nil: return nil
        }
    }

    static func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

    /// Bytes as readable text, for failure messages.
    static func show(_ b: [UInt8]) -> String {
        b.map { $0 == 0x1b ? "ESC" : ($0 < 0x20 || $0 >= 0x7f ? String(format: "<%02x>", $0) : String(UnicodeScalar($0))) }.joined()
    }
}

/// What libghostty-vt's key encoder sends for hardware keys, by terminal mode.
@MainActor
final class GhosttyInputKeyTests: XCTestCase {
    private typealias P = GhosttyInputProbe

    private func expect(_ core: GhosttyCore, _ table: [(String, String)], _ mode: String, file: StaticString = #filePath, line: UInt = #line) {
        for (spelling, want) in table {
            guard let key = P.key(spelling) else {
                XCTFail("\(mode) \(spelling): no key event", file: file, line: line)
                continue
            }
            let got = core.input.encode(key)
            XCTAssertEqual(got, P.bytes(want), "\(mode) \(spelling): sent \(P.show(got)), want \(P.show(P.bytes(want)))", file: file, line: line)
        }
    }

    // MARK: Legacy encoding against the app's own encoder

    private static let keys: [String] = Array("abcdefghijklmnopqrstuvwxyz1234567890").map(String.init)
        + ["-", "=", "[BracketLeft]", "]", "\\", ";", "'", "`", ",", ".", "/",
           "enter", "tab", "escape", "backspace", "space", "up", "down", "left", "right", "home", "end",
           "insert", "delete", "pageup", "pagedown",
           "f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9", "f10", "f11", "f12"]

    /// Where Ghostty's legacy encoding is not `KeyInput.bytes` (the xterm-style bytes the app sends
    /// for key bindings, checked in `KeyEncodingTests`), with what
    /// Ghostty sends. All of it is Ghostty's own choice (`input/key_encode.zig`,
    /// `input/function_keys.zig`), the same bytes the Rex Mac app sends:
    /// - Enter, Tab and Escape with a modifier use xterm's `CSI 27 ; mod ; char ~`, so a program can
    ///   tell Shift+Enter from Enter.
    /// - F3 with a modifier is `CSI 13 ; mod ~`: `CSI 1 ; mod R` would read as a cursor position report.
    /// - Control with a key that has no control character follows "fixterms" (`CSI char ; mod u`).
    private static let ghosttyOnly: [String: String] = [
        "shift+enter": "\u{1b}[27;2;13~", "shift+escape": "\u{1b}[27;2;27~", "shift+f3": "\u{1b}[13;2~",
        "ctrl+-": "\u{1b}[45;5u", "ctrl+=": "\u{1b}[61;5u", "ctrl+;": "\u{1b}[59;5u", "ctrl+'": "\u{1b}[39;5u",
        "ctrl+`": "\u{1b}[96;5u", "ctrl+,": "\u{1b}[44;5u", "ctrl+.": "\u{1b}[46;5u",
        "ctrl+enter": "\u{1b}[27;5;13~", "ctrl+tab": "\u{1b}[27;5;9~", "ctrl+escape": "\u{1b}[27;5;27~",
        "ctrl+f3": "\u{1b}[13;5~", "alt+f3": "\u{1b}[13;3~",
        "shift+alt+enter": "\u{1b}[27;4;13~", "shift+alt+tab": "\u{1b}[27;4;9~", "shift+alt+escape": "\u{1b}[27;4;27~",
        "shift+alt+f3": "\u{1b}[13;4~",
        "ctrl+alt+i": "\u{1b}[105;7u", "ctrl+alt+m": "\u{1b}[109;7u", "ctrl+alt+[BracketLeft]": "\u{1b}[91;7u",
        "ctrl+alt+-": "\u{1b}[45;7u", "ctrl+alt+=": "\u{1b}[61;7u", "ctrl+alt+;": "\u{1b}[59;7u", "ctrl+alt+'": "\u{1b}[39;7u",
        "ctrl+alt+`": "\u{1b}[96;7u", "ctrl+alt+,": "\u{1b}[44;7u", "ctrl+alt+.": "\u{1b}[46;7u",
        "ctrl+alt+enter": "\u{1b}[27;7;13~", "ctrl+alt+tab": "\u{1b}[27;7;9~", "ctrl+alt+escape": "\u{1b}[27;7;27~",
        "ctrl+alt+f3": "\u{1b}[13;7~",
    ]

    func testLegacyBytesMatchTheAppsEncoder() throws {
        let core = P.core()
        var same = 0, seen = Set<String>()
        for mods in ["", "shift+", "ctrl+", "alt+", "shift+alt+", "ctrl+alt+"] {
            for name in Self.keys {
                let spelling = mods + name
                let chord = try XCTUnwrap(KeyChord(spelling: spelling), spelling)
                let key = try XCTUnwrap(P.key(spelling), spelling)
                let got = core.input.encode(key)
                if let want = Self.ghosttyOnly[spelling] {
                    seen.insert(spelling)
                    XCTAssertEqual(got, P.bytes(want), "\(spelling): sent \(P.show(got))")
                    XCTAssertNotEqual(KeyInput.bytes(chord), P.bytes(want), "\(spelling) is no longer a difference")
                } else {
                    let want = try XCTUnwrap(KeyInput.bytes(chord), spelling)
                    XCTAssertEqual(got, want, "\(spelling): sent \(P.show(got)), the app's encoder sends \(P.show(want))")
                    same += 1
                }
            }
        }
        XCTAssertEqual(seen.count, Self.ghosttyOnly.count)
        XCTAssertEqual(same, 6 * Self.keys.count - Self.ghosttyOnly.count)
        XCTAssertGreaterThan(same, 400)
    }

    /// What `KeyEncodingTests` expects of `KeyInput.bytes` holds for the terminal's encoder too.
    func testKeyEncodingTestsExpectationsHold() {
        expect(P.core(), [
            ("ctrl+u", "\u{15}"), ("ctrl+a", "\u{01}"), ("alt+b", "\u{1b}b"), ("alt+backspace", "\u{1b}\u{7f}"),
            ("ctrl+j", "\n"), ("enter", "\r"), ("shift+tab", "\u{1b}[Z"), ("up", "\u{1b}[A"),
            ("ctrl+left", "\u{1b}[1;5D"), ("alt+right", "\u{1b}[1;3C"), ("shift+pageup", "\u{1b}[5;2~"),
            ("f1", "\u{1b}OP"), ("ctrl+f5", "\u{1b}[15;5~"), ("shift+1", "!"), ("ctrl+space", "\u{00}"),
            ("ctrl+[KeyC]", "\u{03}"),
        ], "normal")
    }

    /// Control with a shifted letter is a key of its own in Ghostty (as in Kitty), not the control
    /// character: programs can bind Ctrl+Shift+C apart from Ctrl+C.
    func testControlShiftLetterIsItsOwnKey() {
        expect(P.core(), [("shift+ctrl+c", "\u{1b}[99;6u"), ("shift+ctrl+a", "\u{1b}[97;6u"), ("shift+ctrl+2", "\u{1b}[64;5u")], "normal")
    }

    // MARK: Control keys that are other keys

    func testControlIMAndBracketAreTabEnterEscapeInLegacyMode() {
        // Every legacy terminal sends these; Ghostty's encoder alone
        // would send CSI 105;5u, CSI 109;5u and CSI 91;5u.
        let legacy: [(String, String)] = [("ctrl+i", "\t"), ("ctrl+m", "\r"), ("ctrl+[BracketLeft]", "\u{1b}")]
        expect(P.core(), legacy, "normal")
        expect(P.core(P.cursorKeys), legacy, "DECCKM")
        // A program that asked for an extended protocol gets the real key.
        expect(P.core(P.kittyDisambiguate), [
            ("ctrl+i", "\u{1b}[105;5u"), ("ctrl+m", "\u{1b}[109;5u"), ("ctrl+[BracketLeft]", "\u{1b}[91;5u"),
        ], "kitty 1")
        expect(P.core(P.modifyOtherKeys2), [
            ("ctrl+i", "\u{1b}[27;5;105~"), ("ctrl+m", "\u{1b}[27;5;109~"), ("ctrl+[BracketLeft]", "\u{1b}[27;5;91~"),
        ], "modifyOtherKeys 2")
    }

    // MARK: Modes

    func testCursorKeyApplicationMode() {
        let core = P.core(P.cursorKeys)
        XCTAssertTrue(core.input.modes.cursorKeyApplication)
        expect(core, [
            ("up", "\u{1b}OA"), ("down", "\u{1b}OB"), ("right", "\u{1b}OC"), ("left", "\u{1b}OD"),
            ("home", "\u{1b}OH"), ("end", "\u{1b}OF"),
            // Modified cursor keys keep the CSI form, and the mode touches nothing else.
            ("ctrl+left", "\u{1b}[1;5D"), ("shift+up", "\u{1b}[1;2A"), ("alt+home", "\u{1b}[1;3H"),
            ("pageup", "\u{1b}[5~"), ("delete", "\u{1b}[3~"), ("f1", "\u{1b}OP"), ("f5", "\u{1b}[15~"),
            ("a", "a"), ("enter", "\r"), ("backspace", "\u{7f}"), ("ctrl+c", "\u{03}"), ("alt+b", "\u{1b}b"),
        ], "DECCKM")
        // And back.
        core.feed(P.bytes("\u{1b}[?1l"))
        core.sync()
        XCTAssertFalse(core.input.modes.cursorKeyApplication)
        expect(core, [("up", "\u{1b}[A"), ("home", "\u{1b}[H")], "DECCKM reset")
    }

    private func keypad(_ usage: Int, _ characters: String) -> GhosttyInputKey? {
        if case .encode(let k) = GhosttyInputKeymap.route(usage: usage, flags: .numericPad, characters: characters,
                                                         charactersIgnoringModifiers: characters) { return k }
        return nil
    }

    func testKeypadApplicationMode() throws {
        // Usages 89, 98, 87, 88, 99: keypad 1, 0, +, Enter and the decimal point.
        let keys: [(Int, String, String, String)] = [
            (89, "1", "1", "\u{1b}Oq"), (98, "0", "0", "\u{1b}Op"), (87, "+", "+", "\u{1b}Ok"),
            (88, "\r", "\r", "\u{1b}OM"), (99, ".", ".", "\u{1b}On"),
        ]
        let numeric = P.core(), ignored = P.core("\u{1b}="), application = P.core(P.keypadApplication)
        for (usage, characters, plain, app) in keys {
            let key = try XCTUnwrap(keypad(usage, characters))
            XCTAssertEqual(numeric.input.encode(key), P.bytes(plain), "keypad \(usage)")
            // DECKPAM alone: Ghostty keeps the numeric keypad while mode 1035 is on, its default.
            XCTAssertEqual(ignored.input.encode(key), P.bytes(plain), "keypad \(usage), DECKPAM with mode 1035")
            XCTAssertEqual(application.input.encode(key), P.bytes(app), "keypad \(usage), application")
        }
    }

    func testBackarrowKeyMode() {
        // DECBKM: Backspace sends BS, and Control+Backspace the other one.
        expect(P.core(P.backarrow), [
            ("backspace", "\u{08}"), ("ctrl+backspace", "\u{7f}"), ("alt+backspace", "\u{1b}\u{7f}"),
            ("enter", "\r"), ("up", "\u{1b}[A"), ("a", "a"),
        ], "DECBKM")
        expect(P.core(), [("backspace", "\u{7f}"), ("ctrl+backspace", "\u{08}")], "normal")
    }

    func testKittyDisambiguate() {
        let core = P.core(P.kittyDisambiguate)
        XCTAssertEqual(core.input.modes.kittyFlags, 1)
        expect(core, [
            // Text keys and Enter, Tab, Backspace are as before.
            ("a", "a"), ("shift+a", "A"), ("shift+1", "!"), ("space", " "),
            ("enter", "\r"), ("tab", "\t"), ("backspace", "\u{7f}"),
            // Escape and every modified key are CSI u.
            ("escape", "\u{1b}[27u"), ("ctrl+c", "\u{1b}[99;5u"), ("alt+b", "\u{1b}[98;3u"), ("ctrl+alt+c", "\u{1b}[99;7u"),
            ("shift+enter", "\u{1b}[13;2u"), ("ctrl+enter", "\u{1b}[13;5u"), ("shift+tab", "\u{1b}[9;2u"),
            ("ctrl+backspace", "\u{1b}[127;5u"), ("ctrl+space", "\u{1b}[32;5u"), ("shift+ctrl+c", "\u{1b}[99;6u"),
            // Function keys keep their legacy forms, without SS3.
            ("up", "\u{1b}[A"), ("ctrl+up", "\u{1b}[1;5A"), ("home", "\u{1b}[H"), ("delete", "\u{1b}[3~"),
            ("pageup", "\u{1b}[5~"), ("f1", "\u{1b}[P"), ("shift+f1", "\u{1b}[1;2P"), ("f5", "\u{1b}[15~"),
        ], "kitty 1")
        // No release events without "report events".
        for spelling in ["a", "ctrl+c", "up", "escape"] {
            var key = P.key(spelling)!
            key.action = .release
            XCTAssertEqual(core.input.encode(key), [], "kitty 1 release \(spelling)")
        }
        // The flags belong to the screen that set them, and popping them ends the protocol.
        core.feed(P.bytes("\u{1b}[<u"))
        core.sync()
        XCTAssertEqual(core.input.modes.kittyFlags, 0)
        expect(core, [("escape", "\u{1b}"), ("ctrl+c", "\u{03}")], "kitty popped")
    }

    func testKittyAllFlags() {
        let core = P.core(P.kittyAll)
        XCTAssertEqual(core.input.modes.kittyFlags, 31)
        let table: [(String, String, String)] = [
            // key, press, release. Text keys report the key, alternates and the text.
            ("a", "\u{1b}[97;;97u", "\u{1b}[97;1:3u"),
            ("shift+a", "\u{1b}[97:65;2;65u", "\u{1b}[97:65;2:3u"),
            ("shift+1", "\u{1b}[49:33;2;33u", "\u{1b}[49:33;2:3u"),
            ("space", "\u{1b}[32;;32u", "\u{1b}[32;1:3u"),
            ("ctrl+c", "\u{1b}[99;5u", "\u{1b}[99;5:3u"),
            ("alt+b", "\u{1b}[98;3u", "\u{1b}[98;3:3u"),
            // Enter, Tab, Backspace and Escape are escape codes too ("report all").
            ("enter", "\u{1b}[13u", "\u{1b}[13;1:3u"),
            ("shift+enter", "\u{1b}[13;2u", "\u{1b}[13;2:3u"),
            ("tab", "\u{1b}[9u", "\u{1b}[9;1:3u"),
            ("backspace", "\u{1b}[127u", "\u{1b}[127;1:3u"),
            ("escape", "\u{1b}[27u", "\u{1b}[27;1:3u"),
            ("up", "\u{1b}[1;1:1A", "\u{1b}[1;1:3A"),
            ("ctrl+up", "\u{1b}[1;5:1A", "\u{1b}[1;5:3A"),
            ("home", "\u{1b}[1;1:1H", "\u{1b}[1;1:3H"),
            ("delete", "\u{1b}[3~", "\u{1b}[3;1:3~"),
            ("f1", "\u{1b}[1;1:1P", "\u{1b}[1;1:3P"),
            ("f5", "\u{1b}[15~", "\u{1b}[15;1:3~"),
        ]
        expect(core, table.map { ($0.0, $0.1) }, "kitty 31")
        for (spelling, _, release) in table {
            var key = P.key(spelling)!
            key.action = .release
            let got = core.input.encode(key)
            XCTAssertEqual(got, P.bytes(release), "kitty 31 release \(spelling): sent \(P.show(got))")
        }
        // A held key is event type 2.
        var up = P.key("up")!
        up.action = .repeatPress
        XCTAssertEqual(core.input.encode(up), P.bytes("\u{1b}[1;1:2A"))
        var a = P.key("a")!
        a.action = .repeatPress
        XCTAssertEqual(core.input.encode(a), P.bytes("\u{1b}[97;1:2;97u"))
    }

    func testModifierKeysOnlyReportUnderKittyReportAll() throws {
        // Usage 225 is left Shift, 224 left Control.
        guard case .modifier(let shift) = GhosttyInputKeymap.route(usage: 225, flags: .shift, characters: "", charactersIgnoringModifiers: ""),
              case .modifier(let control) = GhosttyInputKeymap.route(usage: 224, flags: .control, characters: "", charactersIgnoringModifiers: "")
        else { return XCTFail("modifier keys route as modifiers") }
        for setup in ["", P.cursorKeys, P.kittyDisambiguate] {
            XCTAssertEqual(P.core(setup).input.encode(shift), [])
            XCTAssertEqual(P.core(setup).input.encode(control), [])
        }
        XCTAssertEqual(P.core(P.kittyAll).input.encode(shift), P.bytes("\u{1b}[57441;2u"))
        XCTAssertEqual(P.core(P.kittyAll).input.encode(control), P.bytes("\u{1b}[57442;5u"))
    }

    func testModifyOtherKeys2() {
        expect(P.core(P.modifyOtherKeys2), [
            ("a", "a"), ("ctrl+a", "\u{1b}[27;5;97~"), ("alt+a", "\u{1b}[27;3;97~"), ("ctrl+space", "\u{1b}[27;5;32~"),
            ("shift+enter", "\u{1b}[27;2;13~"), ("up", "\u{1b}[A"), ("ctrl+up", "\u{1b}[1;5A"), ("enter", "\r"),
        ], "modifyOtherKeys 2")
    }

    func testOptionIsAlt() {
        // iOS composes Option+B into "∫"; the terminal gets Alt+b.
        expect(P.core(), [("alt+b", "\u{1b}b"), ("shift+alt+b", "\u{1b}B"), ("alt+.", "\u{1b}."), ("alt+1", "\u{1b}1"),
                          ("alt+enter", "\u{1b}\r"), ("alt+left", "\u{1b}[1;3D"), ("ctrl+alt+c", "\u{1b}\u{03}")], "normal")
        // Mode 1036 off: Alt no longer prefixes ESC.
        expect(P.core("\u{1b}[?1036l"), [("alt+b", "b")], "mode 1036 reset")
    }

    // MARK: Routing

    func testCommandKeysStayWithTheSystem() {
        for spelling in ["cmd+c", "cmd+v", "cmd+t", "shift+cmd+d", "cmd+up", "cmd+enter", "ctrl+cmd+f", "alt+cmd+a"] {
            XCTAssertEqual(P.route(spelling), .system, spelling)
        }
        // A key libghostty-vt has no name for.
        XCTAssertEqual(GhosttyInputKeymap.route(usage: 127, flags: [], characters: "", charactersIgnoringModifiers: ""), .system)
    }

    func testTypingKeysGoToTheTextSystem() {
        for spelling in ["a", "shift+a", "1", "shift+1", "-", "space", "enter", "shift+enter", "backspace"] {
            guard case .textInput = P.route(spelling) else { return XCTFail("\(spelling) should type through the text system") }
        }
        for spelling in ["ctrl+a", "alt+a", "ctrl+enter", "alt+backspace", "ctrl+space", "up", "tab", "escape", "f1", "delete", "shift+tab"] {
            guard case .encode = P.route(spelling) else { return XCTFail("\(spelling) should be encoded at once") }
        }
    }

    func testHardwareKeyEvents() {
        // Shift is used up by the text it made; the unshifted character comes from the key.
        var want = P.key("a")!
        XCTAssertEqual(want.text, "a")
        XCTAssertEqual(want.unshifted, 0x61)
        XCTAssertEqual(want.mods, 0)
        want.mods = GhosttyInputKey.shift
        want.consumedMods = GhosttyInputKey.shift
        want.text = "A"
        XCTAssertEqual(P.key("shift+a"), want)
        XCTAssertEqual(P.key("shift+1")?.text, "!")
        XCTAssertEqual(P.key("shift+1")?.unshifted, 0x31)
        // Control: the text is the key's own character, never the control character iOS reports.
        XCTAssertEqual(P.key("ctrl+c")?.text, "c")
        XCTAssertEqual(P.key("alt+b")?.text, "b")
        // Function keys carry no text, whatever `UIKey.characters` says.
        XCTAssertEqual(P.key("up")?.text, "")
        XCTAssertEqual(P.key("enter")?.text, "")
        // A layout where the key types something else: the text follows the layout.
        let route = GhosttyInputKeymap.route(usage: 28, flags: [], characters: "z", charactersIgnoringModifiers: "z")  // KeyY, German
        guard case .textInput(let german) = route else { return XCTFail("a letter types") }
        XCTAssertEqual(german.text, "z")
        XCTAssertEqual(german.unshifted, 0x7a)
        XCTAssertEqual(GhosttyInputKeymap.mods([.shift, .control, .alternate, .command, .alphaShift]),
                       GhosttyInputKey.shift | GhosttyInputKey.ctrl | GhosttyInputKey.alt | GhosttyInputKey.superKey | GhosttyInputKey.capsLock)
    }

    // MARK: The mirror follows the terminal

    func testModesFollowResetAndRestore() throws {
        let core = P.core(P.cursorKeys + P.kittyAll + P.bracketedPaste + P.focusEvents)
        var modes = core.input.modes
        XCTAssertTrue(modes.cursorKeyApplication && modes.bracketedPaste && modes.focusEvents)
        XCTAssertEqual(modes.kittyFlags, 31)
        XCTAssertFalse(modes.alternateScreen)

        core.feed(P.bytes("\u{1b}[?1049h"))
        core.sync()
        XCTAssertTrue(core.input.modes.alternateScreen)
        // Kitty flags are per screen.
        XCTAssertEqual(core.input.modes.kittyFlags, 0)

        core.reset()
        core.sync()
        modes = core.input.modes
        XCTAssertEqual(modes, GhosttyInputMirror.Modes())
        expect(core, [("up", "\u{1b}[A"), ("escape", "\u{1b}")], "after reset")

        // A snapshot restore swaps the terminal: the encoder follows the new one. The fixture is a
        // zsh prompt, which keeps the cursor keys in application mode and has no Kitty flags.
        core.feed(P.bytes(P.kittyAll))
        core.sync()
        XCTAssertEqual(core.input.modes.kittyFlags, 31)
        XCTAssertFalse(core.input.modes.cursorKeyApplication)
        let restored = expectation(description: "restored")
        core.restore(snapshot: try ghosttyFixture("ghostty-history")) { used in
            XCTAssertNotNil(used)
            restored.fulfill()
        }
        wait(for: [restored], timeout: 5)
        XCTAssertEqual(core.input.modes.kittyFlags, 0)
        XCTAssertTrue(core.input.modes.cursorKeyApplication)
        expect(core, [("up", "\u{1b}OA"), ("escape", "\u{1b}")], "after restore")
    }

    /// Typing must not wait for the terminal lock: encode while the feed queue is parsing.
    func testEncodingDoesNotWaitForParsing() {
        let core = P.core()
        var line = ""
        for i in 0..<2000 { line += "\u{1b}[3\(i % 8)mline \(i) of output\u{1b}[0m\r\n" }
        let bytes = P.bytes(line)
        for _ in 0..<200 { core.feed(bytes) }
        let key = P.key("ctrl+c")!
        var times: [Double] = []
        for _ in 0..<200 {
            let t = CACurrentMediaTime()
            XCTAssertEqual(core.input.encode(key), [0x03])
            times.append(CACurrentMediaTime() - t)
            usleep(200)
        }
        core.sync()
        // The encoder's own lock is held for a few loads and stores: an encode takes microseconds
        // (measured: 10 µs median, 70 µs worst), where waiting for the terminal lock took up to
        // 10 ms in the same burst. The 95th percentile leaves room for a busy test machine.
        times.sort()
        XCTAssertLessThan(times[190], 0.002)
    }
}
