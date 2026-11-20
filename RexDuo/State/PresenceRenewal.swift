import Foundation

/// When the app says again that it is in front. Beacon counts a phone as in front only while
/// its claim (`push_presence {active: true}`) is younger than three minutes, so a phone whose
/// "gone to the background" never arrived stops counting by itself. The app therefore repeats
/// the claim while it is in front, and stops when it leaves.
///
/// Only the timing is here; `PushRegistrar` sends the calls and owns the wait.
struct PresenceRenewal: Equatable {
    /// How often the claim is repeated while the app is in front.
    static let every: TimeInterval = 60
    /// How long Beacon keeps a claim that is not repeated (`CLAIM_LIFE` in Relay/src/desk.rs).
    /// Two repeats in a row can be lost before the claim ends.
    static let claimLife: TimeInterval = 180

    /// When the claim last went out. Nil while the app is not in front.
    private(set) var claimedAt: Date?

    /// The app is in front and has just said so.
    mutating func start(at now: Date) {
        claimedAt = now
    }

    /// The app left the front: nothing is repeated until the next `start`.
    mutating func stop() {
        claimedAt = nil
    }

    /// How long to wait before the next repeat is due. Nil while the app is not in front: the
    /// waiting ends. A clock that was set back makes the repeat due now, never later than
    /// `every` from now.
    func wait(at now: Date) -> TimeInterval? {
        guard let claimedAt else { return nil }
        let since = now.timeIntervalSince(claimedAt)
        guard since >= 0 else { return 0 }
        return max(Self.every - since, 0)
    }

    /// True when a repeat is due now, and then counts it as sent. False while the app is not
    /// in front, and for a wait that ended early.
    mutating func renew(at now: Date) -> Bool {
        guard wait(at: now) == 0 else { return false }
        claimedAt = now
        return true
    }
}
