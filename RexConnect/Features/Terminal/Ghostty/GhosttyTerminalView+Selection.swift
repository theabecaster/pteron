import UIKit

/// What the main thread remembers about the selection, so the common question ("is there one?",
/// asked on every tap) needs no lock when the answer is no. The range itself lives in the
/// terminal; stored state is in the "PHASE 2 (selection)" block of GhosttyTerminalView.swift.
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
}

// Selection for the Ghostty engine. TerminalHost owns the gestures, the clipboard, the shimmer
// and the edit menu, and drives these members (see `TerminalEngineView`); they do what
// `RexTerminalView` in Engine/SwiftTermEngine.swift does. The terminal owns the range
// (GhosttyCore+Selection.swift) and the renderer draws it from the render state.
//
// Unlike SwiftTerm, the selection survives a resize: the terminal tracks it through the reflow.
extension GhosttyTerminalView {
    /// Where the grid is in this view. The one place selection reads the viewport's position
    /// from: `bounds` already holds the content offset if this view scrolls natively.
    var selectionGeometry: GhosttySelectionGeometry {
        GhosttySelectionGeometry(cell: cellSize, cols: cols, rows: rows, viewport: bounds, scrollShift: selectionScrollShift)
    }

    /// Points the grid is shifted up by a smooth scroll (what `renderer.setScrollOffset` draws,
    /// divided by the display scale). Nothing scrolls by fractions of a row yet.
    var selectionScrollShift: CGFloat { 0 }

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

    /// This view has no selection pan of its own.
    func isBuiltInSelectionPan(_ pan: UIPanGestureRecognizer) -> Bool { false }

    func beginSelection(at p: CGPoint, word: Bool) {
        let cell = selectionGeometry.cell(at: p)
        let selected = core.beginSelection(col: cell.col, row: cell.row, word: word, anchor: selectionAnchor)
        selectionState = GhosttySelectionState(active: selected, fromGesture: selected, dragging: true, moved: false)
    }

    func extendSelection(to p: CGPoint, autoscroll: Bool) {
        guard selectionState.dragging else { return }
        let geometry = selectionGeometry
        let cell = geometry.cell(at: p)
        // The grid scrolls under the finger, so the same point then names the next row.
        let scroll = autoscroll ? geometry.autoscrollRows(at: p) : 0
        let result = core.extendSelection(col: cell.col, row: cell.row, anchor: selectionAnchor, scrollRows: scroll,
                                          keepOnAnchor: !selectionState.moved)
        if case .extended = result {
            selectionState.moved = true
            selectionState.active = true
            selectionState.fromGesture = true
        }
    }

    func endSelectionDrag() {
        guard selectionState.dragging else { return }
        selectionState.dragging = false
        selectionState.moved = false
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
        guard selectionState.active, selectionState.fromGesture, let extent = core.selectionExtent else { return [] }
        return selectionGeometry.rects(for: extent)
    }

    func selectAllText() {
        selectionState.active = core.selectAll()
        selectionState.fromGesture = false
    }
}
