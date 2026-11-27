import Foundation
import RexKit

/// A pane whose tab moves to another session of its computer (docs/terminal.md, A tab that
/// moves). The host, its screen, its history and its fit claim stay; only the session its
/// stream and its calls go through changes.
extension TerminalHost {
    /// This iPhone is moving the pane's tab: the stream's end through the old session waits for
    /// the move's end, with the screen kept behind the fence.
    func moving() { stream.expectMove() }

    /// The move failed: the pane stays where it was.
    func moveFailed() { stream.moveFailed() }

    /// The pane's tab is in `session` now: the stream opens once through it, keeping the screen
    /// until the new snapshot (`TerminalStream.moved(to:)`), and the pane's files, sharing and
    /// ports go through it. A claim the pane holds stays: the size is the same, so no resize.
    func moved(to session: String) {
        guard session != stream.sessionID else { return }
        files?.sessionID = session
        share?.sessionID = session
        ports?.sessionID = session
        reobserve?()
        stream.moved(to: session)
    }
}
