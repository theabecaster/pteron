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
    }

    @Test func sendClosesComposeAsItsKeyDoesAndClearsTheDraft() {
        let (host, writes, _) = makeHost()
        host.openCompose()
        type(host, "make test")
        host.sendCompose()
        #expect(writes.all.count == 1)
        #expect(!host.composeSlot.open && !host.keyBar.composeOpen && !host.term.composeOpen, "closed as ✎ closes it")
        #expect(host.keyBar.compose.isHidden)
        #expect(host.composeSlot.text.isEmpty && host.keyBar.compose.field.text.isEmpty)
        // Declined: nothing went, so compose stays open with the draft.
        var answered = false
        host.confirmPaste = { _, answer in answered = true; answer(false) }
        host.openCompose()
        type(host, "echo a\necho b")
        host.sendCompose()
        #expect(answered && writes.all.count == 1)
        #expect(host.composeSlot.open && host.composeSlot.text == "echo a\necho b")
    }

    @Test func aSendTheFenceDroppedOpensComposeAgainWithIt() {
        let (host, _, _) = makeHost()
        host.openCompose()
        type(host, "keep me")
        host.sendCompose()
        #expect(!host.composeSlot.open)
        // As if the send had gone behind the fence and the fence dropped it.
        host.lastComposeSend = ("keep me", CACurrentMediaTime())
        host.composeInputDropped()
        #expect(host.composeSlot.open && host.keyBar.composeOpen, "open again")
        #expect(host.keyBar.compose.field.text == "keep me" && host.composeSlot.text == "keep me")
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

/// The handle's drag: when it begins and when letting go closes compose.
struct ComposeDragTests {
    private let handle = CGRect(x: 0, y: 0, width: 390, height: ComposeDrag.handleHeight)
    private let start = CGPoint(x: 195, y: 10)

    private func begins(to dx: CGFloat, _ dy: CGFloat, velocity: CGPoint = .zero, from start: CGPoint? = nil,
                        buttons: [CGRect] = []) -> Bool {
        let s = start ?? self.start
        return ComposeDrag.begins(from: s, to: CGPoint(x: s.x + dx, y: s.y + dy), velocity: velocity, handle: handle, buttons: buttons)
    }

    @Test func aSlowDragDownBegins() {
        // UIKit begins a pan about 10 pt from the touch; a slow drag has almost no velocity.
        #expect(begins(to: 0, 10))
        #expect(begins(to: 3, 10, velocity: .zero))
        #expect(begins(to: -4, 11, velocity: CGPoint(x: 0, y: 2)))
        // Into the field below the handle: it started in the handle.
        #expect(begins(to: 0, 40))
    }

    @Test func sidewaysOrUpDoesNotBegin() {
        #expect(!begins(to: 10, 0))
        #expect(!begins(to: -10, 3))
        #expect(!begins(to: 10, 9, velocity: CGPoint(x: 0, y: 900)), "more sideways: the velocity doesn't overrule it")
        #expect(!begins(to: 0, -10))
        #expect(!begins(to: 2, -10, velocity: CGPoint(x: 0, y: 300)))
    }

    @Test func theVelocityOnlyBreaksATie() {
        #expect(begins(to: 0, 0, velocity: CGPoint(x: 0, y: 40)))
        #expect(!begins(to: 0, 0, velocity: CGPoint(x: 40, y: 0)))
        #expect(!begins(to: 0, 0, velocity: .zero))
        #expect(begins(to: 7, 7, velocity: CGPoint(x: 1, y: 30)))
        #expect(!begins(to: 7, 7, velocity: CGPoint(x: 30, y: 1)))
    }

    @Test func startingInTheFieldOrOnAButtonDoesNotBegin() {
        #expect(!begins(to: 0, 10, from: CGPoint(x: 195, y: 50)), "in the field, below the handle")
        #expect(!begins(to: 0, 10, from: CGPoint(x: 195, y: -2)))
        let send = CGRect(x: 346, y: 8, width: 36, height: 36)
        #expect(!begins(to: 0, 10, from: CGPoint(x: 360, y: 20), buttons: [send]))
        #expect(begins(to: 0, 10, from: CGPoint(x: 300, y: 20), buttons: [send]))
    }

    @Test func lettingGoClosesPastTheDistanceOrOnAFlick() {
        #expect(ComposeDrag.closes(drop: 40, speed: 0))
        #expect(ComposeDrag.closes(drop: 6, speed: 900))
        #expect(!ComposeDrag.closes(drop: 14, speed: 40))
        #expect(!ComposeDrag.closes(drop: 0, speed: 0))
    }
}

/// A pan whose touches are scripted: where the finger is, and how fast.
private final class ScriptedPan: UIPanGestureRecognizer {
    var at = CGPoint.zero
    var startAt = CGPoint.zero
    var speed = CGPoint.zero
    var scripted: UIGestureRecognizer.State = .possible
    override var state: UIGestureRecognizer.State {
        get { scripted }
        set { scripted = newValue }
    }
    override func location(in view: UIView?) -> CGPoint { at }
    override func translation(in view: UIView?) -> CGPoint { CGPoint(x: at.x - startAt.x, y: at.y - startAt.y) }
    override func velocity(in view: UIView?) -> CGPoint { speed }
}

/// The handle on a card laid out as on screen, driven by a scripted finger through the card's
/// own recognizer methods and into the host, as a drag on the phone is.
@MainActor
struct ComposeHandleTests {
    private func openHost(compact: Bool = false) -> (TerminalHost, ComposeCard) {
        let control = RexControl(address: "", client: ClientInfo(name: "test", version: "0", label: "test"))
        let host = TerminalHost(stream: TerminalStream(control: control, sessionID: "s", blockID: "b"), sizing: .mirror,
                                fontSize: 12, theme: ThemeStore.fallback)
        host.composeWrite = { _, _ in }
        host.openCompose()
        let card = host.keyBar.compose
        card.compact = compact
        card.frame = CGRect(x: 0, y: 0, width: 390, height: ComposeCard.height(compact: compact))
        card.layoutIfNeeded()
        return (host, card)
    }

    /// A drag from `from` down by `drop` in `steps` moves, then let go at `release` points a second.
    /// False when the card's recognizer didn't begin.
    private func drag(_ card: ComposeCard, from: CGPoint, drop: CGFloat, steps: Int = 8, speed: CGFloat,
                      release: CGFloat, during: (CGFloat) -> Void = { _ in }) -> Bool {
        let pan = ScriptedPan()
        card.addGestureRecognizer(pan)
        defer { card.removeGestureRecognizer(pan) }
        pan.startAt = from
        // UIKit asks about 10 pt in.
        pan.at = CGPoint(x: from.x, y: from.y + min(10, drop))
        pan.speed = CGPoint(x: 0, y: speed)
        guard card.gestureRecognizerShouldBegin(pan) else { return false }
        pan.scripted = .began
        card.panned(pan)
        for i in 1...steps {
            pan.at = CGPoint(x: from.x, y: from.y + drop * CGFloat(i) / CGFloat(steps))
            pan.scripted = .changed
            card.panned(pan)
            during(pan.at.y - from.y)
        }
        pan.speed = CGPoint(x: 0, y: release)
        pan.scripted = .ended
        card.panned(pan)
        return true
    }

    @Test func aSlowDragDownTheHandleClosesComposeAsItsKeyDoes() {
        let (host, card) = openHost()
        card.show(text: "draft")
        host.composeSlot.text = "draft"
        let follows = !UIAccessibility.isReduceMotionEnabled
        var moved: [CGFloat] = []
        let began = drag(card, from: CGPoint(x: 195, y: 10), drop: 60, speed: 40, release: 30) { _ in moved.append(card.transform.ty) }
        #expect(began, "a slow drag begins")
        if follows { #expect(moved.last == 60, "the card follows the finger") } else { #expect(moved.allSatisfy { $0 == 0 }) }
        #expect(!host.composeSlot.open && !host.keyBar.composeOpen && !host.term.composeOpen, "closed")
        #expect(card.transform == .identity)
        #expect(host.composeSlot.text == "draft" && card.field.text == "draft", "the draft stays")
    }

    @Test func aShortDragSettlesBack() {
        let (host, card) = openHost()
        #expect(drag(card, from: CGPoint(x: 195, y: 10), drop: 14, speed: 40, release: 20))
        #expect(host.composeSlot.open && host.keyBar.composeOpen, "still open")
    }

    @Test func aFlickClosesIt() {
        let (host, card) = openHost()
        #expect(drag(card, from: CGPoint(x: 195, y: 6), drop: 20, steps: 2, speed: 1_400, release: 1_500))
        #expect(!host.composeSlot.open)
    }

    @Test func aDragInTheFieldIsTheFields() {
        let (host, card) = openHost()
        let inField = CGPoint(x: card.field.frame.midX, y: card.field.frame.midY)
        #expect(inField.y > ComposeDrag.handleHeight)
        #expect(!drag(card, from: inField, drop: 60, speed: 40, release: 30))
        #expect(host.composeSlot.open)
    }

    @Test func theHandleIsAThumbTallAcrossTheTopOfEitherCard() {
        for compact in [false, true] {
            let (host, card) = openHost(compact: compact)
            #expect(card.handleArea == CGRect(x: 0, y: 0, width: 390, height: 30), "compact \(compact)")
            #expect(drag(card, from: CGPoint(x: 120, y: 26), drop: 50, speed: 50, release: 10), "compact \(compact)")
            #expect(!host.composeSlot.open, "compact \(compact)")
        }
    }
}
