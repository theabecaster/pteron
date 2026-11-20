import Foundation
import GhosttyVt

// Selection, the way upstream's guide lays it out (`Vendor/ghostty/dist/doxygen/pages/guides/selection.md`):
//
// - The selection is the terminal's own (`GHOSTTY_TERMINAL_OPT_SELECTION`). The terminal copies
//   what we pass into tracked state, so it follows its text through output, scrolling, pruning
//   and reflow, and the render state reports it per row. Nothing here keeps a range of its own.
// - The fixed end of a drag is one tracked grid reference (`GhosttySelectionAnchor`), alive only
//   while the gesture is.
// - Words come from `ghostty_terminal_select_word`, with our own boundary characters
//   (`selectionWordBoundaries`).
// - Copy is a formatter over the selection, with UNWRAP and TRIM: the text Ghostty itself puts
//   on the clipboard.
//
// Why not the selection gesture object: the host's contract is "from the anchor to the cell
// under the finger, both included". The gesture's cell drag includes an end cell only
// past 60% of its width, in a direction fixed at the press, and its word press makes the whole
// drag word-granular; neither can be turned off.
//
// Threads: every function here takes `termLock` once and is called on the main thread. The feed
// queue holds that lock for one slice of `sliceSize` bytes at a time, so the wait is one slice,
// not one burst. Grid references and selection values are snapshots that die on the next call
// that changes the terminal: each is made and used inside one critical section.

/// The fixed end of a selection drag. It names a tracked grid reference, so the anchor stays on
/// its cell while output scrolls the screen or the drag scrolls the viewport.
///
/// The reference itself is the core's (`GhosttyCore.trackedRefs`, under `termLock`), because it
/// borrows the terminal: a snapshot restore frees it with the terminal it was made on, and the
/// anchor then names nothing.
final class GhosttySelectionAnchor: Sendable {
    private let core: GhosttyCore

    init(core: GhosttyCore) {
        self.core = core
    }

    deinit {
        // Freeing touches the terminal's page list while the terminal is alive.
        core.lockTerminal()
        core.releaseTrackedRef(of: ObjectIdentifier(self))
        core.termLock.unlock()
    }
}

/// What part of the selection the viewport shows: two viewport cells, both included, in reading
/// order, clipped to the viewport.
struct GhosttySelectionExtent: Equatable {
    /// The terminal's grid at the moment of the read.
    var cols: Int
    var rows: Int
    var startCol: Int
    var startRow: Int
    var endCol: Int
    var endRow: Int
    /// A block of cells instead of a run of text.
    var rectangle = false
    /// The selection really starts above the viewport / ends below it: that end was cut to the
    /// viewport's edge (selection handles hide for such an end).
    var startClipped = false
    var endClipped = false
}

enum GhosttySelectionExtendResult: Equatable {
    /// No drag is under way, or its anchor is gone (the program switched screens, or the
    /// terminal was replaced). Nothing changed.
    case noAnchor
    /// The finger is still on the cell it pressed: the press's selection stays.
    case onAnchor
    /// The selection runs from the anchor to the cell. `changed` is false if it already did.
    case extended(changed: Bool)
}

extension GhosttyCore {
    /// What ends a word for a long press: spaces, quotes, brackets, pipes, separators and the
    /// box-drawing bar, so paths, URLs and flags select whole.
    static let selectionWordBoundaries: [UInt32] = " \t\"'`()[]{}<>|;,│".unicodeScalars.map(\.value)
    /// Left out at the end of a word: there it reads as sentence punctuation.
    static let selectionTrailingPunctuation: [UInt32] = ".:!?".unicodeScalars.map(\.value)

    // MARK: Gesture

    /// Starts a drag anchored at a viewport cell. With `word`, selects the word there; otherwise,
    /// or when the cell holds no word, clears the selection. Returns true if there is a selection.
    @discardableResult
    func beginSelection(col: Int, row: Int, word: Bool, anchor: GhosttySelectionAnchor) -> Bool {
        var selected = false
        var changed = false
        lockTerminal()
        if let t = terminal {
            releaseTrackedRef(of: ObjectIdentifier(anchor))
            var cell = Self.clamp(t, col: col, row: row)
            // The right half of a wide character belongs to the cell on its left.
            if Self.wide(t, cell) == GHOSTTY_CELL_WIDE_SPACER_TAIL, cell.col > 0 { cell.col -= 1 }
            var tracked: GhosttyTrackedGridRef?
            if ghostty_terminal_grid_ref_track(t, Self.viewportPoint(cell), &tracked) == GHOSTTY_SUCCESS, let tracked {
                trackedRefs[ObjectIdentifier(anchor)] = GhosttyTrackedRef(ref: tracked, screen: Self.activeScreen(t))
            }
            let had = Self.currentSelection(t) != nil
            if word, var ref = Self.ref(t, cell), var selection = Self.wordSelection(t, &ref) {
                ghostty_terminal_set(t, GHOSTTY_TERMINAL_OPT_SELECTION, &selection)
                selected = true
                changed = true
            } else if had {
                ghostty_terminal_set(t, GHOSTTY_TERMINAL_OPT_SELECTION, nil)
                changed = true
            }
        }
        termLock.unlock()
        if changed { selectionChanged() }
        return selected
    }

    /// Selects from the anchor to a viewport cell, both included, in reading order.
    ///
    /// `keepOnAnchor`: while the finger hasn't left the cell it pressed, leave the press's
    /// selection (a word, or nothing) alone.
    ///
    /// Never scrolls: the viewport belongs to `GhosttyScrollState`. A drag at an edge asks the
    /// scroller for a line and extends again once that frame is drawn.
    func extendSelection(col: Int, row: Int, anchor: GhosttySelectionAnchor,
                         keepOnAnchor: Bool) -> GhosttySelectionExtendResult {
        var result = GhosttySelectionExtendResult.noAnchor
        var dirty = false
        lockTerminal()
        if let t = terminal, let held = trackedRefs[ObjectIdentifier(anchor)], ghostty_tracked_grid_ref_has_value(held.ref),
           held.screen == Self.activeScreen(t) {
            let tracked = held.ref
            let cell = Self.clamp(t, col: col, row: row)
            var start = GhosttyGridRef()
            if ghostty_tracked_grid_ref_snapshot(tracked, &start) == GHOSTTY_SUCCESS, var head = Self.ref(t, cell) {
                // A wide character is one cell to the user: its right half is the cell on its left.
                var owner = head
                if Self.wide(t, cell) == GHOSTTY_CELL_WIDE_SPACER_TAIL, cell.col > 0,
                   let left = Self.ref(t, (cell.col - 1, cell.row)) {
                    owner = left
                }
                if keepOnAnchor, Self.same(t, start, owner) {
                    result = .onAnchor
                } else {
                    var selection = GhosttySelection(start: start, end: head, rectangle: false)
                    var order = GHOSTTY_SELECTION_ORDER_FORWARD
                    ghostty_terminal_selection_order(t, &selection, &order)
                    if order == GHOSTTY_SELECTION_ORDER_REVERSE {
                        // The finger is the first cell: start on the character, not inside it.
                        head = owner
                        selection.end = head
                    }
                    var equal = false
                    if var current = Self.currentSelection(t) {
                        ghostty_terminal_selection_equal(t, &current, &selection, &equal)
                    }
                    if !equal {
                        ghostty_terminal_set(t, GHOSTTY_TERMINAL_OPT_SELECTION, &selection)
                        dirty = true
                    }
                    result = .extended(changed: !equal)
                }
            }
        }
        termLock.unlock()
        if dirty { selectionChanged() }
        return result
    }

    /// The gesture is over: drop the anchor. The selection stays.
    func endSelection(anchor: GhosttySelectionAnchor) {
        lockTerminal()
        releaseTrackedRef(of: ObjectIdentifier(anchor))
        termLock.unlock()
    }

    /// Frees the tracked reference an anchor names, if it names one. Call with `termLock` held.
    func releaseTrackedRef(of anchor: ObjectIdentifier) {
        if let held = trackedRefs.removeValue(forKey: anchor) { ghostty_tracked_grid_ref_free(held.ref) }
    }

    /// Asks for a frame that shows the new selection, also while the program holds the screen
    /// (upstream: a hold may be ignored while the user selects).
    private func selectionChanged() {
        selectionDirty.store(true, ordering: .relaxed)
        onDirty?()
    }

    // MARK: The terminal's selection

    /// Clears the selection. Returns true if there was one.
    @discardableResult
    func clearSelection() -> Bool {
        var changed = false
        lockTerminal()
        if let t = terminal, Self.currentSelection(t) != nil {
            ghostty_terminal_set(t, GHOSTTY_TERMINAL_OPT_SELECTION, nil)
            changed = true
        }
        termLock.unlock()
        if changed { selectionChanged() }
        return changed
    }

    /// Selects everything on the active screen, scrollback included. Returns true if there is
    /// anything to select.
    @discardableResult
    func selectAll() -> Bool {
        var selected = false
        lockTerminal()
        if let t = terminal {
            var selection = GhosttySelection()
            if ghostty_terminal_select_all(t, &selection) == GHOSTTY_SUCCESS {
                ghostty_terminal_set(t, GHOSTTY_TERMINAL_OPT_SELECTION, &selection)
                selected = true
            }
        }
        termLock.unlock()
        if selected { selectionChanged() }
        return selected
    }

    /// True while the active screen holds a selection.
    var hasSelection: Bool {
        withTerminal { Self.currentSelection($0) != nil } ?? false
    }

    /// The selected text as Ghostty copies it: plain, soft-wrapped rows joined into the line the
    /// program wrote, spaces at the end of each line and blank lines at the end removed.
    /// Nil without a selection.
    var selectedText: String? { format(scope: .selection, emit: .plain) }

    /// What a share formats from the pane's own terminal.
    enum FormatScope: Sendable {
        /// The selection, as Copy takes it (`selectedText`).
        case selection
        /// The viewport as drawn: every row of the grid at the place the view is scrolled to,
        /// rows under the keyboard included, each row its own line.
        case viewport
    }

    enum FormatEmit: Sendable {
        case plain
        /// Inline-styled HTML, with the palette as CSS variables (`--vt-palette-N`) in a
        /// `<style>` block before the content.
        case html
    }

    /// Formats the selection or the viewport in one `termLock` section, which stalls only this
    /// pane's parsing. Callable from any thread: a share runs it off the main thread. Nil when
    /// there is nothing to format (no selection) or the formatter fails.
    func format(scope: FormatScope, emit: FormatEmit) -> String? {
        withTerminal { t -> String? in
            var selection: GhosttySelection
            switch scope {
            case .selection:
                guard let current = Self.currentSelection(t) else { return nil }
                selection = current
            case .viewport:
                let size = Self.grid(t)
                guard let start = Self.ref(t, (0, 0)), let end = Self.ref(t, (size.cols - 1, size.rows - 1)) else { return nil }
                selection = GhosttySelection(start: start, end: end, rectangle: false)
            }
            // The formatter borrows the terminal, and a snapshot restore replaces the terminal,
            // so it lives for this one call.
            var formatter: GhosttyFormatter?
            guard ghostty_formatter_terminal_new(nil, &formatter, t) == GHOSTTY_SUCCESS, let formatter else { return nil }
            defer { ghostty_formatter_free(formatter) }
            var format = emit == .html ? GHOSTTY_FORMATTER_FORMAT_HTML : GHOSTTY_FORMATTER_FORMAT_PLAIN
            var yes = true
            // The selection is copied as the program wrote it; the viewport keeps its rows.
            var unwrap = scope == .selection
            var extras = GhosttyFormatterExtras(GHOSTTY_FORMATTER_EXTRA_PALETTE)
            ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_EMIT, &format)
            ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_UNWRAP, &unwrap)
            ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_TRIM, &yes)
            ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_EXTRAS, &extras)
            guard ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_SELECTION, &selection) == GHOSTTY_SUCCESS else { return nil }
            var bytes: UnsafeMutablePointer<UInt8>?
            var count = 0
            guard ghostty_formatter_format_alloc(formatter, nil, &bytes, &count) == GHOSTTY_SUCCESS else { return nil }
            guard let bytes else { return "" }
            defer { ghostty_free(nil, bytes, count) }
            return String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self)
        } ?? nil
    }

    /// The part of the selection the viewport shows, or nil if there is no selection or none of
    /// it is in view. Covers the same cells the renderer highlights.
    var selectionExtent: GhosttySelectionExtent? { selectionExtent(rowsBelow: 0) }

    /// `rowsBelow`: rows drawn under the viewport that count as in view (the overscan row a
    /// smooth scroll shows part of). Their row numbers continue past the grid's last row.
    func selectionExtent(rowsBelow: Int) -> GhosttySelectionExtent? {
        withTerminal { t -> GhosttySelectionExtent? in
            guard var selection = Self.currentSelection(t) else { return nil }
            var ordered = GhosttySelection()
            guard ghostty_terminal_selection_ordered(t, &selection, GHOSTTY_SELECTION_ORDER_FORWARD, &ordered) == GHOSTTY_SUCCESS,
                  var top = Self.ref(t, (0, 0)) else { return nil }
            // Screen coordinates name every row, in view or not. The lookups walk the page list,
            // which is fine for a read that happens once per gesture.
            var origin = GhosttyPointCoordinate(), first = GhosttyPointCoordinate(), last = GhosttyPointCoordinate()
            guard ghostty_terminal_point_from_grid_ref(t, &top, GHOSTTY_POINT_TAG_SCREEN, &origin) == GHOSTTY_SUCCESS,
                  ghostty_terminal_point_from_grid_ref(t, &ordered.start, GHOSTTY_POINT_TAG_SCREEN, &first) == GHOSTTY_SUCCESS,
                  ghostty_terminal_point_from_grid_ref(t, &ordered.end, GHOSTTY_POINT_TAG_SCREEN, &last) == GHOSTTY_SUCCESS
            else { return nil }
            let size = Self.grid(t)
            var extent = GhosttySelectionExtent(
                cols: size.cols, rows: size.rows,
                startCol: Int(first.x), startRow: Int(first.y) - Int(origin.y),
                endCol: Int(last.x), endRow: Int(last.y) - Int(origin.y), rectangle: ordered.rectangle)

            // Wide characters, as the render state and the row builder treat them: a start on
            // the right half takes the whole character, and so does an end on the left half. An
            // end on the filler before a wide character that wrapped is on that character.
            var cell: GhosttyCell = 0
            var wide = GHOSTTY_CELL_WIDE_NARROW
            if ghostty_grid_ref_cell(&ordered.start, &cell) == GHOSTTY_SUCCESS,
               ghostty_cell_get(cell, GHOSTTY_CELL_DATA_WIDE, &wide) == GHOSTTY_SUCCESS,
               wide == GHOSTTY_CELL_WIDE_SPACER_TAIL, extent.startCol > 0 {
                extent.startCol -= 1
            }
            wide = GHOSTTY_CELL_WIDE_NARROW
            if ghostty_grid_ref_cell(&ordered.end, &cell) == GHOSTTY_SUCCESS,
               ghostty_cell_get(cell, GHOSTTY_CELL_DATA_WIDE, &wide) == GHOSTTY_SUCCESS {
                if wide == GHOSTTY_CELL_WIDE_SPACER_HEAD, !extent.rectangle {
                    extent.endRow += 1
                    extent.endCol = min(1, size.cols - 1)
                } else if wide == GHOSTTY_CELL_WIDE_WIDE {
                    extent.endCol = min(extent.endCol + 1, size.cols - 1)
                }
            }

            let lastRow = size.rows - 1 + max(0, rowsBelow)
            guard extent.endRow >= 0, extent.startRow <= lastRow else { return nil }
            if extent.startRow < 0 {
                extent.startRow = 0
                extent.startClipped = true
                if !extent.rectangle { extent.startCol = 0 }
            }
            if extent.endRow > lastRow {
                extent.endRow = lastRow
                extent.endClipped = true
                if !extent.rectangle { extent.endCol = size.cols - 1 }
            }
            return extent
        } ?? nil
    }

    // MARK: Selection UI (handles, triple tap). See docs/selection.md.

    /// Starts a drag that moves one end of the selection there is: the other end becomes the
    /// anchor, and `extendSelection` then selects from it to the finger. Returns false without a
    /// selection.
    @discardableResult
    func beginSelectionAdjust(movingStart: Bool, anchor: GhosttySelectionAnchor) -> Bool {
        var began = false
        lockTerminal()
        if let t = terminal, var selection = Self.currentSelection(t) {
            releaseTrackedRef(of: ObjectIdentifier(anchor))
            var ordered = GhosttySelection()
            if ghostty_terminal_selection_ordered(t, &selection, GHOSTTY_SELECTION_ORDER_FORWARD, &ordered) == GHOSTTY_SUCCESS {
                var fixed = movingStart ? ordered.end : ordered.start
                // A reference is tracked from a point. Screen coordinates name every row; the
                // lookup walks the page list once per grab.
                var point = GhosttyPoint()
                point.tag = GHOSTTY_POINT_TAG_SCREEN
                var tracked: GhosttyTrackedGridRef?
                if ghostty_terminal_point_from_grid_ref(t, &fixed, GHOSTTY_POINT_TAG_SCREEN, &point.value.coordinate) == GHOSTTY_SUCCESS,
                   ghostty_terminal_grid_ref_track(t, point, &tracked) == GHOSTTY_SUCCESS, let tracked {
                    trackedRefs[ObjectIdentifier(anchor)] = GhosttyTrackedRef(ref: tracked, screen: Self.activeScreen(t))
                    began = true
                }
            }
        }
        termLock.unlock()
        return began
    }

    /// Selects the line on a viewport cell: Ghostty's line selection, which follows soft wraps
    /// and leaves out the blanks around the text. Returns false on an empty line (the selection
    /// there was is cleared, like a press that finds no word).
    @discardableResult
    func selectLine(col: Int, row: Int) -> Bool {
        var selected = false
        var changed = false
        lockTerminal()
        if let t = terminal {
            let had = Self.currentSelection(t) != nil
            var options = GhosttyTerminalSelectLineOptions()
            options.size = MemoryLayout<GhosttyTerminalSelectLineOptions>.size
            var selection = GhosttySelection()
            if let ref = Self.ref(t, Self.clamp(t, col: col, row: row)) {
                options.ref = ref
                if ghostty_terminal_select_line(t, &options, &selection) == GHOSTTY_SUCCESS {
                    ghostty_terminal_set(t, GHOSTTY_TERMINAL_OPT_SELECTION, &selection)
                    selected = true
                    changed = true
                }
            }
            if !selected, had {
                ghostty_terminal_set(t, GHOSTTY_TERMINAL_OPT_SELECTION, nil)
                changed = true
            }
        }
        termLock.unlock()
        if changed { selectionChanged() }
        return selected
    }

    // MARK: Helpers (call with `termLock` held)

    private static func grid(_ t: GhosttyTerminal) -> (cols: Int, rows: Int) {
        var c: UInt16 = 0, r: UInt16 = 0
        ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_COLS, &c)
        ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_ROWS, &r)
        return (max(1, Int(c)), max(1, Int(r)))
    }

    private static func clamp(_ t: GhosttyTerminal, col: Int, row: Int) -> (col: Int, row: Int) {
        let size = grid(t)
        return (max(0, min(col, size.cols - 1)), max(0, min(row, size.rows - 1)))
    }

    private static func activeScreen(_ t: GhosttyTerminal) -> UInt32 {
        var screen = GHOSTTY_TERMINAL_SCREEN_PRIMARY
        ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &screen)
        return screen.rawValue
    }

    private static func viewportPoint(_ cell: (col: Int, row: Int)) -> GhosttyPoint {
        var point = GhosttyPoint()
        point.tag = GHOSTTY_POINT_TAG_VIEWPORT
        point.value.coordinate = GhosttyPointCoordinate(x: UInt16(clamping: cell.col), y: UInt32(clamping: cell.row))
        return point
    }

    /// An untracked reference to a viewport cell. Dies on the next call that changes the terminal.
    private static func ref(_ t: GhosttyTerminal, _ cell: (col: Int, row: Int)) -> GhosttyGridRef? {
        var ref = GhosttyGridRef()
        return ghostty_terminal_grid_ref(t, viewportPoint(cell), &ref) == GHOSTTY_SUCCESS ? ref : nil
    }

    private static func wide(_ t: GhosttyTerminal, _ cell: (col: Int, row: Int)) -> GhosttyCellWide {
        var wide = GHOSTTY_CELL_WIDE_NARROW
        guard var ref = ref(t, cell) else { return wide }
        var raw: GhosttyCell = 0
        if ghostty_grid_ref_cell(&ref, &raw) == GHOSTTY_SUCCESS {
            ghostty_cell_get(raw, GHOSTTY_CELL_DATA_WIDE, &wide)
        }
        return wide
    }

    private static func currentSelection(_ t: GhosttyTerminal) -> GhosttySelection? {
        var selection = GhosttySelection()
        return ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_SELECTION, &selection) == GHOSTTY_SUCCESS ? selection : nil
    }

    /// True if two references name the same cell.
    private static func same(_ t: GhosttyTerminal, _ a: GhosttyGridRef, _ b: GhosttyGridRef) -> Bool {
        var one = GhosttySelection(start: a, end: a, rectangle: false)
        var other = GhosttySelection(start: b, end: b, rectangle: false)
        var equal = false
        ghostty_terminal_selection_equal(t, &one, &other, &equal)
        return equal
    }

    /// The first codepoint of the cell, or nil if the cell is empty.
    private static func codepoint(_ ref: inout GhosttyGridRef) -> UInt32? {
        var buffer: (UInt32, UInt32, UInt32, UInt32) = (0, 0, 0, 0)
        var written = 0
        let result = withUnsafeMutablePointer(to: &buffer) {
            $0.withMemoryRebound(to: UInt32.self, capacity: 4) { ghostty_grid_ref_graphemes(&ref, $0, 4, &written) }
        }
        // A cluster longer than the buffer still starts with a real codepoint: it is a word.
        if result == GHOSTTY_OUT_OF_SPACE { return 0x61 }
        return result == GHOSTTY_SUCCESS && written > 0 ? buffer.0 : nil
    }

    /// The word on a cell: Ghostty's word selection (it follows soft wraps) with our boundary
    /// set, minus sentence punctuation at its end. Nil on an empty cell or a boundary character.
    private static func wordSelection(_ t: GhosttyTerminal, _ ref: inout GhosttyGridRef) -> GhosttySelection? {
        guard let first = codepoint(&ref), !selectionWordBoundaries.contains(first) else { return nil }
        var options = GhosttyTerminalSelectWordOptions()
        options.size = MemoryLayout<GhosttyTerminalSelectWordOptions>.size
        options.ref = ref
        var selection = GhosttySelection()
        let found = selectionWordBoundaries.withUnsafeBufferPointer { boundaries -> Bool in
            options.boundary_codepoints = boundaries.baseAddress
            options.boundary_codepoints_len = boundaries.count
            return ghostty_terminal_select_word(t, &options, &selection) == GHOSTTY_SUCCESS
        }
        guard found else { return nil }
        // A word of only punctuation keeps its first character.
        var guardCount = 0
        while guardCount < 256, !same(t, selection.start, selection.end),
              let last = codepoint(&selection.end), selectionTrailingPunctuation.contains(last) {
            guard ghostty_terminal_selection_adjust(t, &selection, GHOSTTY_SELECTION_ADJUST_LEFT) == GHOSTTY_SUCCESS else { break }
            guardCount += 1
        }
        return selection
    }
}
