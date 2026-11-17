import UIKit

/// A cell of the terminal: `row` counts from the top of the scrollback.
struct TerminalGridCell: Equatable {
    var col: Int
    var row: Int
}

/// Where the two ends of the selection are drawn, in the engine view's coordinates: the rect of
/// the first selected cell and of the last. An end is nil while it is scrolled out of view.
struct TerminalSelectionEnds: Equatable {
    var start: CGRect?
    var end: CGRect?
}
