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

/// The selection UI members an engine may leave out (see `TerminalEngineView`). With these
/// defaults the host shows no handles and leaves taps to the engine's own view.
extension TerminalEngineView {
    var usesHostSelectionUI: Bool { false }
    var selectionEnds: TerminalSelectionEnds? { nil }
    var selectionGeometryStamp: Int { 0 }
    func beginSelectionAdjust(movingStart: Bool) -> Bool { false }
    func selectLine(at p: CGPoint) -> Bool { false }
    func gridCell(at p: CGPoint) -> TerminalGridCell? { nil }
    var cursorGridCell: TerminalGridCell? { nil }
    var sendsTapsToProgram: Bool { false }
}
