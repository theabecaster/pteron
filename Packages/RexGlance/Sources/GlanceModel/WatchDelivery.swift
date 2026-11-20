import Foundation

/// When the phone sends the snapshot to the watch, and how. Pure: the time, the snapshot and
/// what the session says are passed in, and `GlanceBridge` does what the returned step says.
///
/// Every delivery can wake the watch, so few are made:
///
/// - **A change in who waits** goes at once, and the next one no sooner than `urgentGap` after
///   the last delivery.
/// - **Any other change** (counts, a link, a color) goes no sooner than `quietGap` after the
///   last delivery.
/// - **Nothing new to show** sends nothing, except a restamp: a snapshot dated `restampEvery`
///   after the one last sent goes too, so the watch's "as of" doesn't age while the app watches.
/// - **The app leaves** (`.leaving`): a change still held goes now, whatever the gap.
/// - **The session opens** (`.opened`: it was activated, the watch app was installed, or the
///   person switched watches): the newest snapshot goes once, whatever was sent before.
/// - **A complication transfer** rides along only when the count of waiting agents differs
///   from the one last transferred, a complication is on a watch face, and the day's budget has
///   transfers left. Otherwise the system would queue it as plain user info.
///
/// Nothing is sent while the session isn't activated, no watch is paired or the watch app
/// isn't installed.
public struct WatchDelivery: Equatable, Sendable {
    public static var urgentGap: TimeInterval { 30 }
    public static var quietGap: TimeInterval { 60 }
    public static var restampEvery: TimeInterval { WriteThrottle<Int>.restampEvery }

    /// What the session says before a send.
    public struct Link: Equatable, Sendable {
        /// Activated, with a paired watch that has the watch app.
        public var ready: Bool
        public var complicationEnabled: Bool
        public var transfersLeft: Int

        public init(ready: Bool, complicationEnabled: Bool = false, transfersLeft: Int = 0) {
            self.ready = ready
            self.complicationEnabled = complicationEnabled
            self.transfersLeft = transfersLeft
        }
    }

    public enum Reason: Equatable, Sendable {
        /// The app wrote a snapshot, or a held one comes due.
        case wrote
        /// The app goes to the background.
        case leaving
        /// The session can deliver now and could not before.
        case opened
    }

    public struct Step: Equatable, Sendable {
        /// `updateApplicationContext`.
        public var context: Bool
        /// `transferCurrentComplicationUserInfo`, with the same payload.
        public var complication: Bool

        public static let none = Step(context: false, complication: false)
    }

    /// One wait: the machine, the pane and since when. An agent that is answered and asks
    /// again in the same pane is another wait.
    struct Wait: Hashable, Sendable {
        var machine, block: String
        var since: Date
    }

    private var sentKey: GlanceSnapshot.VisibleKey?
    private var sentWaits: Set<Wait> = []
    private var sentAsOf: Date?
    private var lastSend: Date?
    /// The waiting count of the last complication transfer.
    private var transferred: Int?

    public init() {}

    static func waits(_ s: GlanceSnapshot) -> Set<Wait> {
        Set(s.machines.flatMap { m in m.waiting.map { Wait(machine: m.id, block: $0.block, since: $0.since) } })
    }

    /// The count a complication shows: over the machines that were connected at the write.
    static func waitingCount(_ s: GlanceSnapshot) -> Int {
        s.machines.filter { $0.link == .live }.reduce(0) { $0 + $1.counts.waiting }
    }

    private func isNews(_ s: GlanceSnapshot) -> Bool {
        guard let sentKey, let sentAsOf else { return true }
        return s.visibleKey != sentKey || s.asOf.timeIntervalSince(sentAsOf) >= Self.restampEvery
    }

    /// When `snapshot` may go: now or earlier when it is due, nil when it has nothing new.
    private func due(_ s: GlanceSnapshot) -> Date? {
        guard isNews(s) else { return nil }
        guard let lastSend else { return .distantPast }
        let urgent = sentKey == nil || Self.waits(s) != sentWaits
        return lastSend.addingTimeInterval(urgent ? Self.urgentGap : Self.quietGap)
    }

    /// When to offer the newest snapshot again because the gap holds it. Nil: nothing is held.
    public func wake(_ snapshot: GlanceSnapshot?, now: Date) -> Date? {
        guard let snapshot, let due = due(snapshot), due > now else { return nil }
        return due
    }

    /// What to send of `snapshot` now. A step that sends is taken as sent; call `failed()` when
    /// the session refused it.
    public mutating func offer(_ s: GlanceSnapshot, reason: Reason, link: Link, now: Date) -> Step {
        guard link.ready else { return .none }
        switch reason {
        case .opened:
            break
        case .leaving:
            guard isNews(s) else { return .none }
        case .wrote:
            guard let due = due(s), due <= now else { return .none }
        }
        sentKey = s.visibleKey
        sentWaits = Self.waits(s)
        sentAsOf = s.asOf
        lastSend = now
        let count = Self.waitingCount(s)
        let complication = link.complicationEnabled && link.transfersLeft > 0 && count != transferred
        if complication { transferred = count }
        return Step(context: true, complication: complication)
    }

    /// The session refused the last send: the next snapshot counts as new again. The gap stays.
    public mutating func failed() {
        sentKey = nil
        sentAsOf = nil
        transferred = nil
    }

    /// Another watch: nothing was sent to it yet.
    public mutating func reset() {
        self = WatchDelivery()
    }
}
