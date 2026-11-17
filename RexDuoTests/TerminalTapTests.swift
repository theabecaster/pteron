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
    private func decide(_ facts: Facts, engine: Bool = false, mouse: Bool = false, cursor: Bool = false)
        -> (outcome: TerminalTapOutcome, asked: [String]) {
        var asked: [String] = []
        let outcome = TerminalTapDecision.outcome(
            facts,
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
            // 3. No keyboard on this pane: focus, and nothing else, even over a link or in a mouse program.
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
    }

    func testTheEngineAndTheTerminalAreAskedOnlyWhenTheTapGetsThatFar() {
        // A link must not open, and no lock is taken, for a tap that means something earlier.
        XCTAssertEqual(decide(Facts(onHandle: true)).asked, [])
        XCTAssertEqual(decide(Facts(tapCount: 2)).asked, [])
        XCTAssertEqual(decide(Facts(keyboardUp: false), engine: true).asked, [])
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

    func testTheTapThatBringsTheKeyboardIsNeverAClickForAMouseProgram() {
        let (host, spy) = makeHost(mouseProgram + "menu")
        let point = CGPoint(x: 20, y: 20)
        // The suspected defect: the focusing tap reached a program that tracks the mouse.
        XCTAssertEqual(host.tap(at: point, shift: false, keyboardUp: false, hadSelection: false), .focus(clearsSelection: false))
        XCTAssertEqual(spy.sent, [], "no click for the tap that only focused")
        // And nothing is left behind to eat the next tap: a second tap far away, at once, clicks.
        let next = CGPoint(x: 200, y: 100)
        XCTAssertEqual(host.tap(at: next, shift: false, keyboardUp: true, hadSelection: false), .programClick)
        XCTAssertEqual(spy.sent.count, 1)
        XCTAssertTrue(spy.sent[0].starts(with: Array("\u{1b}[<0;".utf8)), "an SGR left press")
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
}
