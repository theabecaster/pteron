import CoreGraphics

/// Grid math for `TerminalHost`, kept free of UIKit so it can be tested.
enum TerminalLayout {
    /// Fit mode never asks Rex for a grid smaller than this, however small the view.
    static let minCols = 12
    static let minRows = 4

    /// The largest grid of `cell`-sized cells that fits in `size`.
    static func fitGrid(in size: CGSize, cell: CGSize) -> (cols: Int, rows: Int) {
        // The 0.01 keeps a view that is an exact multiple of the cell from losing a column to rounding.
        let c = max(Int((size.width + 0.01) / max(cell.width, 1)), minCols)
        let r = max(Int((size.height + 0.01) / max(cell.height, 1)), minRows)
        return (c, r)
    }

    /// The size fit mode fits the grid to. The software keyboard covers a pane instead of
    /// resizing it, so on the main screen that is the pane's size with the keyboard down
    /// (`rest`) while the pane is shorter than that. `rest` counts only for the pane's width as
    /// it is now (after a rotation or a fold it is another pane's). On the alternate screen the
    /// grid fits what shows.
    static func fitSize(bounds: CGSize, rest: CGSize?, alternateScreen: Bool) -> CGSize {
        guard !alternateScreen, let rest, abs(rest.width - bounds.width) < 1, rest.height > bounds.height else { return bounds }
        return CGSize(width: bounds.width, height: rest.height)
    }

    /// How much of a terminal `terminal` points tall the bottom of a pane `pane` points tall
    /// hides. A grid that fits its pane can be a point or so taller than it; that is no cover.
    static func cover(terminal: CGFloat, pane: CGFloat) -> CGFloat {
        let over = terminal - pane
        return over < 2 ? 0 : over
    }
}
