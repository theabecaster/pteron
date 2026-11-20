import Foundation

/// When the app writes the snapshot and when it asks WidgetKit to redraw. Pure: the time, the
/// app's state and the snapshot's visible key are passed in, and the writer does what the
/// returned step says.
///
/// - **Write.** A new waiting agent is written within `soon`. Any other change is written
///   `later` after the first change not yet written. Going to the background always writes.
/// - **Reload while active.** After a write whose visible key differs from the one last
///   reloaded, at most once every `reloadEvery`. Reloads cost nothing while the app is in front.
/// - **Reload on the way to the background.** Only when the visible key changed since the last
///   reload. Otherwise the widgets keep the older `asOf`, which makes them look less fresh than
///   they are, never more.
/// - **Restamp.** While the app is active and a machine is live, a write and a reload every
///   `restampEvery`, so the widgets' "as of" doesn't age while the app is watching.
public struct WriteThrottle<Key: Equatable> {
    public static var soon: TimeInterval { 0.5 }
    public static var later: TimeInterval { 2 }
    public static var reloadEvery: TimeInterval { 10 }
    public static var restampEvery: TimeInterval { 15 * 60 }

    public struct Step: Equatable {
        public var write: Bool
        public var reload: Bool
    }

    private var writeDue: Date?
    private var lastWrite: Date?
    private var lastReload: Date?
    /// The visible key of the last write, and of the last reload.
    private var written: Key?
    private var reloaded: Key?
    /// A restamp was written and its reload waits for `reloadEvery`.
    private var restamped = false

    public init() {}

    /// Something the snapshot holds changed.
    public mutating func changed(newWaiting: Bool, now: Date) {
        let due = now.addingTimeInterval(newWaiting ? Self.soon : Self.later)
        writeDue = min(writeDue ?? due, due)
    }

    /// When to call `fire` next, if nothing changes before. Nil: nothing is due.
    public func wake(active: Bool, anyLive: Bool) -> Date? {
        var times: [Date] = []
        if let writeDue { times.append(writeDue) }
        if active {
            if let lastReload, wantsReload { times.append(lastReload.addingTimeInterval(Self.reloadEvery)) }
            if anyLive, let lastWrite { times.append(lastWrite.addingTimeInterval(Self.restampEvery)) }
        }
        return times.min()
    }

    private var wantsReload: Bool { written != nil && (written != reloaded || restamped) }

    /// What is due at `now`. `key` is the visible key of the snapshot a write would hold.
    public mutating func fire(now: Date, key: Key, active: Bool, anyLive: Bool) -> Step {
        let restamp = active && anyLive && lastWrite.map { now.timeIntervalSince($0) >= Self.restampEvery } == true
        let write = restamp || writeDue.map { now >= $0 } == true
        if write {
            writeDue = nil
            lastWrite = now
            written = key
            if restamp { restamped = true }
        }
        let free = lastReload.map { now.timeIntervalSince($0) >= Self.reloadEvery } ?? true
        let reload = active && wantsReload && free
        if reload { noteReload(now) }
        return Step(write: write, reload: reload)
    }

    /// The app goes to the background: always a write, and a reload only for a new picture.
    public mutating func background(now: Date, key: Key) -> Step {
        writeDue = nil
        lastWrite = now
        written = key
        let reload = written != reloaded
        if reload { noteReload(now) }
        restamped = false
        return Step(write: true, reload: reload)
    }

    private mutating func noteReload(_ now: Date) {
        lastReload = now
        reloaded = written
        restamped = false
    }
}
