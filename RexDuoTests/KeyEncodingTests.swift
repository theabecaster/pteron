import Testing
@testable import RexDuo

private func b(_ s: String) -> [UInt8] { Array(s.utf8) }

/// Bytes sent for hardware-key bindings (`pane.send_key`) and key bar keys.
@MainActor
struct KeyEncodingTests {
    @Test(arguments: [
        ("ctrl+u", [0x15] as [UInt8]),
        ("ctrl+a", [0x01]),
        ("alt+b", [0x1b, 0x62]),
        ("alt+backspace", [0x1b, 0x7f]),
        ("ctrl+j", [0x0a]),
        ("enter", [0x0d]),
        ("shift+tab", b("\u{1b}[Z")),
        ("up", b("\u{1b}[A")),
        ("ctrl+left", b("\u{1b}[1;5D")),
        ("alt+right", b("\u{1b}[1;3C")),
        ("shift+pageup", b("\u{1b}[5;2~")),
        ("f1", b("\u{1b}OP")),
        ("ctrl+f5", b("\u{1b}[15;5~")),
        ("shift+1", b("!")),
        ("ctrl+space", [0x00]),
    ])
    func sendKeyBytes(spelling: String, bytes: [UInt8]) throws {
        let c = try #require(KeyChord(spelling: spelling))
        #expect(KeyInput.bytes(c) == bytes)
    }

    @Test func physicalKeyUsesItsName() throws {
        let c = try #require(KeyChord(spelling: "ctrl+[KeyC]"))
        #expect(KeyInput.bytes(c) == [0x03])
    }

    @Test func barKeysFollowCursorMode() {
        #expect(KeyBar.bytes(for: "up", appCursor: false) == b("\u{1b}[A"))
        #expect(KeyBar.bytes(for: "up", appCursor: true) == b("\u{1b}OA"))
        #expect(KeyBar.bytes(for: "pgdn", appCursor: true) == b("\u{1b}[6~"))
        #expect(KeyBar.bytes(for: "ctrl-c", appCursor: false) == [0x03])
        #expect(KeyBar.bytes(for: "|", appCursor: false) == b("|"))
        #expect(KeyBar.bytes(for: "paste", appCursor: false) == nil)
    }

    @Test func modifiedSequences() {
        // mod = 1 + shift + alt·2 + ctrl·4
        #expect(KeyBar.modifiedSequence("left", mod: 5) == b("\u{1b}[1;5D"))
        #expect(KeyBar.modifiedSequence("pgup", mod: 3) == b("\u{1b}[5;3~"))
        #expect(KeyBar.modifiedSequence("x", mod: 5) == nil)
    }

    @Test func controlCharacters() {
        #expect(KeyBar.control(UInt8(ascii: "c")) == 0x03)
        #expect(KeyBar.control(UInt8(ascii: "[")) == 0x1b)
        #expect(KeyBar.control(UInt8(ascii: " ")) == 0x00)
        #expect(KeyBar.control(UInt8(ascii: "?")) == 0x7f)
        #expect(KeyBar.control(UInt8(ascii: "1")) == nil)
    }

    @Test func snakeCaseCodes() {
        #expect(KeyInput.snake("KeyA") == "key_a")
        #expect(KeyInput.snake("ArrowLeft") == "arrow_left")
        #expect(KeyInput.snake("Digit1") == "digit_1")
        #expect(KeyInput.snake("F5") == "f5")
    }
}
