import Testing
import UIKit
import RexKit
@testable import Pteron

@MainActor
private final class Spy: TerminalEngineDelegate {
    var sent: [[UInt8]] = []
    func engineGridChanged(cols: Int, rows: Int) {}
    func engineSend(_ bytes: [UInt8]) { sent.append(bytes) }
}

private func b(_ s: String) -> [UInt8] { Array(s.utf8) }

/// The key bar's keys from the setup: shortcuts, group menus, the new keys (shift, Backspace,
/// Delete) and ⌘ for the palette. What each sends goes through the engine, as any key.
@MainActor
struct KeyBarSetupBarTests {
    private func makeHost() -> (TerminalHost, Spy) {
        let control = RexControl(address: "", client: ClientInfo(name: "test", version: "0", label: "test"))
        let host = TerminalHost(stream: TerminalStream(control: control, sessionID: "s", blockID: "b"), sizing: .mirror,
                                fontSize: 12, theme: ThemeStore.fallback)
        let spy = Spy()
        host.term.engineDelegate = spy
        return (host, spy)
    }

    private func shortcut(_ kind: ShortcutGroup.Kind, _ id: String) -> Shortcut {
        ShortcutGroup.standard(kind).items.first { $0.id == id }!
    }

    @Test func shortcutsSendTheirBytes() {
        let (host, spy) = makeHost()
        let bar = host.keyBar
        bar.fire(shortcut: shortcut(.shortcuts, "ctrl-c"))
        #expect(spy.sent.last == [0x03])
        bar.fire(shortcut: shortcut(.characters, "~"))
        #expect(spy.sent.last == b("~"))
        bar.fire(shortcut: shortcut(.characters, ".."))
        #expect(spy.sent.last == b(".."))
        bar.fire(shortcut: shortcut(.functionKeys, "f5"))
        #expect(spy.sent.last == b("\u{1b}[15~"))
        // Custom ones: text exactly, newline and all; a key with its modifiers.
        bar.fire(shortcut: .custom(label: "two", send: .text("git status\n")))
        #expect(spy.sent.last == b("git status\n"))
        bar.fire(shortcut: .custom(label: "⌃⌥C", send: .key(KeyStroke(key: "c", ctrl: true, alt: true))))
        #expect(spy.sent.last == [0x1b, 0x03])
        bar.fire(shortcut: .custom(label: "⇧↑", send: .key(KeyStroke(key: "up", shift: true))))
        #expect(spy.sent.last == b("\u{1b}[1;2A"))
    }

    @Test func theBarsModifiersApplyToShortcuts() {
        let (host, spy) = makeHost()
        let bar = host.keyBar
        bar.fire("alt")
        bar.fire(shortcut: shortcut(.characters, "|"))
        #expect(spy.sent.last == b("\u{1b}|"))
        #expect(bar.alt == .off)
        bar.fire("ctrl")
        bar.fire(shortcut: .custom(label: "F2", send: .key(KeyStroke(key: "f2"))))
        #expect(spy.sent.last == b("\u{1b}[1;5Q"))
        #expect(bar.ctrl == .off)
    }

    @Test func shiftAppliesToTheNextBarKey() {
        let (host, spy) = makeHost()
        let bar = host.keyBar
        #expect(KeyBar.kind(of: "shift") == .modifier)
        bar.fire("shift")
        #expect(bar.shift == .once)
        bar.fire("tab")
        #expect(spy.sent.last == b("\u{1b}[Z"), "⇧ then ⇥ is Shift-Tab")
        #expect(bar.shift == .off)
        bar.fire("shift")
        bar.fire("up")
        #expect(spy.sent.last == b("\u{1b}[1;2A"))
        bar.fire("shift")
        bar.fire("enter")
        #expect(spy.sent.last == b("\u{1b}[27;2;13~"), "Shift-Return, as the held Return sends it")
        bar.fire("shift")
        bar.fire(shortcut: .custom(label: "a", send: .text("a")))
        #expect(spy.sent.last == b("A"))
        // Locked, it stays.
        bar.fire("shift")
        bar.fire("shift")
        #expect(bar.shift == .locked)
        bar.fire("tab")
        bar.fire("tab")
        #expect(spy.sent.suffix(2) == [b("\u{1b}[Z"), b("\u{1b}[Z")])
        #expect(bar.shift == .locked)
    }

    @Test func backspaceAndDelete() {
        let (host, spy) = makeHost()
        host.keyBar.fire("backspace")
        #expect(spy.sent.last == [0x7f])
        host.keyBar.fire("delete")
        #expect(spy.sent.last == b("\u{1b}[3~"))
        host.keyBar.fire("alt")
        host.keyBar.fire("backspace")
        #expect(spy.sent.last == [0x1b, 0x7f], "option-Backspace deletes a word")
        #expect(KeyBar.kind(of: "backspace") == .repeating)
    }

    @Test func commandOpensThePalette() {
        let (host, spy) = makeHost()
        var commands: [RexCommand] = []
        host.onCommand = { commands.append($0) }
        host.keyBar.fire("palette")
        #expect(commands == [.goTo(.commands)])
        #expect(spy.sent.isEmpty)
    }

    @Test func everyKeyHasACapAndAName() {
        let keys = KeyBarSetup.primaryKeys + KeyBarSetup.editingKeys + ["palette", "compose", "attach", "enter", "arrows", "hide"]
        for key in keys {
            #expect(KeyBar.symbolImage(key, pointSize: 16) != nil || KeyBar.titles[key] != nil, "\(key)")
            #expect(KeyBar.names[key] != nil, "\(key)")
        }
        #expect(KeyBar.titles["esc"] == "esc", "esc keeps its text")
        for kind in ShortcutGroup.Kind.allCases {
            #expect(UIImage(systemName: kind.symbol) != nil, "\(kind)")
        }
    }

    @Test func aGroupIsOneKeyWithAMenuOfItsShortcuts() {
        var setup = KeyBarSetup.standard
        setup.update(.shortcuts) { $0.shown = true }
        let items = setup.items
        guard case .group(let g)? = items.first(where: { if case .group = $0 { return true } else { return false } }) else {
            Issue.record("no group key")
            return
        }
        #expect(g.id == .shortcuts)
        #expect(g.items.filter(\.on).count == 10)
    }
}
