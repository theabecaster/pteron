import Foundation

/// How old a snapshot is, as the widgets treat it. Pure, with the time passed in.
///
/// | Age | Shown |
/// |---|---|
/// | under 2 min | as current |
/// | 2 min to 1 h | with "as of 12:04" |
/// | over 1 h | dimmed, with "Open … to refresh" |
///
/// A snapshot dated in the future (the clock was set back) is taken as written now.
public enum GlanceFreshness: Equatable, Sendable {
    case fresh, aging, stale

    public static let agingAfter: TimeInterval = 2 * 60
    public static let staleAfter: TimeInterval = 60 * 60

    public init(asOf: Date, now: Date) {
        let age = now.timeIntervalSince(asOf)
        self = age < Self.agingAfter ? .fresh : age < Self.staleAfter ? .aging : .stale
    }

    /// The moments a widget's timeline needs an entry for, so it ages with no reload: `now`,
    /// then when the snapshot turns aging and when it turns stale, where those are still ahead.
    public static func entryDates(asOf: Date, now: Date) -> [Date] {
        let from = min(asOf, now)
        return [now] + [from.addingTimeInterval(agingAfter), from.addingTimeInterval(staleAfter)].filter { $0 > now }
    }
}
