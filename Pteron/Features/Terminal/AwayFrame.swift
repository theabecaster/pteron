/// The screen a pane showed as the app left the front, kept on show at its own grid until the
/// return has caught up (docs/terminal.md, Back from the background).
///
/// In the background a fitted pane is handed back to the Mac (after `BackgroundGrace`), and
/// the Mac's size and redraw can reach the phone while the app still runs there. Laid out at that grid,
/// the pane's layer grew around the last frame it had presented, the phone's, and nothing drew
/// in the background: on the return the pane showed that frame stretched to the Mac's grid
/// (about 7 times as wide on the folded Duo), then the Mac's grid for a frame, then its own.
///
/// So from the moment the app leaves, the pane's view keeps the grid of the frame on show, and
/// the engine keeps that frame (`GhosttyTerminalView.holdWhileAway`, a catch-up hold with no
/// time limit), while the terminal parses whatever comes. Back in front, the frame stays until
/// the stream's fence comes down or its hold ends: the claim's resize has landed and the
/// screen is current, and it shows as one frame at the pane's own size.
struct AwayFrame {
    /// The grid of the frame kept on show. Nil while nothing is kept.
    private(set) var grid: (cols: Int, rows: Int)?

    var isOn: Bool { grid != nil }

    /// The app left the front. Only a pane in a window that shows a screen keeps it. True when
    /// the keeping begins now; a second departure before the return caught up keeps the frame
    /// the user saw first.
    mutating func left(showing shown: (cols: Int, rows: Int), hasScreen: Bool, inWindow: Bool) -> Bool {
        guard grid == nil, hasScreen, inWindow, shown.cols > 0, shown.rows > 0 else { return false }
        grid = shown
        return true
    }

    /// The grid to lay the pane's view out at: the kept frame's while there is one, else the
    /// engine's.
    func layoutGrid(engine: (cols: Int, rows: Int)) -> (cols: Int, rows: Int) {
        grid ?? engine
    }

    /// The app is back in front. With the stream catching up the frame stays until it has
    /// (`caughtUp`); with nothing to catch up it goes now. True when it ends now.
    mutating func returned(catchingUp: Bool) -> Bool {
        guard grid != nil, !catchingUp else { return false }
        grid = nil
        return true
    }

    /// The stream's fence came down or its hold ended. In the background that changes nothing:
    /// the Mac's grid may still come, and the frame must not follow it. True when it ends now.
    mutating func caughtUp(inBackground: Bool) -> Bool {
        guard grid != nil, !inBackground else { return false }
        grid = nil
        return true
    }

    /// The pane leaves the screen or stops: nothing is kept. True when it ends now.
    mutating func end() -> Bool {
        guard grid != nil else { return false }
        grid = nil
        return true
    }
}
