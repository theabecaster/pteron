import Foundation

/// What the app knows about its servers' agents when it writes a snapshot, as plain values.
public enum GlanceInput {
    public struct Machine: Equatable, Sendable {
        public var id: String
        public var name: String
        public var link: GlanceSnapshot.Link
        /// It has been connected since the app was launched, so `states` and `waiting` are what
        /// it last said. Otherwise the app knows nothing newer than the snapshot before.
        public var known: Bool
        /// Every agent's state: `blocked`, `error`, `working`, `done`; anything else is idle.
        public var states: [String?]
        /// The agents in state `blocked`, in the server's order.
        public var waiting: [Wait]
        /// Every other agent, in the server's order: what the widgets' tiles draw.
        public var busy: [GlanceSnapshot.Busy]

        public init(id: String, name: String, link: GlanceSnapshot.Link, known: Bool, states: [String?], waiting: [Wait],
                    busy: [GlanceSnapshot.Busy] = []) {
            self.id = id
            self.name = name
            self.link = link
            self.known = known
            self.states = states
            self.waiting = waiting
            self.busy = busy
        }
    }

    public struct Wait: Equatable, Sendable {
        public var session, window, block: String
        public var kind: String?
        public var name, symbol: String
        public var why: String?
        public var place: String
        public var record: String
        public var msg: String?
        /// `ActionGuard.fingerprint` of the wait, from the status record as the server gave it.
        public var fp: String?
        /// When the phone first saw this agent waiting, in this run of the app.
        public var firstSeen: Date?

        public init(session: String, window: String, block: String, kind: String?, name: String, symbol: String,
                    why: String?, place: String, record: String, msg: String?, fp: String? = nil, firstSeen: Date?) {
            self.session = session
            self.window = window
            self.block = block
            self.kind = kind
            self.name = name
            self.symbol = symbol
            self.why = why
            self.place = place
            self.record = record
            self.msg = msg
            self.fp = fp
            self.firstSeen = firstSeen
        }
    }
}

/// Builds the snapshot from what the app knows now and the snapshot before. Pure.
public enum GlanceSummary {
    /// - `previous`: the snapshot on disk, for what carries over: a wait's start
    ///   (`GlanceSince`), a machine's `seen`, and all of a machine this run of the app has not
    ///   reached yet. Such a machine keeps what was last written about it, marked `stale`,
    ///   so a launch with a server down doesn't wipe what the widgets say about it.
    ///
    /// Every date in the result is a whole second, as the file keeps them.
    public static func snapshot(machines: [GlanceInput.Machine], palette: GlanceSnapshot.Palette,
                                previous: GlanceSnapshot?, seq: Int?, now: Date) -> GlanceSnapshot {
        // Whole seconds, as the file keeps them: what is in memory is what a reader gets back.
        let now = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down))
        let before = Dictionary((previous?.machines ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out = machines.map { m -> GlanceSnapshot.Machine in
            let old = before[m.id]
            if !m.known, let old {
                return GlanceSnapshot.Machine(id: m.id, name: m.name, link: old.link == .never ? .never : .stale,
                                              counts: old.counts, waiting: old.waiting, seen: old.seen, busy: old.busy)
            }
            let agents = m.waiting.map { w in
                GlanceSnapshot.Agent(session: w.session, window: w.window, block: w.block, kind: w.kind, name: w.name,
                                     symbol: w.symbol, why: w.why, place: w.place,
                                     since: GlanceSince.since(server: m.id, wait: w, previous: previous, now: now),
                                     record: w.record, msg: w.msg, fp: w.fp)
            }
            // The longest wait first; equal starts keep the server's order.
            let sorted = agents.enumerated().sorted { ($0.element.since, $0.offset) < ($1.element.since, $1.offset) }.map(\.element)
            return GlanceSnapshot.Machine(id: m.id, name: m.name, link: m.link, counts: counts(m.states),
                                          waiting: Array(sorted.prefix(GlanceSnapshot.waitingLimit)),
                                          seen: m.link == .live ? now : old?.seen,
                                          busy: m.busy.enumerated().sorted { ($0.element.rank, $0.offset) < ($1.element.rank, $1.offset) }.map(\.element))
        }
        capBusy(&out)
        return GlanceSnapshot(seq: seq, asOf: now, palette: palette, machines: out)
    }

    /// Keeps `GlanceSnapshot.busyLimit` agents over all machines: errors first wherever they
    /// are, then working, done and idle, and machines in their order within a state. Each
    /// machine's list is already in that order, so it is cut, never reordered.
    static func capBusy(_ machines: inout [GlanceSnapshot.Machine]) {
        var room = GlanceSnapshot.busyLimit
        var keep = Array(repeating: 0, count: machines.count)
        for rank in GlanceSnapshot.Busy.order.indices {
            for (i, m) in machines.enumerated() {
                let n = (m.busy ?? []).filter { $0.rank == rank }.count
                let taken = min(n, room)
                keep[i] += taken
                room -= taken
            }
        }
        for i in machines.indices {
            machines[i].busy = machines[i].busy.map { Array($0.prefix(keep[i])) }
        }
    }

    public static func counts(_ states: [String?]) -> GlanceSnapshot.Counts {
        var c = GlanceSnapshot.Counts()
        for s in states {
            switch s {
            case "blocked": c.waiting += 1
            case "error": c.error += 1
            case "working": c.working += 1
            case "done": c.done += 1
            default: c.idle += 1
            }
        }
        return c
    }
}

/// When a wait began, as far as the phone can honestly say.
///
/// Rex gives no start time for a wait, so the start is the first time the phone saw it. That
/// time is carried over from the snapshot before only when this is the same wait: the same
/// server and pane, the same status record with an id that isn't empty, the same message and the
/// same reason. A new wait almost always asks something new. In every other case the start is
/// when this run of the app first saw the agent waiting, so "waiting at least since" holds.
public enum GlanceSince {
    public static func since(server: String, wait: GlanceInput.Wait, previous: GlanceSnapshot?, now: Date) -> Date {
        let first = min(wait.firstSeen ?? now, now)
        let seen = Date(timeIntervalSince1970: first.timeIntervalSince1970.rounded(.down))
        guard !wait.record.isEmpty,
              let old = previous?.machines.first(where: { $0.id == server })?.waiting.first(where: { $0.block == wait.block }),
              old.record == wait.record, old.why == wait.why,
              old.msg == wait.msg.map({ String($0.prefix(GlanceSnapshot.messageLimit)) }) else { return seen }
        return min(old.since, seen)
    }
}
