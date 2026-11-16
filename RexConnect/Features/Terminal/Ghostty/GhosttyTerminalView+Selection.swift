import UIKit

/// What the main thread remembers about the selection, so the common question ("is there one?",
/// asked on every tap) needs no lock when the answer is no. The range itself lives in the
/// terminal; stored state is in the "Selection" block of GhosttyTerminalView.swift.
struct GhosttySelectionState: Equatable {
    /// We installed a selection and haven't cleared it. The terminal can still drop it by itself
    /// (a reset, a snapshot restore), so a true is checked against the terminal before it's told.
    var active = false
    /// The selection came from `beginSelection` / `extendSelection`, not from Select All.
    var fromGesture = false
    /// A press or pointer drag is under way.
    var dragging = false
    /// The drag has left the cell it started on.
    var moved = false
    /// Where the finger last was, in the view's coordinates.
    var point = CGPoint.zero
    /// The scroll request an edge of the drag asked for (`GhosttyScroller.lastRequest`). Once a
    /// frame has applied it, the selection is extended to the row that came under the finger.
    var autoscrollRequest: Int?
}

/// The shapes `selectionRects` reports, from the cells the viewport shows of a selection. Pure:
/// `place` says where cells of one row are drawn.
enum GhosttySelectionRects {
    /// One rectangle per selected stretch, clipped to `bounds`: the first row from its start to
    /// the right edge, the rows between as one block, and the last row up to its end. The same
    /// shapes the SwiftTerm engine reports.
    static func make(_ e: GhosttySelectionExtent, bounds: CGRect, place: (_ row: Int, _ columns: Range<Int>) -> CGRect) -> [CGRect] {
        guard e.endRow >= e.startRow else { return [] }
        let cols = max(e.cols, 1)
        func rect(rows: ClosedRange<Int>, from: Int, through: Int) -> CGRect {
            let columns = from..<(through + 1)
            return place(rows.lowerBound, columns).union(place(rows.upperBound, columns))
        }
        var out: [CGRect] = []
        if e.rectangle {
            out.append(rect(rows: e.startRow...e.endRow, from: min(e.startCol, e.endCol), through: max(e.startCol, e.endCol)))
        } else if e.startRow == e.endRow {
            guard e.endCol >= e.startCol else { return [] }
            out.append(rect(rows: e.startRow...e.startRow, from: e.startCol, through: e.endCol))
        } else {
            out.append(rect(rows: e.startRow...e.startRow, from: e.startCol, through: cols - 1))
            if e.endRow - e.startRow > 1 {
                out.append(rect(rows: (e.startRow + 1)...(e.endRow - 1), from: 0, through: cols - 1))
            }
            out.append(rect(rows: e.endRow...e.endRow, from: 0, through: e.endCol))
        }
        return out.map { $0.intersection(bounds) }.filter { !$0.isNull && $0.width > 0 && $0.height > 0 }
    }
}



// Selection for the Ghostty engine. TerminalHost owns the gestures, the clipboard, the shimmer
// and the edit menu, and drives these members (see `TerminalEngineView`); they do what
// `RexTerminalView` in Engine/SwiftTermEngine.swift does. The terminal owns the range
// (GhosttyCore+Selection.swift) and the renderer draws it from the render state.
//
// Where the grid is comes from the scroller (GhosttyTerminalView+Scroll.swift): `viewportCell(at:)`
// for points, `viewportRect(row:columns:)` for rects, `autoscrollSelection(at:)` for a drag at an
// edge. Those read the scroll position of the last drawn frame, so hit-testing and rects are
// right at any fraction of a row and anywhere in the scrollback. This view doesn't scroll, so
// points and rects are in the viewport's coordinates.
//
// Unlike SwiftTerm, the selection survives a resize: the terminal tracks it through the reflow.
extension GhosttyTerminalView {
    var hasActiveSelection: Bool {
        guard selectionState.active else { return false }
        if !core.hasSelection {
            selectionState.active = false
            selectionState.fromGesture = false
        }
        return selectionState.active
    }

    /// A plain long press, as SwiftTerm's view has one: the host gives it its target and timing.
    var selectionPressRecognizer: UILongPressGestureRecognizer? { selectionPress }

    /// This engine has no pan that selects: its pans are the scroll surface's own
    /// (`scrollPanRecognizer`), the one-finger pan that sends wheel reports or arrow keys to a
    /// program, and the pointer-scroll pans. All of them ask `panGate`, where the host refuses
    /// every pan while it selects, so a selection is only ever changed by the host's long press
    /// or pointer drag through `beginSelection` / `extendSelection`.
    func isBuiltInSelectionPan(_ pan: UIPanGestureRecognizer) -> Bool { false }

    func beginSelection(at p: CGPoint, word: Bool) {
        let cell = viewportCell(at: p)
        let selected = core.beginSelection(col: cell.col, row: cell.row, word: word, anchor: selectionAnchor)
        selectionState = GhosttySelectionState(active: selected, fromGesture: selected, dragging: true, moved: false, point: p)
    }

    func extendSelection(to p: CGPoint, autoscroll: Bool) {
        guard selectionState.dragging else { return }
        selectionState.point = p
        extendSelectionToPoint()
        // At an edge, one line per move, like the SwiftTerm engine. The scroller moves the
        // viewport with the next frame; `selectionScrollApplied` then extends to the row that
        // scrolled under the finger.
        if autoscroll, autoscrollSelection(at: p) != 0 { selectionState.autoscrollRequest = scroller.lastRequest }
    }

    private func extendSelectionToPoint() {
        let cell = viewportCell(at: selectionState.point)
        let result = core.extendSelection(col: cell.col, row: cell.row, anchor: selectionAnchor, keepOnAnchor: !selectionState.moved)
        if case .extended = result {
            selectionState.moved = true
            selectionState.active = true
            selectionState.fromGesture = true
        }
    }

    /// The scroller took a frame's scroll state. If it applied the line an edge drag asked for,
    /// the finger is now over another row.
    func selectionScrollApplied(_ snapshot: GhosttyScrollState.Snapshot) {
        guard selectionState.dragging, let request = selectionState.autoscrollRequest, snapshot.appliedSequence >= request else { return }
        selectionState.autoscrollRequest = nil
        extendSelectionToPoint()
    }

    func endSelectionDrag() {
        guard selectionState.dragging else { return }
        selectionState.dragging = false
        selectionState.moved = false
        selectionState.autoscrollRequest = nil
        core.endSelection(anchor: selectionAnchor)
    }

    func clearSelectedRange() {
        guard selectionState.active else { return }
        selectionState.active = false
        selectionState.fromGesture = false
        core.clearSelection()
    }

    var selectedText: String? {
        selectionState.active ? core.selectedText : nil
    }

    var selectionRects: [CGRect] {
        guard selectionState.active, selectionState.fromGesture else { return [] }
        // A row scrolled partly past the top leaves part of the row under the grid in view.
        let scroll = scrollSnapshot
        guard let extent = core.selectionExtent(rowsBelow: scroll.fraction > 0 ? 1 : 0) else { return [] }
        return GhosttySelectionRects.make(extent, bounds: bounds) { viewportRect(row: $0, columns: $1) }
    }

    func selectAllText() {
        selectionState.active = core.selectAll()
        selectionState.fromGesture = false
    }
}
