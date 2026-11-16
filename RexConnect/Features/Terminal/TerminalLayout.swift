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
}
