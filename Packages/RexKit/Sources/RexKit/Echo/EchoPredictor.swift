import Foundation

// Predicted echo (docs/terminal.md, Predicted echo): mosh's prediction engine, narrowed to the
// shell's prompt input and to mosh's acknowledgement rule. Guesses are an overlay the app draws
// over the grid; they are never written into the terminal, and never sent.

/// A colour as the terminal stores it, resolved by whoever draws it.
public enum EchoColor: Hashable, Sendable {
    /// The theme's foreground (for text) or background (for a background).
    case `default`
    case palette(UInt8)
    /// 0xRRGGBB.
    case rgb(UInt32)
}

/// One grid cell as the predictor reads it.
public struct EchoCell: Equatable, Sendable {
    /// The cell's character: 0 for an empty cell. Wide characters and clusters are a value no
    /// typed byte can equal.
    public var scalar: UInt32
    public var fg: EchoColor
    public var bg: EchoColor
    public var bold: Bool

    public init(scalar: UInt32 = 0, fg: EchoColor = .default, bg: EchoColor = .default, bold: Bool = false) {
        self.scalar = scalar
        self.fg = fg
        self.bg = bg
        self.bold = bold
    }

    public static let blank = EchoCell()
    /// No content: empty, or a space.
    public var isBlank: Bool { scalar == 0 || scalar == 0x20 }
}

/// The OSC 133 markers parsed so far, by serial number (one counter for all of them).
public struct EchoPromptMarks: Equatable, Sendable {
    /// The serial of the last `133;B` (input starts), 0 for none.
    public var lastB = 0
    /// The serial of the last `133;C`, `D` or `A` (input over, a command's output, a new prompt).
    public var lastEnd = 0
    /// The shell announced its input with `133;B` since the foreground program last changed.
    public var sentB = false

    public init(lastB: Int = 0, lastEnd: Int = 0, sentB: Bool = false) {
        self.lastB = lastB
        self.lastEnd = lastEnd
        self.sentB = sentB
    }
}

/// The screen as the predictor sees it: the active area, after everything parsed so far.
/// The app's is `GhosttyEchoGrid`, read on the feed queue with the terminal lock held.
public protocol EchoGrid {
    var cols: Int { get }
    var rows: Int { get }
    var cursorX: Int { get }
    var cursorY: Int { get }
    /// The cursor waits to wrap after the last column.
    var pendingWrap: Bool { get }
    /// Primary screen, cursor visible (DECTCEM), insert mode off (IRM), wraparound on (DECAWM),
    /// no Kitty keyboard flags.
    var screenAllows: Bool { get }
    var scrollbackRows: Int { get }
    var marks: EchoPromptMarks { get }
    /// The cursor is at a prompt or its input (OSC 133).
    var cursorAtPrompt: Bool { get }
    func cell(_ x: Int, _ y: Int) -> EchoCell
}

/// What the app draws over the grid: guessed characters, masks over stale ones, and the
/// predicted cursor. Rows are active-area rows.
public struct EchoOverlay: Equatable, Sendable {
    public struct Cell: Equatable, Sendable {
        public var col: Int
        public var row: Int
        /// The guessed character, 0x20 for a guessed space (an underline only), 0 for none (a
        /// mask only).
        public var scalar: UInt32
        public var fg: EchoColor
        public var bold: Bool
        /// A rect in this background under the glyph, over content the guess replaces (the
        /// character a pending Backspace removes). Nil over a blank cell: its background shows.
        public var mask: EchoColor?
        public var underlined: Bool

        public init(col: Int, row: Int, scalar: UInt32, fg: EchoColor = .default, bold: Bool = false,
                    mask: EchoColor? = nil, underlined: Bool = false) {
            self.col = col
            self.row = row
            self.scalar = scalar
            self.fg = fg
            self.bold = bold
            self.mask = mask
            self.underlined = underlined
        }

        /// Draws a glyph.
        public var hasGlyph: Bool { scalar > 0x20 }
    }

    public struct Point: Equatable, Sendable {
        public var col: Int
        public var row: Int
        public init(col: Int, row: Int) { self.col = col; self.row = row }
    }

    public var cells: [Cell]
    /// Where the cursor is drawn instead of the real one.
    public var cursor: Point?
    /// A drawn guess is unconfirmed: the real cursor lags the one on screen.
    public var unsettled: Bool

    public init(cells: [Cell], cursor: Point?, unsettled: Bool) {
        self.cells = cells
        self.cursor = cursor
        self.unsettled = unsettled
    }
}

/// The prediction engine of one pane. Pure: it reads the screen only through `EchoGrid`, has no
/// clock of its own (every call passes `now`), and sends nothing. The app keeps one per pane on
/// the feed queue while the pane's level is not `.off`.
///
/// Epochs are runs of guesses that are all right or all wrong. Each starts tentative (tracked,
/// not drawn) until the server confirms its first key. A key is judged in typing order against
/// prefix states L₀…Lₙ (L₀ the start, Lᵢ with key i applied), confirming the smallest later
/// state the grid shows, never one that looks like the confirmed state (the grid shows that
/// before any echo), and only once its own write was answered. Only contrary screen content removes a guess; a late echo never does,
/// and a guess unconfirmed 1.5 s after its write's answer is cleared silently.
public final class EchoPredictor {
    /// A key is cleared this long after its write's answer without a confirmation (s).
    public static let cap = 1.5
    /// mosh's delay on the server's echo acknowledgement (s).
    public static let settle = 0.05
    /// A drawn guess this old (from its typing) marks the link slow; keys typed this long after
    /// an unconfirmed drawn key's answer are not drawn until it confirms (s).
    public static let overdue = 0.3
    /// The accuracy guard: the last `window` judged keys; at or below `low` correct (after at
    /// least `minimum` of them) epochs stay undrawn until it is back above `high`.
    public static let window = 24
    public static let minimum = 5
    public static let low = 0.3
    public static let high = 0.6

    public struct Counters: Equatable, Sendable {
        /// Keys tracked as guesses.
        public var placed = 0
        /// Keys drawn at least once.
        public var drawn = 0
        public var confirmed = 0
        /// Epochs the screen proved wrong.
        public var mismatched = 0
        /// Cap clears that removed a drawn guess.
        public var vanished = 0
        /// Every cap clear.
        public var capped = 0
        /// Silent resets: the cursor stayed on another row, a grid change (resize, restore).
        public var resets = 0
        /// Epochs a `133;C`, `D` or `A` ended.
        public var markerKills = 0
        public init() {}
    }

    private enum Op: Equatable {
        case char(UInt8)
        case backspace
    }

    private struct Key {
        var op: Op
        var seq: Int
        var typedAt: Double
        var answeredAt: Double?
        var drawnAt: Double?
    }

    /// One line state: the cells from the epoch's start column, and the cursor's column.
    private struct Line {
        /// 0 for a blank (empty or erased), 0x20 for a typed space.
        var cells: [UInt32] = []
        var cursor: Int

        @inline(__always) func content(_ x: Int, start: Int) -> UInt32 {
            let i = x - start
            return i >= 0 && i < cells.count ? cells[i] : 0
        }
    }

    private struct Epoch {
        var row: Int
        var start: Int
        /// The content of the cell left of the start column (0 at column 0).
        var anchor: UInt32
        var scrollback: Int
        /// `marks.lastEnd` when the epoch began.
        var endSerial: Int
        var keys: [Key] = []
        /// L₀…Lₙ; `states[i]` is the line after `keys[i - 1]`.
        var states: [Line]
        /// The index of the confirmed state (0 at the start).
        var confirmed = 0
        /// No more keys: a boundary came.
        var closed = false
        /// The boundary was a new line: what the screen does now is the program's, so a failed
        /// judgement is not a wrong guess.
        var endedByNewLine = false
        /// Drain batches in a row that ended with the cursor away from the epoch's row.
        var awayBatches = 0
        var tentative: Bool { confirmed == 0 }
        var extent: Int { states.map(\.cells.count).max() ?? 0 }
    }

    private enum Lockout { case none, untilBoundary, untilNewLine }

    /// `.on` draws guesses unmarked, `.slow` underlined.
    public var level: EchoLevel
    public private(set) var overlay: EchoOverlay?
    public private(set) var counters = Counters()

    // Acknowledgement.
    public private(set) var lastSeq: Int
    public private(set) var answeredThrough: Int
    private var lastAnswerAt: Double?
    private var settledAt: Double?
    private var settledAtStart: Bool

    // The prompt state.
    /// A new line was typed with this sequence number and its write is not answered yet.
    private var newLineSeq: Int?
    /// `marks.lastB` when the last new line's write was answered.
    private var bAtAnswer: Int?
    /// Without OSC 133: an `input_mode` reading proved a line editor or an echoing reader since
    /// the last new line.
    private var proven = false
    /// Counts new lines, so a reading asked for before one proves nothing after it.
    private var proofGeneration = 0
    private var proofInFlight = false
    private var proofWanted: Int?

    private var epoch: Epoch?
    private var lockout = Lockout.none
    private var judged: [Bool] = []
    private var lowAccuracy = false
    private var slowWanted = false

    /// `lastSeq` and `answeredThrough` describe the stream when the predictor is made; `settled`
    /// says whether its last answer is 50 ms old.
    public init(level: EchoLevel, lastSeq: Int = 0, answeredThrough: Int = 0, settled: Bool = true) {
        self.level = level
        self.lastSeq = lastSeq
        self.answeredThrough = answeredThrough
        settledAtStart = settled
    }

    /// A key is tracked and not confirmed yet (drawn or not). A line whose keys are all
    /// confirmed has nothing pending: a lower level may apply, and the predictor may go.
    public var hasPending: Bool { epoch.map { $0.confirmed < $0.keys.count } ?? false }

    /// The generation of an `input_mode` reading the predictor wants, once. Answer it with
    /// `inputMode(_:foreground:generation:)`.
    public func takeInputModeRequest() -> Int? {
        defer { proofWanted = nil }
        return proofWanted
    }

    /// A drawn guess waited `overdue` unconfirmed while the level was `.on`: the server's gate
    /// should mark guesses (`EchoGate.noteOverdue`). Once per occasion.
    public func takeSlowSignal() -> Bool {
        defer { slowWanted = false }
        return slowWanted
    }

    /// The next time `tick` has something to do, if any.
    public func nextDeadline() -> Double? {
        guard let e = epoch else { return nil }
        var next: Double?
        func consider(_ t: Double) { next = min(next ?? t, t) }
        for i in (e.confirmed + 1)..<(e.keys.count + 1) {
            let k = e.keys[i - 1]
            if let a = k.answeredAt { consider(a + Self.cap) }
            if level == .on, k.drawnAt != nil { consider(k.typedAt + Self.overdue) }
        }
        return next
    }

    // MARK: Input

    /// An input call, classified, with its sequence number. Runs after all output the app had
    /// received before the call.
    public func typed(_ kind: EchoInputKind, seq: Int, at now: Double, grid: some EchoGrid) {
        lastSeq = max(lastSeq, seq)
        switch kind {
        case .boundary(let newLine):
            boundary(newLine: newLine, seq: seq)
        case .char, .backspace:
            if !place(kind == .backspace ? .backspace : .char(Self.byte(kind)), seq: seq, at: now, grid: grid) {
                // A key that fails a gate is a boundary, but not one that ends a lockout.
                endEpoch(newLine: false)
            }
        }
        publish(grid: grid, now: now)
    }

    private static func byte(_ kind: EchoInputKind) -> UInt8 {
        if case .char(let b) = kind { return b }
        return 0
    }

    private func boundary(newLine: Bool, seq: Int) {
        endEpoch(newLine: newLine)
        if newLine {
            newLineSeq = seq
            bAtAnswer = nil
            proven = false
            proofGeneration += 1
            proofWanted = nil
            lockout = .none
        } else if lockout == .untilBoundary {
            lockout = .none
        }
    }

    private func endEpoch(newLine: Bool) {
        guard var e = epoch else { return }
        if e.confirmed == e.keys.count { epoch = nil; return }
        e.closed = true
        if newLine { e.endedByNewLine = true }
        epoch = e
    }

    /// Tries to track key `op` as a guess. False when a gate fails.
    private func place(_ op: Op, seq: Int, at now: Double, grid: some EchoGrid) -> Bool {
        guard lockout == .none, grid.screenAllows else { return false }
        // With OSC 133 a key is placed only at the shell's open input. Without it, keys are
        // tracked (not drawn) until a reading proves the program echoes.
        if grid.marks.sentB, !markersOpen(grid) { return false }
        let cols = grid.cols
        if var e = epoch {
            guard !e.closed, consistent(e, grid) else { return false }
            let last = e.states[e.states.count - 1]
            var next = last
            switch op {
            case .char(let b):
                let x = last.cursor
                guard x < cols - 1, marginFree(e, x: x, grid: grid) else { return false }
                let i = x - e.start
                if next.cells.count <= i { next.cells += [UInt32](repeating: 0, count: i + 1 - next.cells.count) }
                next.cells[i] = UInt32(b)
                next.cursor = x + 1
            case .backspace:
                // Never into the prompt (the mosh bug).
                guard last.cursor > e.start else { return false }
                next.cursor = last.cursor - 1
                let i = next.cursor - e.start
                if i < next.cells.count { next.cells[i] = 0 }
            }
            e.keys.append(Key(op: op, seq: seq, typedAt: now))
            e.states.append(next)
            epoch = e
            counters.placed += 1
            return true
        }
        // A new epoch: mosh's acknowledgement rule, so the grid reflects every earlier key.
        guard case .char(let b) = op, acknowledged(before: seq) else { return false }
        let x = grid.cursorX, y = grid.cursorY
        guard !grid.pendingWrap, x < cols - 1, y >= 0, y < grid.rows,
              grid.cell(x, y).isBlank, grid.cell(x + 1, y).isBlank else { return false }
        var first = Line(cursor: x + 1)
        first.cells = [UInt32(b)]
        epoch = Epoch(row: y, start: x, anchor: x > 0 ? Self.norm(grid.cell(x - 1, y).scalar) : 0,
                      scrollback: grid.scrollbackRows, endSerial: grid.marks.lastEnd,
                      keys: [Key(op: op, seq: seq, typedAt: now)], states: [Line(cursor: x), first])
        counters.placed += 1
        return true
    }

    /// Everything before `seq` is answered and the last answer has settled.
    private func acknowledged(before seq: Int) -> Bool {
        guard answeredThrough >= seq - 1 else { return false }
        guard let last = lastAnswerAt else { return settledAtStart }
        return settledAt == last
    }

    /// The target cell and the one after it are blank, or hold what an earlier state expects
    /// there (a character a pending Backspace removes). Cells further right may hold a
    /// right-hand prompt.
    private func marginFree(_ e: Epoch, x: Int, grid: some EchoGrid) -> Bool {
        for cx in x...(x + 1) {
            let have = Self.norm(grid.cell(cx, e.row).scalar)
            guard have == 0 || expected(e, x: cx, have: have, from: e.confirmed, through: e.states.count - 1) else { return false }
        }
        return true
    }

    /// The epoch still describes the screen: same row, scrollback and anchor, the cursor at the
    /// confirmed state or a later one, no contrary content left of it.
    private func consistent(_ e: Epoch, _ grid: some EchoGrid) -> Bool {
        guard grid.cursorY == e.row, grid.scrollbackRows == e.scrollback, anchorHolds(e, grid) else { return false }
        let cx = grid.cursorX
        guard e.states[e.confirmed...].contains(where: { $0.cursor == cx }) else { return false }
        return !contrary(e, grid)
    }

    private func anchorHolds(_ e: Epoch, _ grid: some EchoGrid) -> Bool {
        e.start == 0 || Self.norm(grid.cell(e.start - 1, e.row).scalar) == e.anchor
    }

    /// A cell left of the real cursor holds content that no state from the confirmed one on has
    /// there.
    private func contrary(_ e: Epoch, _ grid: some EchoGrid) -> Bool {
        let end = min(grid.cursorX, e.start + e.extent)
        guard end > e.start else { return false }
        for x in e.start..<end {
            let have = Self.norm(grid.cell(x, e.row).scalar)
            if !expected(e, x: x, have: have, from: e.confirmed, through: e.states.count - 1) { return true }
        }
        return false
    }

    /// Some state in `from...through` has `have` at column `x`.
    private func expected(_ e: Epoch, x: Int, have: UInt32, from: Int, through: Int) -> Bool {
        guard from <= through else { return false }
        for j in from...through where Self.norm(e.states[j].content(x, start: e.start)) == have { return true }
        return false
    }

    @inline(__always) private static func norm(_ s: UInt32) -> UInt32 { s == 0x20 ? 0 : s }

    // MARK: Acknowledgement

    /// The stream answered the item holding input through `seq`. Runs after every byte the app
    /// received before the answer.
    public func answered(through seq: Int, at time: Double, now: Double, grid: some EchoGrid) {
        answeredThrough = max(answeredThrough, seq)
        lastAnswerAt = time
        if let s = newLineSeq, seq >= s {
            bAtAnswer = grid.marks.lastB
            newLineSeq = nil
        }
        if var e = epoch {
            for i in e.keys.indices where e.keys[i].seq <= seq && e.keys[i].answeredAt == nil { e.keys[i].answeredAt = time }
            epoch = e
        }
        // An echo that arrived before its answer is confirmed here, if the grid still shows it.
        judge(grid: grid, now: now, batch: false)
        publish(grid: grid, now: now)
    }

    /// 50 ms passed since the answer at `answer`. Before the predictor has heard an answer of
    /// its own, that is the stream's settle from when it began to listen: the start it was made
    /// with (`settled: false`) is over.
    public func settled(after answer: Double) {
        guard let last = lastAnswerAt else {
            settledAtStart = true
            return
        }
        if answer == last { settledAt = answer }
    }

    /// Input through `seq` was dropped, or will arrive unpredicted: every guess goes.
    public func cleared(_ reason: EchoClearReason, through seq: Int) {
        if reason.dropsInput {
            answeredThrough = max(answeredThrough, seq)
            lastSeq = max(lastSeq, seq)
        }
        epoch = nil
        overlay = nil
    }

    /// The grid changed under the guesses (a resize, a reset, a restore, a theme, dropped
    /// output): a boundary with every guess cleared.
    public func reset() {
        if epoch != nil { counters.resets += 1 }
        epoch = nil
        overlay = nil
    }

    /// The reply to an `input_mode` reading asked for with `generation`. `foreground` is the
    /// program in front when it arrived.
    public func inputMode(_ mode: EchoInputMode?, foreground: String?, generation: Int, now: Double, grid: some EchoGrid) {
        proofInFlight = false
        if generation == proofGeneration, EchoInputMode.proves(mode, foreground: foreground) { proven = true }
        publish(grid: grid, now: now)
    }

    // MARK: Output

    /// After each slice of output, in the same lock section that parsed it: recomputes the
    /// overlay against the grid, without judging. A `133;C`, `D` or `A` ends the epoch.
    public func slice(grid: some EchoGrid, now: Double) {
        killOnMarker(grid)
        publish(grid: grid, now: now)
    }

    /// After each drain batch: judges the epoch (confirm, mismatch, reset), then recomputes the
    /// overlay.
    public func batchEnd(grid: some EchoGrid, now: Double) {
        killOnMarker(grid)
        judge(grid: grid, now: now, batch: true)
        publish(grid: grid, now: now)
    }

    /// At `nextDeadline`: the safety cap and the slow-link signal.
    public func tick(grid: some EchoGrid, now: Double) {
        judge(grid: grid, now: now, batch: false)
        publish(grid: grid, now: now)
    }

    private func killOnMarker(_ grid: some EchoGrid) {
        guard let e = epoch, grid.marks.sentB, grid.marks.lastEnd != e.endSerial else { return }
        epoch = nil
        counters.markerKills += 1
    }

    /// With OSC 133: the shell's input is open now.
    private func markersOpen(_ grid: some EchoGrid) -> Bool {
        guard newLineSeq == nil else { return false }
        let m = grid.marks
        return m.lastB > max(m.lastEnd, bAtAnswer ?? 0) && grid.cursorAtPrompt
    }

    private func promptOpen(_ grid: some EchoGrid) -> Bool {
        grid.marks.sentB ? markersOpen(grid) : proven
    }

    private func judge(grid: some EchoGrid, now: Double, batch: Bool) {
        guard var e = epoch else { return }
        // The safety cap, before anything else: no evidence either way for too long.
        let pending = e.keys[e.confirmed...]
        if pending.contains(where: { $0.answeredAt.map { now - $0 >= Self.cap } ?? false }) {
            counters.capped += 1
            // A vanish is something taken off the screen: keys that cancel out (`a⌫`) show
            // nothing by now.
            if overlay != nil, pending.contains(where: { $0.drawnAt != nil }) { counters.vanished += 1 }
            epoch = nil
            return
        }
        if level == .on, e.keys[e.confirmed...].contains(where: { $0.drawnAt != nil && now - $0.typedAt >= Self.overdue }) {
            slowWanted = true
        }
        if grid.scrollbackRows != e.scrollback { return wrong(e) }
        if grid.cursorY != e.row || grid.cursorX < e.start {
            // Not a mismatch: a prompt redraw can take the cursor away and back across messages.
            if batch {
                e.awayBatches += 1
                if e.awayBatches >= 2 {
                    counters.resets += 1
                    epoch = nil
                    return
                }
            }
            epoch = e
            return
        }
        if batch { e.awayBatches = 0 }
        guard anchorHolds(e, grid) else { return wrong(e) }

        // Confirm: the smallest later state the grid shows, in typing order, only for keys whose
        // write was answered, and only a state the grid could not be showing already. A state
        // that looks like the confirmed one (`a⌫` after nothing, the second `a` of `a⌫a`) is no
        // evidence: the grid looks that way before the echo too. It is confirmed with the next
        // state that differs, or goes with the safety cap.
        let before = e.confirmed
        var j = e.confirmed + 1
        while j <= e.keys.count, e.keys[j - 1].seq <= answeredThrough {
            if matches(e, j, grid), !Self.sameView(e.states[e.confirmed], e.states[j], start: e.start) {
                e.confirmed = j
                break
            }
            j += 1
        }
        if e.confirmed > before {
            let n = e.confirmed - before
            counters.confirmed += n
            for _ in 0..<n { note(true) }
            if before == 0, !grid.marks.sentB, !proven, !proofInFlight {
                proofInFlight = true
                proofWanted = proofGeneration
            }
        }
        if contrary(e, grid) { return wrong(e) }
        if e.closed, e.confirmed == e.keys.count {
            epoch = nil
            return
        }
        epoch = e
    }

    /// The grid shows state `j`: its cells left of its cursor, the cursor, and the blank a
    /// Backspace left.
    private func matches(_ e: Epoch, _ j: Int, _ grid: some EchoGrid) -> Bool {
        let s = e.states[j]
        guard grid.cursorX == s.cursor else { return false }
        if s.cursor > e.start {
            for x in e.start..<s.cursor where Self.norm(grid.cell(x, e.row).scalar) != Self.norm(s.content(x, start: e.start)) {
                return false
            }
        }
        if e.keys[j - 1].op == .backspace, !grid.cell(s.cursor, e.row).isBlank { return false }
        return true
    }

    /// Two states look the same on the grid: the same cursor and the same cells left of it.
    private static func sameView(_ a: Line, _ b: Line, start: Int) -> Bool {
        guard a.cursor == b.cursor else { return false }
        return (start..<max(start, a.cursor)).allSatisfy { norm(a.content($0, start: start)) == norm(b.content($0, start: start)) }
    }

    private func wrong(_ e: Epoch) {
        epoch = nil
        if e.endedByNewLine { counters.resets += 1; return }
        counters.mismatched += 1
        for _ in e.confirmed..<e.keys.count { note(false) }
        lockout = e.tentative ? .untilBoundary : .untilNewLine
    }

    private func note(_ right: Bool) {
        judged.append(right)
        if judged.count > Self.window { judged.removeFirst(judged.count - Self.window) }
        guard judged.count >= Self.minimum else { return }
        let ratio = Double(judged.filter { $0 }.count) / Double(judged.count)
        if !lowAccuracy, ratio <= Self.low { lowAccuracy = true }
        if lowAccuracy, ratio > Self.high { lowAccuracy = false }
    }

    /// How many keys of `e` are drawn: none while tentative, while the prompt isn't open or
    /// accuracy is low; otherwise all, except keys typed `overdue` after an unconfirmed drawn
    /// key's answer, which wait for it.
    private func shown(_ e: Epoch, grid: some EchoGrid) -> Int {
        guard !e.tentative, !lowAccuracy, promptOpen(grid) else { return e.confirmed }
        var d = e.keys.count
        var i = e.confirmed
        while i < e.keys.count {
            let k = e.keys[i]
            if k.drawnAt != nil, let a = k.answeredAt,
               let later = e.keys[(i + 1)...].firstIndex(where: { $0.typedAt >= a + Self.overdue }) {
                d = min(d, later)
            }
            i += 1
        }
        return max(d, e.confirmed)
    }

    /// Recomputes the overlay: Lₙ over the epoch's region where the grid doesn't show it yet,
    /// masks over expected stale content, nothing at all if the grid contradicts the epoch.
    private func publish(grid: some EchoGrid, now: Double) {
        guard var e = epoch else { overlay = nil; return }
        let d = shown(e, grid: grid)
        guard d > e.confirmed, grid.cursorY == e.row, grid.cursorX >= e.start,
              grid.scrollbackRows == e.scrollback, anchorHolds(e, grid) else { overlay = nil; return }
        let target = e.states[d]
        let realX = grid.cursorX
        let underlined = level == .slow
        var cells: [EchoOverlay.Cell] = []
        // The style of the cell left of `x`, when it was typed in this epoch.
        var left: (fg: EchoColor, bold: Bool)?
        let end = min(e.start + e.extent, grid.cols)
        var x = e.start
        while x < end {
            let want = target.content(x, start: e.start)
            let have = grid.cell(x, e.row)
            let haveN = Self.norm(have.scalar), wantN = Self.norm(want)
            let style = left ?? (.default, false)
            if haveN == wantN {
                if wantN != 0 {
                    // The server shows it.
                    left = (have.fg, have.bold)
                } else if want == 0x20, x >= realX {
                    // A guessed space the server hasn't reached: the trail stays continuous.
                    cells.append(.init(col: x, row: e.row, scalar: 0x20, fg: style.fg, bold: style.bold, underlined: underlined))
                    left = style
                } else {
                    left = nil
                }
            } else if haveN == 0 {
                cells.append(.init(col: x, row: e.row, scalar: want, fg: style.fg, bold: style.bold, underlined: underlined))
                left = style
            } else if expected(e, x: x, have: haveN, from: e.confirmed, through: d - 1) {
                // Stale: a pending Backspace or a later guess replaces it.
                cells.append(.init(col: x, row: e.row, scalar: want, fg: style.fg, bold: style.bold, mask: have.bg,
                                   underlined: underlined && want != 0))
                left = want == 0 ? nil : style
            } else if expected(e, x: x, have: haveN, from: d + 1, through: e.states.count - 1) {
                // The server is ahead of what is drawn.
                left = (have.fg, have.bold)
            } else {
                // Contrary: hidden until the batch judges it.
                overlay = nil
                return
            }
            x += 1
        }
        let cursor = target.cursor != realX && target.cursor < grid.cols ? EchoOverlay.Point(col: target.cursor, row: e.row) : nil
        guard !cells.isEmpty || cursor != nil else { overlay = nil; return }
        for i in e.confirmed..<d where e.keys[i].drawnAt == nil {
            e.keys[i].drawnAt = now
            counters.drawn += 1
        }
        epoch = e
        overlay = EchoOverlay(cells: cells, cursor: cursor, unsettled: true)
    }
}
