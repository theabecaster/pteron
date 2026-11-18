import Foundation

/// What a finished pinch on a pane does. A pinch is the user asking for a text size, so it means
/// the same in every state: the size is stored (`Prefs.fontSize`) and shown. A selection being
/// dragged is the one exception: the pinch doesn't start (`TerminalPinch.starts`).
struct TerminalPinchOutcome: Equatable {
    /// The size to store and show, or nil when the pinch landed on the size the pane has.
    var size: Double?
    /// Take the pane back from the client that resized it, as tapping "Resized elsewhere · tap to
    /// fit here" does, so its grid follows the new size.
    var fitHere: Bool
}

@MainActor  // `Prefs.fontSize`, the shared rule, is on the main actor with the rest of `Prefs`.
enum TerminalPinch {
    /// Where the pane's size comes from when the pinch starts.
    enum PaneState: Equatable, CaseIterable {
        /// Fit mode, and the pane is ours: the grid follows the text size.
        case fitted
        /// Fit mode, but another client resized the pane; the chip offers to fit it here.
        case resizedElsewhere
        /// Mirror mode: the pane keeps the server's grid and is never claimed, so it can't be
        /// fitted here. The grid is drawn at the new size, scaled to the view's width.
        case mirror
    }

    /// A pinch starts in every state but while a selection is being dragged.
    static func starts(selecting: Bool) -> Bool { !selecting }

    /// The pinch went from `base` points by `scale`.
    static func outcome(_ state: PaneState, base: Double, scale: Double) -> TerminalPinchOutcome {
        let s = Prefs.fontSize(base * scale)
        return TerminalPinchOutcome(size: abs(s - base) > 0.01 ? s : nil, fitHere: state == .resizedElsewhere)
    }
}
