import UIKit

// What the host's selection UI (Selection/, docs/selection.md) needs from the terminal view:
// the ends of the selection for the handles, a drag that moves one end, line selection, and
// cells for haptic ticks and the cursor's Paste menu. Points, cells and rects all go through
// `gridGeometry` (GhosttyTerminalView+Scroll.swift), the one mapping.
extension GhosttyTerminalView {
    /// Where the selection's first and last cells are drawn, or nil without a selection.
    var selectionEnds: TerminalSelectionEnds? {
        guard hasActiveSelection else { return nil }
        let scroll = scrollSnapshot
        // Wholly out of view: there is a selection, and no end to draw.
        guard let extent = core.selectionExtent(rowsBelow: scroll.fraction > 0 ? 1 : 0) else { return TerminalSelectionEnds() }
        let geometry = gridGeometry
        var ends = TerminalSelectionEnds()
        let left = extent.rectangle ? min(extent.startCol, extent.endCol) : extent.startCol
        let right = extent.rectangle ? max(extent.startCol, extent.endCol) : extent.endCol
        if !extent.startClipped { ends.start = geometry.rect(row: extent.startRow, columns: left..<(left + 1)) }
        if !extent.endClipped { ends.end = geometry.rect(row: extent.endRow, columns: right..<(right + 1)) }
        return ends
    }

    /// The scroll position of the last drawn frame, folded into one number. A selection moves on
    /// screen only when one of these does. Reads the scroll state's own small lock, never the
    /// terminal's.
    var selectionGeometryStamp: Int {
        let s = scrollSnapshot
        var stamp = s.offset
        stamp = stamp &* 1_000_003 &+ s.fraction
        stamp = stamp &* 1_000_003 &+ s.bounce
        stamp = stamp &* 1_000_003 &+ s.total
        stamp = stamp &* 1_000_003 &+ s.rebase
        return stamp &* 1_000_003 &+ s.cellHeight
    }

    /// Starts a drag that moves one end of the selection while the other stays; continue with
    /// `extendSelection` and finish with `endSelectionDrag`. False without a selection.
    func beginSelectionAdjust(movingStart: Bool) -> Bool {
        guard hasActiveSelection, core.beginSelectionAdjust(movingStart: movingStart, anchor: selectionAnchor) else { return false }
        // `moved`: the finger starts on a handle, not on the anchor, so every move extends.
        selectionState.dragging = true
        selectionState.moved = true
        selectionState.autoscrollRequest = nil
        return true
    }

    /// Selects the line under `p` (a triple tap). False if there is nothing on it.
    func selectLine(at p: CGPoint) -> Bool {
        let cell = viewportCell(at: p)
        let selected = core.selectLine(col: cell.col, row: cell.row)
        selectionState.active = selected
        selectionState.fromGesture = selected
        return selected
    }

    /// The cell under `p`, with rows counted from the top of the scrollback, so a row keeps its
    /// number while the view scrolls.
    func gridCell(at p: CGPoint) -> TerminalGridCell {
        let cell = viewportCell(at: p)
        return TerminalGridCell(col: cell.col, row: scrollbackRow(ofViewportRow: cell.row))
    }

    /// The cursor's cell, in `gridCell(at:)`'s space.
    /// Takes the terminal lock (bounded, see docs/ghostty-engine.md, Threads and locks): asked on a tap.
    var cursorGridCell: TerminalGridCell {
        let cursor = core.cursorPosition
        return TerminalGridCell(col: cursor.x, row: scrollSnapshot.maxRow + cursor.y)
    }

    /// The program tracks the mouse: a tap is a click for it.
    /// Takes the terminal lock like the view's own tap does for the same question.
    var sendsTapsToProgram: Bool { core.programScrollModes().mouseTracking }
}
