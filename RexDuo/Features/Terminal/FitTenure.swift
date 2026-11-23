import Foundation
import RexKit

/// What a fitted pane knows about losing the size this phone gave it: to somebody, or only to
/// the phone's own absence. Pure: `TerminalHost` asks.
///
/// A pane follows its owner's size. When the owner's connection drops, the server passes the
/// pane to the next client in line (the Mac app, which takes the panes it shows), and the pane
/// takes that client's size. Nobody asked for that. The server says why an owner changed
/// (`BlockOwnerChange.Reason`), but a client that is away hears nothing: events from while it
/// had no connection are lost. So the pane goes by what it can know when it is back:
///
/// - **The connection never dropped** since the claim was answered: another client's size or
///   name on the pane is that client's doing. The chip.
/// - **Another client asked for the pane** (`take` or `request`, heard on the connection) and
///   this phone has not taken it since: the chip, whatever else happened.
/// - **The connection dropped and the server went on with the same client** (the connection
///   was lost with no close frame, and came back inside the server's 60 s): the server gives
///   that client its panes back at its size, unless their owner changed again meanwhile. The
///   client is not told (`restore` reaches the other clients only), but its stream replays
///   the time away: the other client's size, then its own again. So the other client's size
///   is history until the pane has caught up, and nothing is decided or sent. Still there
///   once it has: the owner changed again while the phone was away, which only a client's own
///   call does. The chip.
/// - **The connection dropped and the server started a new client** (the old one was away
///   longer than the server keeps one, or its socket was closed with a close frame, which
///   ends a client at once): the old client's panes went to the next in line because it was
///   gone, and no event can say whether anybody asked for one since. The return is a claim
///   moment, as the app coming back from the background is: the pane is taken again, with no
///   chip.
/// - **The connection is down now**: nothing is decided and nothing is sent. The pane looks
///   again when the connection is back.
///
/// A take back is one reasserting claim (`FitClaim.request(reassert:)`). Its answer starts a
/// new tenure, so a size another client sets after it is that client's doing: the chip, never
/// a second take back.
struct FitTenure: Equatable {
    /// The control connection since the claim was answered.
    enum Link: Equatable {
        /// Up the whole time.
        case steady
        /// Down now.
        case down
        /// Dropped and back. `sameClient`: the server went on with the client that made the
        /// claim.
        case back(sameClient: Bool)

        /// `welcomes`: the welcomes the pane has counted, now and when the claim was answered.
        /// `down`: the connection is lost or being made. `client`: which of its clients the
        /// connection is on the server (`RexControl.clientGeneration`), now and at the answer.
        static func now(welcomes: Int, heldAt: Int, down: Bool, client: Int, heldAs: Int) -> Link {
            if down { return .down }
            if welcomes == heldAt { return .steady }
            return .back(sameClient: client == heldAs)
        }
    }

    enum Verdict: Equatable {
        /// Another client has the pane: the chip, and no fight.
        case lost
        /// The pane passed on only because this phone was away: taken again, silently.
        case takeBack
        /// Not known yet: looked at again when the pane has caught up, or the connection is back.
        case wait
    }

    /// A claim was answered and has not been given up since.
    private(set) var holds = false
    /// Which of the connection's clients this phone was when the claim was answered
    /// (`RexControl.clientGeneration`).
    private(set) var heldAs = 0
    /// The welcomes counted when the claim was answered.
    private(set) var heldAt = 0
    /// The last owner event heard named another client that asked for the pane.
    private(set) var taken = false

    /// The claim was answered: the pane is this client's, on this connection.
    mutating func claimed(as client: Int, welcomes: Int) {
        holds = true
        heldAs = client
        heldAt = welcomes
    }

    /// The pane was found as it should be after the connection came back: its tenure goes on
    /// from this connection.
    mutating func settled(as client: Int, welcomes: Int) {
        guard holds else { return }
        claimed(as: client, welcomes: welcomes)
    }

    /// The phone gave the pane up or stopped asking for it: the background, the grace after
    /// leaving it, mirror mode, a stop, the chip.
    mutating func released() {
        holds = false
        heldAs = 0
        heldAt = 0
    }

    /// An owner event for the pane.
    mutating func ownerChanged(_ change: BlockOwnerChange, me: String?) {
        switch BlockOwnerChange.party(change.owner, me: me) {
        case .other:
            // Passed on without a wish (the owner dropped, left or gave it up) is no take; a
            // take heard before stays one.
            if change.reason.isClaim { taken = true }
        case .me:
            taken = false
        case .none:
            break
        }
    }

    /// Another client's size or name was found on the pane. `settled`: the pane has caught up
    /// and nothing is on its way, so what was not heard by now will not come.
    func verdict(link: Link, settled: Bool) -> Verdict {
        guard holds, !taken else { return .lost }
        switch link {
        case .steady: return .lost
        case .down: return .wait
        case .back(sameClient: false): return .takeBack
        case .back(sameClient: true): return settled ? .lost : .wait
        }
    }

    /// Whether a pane in this place is taken back at all: only one the user is looking at.
    /// A pane that left the screen, is under the agent board, or belongs to an app in the
    /// background is not; its claim is given up by the rules for leaving, as before.
    static func mayTakeBack(inWindow: Bool, background: Bool, parked: Bool, warm: Bool, covered: Bool) -> Bool {
        inWindow && !background && !parked && !warm && !covered
    }
}
