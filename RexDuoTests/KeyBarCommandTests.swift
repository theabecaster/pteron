import Testing
import UIKit
import RexKit
@testable import RexDuo

// The key bar's cmd: the next key runs through Rex's keymap as a hardware ⌘ press does, and is
// never typed.

@MainActor
private final class SendSpy: TerminalEngineDelegate {
    var sent: [[UInt8]] = []
    func engineGridChanged(cols: Int, rows: Int) {}
    func engineSend(_ bytes: [UInt8]) { sent.append(bytes) }
}

/// The presses the bar makes, against what a hardware keyboard reports for the same keys.
struct KeyBarPressTests {
    private func spellings(_ p: KeyInput.Press?) -> [[String]] {
        p.map { KeyInput.chordTiers($0).map { $0.map(\.spelling) } } ?? []
    }

    @Test func typedCharactersBecomeTheKeyThatTypesThem() {
        #expect(spellings(KeyInput.press(typing: "d", mods: .cmd)) == [["cmd+d", "cmd+[KeyD]"]])
        // Shift as the hardware path derives it: the US key and shift.
        let upper = KeyInput.press(typing: "D", mods: .cmd)
        #expect(upper?.flags == [.command, .shift])
        #expect(upper?.charactersIgnoringModifiers == "d")
        #expect(spellings(upper) == [["shift+cmd+d", "shift+cmd+[KeyD]"]])
        #expect(spellings(KeyInput.press(typing: "?", mods: .cmd)) == [["shift+cmd+/", "shift+cmd+[Slash]"], ["cmd+?"]])
        #expect(spellings(KeyInput.press(typing: "1", mods: .cmd)) == [["cmd+1", "cmd+[Digit1]"]])
        #expect(spellings(KeyInput.press(typing: "\n", mods: .cmd)) == [["cmd+enter", "cmd+[Enter]"]])
        #expect(spellings(KeyInput.press(typing: "\u{7f}", mods: .cmd)) == [["cmd+backspace", "cmd+[Backspace]"]])
        // No US key types it: only what it types.
        #expect(spellings(KeyInput.press(typing: "ñ", mods: .cmd)) == [["cmd+ñ"]])
        #expect(KeyInput.press(typing: "ab", mods: .cmd) == nil)
    }

    @Test func barKeys() {
        #expect(spellings(KeyInput.press(barKey: "tab", mods: .cmd)) == [["cmd+tab", "cmd+[Tab]"]])
        #expect(spellings(KeyInput.press(barKey: "shift-tab", mods: .cmd)) == [["shift+cmd+tab", "shift+cmd+[Tab]"]])
        #expect(spellings(KeyInput.press(barKey: "esc", mods: .cmd)) == [["cmd+escape", "cmd+[Escape]"]])
        #expect(spellings(KeyInput.press(barKey: "up", mods: [.cmd, .alt])) == [["alt+cmd+up", "alt+cmd+[ArrowUp]"]])
        #expect(spellings(KeyInput.press(barKey: "pgdn", mods: .cmd)) == [["cmd+pagedown", "cmd+[PageDown]"]])
        #expect(spellings(KeyInput.press(barKey: "ctrl-c", mods: .cmd)) == [["ctrl+cmd+c", "ctrl+cmd+[KeyC]"]])
        #expect(spellings(KeyInput.press(barKey: "|", mods: .cmd)) == [["shift+cmd+\\", "shift+cmd+[Backslash]"], ["cmd+|"]])
        for key in ["paste", "hide", "attach", "arrows", "ctrl", "alt", "cmd"] {
            #expect(KeyInput.press(barKey: key, mods: .cmd) == nil, "\(key)")
        }
    }

    @Test @MainActor func theBarsPressRunsTheBindingTheHardwarePressRuns() {
        let s = KeymapStore(control: RexControl(address: "", client: ClientInfo(name: "test", version: "0", label: "test")))
        let hardware = KeyInput.Press(usage: 56, flags: .command, characters: "/", charactersIgnoringModifiers: "/")
        let bar = KeyInput.press(typing: "/", mods: .cmd)!
        #expect(s.resolve(press: bar)?.0.action == s.resolve(press: hardware)?.0.action)
        #expect(s.resolve(press: bar)?.0.action == "client.sidebar.toggle")
        #expect(s.resolve(press: KeyInput.press(typing: "x", mods: .cmd)!) == nil)
    }
}

/// The bar's modifier states and the whole path: bar, engine view, host, keymap, command.
@MainActor
struct KeyBarCommandTests {
    private final class Counter { var n = 0 }

    private func makeHost(_ extra: [(String, String)] = []) -> (TerminalHost, SendSpy, Counter) {
        let control = RexControl(address: "", client: ClientInfo(name: "test", version: "0", label: "test"))
        let host = TerminalHost(stream: TerminalStream(control: control, sessionID: "s", blockID: "b"), sizing: .mirror,
                                fontSize: 12, theme: ThemeStore.fallback)
        let keymap = KeymapStore(control: control)
        if !extra.isEmpty {
            keymap.apply(extra.compactMap { k, a in KeyChord(spelling: k).map { KeyBinding(chord: $0, action: a, args: nil) } }
                         + KeyDefaults.resolved)
        }
        host.keymap = keymap
        let spy = SendSpy()
        host.term.engineDelegate = spy
        let counter = Counter()
        host.keyBar.onUnbound = { counter.n += 1 }
        return (host, spy, counter)
    }

    @Test func modifierTaps() {
        #expect(KeyBar.next(.off, quick: false) == .once)
        #expect(KeyBar.next(.once, quick: true) == .locked)
        #expect(KeyBar.next(.once, quick: false) == .off)
        #expect(KeyBar.next(.locked, quick: true) == .off)
        #expect(KeyBar.kind(of: "cmd") == .modifier)
        #expect(KeyBar.titles["cmd"] == "cmd")
        #expect(KeyBar.names["cmd"] == "Command")
        #expect(KeyBar.bytes(for: "cmd", appCursor: false) == nil)
    }

    @Test func cmdOnceRunsOneShortcutThenClears() {
        let (host, spy, unbound) = makeHost()
        var commands: [RexCommand] = []
        host.onCommand = { commands.append($0) }
        host.keyBar.fire("cmd")
        #expect(host.keyBar.cmd == .once)
        #expect(host.term.commandModifier)
        host.term.insertText("t")
        #expect(commands == [.newTab])
        #expect(host.keyBar.cmd == .off)
        #expect(!host.term.commandModifier)
        #expect(spy.sent.isEmpty, "cmd never types")
        #expect(unbound.n == 0)
        // The next key types again.
        host.term.insertText("t")
        #expect(commands == [.newTab])
        #expect(spy.sent.flatMap { $0 } == Array("t".utf8))
    }

    @Test func cmdLockedStaysUntilTappedAgain() {
        let (host, spy, _) = makeHost()
        var commands: [RexCommand] = []
        host.onCommand = { commands.append($0) }
        host.keyBar.fire("cmd")
        host.keyBar.fire("cmd")
        #expect(host.keyBar.cmd == .locked)
        host.keyBar.fire("1")
        host.term.insertText("D")
        host.keyBar.fire("shift-tab")
        #expect(commands == [.goToTab(1), .splitDown])
        #expect(host.keyBar.cmd == .locked)
        host.keyBar.fire("cmd")
        #expect(host.keyBar.cmd == .off)
        #expect(!host.term.commandModifier)
        #expect(spy.sent.isEmpty)
    }

    @Test func barKeysWithCmdRunTheirBindings() {
        let (host, spy, unbound) = makeHost()
        var commands: [RexCommand] = []
        host.onCommand = { commands.append($0) }
        for key in ["/", "enter", "-"] {
            host.keyBar.fire("cmd")
            host.keyBar.fire(key)
        }
        // cmd+enter is Split Pane Best Fit: along the longer side.
        #expect(commands.count == 3)
        #expect(commands.first == .toggleSidebar)
        #expect(commands.last == .fontSmaller)
        #expect(spy.sent.isEmpty)
        #expect(unbound.n == 0)
    }

    @Test func aBoundKeyThatSendsAKeyGoesThroughItsAction() {
        // cmd+Delete is pane.send_key ctrl+u: the action's bytes, not a typed character.
        let (host, spy, _) = makeHost()
        host.keyBar.fire("cmd")
        host.term.deleteBackward()
        #expect(spy.sent == [[0x15]])
        #expect(host.keyBar.cmd == .off)
    }

    @Test func anUnboundChordSendsNothing() {
        let (host, spy, unbound) = makeHost()
        var commands: [RexCommand] = []
        host.onCommand = { commands.append($0) }
        host.keyBar.fire("cmd")
        host.term.insertText("x")
        #expect(commands.isEmpty)
        #expect(spy.sent.isEmpty)
        #expect(unbound.n == 1)
        #expect(host.keyBar.cmd == .off)
        // A bar key with nothing bound: the same.
        host.keyBar.fire("cmd")
        host.keyBar.fire("esc")
        #expect(spy.sent.isEmpty)
        #expect(unbound.n == 2)
        #expect(host.keyBar.cmd == .off)
    }

    @Test func ctrlAndCmdMakeOneChord() {
        let (host, spy, unbound) = makeHost([("ctrl+cmd+f", "client.tab.new")])
        var commands: [RexCommand] = []
        host.onCommand = { commands.append($0) }
        host.keyBar.fire("ctrl")
        host.keyBar.fire("cmd")
        host.term.insertText("f")
        #expect(commands == [.newTab])
        #expect(host.keyBar.ctrl == .off)
        #expect(host.keyBar.cmd == .off)
        #expect(!host.term.controlModifier)
        #expect(spy.sent.isEmpty)
        // ctrl-c from the bar with cmd is ctrl+cmd+c: unbound, nothing sent, no ^C.
        host.keyBar.fire("cmd")
        host.keyBar.fire("ctrl-c")
        #expect(spy.sent.isEmpty)
        #expect(unbound.n == 1)
        // alt with cmd and an arrow: Focus Pane Left.
        host.keyBar.fire("alt")
        host.keyBar.fire("cmd")
        host.keyBar.fire("left")
        #expect(commands == [.newTab, .previousPane])
        #expect(host.keyBar.alt == .off)
    }

    @Test func ctrlAndAltWithoutCmdStillType() {
        let (host, spy, unbound) = makeHost()
        host.keyBar.fire("ctrl")
        host.term.insertText("c")
        #expect(spy.sent.flatMap { $0 } == [0x03])
        #expect(host.keyBar.ctrl == .off)
        host.keyBar.fire("alt")
        host.keyBar.fire("tab")
        #expect(spy.sent.flatMap { $0 } == [0x03, 0x1b, 0x09])
        #expect(unbound.n == 0)
    }
}
