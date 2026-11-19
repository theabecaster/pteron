import Foundation

/// Decides when the phone stands as a tent: folded most of the way back, the app on the outer
/// screen, and nobody holding it. The agent board shows then (`TentBoard`).
///
/// The hinge is used here and nowhere else, and only to enter and leave: layout never reads it
/// (`Arrangement`). Pure, with the time passed in, so it is tested.
///
/// - **Enter:** the window fills its screen, has no fold in it (an inactive one counts as a fold),
///   and the hinge has stayed between 20° and 160° for one second.
/// - **Leave at once:** the hinge goes under 15°, stops reporting, or a fold appears in the window
///   (the phone was opened and the app moved to the inner screen).
/// - Between 15° and 20°, and above 160°, a tent stays a tent: the two bounds are for entering.
///
/// A device that reports no hinge, or an angle of 0 on its outer screen, never enters.
struct TentDetector: Equatable {
    struct Reading: Equatable {
        /// The window has a fold in it, active or not: it is on the inner screen.
        var hasDivision: Bool
        /// The window covers its whole screen (not Split View, not a resized window).
        var fillsScreen: Bool
        /// The hinge's angle in degrees. Nil with no hinge.
        var angle: Double?
    }

    static let enter = 20.0...160.0
    static let exitBelow = 15.0
    static let hold: TimeInterval = 1

    private(set) var inTent = false
    /// When the readings began to qualify for entering.
    private var candidateSince: Date?

    /// Takes a reading. Returns when to call again with the same reading (the end of the hold), or
    /// nil when nothing is pending. The hinge has no guaranteed update rate, so the hold ends on
    /// that deadline, not on a second update.
    mutating func update(_ r: Reading, now: Date) -> Date? {
        let angle = r.angle.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        if inTent {
            if r.hasDivision || angle == nil || angle! < Self.exitBelow {
                inTent = false
                candidateSince = nil
            }
            return nil
        }
        guard !r.hasDivision, r.fillsScreen, let angle, Self.enter.contains(angle) else {
            candidateSince = nil
            return nil
        }
        let since = candidateSince ?? now
        candidateSince = since
        if now.timeIntervalSince(since) >= Self.hold {
            inTent = true
            candidateSince = nil
            return nil
        }
        return since.addingTimeInterval(Self.hold)
    }
}
