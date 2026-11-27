import Testing
import UIKit
import RexKit
@testable import Pteron

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
        #expect(spellings(KeyInput.press(barKey: "shift-enter", mods: .cmd)) == [["shift+cmd+enter", "shift+cmd+[Enter]"]])
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

    // MARK: The pinned Return

    @Test func returnIsPinnedOnceOutsideTheScrollingKeys() {
        let (host, _, _) = makeHost()
        func caps(_ v: UIView) -> [KeyCap] { v.subviews.flatMap { ($0 as? KeyCap).map { [$0] } ?? caps($0) } }
        let returns = caps(host.keyBar).filter { $0.key == "enter" }
        #expect(returns.count == 1)
        var v: UIView? = returns.first
        while let s = v?.superview, s !== host.keyBar {
            #expect(!(s is UIScrollView), "Return scrolls")
            v = s
        }
        #expect(returns.first?.accessibilityLabel == "Return")
        #expect(returns.first?.accessibilityCustomActions?.map(\.name) == ["Shift-Return"])
        // It never repeats: a held Return is Shift-Return, once.
        #expect(KeyBar.kind(of: "enter") == .normal)
        #expect(returns.first?.onHold != nil)
    }

    @Test func returnSendsReturnWithTheBarsModifiers() {
        let (host, spy, unbound) = makeHost()
        host.keyBar.fire("enter")
        #expect(spy.sent.last == [0x0d])
        // ctrl+Return is Return (ctrl-M), as before; the one-shot ends.
        host.keyBar.fire("ctrl")
        host.keyBar.fire("enter")
        #expect(spy.sent.last == [0x0d])
        #expect(host.keyBar.ctrl == .off)
        // alt+Return: ESC CR. Locked alt stays locked.
        host.keyBar.fire("alt")
        host.keyBar.fire("alt")
        #expect(host.keyBar.alt == .locked)
        host.keyBar.fire("enter")
        host.keyBar.fire("enter")
        #expect(spy.sent.suffix(2) == [[0x1b, 0x0d], [0x1b, 0x0d]])
        #expect(host.keyBar.alt == .locked)
        #expect(unbound.n == 0)
    }

    @Test func cmdReturnRunsItsShortcutAndHeldIsShiftCmdReturn() {
        let (host, spy, unbound) = makeHost()
        var commands: [RexCommand] = []
        host.onCommand = { commands.append($0) }
        host.keyBar.fire("cmd")
        host.keyBar.fire("enter")
        host.keyBar.fire("cmd")
        host.keyBar.hold("enter")
        // cmd+enter splits along the longer side; shift+cmd+enter zooms the pane.
        #expect(commands.count == 2)
        #expect(commands.last == .toggleZoom)
        #expect(host.keyBar.cmd == .off)
        #expect(spy.sent.isEmpty)
        #expect(unbound.n == 0)
    }

    @Test func heldReturnIsShiftReturnAsTheHardwareKeyboardSendsIt() {
        let (host, spy, _) = makeHost()
        host.keyBar.hold("enter")
        #expect(spy.sent.last == Array("\u{1b}[27;2;13~".utf8))
        host.keyBar.fire("alt")
        host.keyBar.hold("enter")
        #expect(spy.sent.last == Array("\u{1b}[27;4;13~".utf8))
        #expect(host.keyBar.alt == .off)
        // Under the Kitty protocol, as agents ask for it.
        host.term.feed(text: "\u{1b}[>1u")
        host.term.core.sync()
        host.keyBar.hold("enter")
        #expect(spy.sent.last == Array("\u{1b}[13;2u".utf8))
        // Only Return holds.
        let n = spy.sent.count
        host.keyBar.hold("esc")
        #expect(spy.sent.count == n)
    }

    // MARK: The Shift-Return key

    /// ⇧⏎ sends what the held Return sends, through the same encoder: normal, with the bar's
    /// modifiers, and under the Kitty protocol.
    @Test func theShiftReturnKeySendsWhatTheHeldReturnSends() {
        let (host, spy, _) = makeHost()
        let (held, heldSpy, _) = makeHost()
        host.keyBar.fire("shift-enter")
        held.keyBar.hold("enter")
        #expect(spy.sent.last == Array("\u{1b}[27;2;13~".utf8))
        #expect(spy.sent == heldSpy.sent)
        host.keyBar.fire("alt")
        host.keyBar.fire("shift-enter")
        #expect(spy.sent.last == Array("\u{1b}[27;4;13~".utf8))
        #expect(host.keyBar.alt == .off, "the one-shot ends")
        host.keyBar.fire("shift")
        host.keyBar.fire("shift-enter")
        #expect(spy.sent.last == Array("\u{1b}[27;2;13~".utf8), "shift adds nothing to it")
        for h in [host, held] {
            h.term.feed(text: "\u{1b}[>1u")
            h.term.core.sync()
        }
        host.keyBar.fire("shift-enter")
        held.keyBar.hold("enter")
        #expect(spy.sent.last == Array("\u{1b}[13;2u".utf8))
        #expect(spy.sent.last == heldSpy.sent.last)
        // Its bytes are the engine's alone, and it never repeats.
        #expect(KeyBar.bytes(for: "shift-enter", appCursor: false) == nil)
        #expect(KeyBar.composeText(for: "shift-enter") == nil)
        #expect(KeyBar.kind(of: "shift-enter") == .normal)
    }

    @Test func theShiftReturnKeyWithCmdIsShiftCmdReturn() {
        let (host, spy, unbound) = makeHost()
        var commands: [RexCommand] = []
        host.onCommand = { commands.append($0) }
        host.keyBar.fire("cmd")
        host.keyBar.fire("shift-enter")
        #expect(commands == [.toggleZoom], "shift+cmd+enter, as the held Return runs it")
        #expect(host.keyBar.cmd == .off)
        #expect(spy.sent.isEmpty)
        #expect(unbound.n == 0)
    }

    @Test func theShiftReturnKeyWhileComposingCommitsTheComposition() {
        let (host, spy, _) = makeHost()
        host.term.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0))
        host.keyBar.fire("shift-enter")
        #expect(!host.term.isComposing)
        #expect(spy.sent.flatMap { $0 } == Array("か".utf8), "committed, not sent")
        host.keyBar.fire("shift-enter")
        #expect(spy.sent.last == Array("\u{1b}[27;2;13~".utf8))
    }

    @Test func theShiftReturnKeyIsACapWithItsGlyphAndName() {
        let cap = KeyCap(key: "shift-enter", kind: KeyBar.kind(of: "shift-enter"))
        #expect(cap.accessibilityLabel == "Shift-Return")
        #expect(cap.onHold == nil, "held, it is a slow tap")
        #expect(KeyBar.symbolPairs["shift-enter"] == ["shift", "return"])
        #expect(KeyBar.symbolImage("shift-enter", pointSize: 16) != nil)
        #expect(KeyBarLayoutPage.title("shift-enter") == "Shift-Return")
    }

    @Test func theAgentBoardBlocksReturn() {
        let (host, spy, _) = makeHost()
        host.setCovered(true)
        host.keyBar.fire("enter")
        host.keyBar.hold("enter")
        host.keyBar.fire("shift-enter")
        host.keyBar.fire("esc")
        #expect(spy.sent.isEmpty)
        host.setCovered(false)
        host.keyBar.fire("enter")
        #expect(spy.sent == [[0x0d]])
    }

    @Test func returnWhileComposingCommitsTheComposition() {
        let (host, spy, _) = makeHost()
        host.term.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0))
        #expect(host.term.isComposing)
        #expect(spy.sent.isEmpty, "composing sends nothing")
        host.keyBar.fire("enter")
        #expect(!host.term.isComposing)
        #expect(spy.sent.flatMap { $0 } == Array("か".utf8), "committed, not sent")
        host.keyBar.fire("enter")
        #expect(spy.sent.last == [0x0d])
        // Held, the same: the composition first.
        host.term.setMarkedText("き", selectedRange: NSRange(location: 1, length: 0))
        host.keyBar.hold("enter")
        #expect(!host.term.isComposing)
        #expect(spy.sent.last == Array("き".utf8))
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
