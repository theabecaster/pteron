import XCTest
@testable import RexKit

/// The prediction engine against a scripted screen (`EchoScript`). Each test checks the overlay
/// after the steps that matter; `history` holds it after every step.
final class EchoPredictorTests: XCTestCase {
    private let zle = EchoInputMode(echo: false, canonical: false)

    /// A prompt `$ ` and a confirmed, proven epoch holding `a` at column 2: the next keys draw.
    private func ready(level: EchoLevel = .slow, markers: Bool = false, cols: Int = 80, rows: Int = 24, row: Int = 0) -> EchoScript {
        let s = EchoScript(level: level, cols: cols, rows: rows)
        s.watchRow = row
        if row > 0 { s.output { $0.cursorY = row } }
        s.prompt(markers: markers)
        s.typeEchoed("a")
        return s
    }

    private func char(_ c: Character) -> EchoInputKind { .char(c.asciiValue!) }

    // MARK: Epochs and acknowledgement

    func testFirstKeyIsTentativeThenPendingGuessesDrawAtOnce() {
        let s = EchoScript()
        s.prompt()
        let k1 = s.key(char("l"))
        XCTAssertNil(s.overlay, "the first key of an epoch is tracked, not drawn")
        let k2 = s.key(char("s"))
        XCTAssertNil(s.overlay)
        s.echo("l")
        XCTAssertNil(s.overlay, "an echo before its write's answer confirms nothing yet")
        s.answer(k1)
        XCTAssertNil(s.overlay, "confirmed, but no reading has shown a line editor yet")
        XCTAssertTrue(s.replyInputMode(zle))
        XCTAssertEqual(s.visible(0), "$ ls", "the pending guess draws as soon as the epoch is confirmed")
        XCTAssertEqual(s.overlay?.cells.map(\.col), [3])
        XCTAssertEqual(s.overlay?.cursor, .init(col: 4, row: 0))
        XCTAssertEqual(s.overlay?.cells.first?.underlined, true)
        s.echo("s")
        XCTAssertNil(s.overlay, "the server shows it")
        s.answer(k2)
        s.key(char("x"))
        XCTAssertEqual(s.guesses, "x", "later guesses in a confirmed epoch draw the frame they are typed")
        XCTAssertEqual(s.p.counters.confirmed, 2)
    }

    func testAcknowledgementRule() {
        let s = ready()
        let arrow = s.key(.boundary(newLine: false))
        let placed = s.p.counters.placed
        let b = s.key(char("b"))
        XCTAssertEqual(s.p.counters.placed, placed, "an earlier write unanswered: a boundary")
        s.answer(b)
        let c = s.key(char("c"))
        XCTAssertEqual(s.p.counters.placed, placed, "answered but not settled: a boundary")
        _ = arrow
        s.answer(c)
        s.settle()
        s.key(char("d"))
        XCTAssertEqual(s.p.counters.placed, placed + 1, "answered and settled: a new tentative epoch")
        XCTAssertNil(s.overlay)
    }

    func testEchoBeforeItsAnswerConfirmsAtTheAnswer() {
        let s = ready()
        let k = s.key(char("b"))
        s.echo("b")
        XCTAssertEqual(s.p.counters.confirmed, 1)
        s.answer(k)
        XCTAssertEqual(s.p.counters.confirmed, 2)
    }

    func testTabThenKey() {
        let s = ready()
        s.type("\t")
        let typed = s.p.counters.placed
        s.key(char("c"))
        // The completion's output lands after the second key was typed.
        s.echo("bc ")
        s.answerAll()
        XCTAssertEqual(s.p.counters.placed, typed, "the key after Tab is a boundary until everything is answered and settled")
        XCTAssertTrue(s.history.suffix(3).allSatisfy { $0 == nil }, "nothing drawn")
    }

    func testSudoTypeaheadLateEcho() {
        let s = ready()
        s.typeEchoed("sudo tr", prove: false)
        s.type("ue")
        XCTAssertEqual(s.guesses, "ue")
        s.type("\r")
        let placed = s.p.counters.placed
        s.type("u")
        XCTAssertEqual(s.p.counters.placed, placed, "an earlier epoch is unconfirmed: the password key is not placed")
        // The echo of `ue` and the Enter land after the first password key.
        s.echo("ue")
        s.echo("\r\nPassword:")
        s.answerAll()
        s.type("pw")
        s.advance(2)
        s.tick()
        s.answerAll()
        s.tick()
        XCTAssertFalse(s.history.contains { $0?.cells.contains { $0.row > 0 } ?? false }, "no password key is ever drawn")
    }

    // MARK: Order of judging

    func testTypoFix() {
        let splits: [[String]] = [
            ["b\u{8} \u{8}c"],
            ["b\u{8} \u{8}", "c"],
            ["b", "\u{8} \u{8}c"],
            ["b", "\u{8} \u{8}", "c"],
            ["b", "\u{8}", " \u{8}", "c"],
            ["b\u{8}\u{1b}[K", "c"],
            ["b", "\u{8}\u{1b}[K", "c"],
            ["b", "\u{8}\u{1b}[Kc"],
        ]
        for chunks in splits {
            let s = ready()
            s.type("b\u{7f}c")
            XCTAssertEqual(s.visible(0), "$ ac")
            for chunk in chunks {
                s.echo(chunk)
                XCTAssertEqual(s.visible(0), "$ ac", "\(chunks): the deleted b never shows")
            }
            s.answerAll()
            s.tick()
            XCTAssertEqual(s.visible(0), "$ ac")
            XCTAssertNil(s.overlay, "\(chunks)")
            XCTAssertEqual(s.p.counters.mismatched, 0, "\(chunks)")
            XCTAssertEqual(s.p.counters.confirmed, 4, "\(chunks)")
        }
    }

    func testTypoFixAnsweredBetweenMessages() {
        let s = ready()
        let keys = s.type("b\u{7f}c")
        s.echo("b")
        s.answer(keys[0])
        s.echo("\u{8} \u{8}")
        s.answer(keys[1])
        XCTAssertEqual(s.visible(0), "$ ac")
        s.echo("c")
        s.answer(keys[2])
        XCTAssertNil(s.overlay)
        XCTAssertEqual(s.p.counters.confirmed, 4)
        XCTAssertEqual(s.p.counters.mismatched, 0)
    }

    func testNoJumpOverBackspace() {
        let s = EchoScript()
        s.prompt()
        s.type("a\u{7f}a")
        s.echo("a")
        s.answerAll()
        s.tick()
        XCTAssertEqual(s.p.counters.confirmed, 1, "the unchanged grid matches L3 too, but L2 was never seen")
        s.echo("\u{8} \u{8}")
        XCTAssertEqual(s.p.counters.confirmed, 2)
        s.echo("a")
        XCTAssertEqual(s.p.counters.confirmed, 3)
    }

    func testSmallestStateDoesNotConfirmTheBackspace() {
        let s = ready()
        s.type("b\u{7f}")
        s.echo("b")
        s.answerAll()
        XCTAssertEqual(s.p.counters.confirmed, 2, "only the b")
        XCTAssertEqual(s.visible(0), "$ a", "the b a pending Backspace removes is masked")
        XCTAssertEqual(s.overlay?.cells.first?.mask, .default)
        XCTAssertEqual(s.overlay?.cursor, .init(col: 3, row: 0))
    }

    func testContraryContentLeftOfTheCursorIsAMismatch() {
        let s = ready()
        s.type("bc")
        s.echo("x")
        XCTAssertNil(s.overlay, "hidden in the frame that shows the server's text")
        XCTAssertEqual(s.p.counters.mismatched, 1)
        let placed = s.p.counters.placed
        s.answerAll()
        s.key(char("d"))
        XCTAssertEqual(s.p.counters.placed, placed, "a confirmed epoch was wrong: nothing until the next Enter")
    }

    func testContentRightOfTheCursorIsNeverJudged() {
        let s = ready()
        s.type("b")
        // An autosuggestion right of the real cursor.
        s.output { g in
            g.cells[0][4] = EchoCell(scalar: 0x7a, fg: .palette(8))
            g.cells[0][5] = EchoCell(scalar: 0x7a, fg: .palette(8))
        }
        XCTAssertEqual(s.p.counters.mismatched, 0)
        XCTAssertEqual(s.guesses, "b")
        s.echo("b")
        s.answerAll()
        XCTAssertEqual(s.p.counters.confirmed, 2)
    }

    // MARK: Time

    func testLateEchoKeepsGuess() {
        let s = ready()
        let k = s.key(char("b"))
        s.answer(k)
        for _ in 0..<9 {
            s.advance(0.1)
            s.tick()
            XCTAssertEqual(s.guesses, "b", "a late echo never removes a guess")
        }
        s.echo("b")
        XCTAssertNil(s.overlay)
        XCTAssertEqual(s.p.counters.mismatched, 0)
        XCTAssertEqual(s.p.counters.vanished, 0)
    }

    func testCapClear() {
        let s = ready()
        let k = s.key(char("b"))
        s.answer(k)
        XCTAssertEqual(s.p.nextDeadline() ?? 0, s.now + EchoPredictor.cap, accuracy: 1e-9)
        s.advance(1.49)
        s.tick()
        XCTAssertEqual(s.guesses, "b")
        s.advance(0.01)
        s.tick()
        XCTAssertNil(s.overlay, "cleared silently 1.5 s after the answer")
        XCTAssertEqual(s.p.counters.capped, 1)
        XCTAssertEqual(s.p.counters.vanished, 1)
        XCTAssertEqual(s.p.counters.mismatched, 0)
        s.settle()
        let placed = s.p.counters.placed
        s.key(char("c"))
        XCTAssertEqual(s.p.counters.placed, placed + 1, "no lockout: the next key starts a tentative epoch")
    }

    func testOverdueStopsDrawing() {
        let s = ready()
        let k = s.key(char("b"))
        s.answer(k)
        s.advance(0.31)
        s.key(char("c"))
        XCTAssertEqual(s.guesses, "b", "no guess stacks on an overdue one")
        s.echo("b")
        XCTAssertEqual(s.guesses, "c", "drawn once the overdue key confirms")
    }

    func testOverdueMarksTheLinkSlow() {
        let s = ready(level: .on)
        s.key(char("b"))
        XCTAssertEqual(s.overlay?.cells.first?.underlined, false, "unmarked in .on")
        s.advance(0.29)
        s.tick()
        XCTAssertFalse(s.p.takeSlowSignal())
        s.advance(0.02)
        s.tick()
        XCTAssertTrue(s.p.takeSlowSignal(), "a drawn guess waited 300 ms")
        // A tentative guess outliving 300 ms never does.
        let t = EchoScript(level: .on)
        t.prompt()
        t.key(char("p"))
        t.advance(1)
        t.tick()
        XCTAssertFalse(t.p.takeSlowSignal())
    }

    func testLinkDownKeepsGuesses() {
        let s = ready(level: .on)
        s.type("bcd")
        s.advance(5)
        s.tick()
        XCTAssertEqual(s.guesses, "bcd", "no answer, no cap: they stay")
        XCTAssertTrue(s.p.takeSlowSignal(), "and are underlined by the 300 ms rule")
        s.p.cleared(.reconnected, through: s.seq)
        XCTAssertNil(s.p.overlay)
    }

    // MARK: Passwords and the prompt state

    func testPasswordNeverDrawn() {
        for markers in [false, true] {
            let s = ready(markers: markers)
            s.typeEchoed("sudo -k", prove: false)
            let enter = s.key(.boundary(newLine: true))
            s.echo("\r\nPassword:")
            s.answer(enter)
            s.settle()
            for _ in 0..<12 {
                let k = s.key(char("p"))
                XCTAssertNil(s.overlay)
                s.advance(0.2)
                s.answer(k)
                s.settle()
                s.tick()
                XCTAssertNil(s.overlay, "markers \(markers)")
            }
        }
    }

    func testTypeaheadEchoOff() {
        // Without OSC 133: the first character echoes (cooked tty), then echo goes off.
        let s = ready()
        let enter = s.key(.boundary(newLine: true))
        s.echo("\r\n")
        s.answer(enter)
        s.settle()
        let x = s.key(char("x"))
        s.echo("x")
        s.answer(x)
        XCTAssertTrue(s.replyInputMode(EchoInputMode(echo: false, canonical: true)))
        s.settle()
        s.type("yz")
        s.answerAll()
        XCTAssertNil(s.overlay)
        XCTAssertFalse(s.history.suffix(8).contains { $0 != nil }, "zero drawn cells after that character")

        // With OSC 133: no B after the Enter's answer, so nothing is even placed.
        let m = ready(markers: true)
        let placed = m.p.counters.placed
        let e = m.key(.boundary(newLine: true))
        m.echo("\r\n")
        m.answer(e)
        m.settle()
        let k = m.key(char("x"))
        m.echo("x")
        m.answer(k)
        m.settle()
        m.type("yz")
        XCTAssertEqual(m.p.counters.placed, placed)
        XCTAssertNil(m.overlay)
    }

    func testInputModeDecision() {
        XCTAssertTrue(EchoInputMode.proves(.init(echo: false, canonical: false), foreground: "zsh"))
        XCTAssertTrue(EchoInputMode.proves(.init(echo: false, canonical: false), foreground: "-zsh"))
        XCTAssertTrue(EchoInputMode.proves(.init(echo: true, canonical: false), foreground: "/bin/bash"))
        XCTAssertFalse(EchoInputMode.proves(.init(echo: false, canonical: true), foreground: "zsh"), "a password reader")
        XCTAssertTrue(EchoInputMode.proves(.init(echo: true, canonical: true), foreground: "zsh"), "a cooked echoing reader")
        for mode in [EchoInputMode(echo: false, canonical: false), .init(echo: true, canonical: true), .init(echo: false, canonical: true)] {
            XCTAssertFalse(EchoInputMode.proves(mode, foreground: "ssh"), "ssh never gives proof")
            XCTAssertFalse(EchoInputMode.proves(mode, foreground: "vim"))
            XCTAssertFalse(EchoInputMode.proves(mode, foreground: nil))
        }
        XCTAssertFalse(EchoInputMode.proves(nil, foreground: "zsh"))
        XCTAssertNil(EchoInputMode(reply: ["echo": true]), "a missing field is no reading")
        XCTAssertEqual(EchoInputMode(reply: ["echo": true, "canonical": false]), .init(echo: true, canonical: false))
    }

    func testAReadingAskedBeforeANewLineProvesNothingAfterIt() {
        let s = EchoScript()
        s.prompt()
        let k = s.key(char("l"))
        s.echo("l")
        s.answer(k)
        let gen = s.p.takeInputModeRequest()
        XCTAssertNotNil(gen)
        s.type("\r")
        s.p.inputMode(zle, foreground: "zsh", generation: gen!, now: s.now, grid: s.grid)
        s.echo("\r\n$ ")
        s.answerAll()
        s.type("x")
        s.echo("x")
        s.answerAll()
        s.type("y")
        XCTAssertNil(s.overlay, "the old reading belongs to the line before")
    }

    func testPromptStateWithMarkers() {
        let s = ready(markers: true)
        XCTAssertNil(s.p.takeInputModeRequest(), "OSC 133 needs no reading")
        s.type("b")
        XCTAssertEqual(s.guesses, "b")
        s.echo("b")
        s.answerAll()
        let enter = s.key(.boundary(newLine: true))
        let placed = s.p.counters.placed
        s.key(char("x"))
        XCTAssertEqual(s.p.counters.placed, placed, "the old prompt's B is stale until the Enter is answered")
        s.output { g in
            g.write("\r\n")
            g.marker("C")
        }
        s.answer(enter)
        s.settle()
        s.key(char("y"))
        XCTAssertEqual(s.p.counters.placed, placed, "no B after the answer: closed")
        s.answerAll()
        s.output { g in
            g.marker("D")
            g.marker("A")
            g.write("$ ")
            g.marker("B")
        }
        s.watchRow = 1
        s.key(char("z"))
        XCTAssertEqual(s.p.counters.placed, placed + 1, "a B after the answer opens it")
    }

    func testMarkerMidEpochKillsSilently() {
        let s = ready(markers: true)
        s.type("bc")
        XCTAssertEqual(s.guesses, "bc")
        s.output { $0.marker("A") }
        XCTAssertNil(s.overlay)
        XCTAssertEqual(s.p.counters.markerKills, 1)
        XCTAssertEqual(s.p.counters.mismatched, 0)
    }

    func testShellWithoutMarkersAfterForegroundChangeAsksForAReading() {
        let s = ready(markers: true)
        s.type("\r")
        s.echo("\r\n$ ")
        s.answerAll()
        // The foreground changed (`ssh` to a host whose shell sends no OSC 133): no inherited markers.
        s.output { $0.marks.sentB = false }
        s.watchRow = 1
        let k = s.key(char("l"))
        s.echo("l")
        s.answer(k)
        XCTAssertNotNil(s.p.takeInputModeRequest())
    }

    // MARK: The screen

    func testRightPrompt() {
        let s = EchoScript(cols: 30)
        s.output { $0.rightPrompt("-╯", row: 0) }
        s.prompt()
        s.typeEchoed(String(repeating: "a", count: 25))
        XCTAssertEqual(s.grid.cursorX, 27)
        let placed = s.p.counters.placed
        s.key(char("b"))
        XCTAssertEqual(s.p.counters.placed, placed, "the guess would land a cell before the right-hand run")
    }

    func testBackspaceStopsAtStart() {
        let s = EchoScript()
        s.prompt()
        s.typeEchoed("ab")
        s.type("\u{7f}\u{7f}")
        XCTAssertEqual(s.visible(0), "$")
        let placed = s.p.counters.placed
        s.type("\u{7f}")
        XCTAssertEqual(s.p.counters.placed, placed, "the third is a boundary")
        XCTAssertFalse(s.history.contains { $0?.cells.contains { $0.col < 2 } ?? false }, "the prompt is never blanked")
        XCTAssertTrue(s.seen.allSatisfy { $0.hasPrefix("$") })
    }

    func testLastColumn() {
        let s = EchoScript(cols: 80)
        s.prompt()
        s.typeEchoed(String(repeating: "a", count: 77))
        XCTAssertEqual(s.grid.cursorX, 79)
        let placed = s.p.counters.placed
        s.key(char("b"))
        XCTAssertEqual(s.p.counters.placed, placed, "never into the last column")
        s.echo("b\r\n")
        s.answerAll()
        s.watchRow = 1
        s.key(char("c"))
        XCTAssertEqual(s.p.counters.placed, placed + 1)
        XCTAssertNil(s.overlay, "the next key is tentative")
    }

    func testRedrawAcrossMessages() {
        let s = EchoScript()
        s.output { $0.write("╭─ ~\r\n") }
        s.watchRow = 1
        s.prompt("╰─ ")
        s.typeEchoed("a")
        s.type("bc")
        XCTAssertEqual(s.guesses, "bc")
        // p10k's reset-prompt: up a row to redraw the top line, back in a second message.
        s.echo("\u{1b}[1A\r╭─ ~ main")
        XCTAssertNil(s.overlay, "hidden while the cursor is away")
        s.echo("\u{1b}[1B\r\u{1b}[4C")
        XCTAssertEqual(s.guesses, "bc", "back on its row: drawn again")
        XCTAssertEqual(s.p.counters.mismatched, 0)
        XCTAssertEqual(s.p.counters.resets, 0)
        XCTAssertEqual(s.history.suffix(2).map { $0 == nil }, [true, false], "hidden for one batch only")
    }

    func testRowChangeThatStaysResetsSilently() {
        let s = ready()
        s.type("bc")
        s.echo("\u{1b}[1B")
        s.echo("x")
        XCTAssertNil(s.overlay)
        XCTAssertEqual(s.p.counters.resets, 1)
        XCTAssertEqual(s.p.counters.mismatched, 0)
        XCTAssertFalse(s.p.hasPending)
        s.answerAll()
        let placed = s.p.counters.placed
        s.key(char("d"))
        XCTAssertEqual(s.p.counters.placed, placed + 1, "no lockout")
    }

    func testOutputScrolls() {
        let s = ready(rows: 24, row: 23)
        s.type("bc")
        XCTAssertEqual(s.guesses, "bc")
        s.echo("\n")
        XCTAssertNil(s.overlay, "hidden in that slice")
        XCTAssertEqual(s.p.counters.mismatched, 1, "and wrong at the batch's end")
    }

    func testResizeResets() {
        let s = ready()
        s.type("bc")
        XCTAssertNotNil(s.overlay)
        s.p.reset()
        XCTAssertNil(s.p.overlay)
        XCTAssertFalse(s.p.hasPending)
    }

    func testPasteBoundary() {
        XCTAssertEqual(EchoInputClassifier.classify(Array("hello".utf8)), .boundary(newLine: false))
        let s = ready()
        s.type("b")
        s.key(EchoInputClassifier.classify(Array("pasted".utf8)))
        let placed = s.p.counters.placed
        s.key(char("z"))
        XCTAssertEqual(s.p.counters.placed, placed, "a key right after a paste is a boundary")
        XCTAssertEqual(s.guesses, "b", "the guesses before the paste stay until judged")
    }

    func testScreenGates() {
        for change in [{ (g: inout FakeEchoGrid) in g.screenAllows = false }, { $0.pendingWrap = true }] {
            let s = EchoScript()
            s.prompt()
            s.output(change)
            s.key(char("l"))
            XCTAssertEqual(s.p.counters.placed, 0)
        }
    }

    // MARK: Accuracy and clears

    func testAccuracyWindow() {
        let s = ready()
        // Two confirmed epochs proved wrong, each after one right key: 2 of 8 right.
        for round in 0..<2 {
            s.type("xyz")
            s.echo("qqq")
            XCTAssertEqual(s.p.counters.mismatched, round + 1)
            s.type("\r")
            s.echo("\r\n$ ")
            s.answerAll()
            s.watchRow += 1
            s.typeEchoed("a")
        }
        s.type("b")
        XCTAssertNil(s.overlay, "at or below 30%: epochs stay undrawn")
        s.echo("b")
        s.answerAll()
        s.typeEchoed("cdefgh")
        s.type("i")
        XCTAssertEqual(s.guesses, "i", "back above 60%")
    }

    func testClearedOnEveryReason() {
        let reasons: [EchoClearReason] = [.unknown, .refused, .unsent, .dropped, .fence, .reconnected, .stopped]
        for reason in reasons {
            let s = ready()
            s.type("bc")
            XCTAssertNotNil(s.overlay)
            s.p.cleared(reason, through: s.seq)
            XCTAssertNil(s.p.overlay, "\(reason)")
            XCTAssertFalse(s.p.hasPending)
            XCTAssertEqual(s.p.answeredThrough == s.seq, reason.dropsInput, "\(reason): dropped input counts as answered")
        }
    }

    func testSpacesCursorAndUnsettled() {
        let s = ready()
        s.type(" b")
        let cells = s.overlay?.cells ?? []
        XCTAssertEqual(cells.map(\.col), [3, 4])
        XCTAssertEqual(cells.map(\.scalar), [0x20, 0x62])
        XCTAssertTrue(cells.allSatisfy(\.underlined), "predicted spaces carry the underline: the trail is continuous")
        XCTAssertEqual(s.overlay?.cursor, .init(col: 5, row: 0))
        XCTAssertEqual(s.overlay?.unsettled, true)
        s.echo(" b")
        s.answerAll()
        XCTAssertNil(s.overlay)
    }

    func testColourComesFromTheLeftCellTypedInThisEpoch() {
        let s = EchoScript()
        s.output { $0.write("\u{1b}[0m") }
        s.prompt()
        s.output { $0.pen = EchoCell(fg: .palette(2), bold: true) }
        s.typeEchoed("a")
        s.type("bc")
        XCTAssertEqual(s.overlay?.cells.map(\.fg), [.palette(2), .palette(2)], "syntax highlighting's colour carries on")
        XCTAssertEqual(s.overlay?.cells.map(\.bold), [true, true])
        let t = EchoScript()
        t.output { $0.pen = EchoCell(fg: .palette(4)) }
        t.prompt()
        t.output { $0.pen = EchoCell() }
        t.typeEchoed("a")
        t.p.reset()
        t.settle()
        t.key(char("b"))
        t.echo("b")
        t.answerAll()
        t.replyInputMode(zle)
        t.type("c")
        XCTAssertEqual(t.overlay?.cells.first?.fg, .default)
    }

    func testMaskTakesTheCellsOwnBackground() {
        let s = EchoScript()
        s.prompt()
        s.output { $0.pen = EchoCell(bg: .rgb(0x223344)) }
        s.typeEchoed("ab")
        s.type("\u{7f}")
        XCTAssertEqual(s.overlay?.cells.first?.mask, .rgb(0x223344))
        XCTAssertEqual(s.overlay?.cells.first?.hasGlyph, false)
    }
}
