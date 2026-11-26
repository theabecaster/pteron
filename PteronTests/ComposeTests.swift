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

/// Compose (docs/terminal.md, Compose): what Send writes, the draft per pane, the card's size,
/// and keys typed with the bar's modifiers.
@MainActor
struct ComposeTests {
    private final class Writes { var all: [(bytes: [UInt8], then: [UInt8])] = [] }

    private func makeHost(_ setup: String = "") -> (TerminalHost, Writes, Spy) {
        let control = RexControl(address: "", client: ClientInfo(name: "test", version: "0", label: "test"))
        let host = TerminalHost(stream: TerminalStream(control: control, sessionID: "s", blockID: "b"), sizing: .mirror,
                                fontSize: 12, theme: ThemeStore.fallback)
        if !setup.isEmpty {
            host.term.feed(text: setup)
            host.term.core.sync()
        }
        let writes = Writes()
        host.composeWrite = { writes.all.append(($0, $1)) }
        let spy = Spy()
        host.term.engineDelegate = spy
        return (host, writes, spy)
    }

    private func type(_ host: TerminalHost, _ text: String) {
        host.keyBar.compose.field.text = text
        host.keyBar.compose.textViewDidChange(host.keyBar.compose.field)
    }

    private static let bracketed = "\u{1b}[?2004h"

    @Test func aLineToAShellIsItsTextThenReturnAlone() {
        let (host, writes, _) = makeHost()
        host.openCompose()
        type(host, "ls -la")
        #expect(host.composeSlot.text == "ls -la")
        host.sendCompose()
        #expect(writes.all.count == 1)
        #expect(writes.all.first?.bytes == b("ls -la"))
        #expect(writes.all.first?.then == [0x0d])
        #expect(host.keyBar.compose.field.text.isEmpty, "the field is empty after a send")
        #expect(host.composeSlot.text.isEmpty)
        #expect(host.composeSlot.open, "compose stays open")
    }

    @Test func aMessageToAnAgentIsABracketedPasteThenReturn() {
        let (host, writes, _) = makeHost(Self.bracketed)
        type(host, "fix the tests")
        host.sendCompose()
        #expect(writes.all.map(\.bytes) == [b("\u{1b}[200~fix the tests\u{1b}[201~")])
        #expect(writes.all.map(\.then) == [[0x0d]])
        // Several lines are one paste, one write.
        type(host, "first line\nsecond line")
        host.sendCompose()
        #expect(writes.all.last?.bytes == b("\u{1b}[200~first line\nsecond line\u{1b}[201~"))
    }

    @Test func longTextEmojiAndCJKGoAsOneWriteOfTheirBytes() {
        let (host, writes, _) = makeHost(Self.bracketed)
        let text = String(repeating: "x", count: 9_996) + "😀漢字"
        #expect(text.count == 9_999)
        type(host, text)
        host.sendCompose()
        #expect(writes.all.count == 1)
        #expect(writes.all.first?.bytes == b("\u{1b}[200~") + b(text) + b("\u{1b}[201~"))
    }

    @Test func severalLinesWithoutBracketedPasteAreAskedAboutFirst() {
        let (host, writes, _) = makeHost()
        var asked: [String] = []
        var yes = false
        host.confirmPaste = { text, answer in
            asked.append(text)
            answer(yes)
        }
        type(host, "echo a\necho b")
        host.sendCompose()
        #expect(asked == ["echo a\necho b"])
        #expect(writes.all.isEmpty, "declined: nothing sent")
        #expect(host.keyBar.compose.field.text == "echo a\necho b", "and the draft stays")
        yes = true
        host.sendCompose()
        #expect(writes.all.map(\.bytes) == [b("echo a\recho b")], "each line end is Return, as a paste's")
        #expect(host.keyBar.compose.field.text.isEmpty)
    }

    @Test func anEmptyFieldSendsNothing() {
        let (host, writes, _) = makeHost()
        host.sendCompose()
        #expect(writes.all.isEmpty)
    }

    @Test func aMessageTheFenceDroppedComesBackIntoAnEmptyField() {
        let (host, _, _) = makeHost()
        host.lastComposeSend = ("keep me", CACurrentMediaTime())
        host.composeInputDropped()
        #expect(host.keyBar.compose.field.text == "keep me")
        #expect(host.composeSlot.text == "keep me")
        // Never over a new draft, and only once.
        type(host, "new")
        host.lastComposeSend = ("old", CACurrentMediaTime())
        host.composeInputDropped()
        #expect(host.keyBar.compose.field.text == "new")
        // Too long ago: nothing.
        type(host, "")
        host.lastComposeSend = ("old", CACurrentMediaTime() - TerminalHost.composeRestoreWindow - 1)
        host.composeInputDropped()
        #expect(host.keyBar.compose.field.text.isEmpty)
    }

    @Test func eachPaneKeepsItsDraftAndWhetherComposeIsOpen() {
        let slots = ComposeSlots()
        let a = TerminalHostPool.Key(server: UUID(), session: "s", block: "a")
        let other = TerminalHostPool.Key(server: a.server, session: "s", block: "b")
        let (first, _, _) = makeHost()
        first.composeSlot = slots.slot(for: a)
        first.openCompose()
        type(first, "half a thought")
        // The host goes (parked, evicted); a new one for the same pane shows the draft, open.
        let (again, _, _) = makeHost()
        again.composeSlot = slots.slot(for: a)
        #expect(again.keyBar.composeOpen)
        #expect(again.keyBar.compose.field.text == "half a thought")
        // Another pane has its own.
        let (next, _, _) = makeHost()
        next.composeSlot = slots.slot(for: other)
        #expect(!next.keyBar.composeOpen)
        #expect(next.keyBar.compose.field.text.isEmpty)
        // A pane whose session closed lets its draft go.
        slots.drop { $0.block == "a" }
        #expect(slots.slot(for: a).text.isEmpty)
    }

    @Test func composeOpensAndClosesWithItsKeyAndMakesTheBarTallerOnce() {
        let (host, _, _) = makeHost()
        #expect(!host.keyBar.composeOpen)
        host.keyBar.fire("compose")
        #expect(host.composeSlot.open && host.keyBar.composeOpen)
        #expect(!host.keyBar.compose.isHidden)
        #expect(KeyBar.height(compact: false, composeOpen: true) == KeyBar.barHeight + ComposeCard.height(compact: false) + KeyBar.cardGap)
        #expect(KeyBar.height(compact: true, composeOpen: true) == KeyBar.compactBarHeight + ComposeCard.height(compact: true) + KeyBar.cardGap)
        let compose = host.keyBar.allCaps.first { $0.key == "compose" }
        #expect(compose?.accessibilityValue == "Open")
        host.keyBar.fire("compose")
        #expect(!host.composeSlot.open && !host.keyBar.composeOpen)
        #expect(host.keyBar.compose.isHidden)
        #expect(compose?.accessibilityValue == nil)
    }

    @Test func aKeyTypedWithTheBarsCtrlGoesToThePaneNotTheMessage() {
        let (host, _, spy) = makeHost()
        let card = host.keyBar.compose
        #expect(card.takesModifiedKey?("c") == false, "no modifier: the field types it")
        host.keyBar.fire("ctrl")
        #expect(card.takesModifiedKey?("c") == true)
        #expect(spy.sent.last == [0x03])
        #expect(host.keyBar.ctrl == .off, "the one-shot ctrl is used up")
    }

    @Test func theCardsButtonsSpeak() {
        let (host, _, _) = makeHost()
        host.refreshFiles()
        let card = host.keyBar.compose
        let labels = (card.accessibilityElements as? [NSObject])?.compactMap(\.accessibilityLabel) ?? []
        #expect(labels == ["Close Compose", ComposePlaceholder.plain, "Attach", "Send"])
    }

    @Test func barKeysThatTypeText() {
        for key in ["~", "|", "..", "1", ":", "x"] { #expect(KeyBar.composeText(for: key) == key, "\(key)") }
        for key in ["esc", "tab", "shift-tab", "enter", "ctrl-c", "f1", "up", "backspace", "paste", "ctrl", "shift"] {
            #expect(KeyBar.composeText(for: key) == nil, "\(key)")
        }
    }
}

/// What compose's empty field says.
struct ComposePlaceholderTests {
    @Test func theAgentOrTheProgramAndTheFolder() {
        #expect(ComposePlaceholder.text(agent: .claude, program: "node", pwd: "/Users/abe/pteron") == "Message Claude Code ~/pteron")
        #expect(ComposePlaceholder.text(agent: .codex, program: nil, pwd: "/home/abe/src/app") == "Message Codex ~/src/app")
        #expect(ComposePlaceholder.text(agent: nil, program: "zsh", pwd: "/Users/abe") == "Message zsh ~")
        #expect(ComposePlaceholder.text(agent: nil, program: "vim", pwd: "/etc") == "Message vim /etc")
        #expect(ComposePlaceholder.text(agent: nil, program: " ", pwd: nil) == "Message")
        #expect(ComposePlaceholder.text(agent: nil, program: nil, pwd: nil) == "Message")
        #expect(ComposePlaceholder.folder("file:///Users/abe/x/") == "~/x")
    }
}
