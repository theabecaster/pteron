import CoreGraphics

/// Where the grid sits in the terminal view, for selection: point to cell and cells to rects.
/// Pure math, so tests cover it without a view.
struct GhosttySelectionGeometry: Equatable {
    /// One cell, in points.
    var cell: CGSize
    var cols: Int
    var rows: Int
    /// The part of the view that shows the grid, in the view's coordinates.
    var viewport: CGRect
    /// How far the grid is shifted up inside the viewport, in points: the fraction of a row a
    /// smooth scroll has moved it. Row 0's top is at `viewport.minY - scrollShift`.
    var scrollShift: CGFloat = 0

    private var top: CGFloat { viewport.minY - scrollShift }

    /// The viewport cell under a point in the view, clamped to the grid.
    func cell(at p: CGPoint) -> (col: Int, row: Int) {
        guard cell.width > 0, cell.height > 0 else { return (0, 0) }
        let col = Int(((p.x - viewport.minX) / cell.width).rounded(.down))
        let row = Int(((p.y - top) / cell.height).rounded(.down))
        return (max(0, min(col, max(cols - 1, 0))), max(0, min(row, max(rows - 1, 0))))
    }

    /// Rows to scroll for a drag at `p`: one up within half a cell of the top edge, one down
    /// within half a cell of the bottom edge, like the SwiftTerm engine.
    func autoscrollRows(at p: CGPoint) -> Int {
        if p.y < viewport.minY + cell.height * 0.5 { return -1 }
        if p.y > viewport.maxY - cell.height * 0.5 { return 1 }
        return 0
    }

    /// One rectangle per selected stretch, in the view's coordinates, clipped to the viewport:
    /// the first row from its start to the right edge, the rows between as one block, and the
    /// last row up to its end. The same shapes the SwiftTerm engine reports.
    func rects(for e: GhosttySelectionExtent) -> [CGRect] {
        guard e.endRow >= e.startRow, cell.width > 0, cell.height > 0 else { return [] }
        let cols = max(e.cols, 1)
        func rect(rows: ClosedRange<Int>, from: Int, through: Int) -> CGRect {
            CGRect(x: viewport.minX + CGFloat(from) * cell.width, y: top + CGFloat(rows.lowerBound) * cell.height,
                   width: CGFloat(through - from + 1) * cell.width, height: CGFloat(rows.count) * cell.height)
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
        return out.map { $0.intersection(viewport) }.filter { !$0.isNull && $0.width > 0 && $0.height > 0 }
    }
}
