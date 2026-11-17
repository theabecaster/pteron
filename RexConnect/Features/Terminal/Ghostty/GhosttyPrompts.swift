import Foundation
import GhosttyVt

// Prompt click: a tap on the shell's input line moves the shell's cursor there (OSC 133).
//
// libghostty-vt keeps what is needed on the grid (which cells are input, which rows continue a
// prompt, whether the cursor is at a prompt) and the C API reads all of it. Two things the Ghostty
// app uses are not in the C API at this pin: the click mode the shell announced on `OSC 133 ; A`
// (`cl=…` or `click_events=…`, `Screen.semantic_prompt.click`), and the move itself
// (`Screen.promptClickMove`). So:
//
// - The click mode is read from the stream with `ghostty_terminal_vt_write_until`, upstream's way
//   to see "the exact bytes of each … OSC string" with the same parse that updates the terminal
//   (guides/custom-sequences.md). Options are read the way `osc/parsers/semantic_prompt.zig` does.
// - The move is `Screen.promptClickLine` again, over cells read through grid references.
//
// Rules, from Ghostty's `Surface.maybePromptClick`:
// the shell must have asked for clicks, the cursor must be at a prompt (never on an alternate
// screen, never while a command runs), there is no selection, and the tap is not above the prompt.

/// What the shell said a click on its prompt should send.
enum GhosttyPromptClickMode: Equatable, Sendable {
    /// The shell didn't ask: a tap moves nothing.
    case none
    /// `cl=line`, `m`, `v` or `w`: left and right arrow keys. Like Ghostty, all four move within
    /// one input line.
    case cursorKeys
    /// `click_events=1` (`relative` false) or `2`: the shell gets the click as an SGR mouse press
    /// and moves the cursor itself.
    case clickEvents(relative: Bool)

    /// The mode an `OSC 133 ; A` or `N` sets, given the text after `133;`. Nil leaves the mode
    /// as it is: another action, or neither option present or valid.
    static func announced(by content: some Collection<UInt8>) -> GhosttyPromptClickMode? {
        var fields = content.split(separator: UInt8(ascii: ";"), omittingEmptySubsequences: false).makeIterator()
        guard let action = fields.next(), action.count == 1, let letter = action.first,
              letter == UInt8(ascii: "A") || letter == UInt8(ascii: "N") else { return nil }
        // Upstream reads the first field with the option's name and ignores it if its value is
        // not one it knows. `click_events` wins over `cl`.
        var click: GhosttyPromptClickMode?, keys: GhosttyPromptClickMode?
        var sawClick = false, sawKeys = false
        while let field = fields.next() {
            guard let equals = field.firstIndex(of: UInt8(ascii: "=")) else { continue }
            let name = String(decoding: field[..<equals], as: UTF8.self)
            let value = String(decoding: field[field.index(after: equals)...], as: UTF8.self)
            if name == "click_events", !sawClick {
                sawClick = true
                click = value == "1" ? .clickEvents(relative: false) : value == "2" ? .clickEvents(relative: true) : nil
            } else if name == "cl", !sawKeys {
                sawKeys = true
                keys = ["line", "m", "v", "w"].contains(value) ? .cursorKeys : nil
            }
        }
        return click ?? keys
    }
}

/// The feed queue's view of OSC strings going past, kept to learn the prompt click mode.
/// Every member is used with the terminal lock held.
struct GhosttyPromptWatch {
    /// More than any `OSC 133 ; A` with options needs; a longer string is not one we read.
    static let captureLimit = 256

    /// The primary screen's mode. Prompt clicks never happen on the alternate screen.
    private(set) var mode = GhosttyPromptClickMode.none
    private var capturing = false
    private var overflowed = false
    private var content: [UInt8] = []

    mutating func reset() {
        mode = .none
        capturing = false
        content.removeAll(keepingCapacity: true)
    }

    fileprivate mutating func begin() {
        capturing = true
        overflowed = false
        content.removeAll(keepingCapacity: true)
    }

    fileprivate mutating func append(_ bytes: UnsafeBufferPointer<UInt8>) {
        guard capturing, !overflowed, !bytes.isEmpty else { return }
        if content.count + bytes.count > Self.captureLimit {
            overflowed = true
        } else {
            content.append(contentsOf: bytes)
        }
    }

    /// The string ended. `complete` is false when it was cancelled or cut off by another string.
    fileprivate mutating func end(complete: Bool, primaryScreen: Bool) {
        defer { capturing = false }
        guard capturing, complete, !overflowed, primaryScreen, content.starts(with: Array("133;".utf8)) else { return }
        if let announced = GhosttyPromptClickMode.announced(by: content.dropFirst(4)) { mode = announced }
    }
}

extension GhosttyCore {
    /// `ghostty_terminal_vt_write`, stopping at the ends of OSC strings to read the ones that set
    /// the prompt click mode. The terminal ends up exactly as after a plain write (upstream:
    /// "Every byte you pass is eventually consumed in order"). Upstream on the cost: asking only
    /// for string boundaries "costs nothing on the bulk paths that handle text and string
    /// payloads, and a little for each byte of an escape sequence".
    ///
    /// Call on the feed queue with the terminal lock held.
    func writeWatchingPrompts(_ t: GhosttyTerminal, _ bytes: UnsafePointer<UInt8>, _ count: Int) {
        let start = UInt32(GHOSTTY_TERMINAL_BOUNDARY_OSC_START.rawValue), end = UInt32(GHOSTTY_TERMINAL_BOUNDARY_OSC_END.rawValue)
        var stop = GhosttyTerminalWriteStop()
        stop.size = MemoryLayout<GhosttyTerminalWriteStop>.size
        var offset = 0
        while offset < count {
            let rest = count - offset
            let result = ghostty_terminal_vt_write_until(t, bytes + offset, rest, start | end, &stop)
            if result == GHOSTTY_NO_VALUE {
                // No boundary in the rest: all of it was consumed. Inside a string, it is content.
                promptWatch.append(UnsafeBufferPointer(start: bytes + offset, count: rest))
                return
            }
            guard result == GHOSTTY_SUCCESS, stop.consumed > 0, stop.consumed <= rest else {
                // Can't happen with these arguments. Never lose output over it.
                ghostty_terminal_vt_write(t, bytes + offset, rest)
                promptWatch.reset()
                return
            }
            if stop.reached & end != 0 {
                // The byte that ended the string is consumed but is not content.
                promptWatch.append(UnsafeBufferPointer(start: bytes + offset, count: stop.consumed - 1))
                let complete = stop.end == GHOSTTY_TERMINAL_STRING_END_BEL || stop.end == GHOSTTY_TERMINAL_STRING_END_ST_ESC
                    || stop.end == GHOSTTY_TERMINAL_STRING_END_ST_C1
                var screen = GHOSTTY_TERMINAL_SCREEN_PRIMARY
                ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &screen)
                promptWatch.end(complete: complete, primaryScreen: screen == GHOSTTY_TERMINAL_SCREEN_PRIMARY)
            }
            // The content starts at the first byte that wasn't consumed.
            if stop.reached & start != 0 { promptWatch.begin() }
            offset += stop.consumed
        }
    }

    /// Installs the full-reset callback: RIS forgets the click mode, as the terminal does.
    /// Called with exclusive access to `t`, whose userdata is this core.
    func installPromptWatch(_ t: GhosttyTerminal) {
        // A new or restored terminal starts with no click mode (a snapshot doesn't carry it).
        promptWatch.reset()
        let reset: GhosttyTerminalResetFn = { _, userdata in
            guard let userdata else { return }
            // Runs inside a terminal call on the feed queue: the terminal lock is held.
            Unmanaged<GhosttyCore>.fromOpaque(userdata).takeUnretainedValue().promptWatch.reset()
        }
        ghostty_terminal_set(t, GHOSTTY_TERMINAL_OPT_RESET, unsafeBitCast(reset, to: UnsafeRawPointer.self))
    }
}

// MARK: The move

/// One grid row as the move needs it.
struct GhosttyPromptRow: Equatable {
    enum Kind: Equatable { case none, prompt, continuation }

    /// True for each cell that holds one character of input. The right half of a wide character
    /// and the filler before a wrapped one are false: the shell moves over the character once.
    var input: [Bool]
    /// The row soft-wraps onto the next one.
    var wrap = false
    /// The row continues a soft-wrapped row.
    var wrapContinuation = false
    var kind = Kind.none
}

/// What a tap on the prompt sends.
enum GhosttyPromptClick: Equatable {
    case none
    /// Arrow keys: so many left, or so many right.
    case keys(left: Int, right: Int)
    /// An SGR mouse press at a 1-based column and row, for a shell that asked for click events.
    case press(column: Int, row: Int)

    /// `ESC [ < 0 ; column ; row M`, what Ghostty and Kitty send for a click event.
    static func pressBytes(column: Int, row: Int) -> [UInt8] {
        Array("\u{1b}[<0;\(column);\(row)M".utf8)
    }
}

enum GhosttyPromptMove {
    /// The arrow keys that take the shell's cursor from `cursor` to `click`, both cells of the
    /// active area. `Screen.promptClickLine`, with two additions: a wide character counts once,
    /// and a cursor waiting to wrap (`pendingWrap`) stands after its cell, not on it.
    ///
    /// Only input cells count: the shell is taken to move over input and nothing else. Soft-wrapped
    /// rows are one line to the shell and are followed; a hard line break ends the walk. A tap
    /// past the end of the text goes to its end, a tap on the prompt text to the start of input.
    static func keys(cursor: (x: Int, y: Int), pendingWrap: Bool, click: (x: Int, y: Int),
                     row: (Int) -> GhosttyPromptRow?) -> (left: Int, right: Int) {
        // Where the cursor stands in reading order: on its cell, or just after it.
        let stand = pendingWrap ? cursor.x + 1 : cursor.x
        if click.y == cursor.y, click.x == stand { return (0, 0) }
        guard let cursorRow = row(cursor.y) else { return (0, 0) }
        var count = 0

        if click.y > cursor.y || (click.y == cursor.y && click.x > stand) {
            let cursorOnInput = !pendingWrap && cursor.x < cursorRow.input.count && cursorRow.input[cursor.x]
            rows: for y in cursor.y...click.y {
                guard let r = y == cursor.y ? cursorRow : row(y) else { break }
                // A later row belongs to this prompt only as its continuation.
                if y != cursor.y, r.kind != .continuation { break }
                // After the cursor on its row; from the first input cell on the others (shells
                // indent continuation lines).
                let from = y == cursor.y ? cursor.x + 1 : (r.input.firstIndex(of: true) ?? r.input.count)
                if from < r.input.count {
                    for x in from..<r.input.count where r.input[x] {
                        count += 1
                        guard y == click.y, x == click.x else { continue }
                        // A cursor waiting to wrap already stands on the next row's first cell.
                        if pendingWrap { count -= 1 }
                        break rows
                    }
                }
                if !r.wrap {
                    // The tap is past the end of the text. From a character, one more step puts
                    // the cursor after the last one.
                    if cursorOnInput { count += 1 }
                    break
                }
            }
            return (0, count)
        }

        rows: for y in stride(from: cursor.y, through: click.y, by: -1) {
            guard let r = y == cursor.y ? cursorRow : row(y) else { break }
            let end = y == cursor.y ? min(stand, r.input.count) : r.input.count
            for x in stride(from: end - 1, through: 0, by: -1) where r.input[x] {
                count += 1
                if y == click.y, x == click.x { break rows }
            }
            if !r.wrapContinuation { break }
        }
        return (count, 0)
    }
}

extension GhosttyCore {
    /// What a tap on viewport cell (`col`, `row`) does to the shell's cursor. `.none` unless the
    /// shell asked for prompt clicks and sits at its prompt. Takes the terminal lock once and
    /// reads at most the rows between the cursor and the tap.
    func promptClick(viewportCol col: Int, row: Int) -> GhosttyPromptClick {
        withTerminal { t in Self.promptClick(t, mode: promptWatch.mode, col: col, row: row) } ?? .none
    }

    /// Call with the terminal lock held.
    static func promptClick(_ t: GhosttyTerminal, mode: GhosttyPromptClickMode, col: Int, row: Int) -> GhosttyPromptClick {
        guard mode != .none else { return .none }
        // False on the alternate screen and while a command's output is being written.
        var atPrompt = false
        guard ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_CURSOR_AT_PROMPT, &atPrompt) == GHOSTTY_SUCCESS, atPrompt else { return .none }
        var tracking = false
        ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, &tracking)
        var selection = GhosttySelection()
        guard !tracking, ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_SELECTION, &selection) != GHOSTTY_SUCCESS else { return .none }

        var c: UInt16 = 0, r: UInt16 = 0, cx: UInt16 = 0, cy: UInt16 = 0
        ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_COLS, &c)
        ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_ROWS, &r)
        ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_CURSOR_X, &cx)
        ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_CURSOR_Y, &cy)
        let cols = Int(c), rows = Int(r)
        guard cols > 0, rows > 0, col >= 0, col < cols, row >= 0 else { return .none }

        // The tap as a cell of the active area. A row of scrollback is not the prompt.
        var point = GhosttyPoint()
        point.tag = GHOSTTY_POINT_TAG_VIEWPORT
        point.value.coordinate = GhosttyPointCoordinate(x: UInt16(col), y: UInt32(row))
        var ref = GhosttyGridRef()
        var active = GhosttyPointCoordinate()
        guard ghostty_terminal_grid_ref(t, point, &ref) == GHOSTTY_SUCCESS,
              ghostty_terminal_point_from_grid_ref(t, &ref, GHOSTTY_POINT_TAG_ACTIVE, &active) == GHOSTTY_SUCCESS else { return .none }
        var click = (x: Int(active.x), y: Int(active.y))
        let cursor = (x: Int(cx), y: Int(cy))

        var cache: [Int: GhosttyPromptRow] = [:]
        func read(_ y: Int) -> GhosttyPromptRow? {
            guard y >= 0, y < rows else { return nil }
            if let hit = cache[y] { return hit }
            let made = promptRow(t, y: y, cols: cols)
            cache[y] = made
            return made
        }

        // Where this prompt starts: up from the cursor through its continuation rows.
        var top = cursor.y
        while top > 0, read(top)?.kind == .continuation { top -= 1 }
        // Above the prompt is output. Below it is allowed: the shell decides (click events), or
        // the walk stops at the end of the input (cursor keys).
        guard click.y >= top else { return .none }

        switch mode {
        case .none:
            return .none
        case .clickEvents(let relative):
            // Upstream: the viewport row for `click_events=1`, the row counted from the prompt's
            // first row for `2`.
            return .press(column: click.x + 1, row: relative ? click.y - top + 1 : row + 1)
        case .cursorKeys:
            // The right half of a wide character is the character on its left.
            if isSpacerTail(t, x: click.x, y: click.y), click.x > 0 { click.x -= 1 }
            var pendingWrap = false
            ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_CURSOR_PENDING_WRAP, &pendingWrap)
            let move = GhosttyPromptMove.keys(cursor: cursor, pendingWrap: pendingWrap, click: click, row: read)
            // A shell line can't be longer than the screen it is on.
            let limit = cols * rows
            return move.left == 0 && move.right == 0 ? .none : .keys(left: min(move.left, limit), right: min(move.right, limit))
        }
    }

    private static func activeRef(_ t: GhosttyTerminal, x: Int, y: Int) -> GhosttyGridRef? {
        var point = GhosttyPoint()
        point.tag = GHOSTTY_POINT_TAG_ACTIVE
        point.value.coordinate = GhosttyPointCoordinate(x: UInt16(clamping: x), y: UInt32(clamping: y))
        var ref = GhosttyGridRef()
        return ghostty_terminal_grid_ref(t, point, &ref) == GHOSTTY_SUCCESS ? ref : nil
    }

    private static func isSpacerTail(_ t: GhosttyTerminal, x: Int, y: Int) -> Bool {
        guard var ref = activeRef(t, x: x, y: y) else { return false }
        var cell: GhosttyCell = 0
        var wide = GHOSTTY_CELL_WIDE_NARROW
        guard ghostty_grid_ref_cell(&ref, &cell) == GHOSTTY_SUCCESS else { return false }
        ghostty_cell_get(cell, GHOSTTY_CELL_DATA_WIDE, &wide)
        return wide == GHOSTTY_CELL_WIDE_SPACER_TAIL
    }

    /// Row `y` of the active area.
    private static func promptRow(_ t: GhosttyTerminal, y: Int, cols: Int) -> GhosttyPromptRow? {
        guard var first = activeRef(t, x: 0, y: y) else { return nil }
        var out = GhosttyPromptRow(input: [Bool](repeating: false, count: cols))
        var raw: GhosttyVt.GhosttyRow = 0
        if ghostty_grid_ref_row(&first, &raw) == GHOSTTY_SUCCESS {
            ghostty_row_get(raw, GHOSTTY_ROW_DATA_WRAP, &out.wrap)
            ghostty_row_get(raw, GHOSTTY_ROW_DATA_WRAP_CONTINUATION, &out.wrapContinuation)
            var kind = GHOSTTY_ROW_SEMANTIC_NONE
            ghostty_row_get(raw, GHOSTTY_ROW_DATA_SEMANTIC_PROMPT, &kind)
            out.kind = kind == GHOSTTY_ROW_SEMANTIC_PROMPT ? .prompt : kind == GHOSTTY_ROW_SEMANTIC_PROMPT_CONTINUATION ? .continuation : .none
        }
        for x in 0..<cols {
            guard var ref = x == 0 ? first : activeRef(t, x: x, y: y) else { break }
            var cell: GhosttyCell = 0
            guard ghostty_grid_ref_cell(&ref, &cell) == GHOSTTY_SUCCESS else { continue }
            var content = GHOSTTY_CELL_SEMANTIC_OUTPUT
            ghostty_cell_get(cell, GHOSTTY_CELL_DATA_SEMANTIC_CONTENT, &content)
            guard content == GHOSTTY_CELL_SEMANTIC_INPUT else { continue }
            var wide = GHOSTTY_CELL_WIDE_NARROW
            ghostty_cell_get(cell, GHOSTTY_CELL_DATA_WIDE, &wide)
            out.input[x] = wide != GHOSTTY_CELL_WIDE_SPACER_TAIL && wide != GHOSTTY_CELL_WIDE_SPACER_HEAD
        }
        return out
    }
}
