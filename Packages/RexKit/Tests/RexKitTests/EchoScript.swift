import Foundation
@testable import RexKit

/// A screen for the predictor: cells with backgrounds, a cursor, modes, a scrollback length and
/// OSC 133 markers with serials. `write` understands what shells echo: printable ASCII, `\b`,
/// `\r`, `\n` (scrolling at the bottom), `ESC [ K` and `ESC [ <n> A` / `B` / `C` / `D` / `G`.
struct FakeEchoGrid: EchoGrid {
    var cols: Int
    var rows: Int
    var cells: [[EchoCell]]
    var cursorX = 0
    var cursorY = 0
    var pendingWrap = false
    var screenAllows = true
    var scrollbackRows = 0
    var marks = EchoPromptMarks()
    var cursorAtPrompt = true
    private var serial = 0
    /// The background new text gets.
    var pen = EchoCell()

    init(cols: Int = 80, rows: Int = 24) {
        self.cols = cols
        self.rows = rows
        cells = Array(repeating: Array(repeating: .blank, count: cols), count: rows)
    }

    func cell(_ x: Int, _ y: Int) -> EchoCell {
        guard y >= 0, y < rows, x >= 0, x < cols else { return .blank }
        return cells[y][x]
    }

    /// The text of row `y`, without trailing blanks.
    func text(_ y: Int) -> String {
        var s = String(cells[y].map { $0.scalar == 0 ? " " : Character(Unicode.Scalar($0.scalar) ?? " ") })
        while s.hasSuffix(" ") { s.removeLast() }
        return s
    }

    mutating func marker(_ letter: Character) {
        serial += 1
        if letter == "B" {
            marks.lastB = serial
            marks.sentB = true
        } else {
            marks.lastEnd = serial
        }
    }

    mutating func write(_ s: String) {
        let u = Array(s.unicodeScalars)
        var i = 0
        while i < u.count {
            let c = u[i]
            switch c.value {
            case 0x08: cursorX = max(0, cursorX - 1)
            case 0x0d: cursorX = 0
            case 0x0a: lineFeed()
            case 0x1b:
                // ESC [ <n> <final>
                var j = i + 2
                var n = 0
                var digits = false
                while j < u.count, let d = Int(String(u[j])) { n = n * 10 + d; digits = true; j += 1 }
                guard j < u.count else { return }
                let count = digits ? n : 1
                switch u[j] {
                case "K": for x in cursorX..<cols { cells[cursorY][x] = .blank }
                case "A": cursorY = max(0, cursorY - count)
                case "B": cursorY = min(rows - 1, cursorY + count)
                case "C": cursorX = min(cols - 1, cursorX + count)
                case "D": cursorX = max(0, cursorX - count)
                case "G": cursorX = max(0, min(cols - 1, count - 1))
                default: break
                }
                i = j
            default:
                if cursorX < cols {
                    var cell = pen
                    cell.scalar = c.value
                    cells[cursorY][cursorX] = cell
                    cursorX += 1
                }
            }
            i += 1
        }
    }

    mutating func lineFeed() {
        if cursorY == rows - 1 {
            cells.removeFirst()
            cells.append(Array(repeating: .blank, count: cols))
            scrollbackRows += 1
        } else {
            cursorY += 1
        }
    }

    /// Writes `text` at the end of row `y` (a right-hand prompt), leaving the cursor where it was.
    mutating func rightPrompt(_ text: String, row y: Int) {
        let u = Array(text.unicodeScalars)
        for (k, c) in u.enumerated() { cells[y][cols - u.count + k] = EchoCell(scalar: c.value) }
    }
}

/// Drives one predictor over a `FakeEchoGrid`, the way the app does: keys with sequence numbers,
/// answers, settles, and output in data-socket messages (each its own drain batch).
final class EchoScript {
    var grid: FakeEchoGrid
    let p: EchoPredictor
    var now = 100.0
    private(set) var seq = 0
    private var lastAnswer: Double?
    /// The overlay after every step, oldest first.
    private(set) var history: [EchoOverlay?] = []
    /// The visible prompt row after every step.
    private(set) var seen: [String] = []
    /// The row the script watches in `seen`.
    var watchRow = 0

    init(level: EchoLevel = .slow, cols: Int = 80, rows: Int = 24) {
        grid = FakeEchoGrid(cols: cols, rows: rows)
        p = EchoPredictor(level: level)
    }

    var overlay: EchoOverlay? { p.overlay }

    private func record() {
        history.append(p.overlay)
        seen.append(visible(watchRow))
    }

    /// The prompt as the user sees it: the grid with the overlay drawn over it.
    func visible(_ y: Int) -> String {
        var row = Array(grid.text(y).padding(toLength: grid.cols, withPad: " ", startingAt: 0))
        for c in p.overlay?.cells ?? [] where c.row == y && c.col < row.count {
            if c.hasGlyph {
                row[c.col] = Character(Unicode.Scalar(c.scalar)!)
            } else if c.mask != nil || c.scalar == 0x20 {
                row[c.col] = " "
            }
        }
        var s = String(row)
        while s.hasSuffix(" ") { s.removeLast() }
        return s
    }

    /// The guessed glyphs, left to right.
    var guesses: String {
        String((p.overlay?.cells ?? []).filter(\.hasGlyph).map { Character(Unicode.Scalar($0.scalar)!) })
    }

    // MARK: Steps

    @discardableResult
    func key(_ kind: EchoInputKind) -> Int {
        seq += 1
        p.typed(kind, seq: seq, at: now, grid: grid)
        record()
        return seq
    }

    /// Types each character of `s` as one key (`\u{7f}` is Backspace, `\t` Tab, `\r` Enter).
    @discardableResult
    func type(_ s: String) -> [Int] {
        s.utf8.map { key(EchoInputClassifier.classify([$0])) }
    }

    func boundary(newLine: Bool = false) -> Int { key(.boundary(newLine: newLine)) }

    /// The write holding input through `seq` is answered now.
    func answer(_ through: Int) {
        lastAnswer = now
        p.answered(through: through, at: now, now: now, grid: grid)
        record()
    }

    /// The settle op for the last answer runs (answer + 50 ms).
    func settle() {
        advance(EchoPredictor.settle)
        if let lastAnswer { p.settled(after: lastAnswer) }
    }

    /// Everything typed so far is answered and settled.
    func answerAll() {
        answer(seq)
        settle()
    }

    /// One data-socket message: parsed, then judged.
    func echo(_ text: String) {
        grid.write(text)
        p.slice(grid: grid, now: now)
        p.batchEnd(grid: grid, now: now)
        record()
    }

    /// A screen change in one message, made by `change`.
    func output(_ change: (inout FakeEchoGrid) -> Void) {
        change(&grid)
        p.slice(grid: grid, now: now)
        p.batchEnd(grid: grid, now: now)
        record()
    }

    func advance(_ dt: Double) { now += dt }

    func tick() {
        p.tick(grid: grid, now: now)
        record()
    }

    /// Answers the predictor's `input_mode` request, if it made one, with `mode`.
    @discardableResult
    func replyInputMode(_ mode: EchoInputMode?, foreground: String = "zsh") -> Bool {
        guard let gen = p.takeInputModeRequest() else { return false }
        p.inputMode(mode, foreground: foreground, generation: gen, now: now, grid: grid)
        record()
        return true
    }

    // MARK: Shells

    /// A prompt `$ ` on the watched row, with OSC 133 `A … B` when `markers`.
    func prompt(_ text: String = "$ ", markers: Bool = false) {
        output { g in
            if markers { g.marker("A") }
            g.write(text)
            if markers { g.marker("B") }
        }
    }

    /// Types `s` one key at a time, each answered, settled and echoed before the next: a slow
    /// typist. The first key of an epoch confirms it; with `prove`, an `input_mode` reading that
    /// shows zsh's line editor follows.
    func typeEchoed(_ s: String, prove: Bool = true) {
        for b in s.utf8 {
            let k = key(EchoInputClassifier.classify([b]))
            if b == 0x7f { echo("\u{8} \u{8}") } else { echo(String(UnicodeScalar(b))) }
            answer(k)
            if prove { replyInputMode(EchoInputMode(echo: false, canonical: false)) }
            settle()
        }
    }
}
