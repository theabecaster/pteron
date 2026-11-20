import Foundation

/// The snapshot as it travels from the phone to the watch: a property list with the
/// snapshot's bytes under one key, as the phone wrote them to its own file.
public enum WatchPayload {
    public static let key = "s"

    public static func dictionary(_ snapshot: Data) -> [String: Any] {
        [key: snapshot]
    }

    public static func snapshot(in payload: [String: Any]) -> Data? {
        payload[key] as? Data
    }
}

/// The watch's side of the snapshot: the one writer of the watch's `glance/snapshot.json`,
/// which the watch app and its complications read. It decides which payload wins and writes
/// the winner as it arrived, so a newer phone's extra fields survive on disk.
///
/// **Which payload wins.** Deliveries can arrive late and out of order.
///
/// | Arrived | Kept on the watch | |
/// |---|---|---|
/// | not a snapshot | anything | dropped |
/// | a higher `v` than this app reads | anything | written: the phone's app is newer, and the watch shows its placeholder |
/// | a snapshot | nothing, or a file it can't read | written |
/// | a snapshot | dated over `clockSlack` in the watch's future (the phone's clock went back) | written |
/// | a higher `seq` | a snapshot | written |
/// | the same or a lower `seq` | a snapshot | written only when its `asOf` is later: the phone's count started again (the app was installed anew); else dropped, as late or as the same snapshot delivered twice |
/// | no `seq` on either side | a snapshot | written when its `asOf` is later |
public struct WatchInbox: Sendable {
    /// How far the phone's clock and the watch's may differ before a date counts as the future.
    public static var clockSlack: TimeInterval { 120 }

    public let store: GlanceStore

    public init(store: GlanceStore) {
        self.store = store
    }

    public static func accepts(_ arrived: GlanceReading, over kept: GlanceReading, now: Date) -> Bool {
        switch arrived {
        case .missing: return false
        case .newer: return true
        case .snapshot(let new):
            guard let old = kept.snapshot else { return true }
            if old.asOf.timeIntervalSince(now) > clockSlack { return true }
            if let a = new.seq, let b = old.seq, a > b { return true }
            return new.asOf > old.asOf
        }
    }

    /// Takes a payload from the phone. True when it replaced the file.
    @discardableResult
    public func receive(_ payload: [String: Any], now: Date) -> Bool {
        guard let data = WatchPayload.snapshot(in: payload) else { return false }
        return receive(data, now: now)
    }

    @discardableResult
    public func receive(_ data: Data, now: Date) -> Bool {
        guard Self.accepts(GlanceReading(data), over: store.read(), now: now) else { return false }
        return (try? store.write(data)) != nil
    }
}

/// How long the watch's background task for a delivery stays: until the session has nothing
/// more to hand over, asked every `step`, and for `limit` at most, so a session that never
/// settles can't hold the task until the system ends it.
public enum WatchDrain {
    public static var step: TimeInterval { 0.2 }
    public static var limit: TimeInterval { 10 }

    /// Returns true when nothing was pending at the end, false when the limit ran out.
    @discardableResult
    public static func wait(pending: @Sendable () -> Bool, sleep: @Sendable (TimeInterval) async -> Void) async -> Bool {
        var steps = 0
        while pending() {
            guard steps < Int((limit / step).rounded()) else { return false }
            await sleep(step)
            steps += 1
        }
        return true
    }
}
