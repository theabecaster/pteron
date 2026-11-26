import CoreGraphics
import RexKit

/// Where a pointer event is in the pane's own pixels, for SGR-Pixels reports (mode 1016).
///
/// A program that asks for pixel reports divides them by the cell size it was told (its window
/// size, CSI 14t), and that is the pane's size on the server (`CellPixels`, 8 x 16 on a Rex pane),
/// not the phone's. So the event's place in cells, fractions included, is scaled to the pane's
/// cell size: the program finds the cell the finger is on. The phone's grid is the server's (the
/// stream's `resize` sets it), so the cell is the same on both.
///
/// Positions are in the view's own device pixels, as `GhosttyScroller.mousePosition` makes them:
/// a mirror zoom or pan and a pane's place in a split are already undone by UIKit.
enum PanePixelMap {
    struct Mapped: Equatable {
        /// Whole pixels of the pane, from its top-left corner. May be outside it for a drag that
        /// left the view.
        var position: CGPoint
        /// The pane's grid in its own pixels, for the mouse encoder.
        var geometry: GhosttyMouseReporter.Geometry
    }

    /// Nil when the pane's cell size is unknown (an older server, or 0): the report is then
    /// made in cells (SGR, mode 1006) instead.
    ///
    /// - Parameters:
    ///   - position: device pixels from the view's top-left corner.
    ///   - device: the view in device pixels, with the phone's cell size.
    ///   - cols, rows: the grid, the same here and on the server.
    static func map(_ position: CGPoint, device: GhosttyMouseReporter.Geometry, pane: CellPixels?,
                    cols: Int, rows: Int) -> Mapped? {
        guard let pane, device.cellWidth > 0, device.cellHeight > 0, cols > 0, rows > 0 else { return nil }
        let width = cols * pane.width, height = rows * pane.height
        // Whole pixels, rounded down: the cell a pixel falls in is then the cell the fraction is
        // in, at any cell size. The encoder rounds what it gets, and leaves whole pixels as
        // they are.
        var x = (position.x / CGFloat(device.cellWidth) * CGFloat(pane.width)).rounded(.down)
        var y = (position.y / CGFloat(device.cellHeight) * CGFloat(pane.height)).rounded(.down)
        // A point on the view past the grid (the part of a cell a pane has left over at its
        // edge) is the last cell, as a cell report clamps it.
        if position.x >= 0, position.x <= CGFloat(device.width) { x = min(x, CGFloat(width - 1)) }
        if position.y >= 0, position.y <= CGFloat(device.height) { y = min(y, CGFloat(height - 1)) }
        return Mapped(position: CGPoint(x: x, y: y),
                      geometry: .init(width: width, height: height, cellWidth: pane.width, cellHeight: pane.height))
    }
}
