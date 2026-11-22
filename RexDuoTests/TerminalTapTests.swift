import RexKit
import XCTest
@testable import RexDuo

@MainActor
private final class SendSpy: TerminalEngineDelegate {
    var sent: [[UInt8]] = []
    func engineGridChanged(cols: Int, rows: Int) {}
    func engineSend(_ bytes: [UInt8]) { sent.append(bytes) }
}

/// What a tap on a pane does: one decision, in one order, from what was true at touch time.
@MainActor
final class TerminalTapTests: XCTestCase {
    private typealias Facts = TerminalTapFacts

    /// The decision with every later question answered, and which of them were asked.
    private func decide(_ facts: Facts, link: Bool = false, engine: Bool = false, mouse: Bool = false, cursor: Bool = false)
        -> (outcome: TerminalTapOutcome, asked: [String]) {
        var asked: [String] = []
        let outcome = TerminalTapDecision.outcome(
            facts,
            opensLink: { asked.append("link"); return link },
            engineUses: { asked.append("engine"); return engine },
            tracksMouse: { asked.append("mouse"); return mouse },
            nearCursor: { asked.append("cursor"); return cursor })
        return (outcome, asked)
    }

    func testTheOrderOfEverythingATapCanMean() {
        // Each row: the facts, the answers of the engine / mouse mode / cursor zone, the outcome.
        let rows: [(Facts, Bool, Bool, Bool, TerminalTapOutcome)] = [
            // 1. A handle is the handle's, whatever else is true.
            (Facts(onHandle: true, tapCount: 2, keyboardUp: false, hadSelection: true), true, true, true, .handle),
            // 2. The second and third tap select, focused or not, selection or not, mouse program or not.
            (Facts(tapCount: 2), true, true, true, .select(line: false)),
            (Facts(tapCount: 3), true, true, true, .select(line: true)),
            (Facts(tapCount: 2, keyboardUp: false, hadSelection: true, shift: true), true, true, true, .select(line: false)),
            // 3. No keyboard on this pane: focus, and nothing else, even over the prompt or in a mouse
            //    program (a link is `testWithTheKeyboardDownALinkOpensAndPlainTextFocuses`).
            (Facts(keyboardUp: false), true, true, true, .focus(clearsSelection: false)),
            (Facts(keyboardUp: false, hadSelection: true), true, true, true, .focus(clearsSelection: true)),
            (Facts(keyboardUp: false, shift: true, menuVisible: true), true, true, true, .focus(clearsSelection: false)),
            // 4. A selection is dismissed before the engine, the program or the menu get the tap.
            (Facts(hadSelection: true), true, true, true, .dismissSelection),
            (Facts(hadSelection: true, shift: true), true, true, true, .dismissSelection),
            // 5. Shift keeps the tap from everything.
            (Facts(shift: true), true, true, true, .nothing),
            // 6. A link or the shell's prompt, also in a mouse program and by the cursor.
            (Facts(), true, true, true, .engineUsed),
            (Facts(menuVisible: true), true, false, false, .engineUsed),
            // 7. A click for a program that tracks the mouse, also by the cursor.
            (Facts(), false, true, true, .programClick),
            (Facts(menuVisible: true), false, true, false, .programClick),
            // 8. Paste by the cursor, unless a menu is up.
            (Facts(), false, false, true, .pasteMenu),
            (Facts(menuVisible: true), false, false, true, .nothing),
            // 9. Nothing.
            (Facts(), false, false, false, .nothing),
        ]
        for (i, row) in rows.enumerated() {
            XCTAssertEqual(decide(row.0, engine: row.1, mouse: row.2, cursor: row.3).outcome, row.4, "row \(i)")
        }
        // Only a click is ever for the program.
        let all: [TerminalTapOutcome] = [.handle, .select(line: false), .select(line: true), .focus(clearsSelection: false),
                                         .focus(clearsSelection: true), .dismissSelection, .engineUsed, .pasteMenu, .nothing]
        XCTAssertTrue(all.allSatisfy { !$0.isForProgram })
        XCTAssertTrue(TerminalTapOutcome.programClick.isForProgram)
        XCTAssertTrue(TerminalTapOutcome.programClickThenKeyboard.isForProgram)
    }

    /// Step 3 on the active pane: with the keyboard down, a tap in a program that tracks the
    /// mouse is a click, and the keyboard follows it.
    func testWithTheKeyboardDownATapOnTheActivePaneIsAClickInAMouseProgram() {
        let down = Facts(keyboardUp: false, active: true)
        XCTAssertEqual(decide(down, mouse: true).outcome, .programClickThenKeyboard)
        XCTAssertEqual(decide(down, mouse: true).asked, ["link", "mouse"], "no prompt move, no menu")
        // A link under the finger still wins, and the keyboard stays down.
        XCTAssertEqual(decide(down, link: true, mouse: true).outcome, .engineUsed)
        XCTAssertEqual(decide(down, link: true, mouse: true).asked, ["link"])
        // A program that does not track the mouse: the tap focuses, as it always did.
        XCTAssertEqual(decide(down, engine: true, cursor: true).outcome, .focus(clearsSelection: false))
        // A pane that is not the active one is only made active and focused.
        XCTAssertEqual(decide(Facts(keyboardUp: false), mouse: true).outcome, .focus(clearsSelection: false))
        XCTAssertEqual(decide(Facts(keyboardUp: false), mouse: true).asked, ["link"], "the mouse mode is not even read")
        // VoiceOver: a tap only focuses.
        XCTAssertEqual(decide(Facts(keyboardUp: false, active: true, voiceOver: true), mouse: true).outcome, .focus(clearsSelection: false))
        // Shift, and a tap that clears a selection, keep the tap from the program.
        XCTAssertEqual(decide(Facts(keyboardUp: false, shift: true, active: true), mouse: true).outcome, .focus(clearsSelection: false))
        XCTAssertEqual(decide(Facts(keyboardUp: false, shift: true, active: true), mouse: true).asked, [])
        XCTAssertEqual(decide(Facts(keyboardUp: false, hadSelection: true, active: true), mouse: true).outcome, .focus(clearsSelection: true))
        // A tap that catches a scroll does nothing, and the second tap of a double tap selects.
        XCTAssertEqual(decide(Facts(keyboardUp: false, stopsScroll: true, active: true), mouse: true).outcome, .nothing)
        XCTAssertEqual(decide(Facts(tapCount: 2, keyboardUp: false, active: true), mouse: true).outcome, .select(line: false))
        // With the keyboard up nothing changed: VoiceOver or not, active or not.
        XCTAssertEqual(decide(Facts(active: true, voiceOver: true), mouse: true).outcome, .programClick)
    }

    func testTheEngineAndTheTerminalAreAskedOnlyWhenTheTapGetsThatFar() {
        // A link must not open, and no lock is taken, for a tap that means something earlier.
        XCTAssertEqual(decide(Facts(onHandle: true)).asked, [])
        XCTAssertEqual(decide(Facts(tapCount: 2)).asked, [])
        XCTAssertEqual(decide(Facts(keyboardUp: false), engine: true).asked, ["link"])
        XCTAssertEqual(decide(Facts(keyboardUp: false, hadSelection: true), link: true).asked, [])
        XCTAssertEqual(decide(Facts(keyboardUp: false, shift: true), link: true).asked, [])
        XCTAssertEqual(decide(Facts(stopsScroll: true), link: true).asked, [])
        XCTAssertEqual(decide(Facts(hadSelection: true), engine: true).asked, [])
        XCTAssertEqual(decide(Facts(shift: true), engine: true).asked, [])
        XCTAssertEqual(decide(Facts(), engine: true).asked, ["engine"])
        XCTAssertEqual(decide(Facts(), mouse: true).asked, ["engine", "mouse"])
        XCTAssertEqual(decide(Facts()).asked, ["engine", "mouse", "cursor"])
        XCTAssertEqual(decide(Facts(menuVisible: true)).asked, ["engine", "mouse"])
    }

    // MARK: Through the host

    private func makeHost(_ setup: String) -> (TerminalHost, SendSpy) {
        let control = RexControl(address: "", client: ClientInfo(name: "test", version: "0", label: "test"))
        let host = TerminalHost(stream: TerminalStream(control: control, sessionID: "s", blockID: "b"), sizing: .mirror,
                                fontSize: 12, theme: ThemeStore.fallback)
        // What the engine sends is recorded instead of going to the stream.
        let spy = SendSpy()
        host.term.engineDelegate = spy
        host.term.setGrid(cols: 40, rows: 10, force: true)
        let cell = host.term.cellSize
        host.term.frame = CGRect(x: 0, y: 0, width: cell.width * 40, height: cell.height * 10)
        host.term.layoutIfNeeded()
        host.term.feed(text: setup)
        let view = host.term
        view.core.sync()
        _ = view.renderer.frame.update(core: view.core)
        view.scroller.apply(view.core.scroll.snapshot)
        return (host, spy)
    }

    private let mouseProgram = "\u{1b}[?1000h\u{1b}[?1006h"

    private func show(_ bytes: [UInt8]) -> String { String(decoding: bytes, as: UTF8.self) }

    /// The cell under `point`, 1-based, as a mouse report names it.
    private func cell(_ host: TerminalHost, _ point: CGPoint) -> (col: Int, row: Int) {
        let size = host.term.cellSize
        return (Int(point.x / size.width) + 1, Int(point.y / size.height) + 1)
    }

    func testWithTheKeyboardDownATapOnTheActivePaneClicksOnce() {
        let (host, spy) = makeHost(mouseProgram + "\u{1b}[?1004h" + "menu")
        host.isActive = true
        let point = CGPoint(x: 20, y: 20)
        let at = cell(host, point)
        XCTAssertEqual(host.tap(at: point, shift: false, keyboardUp: false, hadSelection: false), .programClickThenKeyboard)
        // Press and release in one write, and nothing else: no focus report goes with a tap.
        XCTAssertEqual(spy.sent.map(show), ["\u{1b}[<0;\(at.col);\(at.row)M\u{1b}[<0;\(at.col);\(at.row)m"])
        // A second tap far away, with the keyboard up by now, clicks as before.
        let next = CGPoint(x: 200, y: 100)
        XCTAssertEqual(host.tap(at: next, shift: false, keyboardUp: true, hadSelection: false), .programClick)
        XCTAssertEqual(spy.sent.count, 2)
    }

    func testTheClickOfAProgramWithoutSGRReportsIsTheLegacyOne() {
        // Mode 1000 alone: `ESC [ M`, then the button, the column and the row, each plus 32.
        let (host, spy) = makeHost("\u{1b}[?1000h")
        host.isActive = true
        let point = CGPoint(x: 20, y: 20)
        let at = cell(host, point)
        XCTAssertEqual(host.tap(at: point, shift: false, keyboardUp: false, hadSelection: false), .programClickThenKeyboard)
        let press: [UInt8] = [0x1b, 0x5b, 0x4d, 32, UInt8(32 + at.col), UInt8(32 + at.row)]
        let release: [UInt8] = [0x1b, 0x5b, 0x4d, 35, UInt8(32 + at.col), UInt8(32 + at.row)]
        XCTAssertEqual(spy.sent, [press + release])
    }

    func testWithTheKeyboardDownOnlyTheActivePanesTapIsAClick() {
        let point = CGPoint(x: 20, y: 20)
        // A pane that is not the active one: the tap makes it active and focuses it.
        let (other, otherSpy) = makeHost(mouseProgram + "menu")
        var focused = 0
        other.onFocus = { focused += 1 }
        XCTAssertEqual(other.tap(at: point, shift: false, keyboardUp: false, hadSelection: false), .focus(clearsSelection: false))
        XCTAssertEqual(focused, 1)
        XCTAssertEqual(otherSpy.sent, [], "no click for the tap that made the pane the active one")
        // VoiceOver: a tap only focuses.
        let (spoken, spokenSpy) = makeHost(mouseProgram + "menu")
        spoken.isActive = true
        spoken.voiceOver = { true }
        XCTAssertEqual(spoken.tap(at: point, shift: false, keyboardUp: false, hadSelection: false), .focus(clearsSelection: false))
        XCTAssertEqual(spokenSpy.sent, [])
        // A program that does not track the mouse.
        let (shell, shellSpy) = makeHost("$ ")
        shell.isActive = true
        XCTAssertEqual(shell.tap(at: point, shift: false, keyboardUp: false, hadSelection: false), .focus(clearsSelection: false))
        XCTAssertEqual(shellSpy.sent, [])
    }

    func testWithTheKeyboardDownShiftASelectionAndACaughtScrollKeepTheTapFromTheProgram() {
        let (host, spy) = makeHost(mouseProgram + "some words here")
        host.isActive = true
        let point = CGPoint(x: 200, y: 100)
        XCTAssertEqual(host.tap(at: point, shift: true, keyboardUp: false, hadSelection: false), .focus(clearsSelection: false))
        XCTAssertEqual(host.tap(at: CGPoint(x: 20, y: 60), shift: false, keyboardUp: false, hadSelection: false, stopsScroll: true), .nothing)
        host.term.beginSelection(at: CGPoint(x: 10, y: 8), word: true)
        host.term.endSelectionDrag()
        XCTAssertTrue(host.term.hasActiveSelection)
        XCTAssertEqual(host.tap(at: CGPoint(x: 120, y: 30), shift: false, keyboardUp: false, hadSelection: true), .focus(clearsSelection: true))
        XCTAssertFalse(host.term.hasActiveSelection)
        XCTAssertEqual(spy.sent, [])
    }

    /// A double tap with the keyboard down: the first tap clicks, the second selects the word.
    func testWithTheKeyboardDownADoubleTapClicksOnceAndSelects() {
        let (host, spy) = makeHost(mouseProgram + "some words here")
        host.isActive = true
        let size = host.term.cellSize
        let point = CGPoint(x: size.width * 6.5, y: size.height * 0.5)
        XCTAssertEqual(host.tap(at: point, shift: false, keyboardUp: false, hadSelection: false), .programClickThenKeyboard)
        XCTAssertEqual(host.tap(at: point, shift: false, keyboardUp: false, hadSelection: false), .select(line: false))
        XCTAssertEqual(spy.sent.count, 1, "only the first tap clicked")
        XCTAssertEqual(host.term.selectedText, "words")
    }

    /// A row of the scrollback is no place in the program: the tap makes no click, and what
    /// waits for the click hears that none went.
    func testATapOnARowOfTheScrollbackSendsNothing() {
        let lines = (1...40).map { "\($0) line\r\n" }.joined()
        let (host, spy) = makeHost(lines + mouseProgram)
        let view = host.term
        view.scroller.jump(.lines(-4))
        view.core.sync()
        _ = view.renderer.frame.update(core: view.core)
        view.scroller.apply(view.core.scroll.snapshot)
        XCTAssertFalse(view.core.scroll.snapshot.active)
        var heard: [Bool] = []
        view.sendClickToProgram(at: CGPoint(x: 20, y: view.cellSize.height * 0.5)) { heard.append($0) }
        XCTAssertEqual(heard, [false])
        XCTAssertEqual(spy.sent, [])
        // A row of the live screen below it clicks.
        view.sendClickToProgram(at: CGPoint(x: 20, y: view.cellSize.height * 6.5)) { heard.append($0) }
        XCTAssertEqual(heard, [false, true])
        XCTAssertEqual(spy.sent.count, 1)
    }

    /// A click is not typing on the line the keyboard mirrors: the mirror starts over.
    func testAClickResetsTheKeyboardsMirroredInput() {
        let (host, spy) = makeHost(mouseProgram)
        host.term.insertText("ab")
        XCTAssertTrue(host.term.hasText)
        host.term.sendClickToProgram(at: CGPoint(x: 20, y: 20))
        XCTAssertFalse(host.term.hasText)
        XCTAssertEqual(spy.sent.count, 2, "the typed text and the click")
    }

    func testTheEnginesOwnTapNeverFiresUnderAHost() {
        // The host sends the click itself, so the engine's recognizer is always refused: the
        // order of the two recognizers can't matter. Also before anything was touched, and
        // whatever a tap changed.
        let (host, _) = makeHost(mouseProgram)
        XCTAssertEqual(host.term.tapGate?(), false)
        _ = host.tap(at: CGPoint(x: 20, y: 20), shift: false, keyboardUp: false, hadSelection: false)
        XCTAssertEqual(host.term.tapGate?(), false)
        _ = host.tap(at: CGPoint(x: 200, y: 100), shift: false, keyboardUp: true, hadSelection: false)
        XCTAssertEqual(host.term.tapGate?(), false)
    }

    func testATapThatClearsASelectionIsNotAClick() {
        let (host, spy) = makeHost(mouseProgram + "some words here")
        host.term.beginSelection(at: CGPoint(x: 10, y: 8), word: true)
        host.term.endSelectionDrag()
        XCTAssertTrue(host.term.hasActiveSelection)
        XCTAssertEqual(host.tap(at: CGPoint(x: 200, y: 100), shift: false, keyboardUp: true, hadSelection: true), .dismissSelection)
        XCTAssertFalse(host.term.hasActiveSelection)
        XCTAssertEqual(spy.sent, [])
    }

    func testADoubleTapSelectsAndItsSecondTapIsNotAClick() {
        let (host, spy) = makeHost(mouseProgram + "some words here")
        let cell = host.term.cellSize
        let point = CGPoint(x: cell.width * 6.5, y: cell.height * 0.5)
        XCTAssertEqual(host.tap(at: point, shift: false, keyboardUp: true, hadSelection: false), .programClick)
        XCTAssertEqual(host.tap(at: point, shift: false, keyboardUp: true, hadSelection: false), .select(line: false))
        XCTAssertEqual(spy.sent.count, 1, "only the first tap clicked")
        XCTAssertEqual(host.term.selectedText, "words")
    }

    func testShiftKeepsATapFromTheProgram() {
        let (host, spy) = makeHost(mouseProgram)
        XCTAssertEqual(host.tap(at: CGPoint(x: 20, y: 20), shift: true, keyboardUp: true, hadSelection: false), .nothing)
        XCTAssertEqual(spy.sent, [])
    }

    /// A tap that catches a scroll does nothing at all, even where it would focus, open a link,
    /// click in a mouse program or show Paste. Only a handle comes before it.
    func testATapThatStopsAScrollDoesNothing() {
        let stops = [
            Facts(keyboardUp: false, stopsScroll: true),
            Facts(hadSelection: true, stopsScroll: true),
            Facts(tapCount: 2, stopsScroll: true),
            Facts(stopsScroll: true),
        ]
        for facts in stops {
            let (outcome, asked) = decide(facts, engine: true, mouse: true, cursor: true)
            XCTAssertEqual(outcome, .nothing, "\(facts)")
            XCTAssertEqual(asked, [], "a tap that stops a scroll asks the engine nothing")
        }
        XCTAssertEqual(decide(Facts(onHandle: true, stopsScroll: true)).outcome, .handle)
    }

    func testATapCatchesAScrollWhileItMovesAndJustAfter() {
        typealias Rule = TerminalScrollTouch
        XCTAssertEqual(Rule.settle, 0.15, "short, so a link just scrolled into view opens on the next tap")
        XCTAssertTrue(Rule.stopsScroll(now: 10, moving: true, lastMoved: nil))
        XCTAssertTrue(Rule.stopsScroll(now: 10, moving: false, lastMoved: 10 - Rule.settle + 0.01))
        XCTAssertFalse(Rule.stopsScroll(now: 10, moving: false, lastMoved: 10 - Rule.settle - 0.01))
        XCTAssertFalse(Rule.stopsScroll(now: 10, moving: false, lastMoved: nil))
    }

    // MARK: Links

    func testWithTheKeyboardDownALinkOpensAndPlainTextFocuses() {
        // Step 3: the link is looked up first; the keyboard stays down when one opens.
        XCTAssertEqual(decide(Facts(keyboardUp: false), link: true).outcome, .engineUsed)
        XCTAssertEqual(decide(Facts(keyboardUp: false), link: true).asked, ["link"], "no prompt move, no click, no menu")
        XCTAssertEqual(decide(Facts(keyboardUp: false), link: false, engine: true, mouse: true).outcome, .focus(clearsSelection: false))
        // A tap that clears a selection or holds Shift only focuses, as before.
        XCTAssertEqual(decide(Facts(keyboardUp: false, hadSelection: true), link: true).outcome, .focus(clearsSelection: true))
        XCTAssertEqual(decide(Facts(keyboardUp: false, shift: true), link: true).outcome, .focus(clearsSelection: false))
        // The keyboard up: the link step isn't asked; the engine opens links as before.
        XCTAssertEqual(decide(Facts(), link: true).asked, ["engine", "mouse", "cursor"])
    }

    private let nextDev = "Local:   http://localhost:3000\r\nNetwork: http://10.0.0.246:3000\r\n\r\nplain words here"

    /// The cell's centre, in engine view coordinates.
    private func point(_ host: TerminalHost, col: Int, row: Int) -> CGPoint {
        let rect = host.term.viewportRect(row: row, columns: col..<(col + 1))
        return CGPoint(x: rect.midX, y: rect.midY)
    }

    func testTheKeyboardDownTapOnALinkOpensItAndLeavesTheKeyboardDown() {
        let (host, spy) = makeHost(nextDev)
        var opened: [URL] = []
        host.term.taps.open = { url, _ in opened.append(url) }
        XCTAssertFalse(host.term.isFirstResponder)
        XCTAssertEqual(host.tap(at: point(host, col: 10, row: 0), shift: false, keyboardUp: false, hadSelection: false), .engineUsed)
        XCTAssertEqual(opened, [URL(string: "http://localhost:3000")!])
        XCTAssertFalse(host.term.isFirstResponder, "the keyboard stays down")
        XCTAssertEqual(spy.sent, [])
    }

    func testTheKeyboardDownTapOnPlainTextStillFocuses() {
        let (host, spy) = makeHost(nextDev)
        var opened: [URL] = []
        host.term.taps.open = { url, _ in opened.append(url) }
        XCTAssertEqual(host.tap(at: point(host, col: 3, row: 3), shift: false, keyboardUp: false, hadSelection: false),
                       .focus(clearsSelection: false))
        XCTAssertEqual(opened, [])
        XCTAssertEqual(spy.sent, [])
    }

    func testTheKeyboardUpTapOnALinkOpensItAsBefore() {
        let (host, spy) = makeHost(nextDev)
        var opened: [URL] = []
        host.term.taps.open = { url, _ in opened.append(url) }
        XCTAssertEqual(host.tap(at: point(host, col: 28, row: 1), shift: false, keyboardUp: true, hadSelection: false), .engineUsed)
        XCTAssertEqual(opened, [URL(string: "http://10.0.0.246:3000")!])
        XCTAssertEqual(spy.sent, [])
    }

    /// The phone's Cmd-click: under mouse tracking a tap on an address in the text opens it and
    /// sends the program no click; a tap on plain text still clicks.
    func testUnderMouseTrackingALinkOpensWithNoClickAndPlainTextClicks() {
        let (host, spy) = makeHost(mouseProgram + nextDev)
        var opened: [URL] = []
        host.term.taps.open = { url, _ in opened.append(url) }
        XCTAssertEqual(host.tap(at: point(host, col: 10, row: 0), shift: false, keyboardUp: true, hadSelection: false), .engineUsed)
        XCTAssertEqual(opened, [URL(string: "http://localhost:3000")!])
        XCTAssertEqual(spy.sent, [], "no click for the link")
        XCTAssertEqual(host.tap(at: point(host, col: 3, row: 3), shift: false, keyboardUp: true, hadSelection: false), .programClick)
        XCTAssertEqual(spy.sent.count, 1)
        XCTAssertTrue(spy.sent[0].starts(with: Array("\u{1b}[<0;".utf8)), "an SGR left press")
        XCTAssertEqual(opened.count, 1)
        // With the keyboard down, the link opens there too, and plain text only focuses.
        XCTAssertEqual(host.tap(at: point(host, col: 28, row: 1), shift: false, keyboardUp: false, hadSelection: false), .engineUsed)
        XCTAssertEqual(opened.count, 2)
        XCTAssertEqual(host.tap(at: point(host, col: 3, row: 3), shift: false, keyboardUp: false, hadSelection: false),
                       .focus(clearsSelection: false))
        XCTAssertEqual(spy.sent.count, 1)
    }

    /// A long press still selects an address, also in a mouse program: the way to copy it.
    func testALongPressStillSelectsALinksText() {
        let (host, _) = makeHost(mouseProgram + nextDev)
        host.term.beginSelection(at: point(host, col: 10, row: 0), word: true)
        host.term.endSelectionDrag()
        XCTAssertTrue(host.term.hasActiveSelection)
        XCTAssertEqual(host.tap(at: point(host, col: 10, row: 0), shift: false, keyboardUp: true, hadSelection: true), .dismissSelection)
    }

    func testATapOnAMalformedHyperlinkSaysSo() {
        let (host, spy) = makeHost(mouseProgram + "\u{1b}]8;;not a url\u{1b}\\BAD\u{1b}]8;;\u{1b}\\")
        var notes: [String] = []
        var opened: [URL] = []
        host.term.taps.notify = { notes.append($0) }
        host.term.taps.open = { url, _ in opened.append(url) }
        XCTAssertEqual(host.tap(at: point(host, col: 1, row: 0), shift: false, keyboardUp: true, hadSelection: false), .engineUsed)
        XCTAssertEqual(notes, ["Couldn't open this link: it isn't a web address."])
        XCTAssertEqual(opened, [])
        XCTAssertEqual(spy.sent, [], "never a click instead")
    }

    func testATapJustAfterAScrollCountsAtTheNewSettle() {
        // 0.15 s: a tap 0.1 s after the scrollback moved catches it, one 0.2 s after opens the link.
        typealias Rule = TerminalScrollTouch
        XCTAssertTrue(Rule.stopsScroll(now: 10, moving: false, lastMoved: 9.9))
        XCTAssertFalse(Rule.stopsScroll(now: 10, moving: false, lastMoved: 9.8))
        let (host, _) = makeHost(nextDev)
        var opened: [URL] = []
        host.term.taps.open = { url, _ in opened.append(url) }
        XCTAssertEqual(host.tap(at: point(host, col: 10, row: 0), shift: false, keyboardUp: false, hadSelection: false,
                                stopsScroll: Rule.stopsScroll(now: 10, moving: false, lastMoved: 9.9)), .nothing)
        XCTAssertEqual(opened, [])
        XCTAssertEqual(host.tap(at: point(host, col: 28, row: 1), shift: false, keyboardUp: false, hadSelection: false,
                                stopsScroll: Rule.stopsScroll(now: 10, moving: false, lastMoved: 9.8)), .engineUsed)
        XCTAssertEqual(opened.count, 1)
    }

    /// A reading flick arcs sideways; only a clearly sideways drag swipes panes.
    func testOnlyAClearlySidewaysDragIsHorizontal() {
        typealias Rule = TerminalScrollTouch
        XCTAssertTrue(Rule.isHorizontal(dx: 100, dy: 0))
        XCTAssertTrue(Rule.isHorizontal(dx: -100, dy: 40))
        XCTAssertFalse(Rule.isHorizontal(dx: 100, dy: 60), "about 31 degrees off horizontal scrolls")
        XCTAssertFalse(Rule.isHorizontal(dx: 30, dy: -100))
    }
}
