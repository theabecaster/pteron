import Foundation

/// How long a fitted pane keeps its claim after the app leaves the front (docs/terminal.md, The
/// catch-up fence, "Back from the background").
///
/// Giving the pane back at once cost a quick return two resizes: the Mac's size as the app
/// left, the phone's as it came back. An agent such as Claude Code reprints its whole transcript
/// on each, and the second one ran on while the user was already typing again. Kept for a short
/// absence (a reply to a message, a look at another app), the pane has the size it had and
/// nothing is redrawn: the return is the screen the user left, and typed keys go at once.
///
/// The Mac shows the pane at the phone's size for those seconds, as it does during the claim
/// grace of a pane the phone switched away from (Parking), and then gets its size back. The
/// Mac's own take wins at once at any moment: the server makes it the owner, and the phone
/// never takes the pane back by itself (`FitTenure`).
enum BackgroundGrace {
    /// The same as a parked pane's claim grace (`LeaveTiming.claimGrace`): one rule for how long
    /// the Mac waits for a phone that looked away. Well inside the time iOS gives a background
    /// task (about 30 s), so the release still leaves before the app is suspended.
    static let seconds: TimeInterval = 10

    /// Whether the claim stays as the app leaves: only a size the server answered, with nothing
    /// on its way. A claim still settling or unanswered is given up at once, as before, so it
    /// can't resize the pane for a phone that isn't looking.
    static func keeps(fitted: Bool, claimed: Bool, onItsWay: Bool, inWindow: Bool) -> Bool {
        fitted && claimed && !onItsWay && inWindow
    }
}
