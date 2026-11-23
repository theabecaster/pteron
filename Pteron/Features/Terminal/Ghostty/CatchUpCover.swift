import Foundation

/// Whether a new cover (the keyboard's, find's bar) waits for the end of the catch-up hold.
///
/// A cover to take builds a frame, and a frame takes the whole terminal as parsed so far. While
/// the grid is the one the hold began with, that is the screen the user knows, shifted above
/// the keyboard: it draws at once, as without a hold. Once another grid was asked for or
/// restored under the hold, the cover changes with that grid (a fitted pane that opens with the
/// keyboard up, a claim's resize on its way), and the frame would show the screen half caught
/// up, at a size it does not keep: a 24-row picture, then a 53-row one, before the 30 rows that
/// fit. From then on the cover waits, until the hold ends. Pure: `GhosttyCore` asks at each
/// resize and restore under the hold.
enum CatchUpCover {
    /// `changed`: a grid other than `held` was seen under this hold before. `held`: the grid
    /// when the hold went up. `now`: the grid asked for or restored.
    static func waits(changed: Bool, held: (cols: Int, rows: Int), now: (cols: Int, rows: Int)) -> Bool {
        changed || now != held
    }
}
