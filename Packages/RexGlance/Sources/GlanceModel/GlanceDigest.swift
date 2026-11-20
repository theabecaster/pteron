import Foundation

/// What a widget shows for a snapshot at a moment, worked out once for every size. Pure: the
/// views only lay it out.
///
/// Only machines that were live at the write count in the headline and the counts. A machine
/// that was down keeps its last known agents, dimmed and placed last, and over such agents the
/// headline never says that all is quiet: it says when the machine was last seen.
public struct GlanceDigest: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// No snapshot to trust: the app never ran, the file can't be read, or a newer app
        /// wrote it. The mark and "Open <app>".
        case placeholder
        /// The app has no servers.
        case unpaired
        case agents
    }

    public enum Urgency: Equatable, Sendable { case waiting, error, working, done, quiet, offline }

    public enum Headline: Equatable, Sendable {
        case text(String)
        /// "Last seen 12:04": no live machine, or a quiet one beside a down one with agents.
        case lastSeen(Date)
    }

    public enum Age: Equatable, Sendable {
        /// Written under two minutes ago: shown as current.
        case current
        case asOf(Date)
        /// Over an hour old: "Open <app> to refresh".
        case refresh
    }

    public struct Row: Equatable, Sendable, Identifiable {
        public var agent: GlanceSnapshot.Agent
        public var machine: String
        /// Set only when the snapshot has several machines.
        public var machineName: String?
        /// From a machine that was down at the write: last known, drawn dimmed.
        public var stale: Bool
        public var link: PaneLink
        public var id: String { "\(machine):\(agent.block)" }
    }

    /// One machine's counts, for the medium and large sizes.
    public struct MachineLine: Equatable, Sendable, Identifiable {
        public var id: String
        public var name: String
        public var counts: GlanceSnapshot.Counts
        public var live: Bool
    }

    /// One agent in the widgets' strip: a circle for an agent, a rounded square for another
    /// program, tinted by its kind, with its state's badge.
    public struct Tile: Equatable, Sendable, Identifiable {
        public var id: String
        public var kind: String?
        public var symbol: String
        /// Waiting, error, working, done, or quiet for idle.
        public var state: Urgency
        /// A waiting agent's pane, which a tap opens. Nil for the others: the snapshot names no
        /// pane for them, and a tap on them opens what the widget opens.
        public var link: PaneLink?
        /// From a machine that was down at the write: last known, drawn dimmed.
        public var stale: Bool
    }

    public var kind: Kind
    public var headline: Headline
    public var urgency: Urgency
    /// The sum over the live machines.
    public var counts: GlanceSnapshot.Counts
    /// Waiting agents: live machines' first, the longest wait first, then the down machines'.
    public var rows: [Row]
    /// Waiting agents the snapshot counts beyond `rows` (a machine lists at most eight).
    public var unlisted: Int
    public var machines: [MachineLine]
    /// The line about the machines. Nil with one machine: its name adds nothing.
    public var machineLine: String?
    public var age: Age
    /// Counts, rows and tiles are drawn dimmed: the snapshot is over an hour old, or no machine was live.
    public var dimmed: Bool
    /// The state whose color edges the widget. Nil when nobody waits, fails or works, and when dimmed.
    public var glow: Urgency?
    /// Where a tap on the widget goes.
    public var tap: DeepLink
    /// Every agent as a tile, the most urgent first: the waiting ones in the order of `rows`,
    /// then error, working, done and idle from the live machines, then the down machines'
    /// (last known). Only as many as the snapshot lists (`GlanceSnapshot.busyLimit`).
    public var tiles: [Tile] = []
    /// The snapshot lists the agents that don't wait. A file from an older app doesn't, and
    /// the widgets then show each machine's counts where the tiles would be.
    public var listsAgents = false
    /// Every agent the snapshot counts, on the live and the down machines.
    public var agents = 0

    /// The watch's dimmed share (`WatchStyle`). The Home Screen sizes dim less (`GlanceStyle.dim`).
    public static let dimOpacity = 0.4

    public static var openText: String { "Open \(Brand.appName)" }
    public static var refreshText: String { "Open \(Brand.appName) to refresh" }
    public static let unpairedText = "No machines paired"
    /// The Home Screen sizes' word for the same: what to do, since a tap does it.
    public static let pairText = "Pair a computer"
    public static let noAgentsText = "No agents running"

    public static let placeholder = GlanceDigest(
        kind: .placeholder, headline: .text(openText), urgency: .quiet, counts: .init(), rows: [], unlisted: 0,
        machines: [], machineLine: nil, age: .current, dimmed: false, glow: nil, tap: .open)

    public init(kind: Kind, headline: Headline, urgency: Urgency, counts: GlanceSnapshot.Counts, rows: [Row], unlisted: Int,
                machines: [MachineLine], machineLine: String?, age: Age, dimmed: Bool, glow: Urgency?, tap: DeepLink) {
        self.kind = kind
        self.headline = headline
        self.urgency = urgency
        self.counts = counts
        self.rows = rows
        self.unlisted = unlisted
        self.machines = machines
        self.machineLine = machineLine
        self.age = age
        self.dimmed = dimmed
        self.glow = glow
        self.tap = tap
    }

    public init(_ reading: GlanceReading, now: Date) {
        guard let s = reading.snapshot else { self = .placeholder; return }
        self.init(s, now: now)
    }

    public init(_ s: GlanceSnapshot, now: Date) {
        guard !s.machines.isEmpty else {
            self = GlanceDigest(kind: .unpaired, headline: .text(Self.unpairedText), urgency: .quiet, counts: .init(), rows: [],
                                unlisted: 0, machines: [], machineLine: nil, age: .current, dimmed: false, glow: nil, tap: .pair)
            return
        }
        let live = s.machines.filter { $0.link == .live }
        let down = s.machines.filter { $0.link == .stale }
        // Nothing was ever known about any machine: the same as no snapshot.
        guard !live.isEmpty || !down.isEmpty else { self = .placeholder; return }

        let several = s.machines.count > 1
        func rows(_ group: [GlanceSnapshot.Machine], stale: Bool) -> [Row] {
            group.flatMap { m in
                m.waiting.map { a in
                    Row(agent: a, machine: m.id, machineName: several ? m.name : nil, stale: stale,
                        link: PaneLink(server: m.id, session: a.session, window: a.window, block: a.block))
                }
            }
            .enumerated().sorted { ($0.element.agent.since, $0.offset) < ($1.element.agent.since, $1.offset) }.map(\.element)
        }
        let all = rows(live, stale: false) + rows(down, stale: true)
        let total = live.reduce(GlanceSnapshot.Counts()) { $0 + $1.counts }
        let listed = (live + down).reduce(0) { $0 + $1.waiting.count }
        let counted = (live + down).reduce(0) { $0 + $1.counts.waiting }

        var headline: Headline
        var urgency: Urgency
        if live.isEmpty {
            (headline, urgency) = (.lastSeen(down.compactMap(\.seen).max() ?? s.asOf), .offline)
        } else if total.waiting > 0 {
            (headline, urgency) = (.text(total.waiting == 1 ? "1 needs you" : "\(total.waiting) need you"), .waiting)
        } else if total.error > 0 {
            (headline, urgency) = (.text(total.error == 1 ? "1 error" : "\(total.error) errors"), .error)
        } else if total.working > 0 {
            (headline, urgency) = (.text("\(total.working) working"), .working)
        } else if total.done > 0 {
            (headline, urgency) = (.text("All done"), .done)
        } else {
            (headline, urgency) = (.text("All quiet"), .quiet)
        }
        // "All quiet" over a down machine's agents would be read as the whole truth.
        if urgency == .quiet || urgency == .done, let busy = down.first(where: { $0.counts.busy > 0 }) {
            (headline, urgency) = (.lastSeen(busy.seen ?? s.asOf), .offline)
        }

        let freshness = GlanceFreshness(asOf: s.asOf, now: now)
        let age: Age = switch freshness {
        case .fresh: .current
        case .aging: .asOf(min(s.asOf, now))
        case .stale: .refresh
        }
        let dimmed = freshness == .stale || live.isEmpty
        let glows = !dimmed && (urgency == .waiting || urgency == .error || urgency == .working)
        self = GlanceDigest(
            kind: .agents, headline: headline, urgency: urgency, counts: total, rows: all, unlisted: max(0, counted - listed),
            machines: (live + down).map { MachineLine(id: $0.id, name: $0.name, counts: $0.counts, live: $0.link == .live) },
            machineLine: several ? Self.machineLine(s.machines) : nil, age: age, dimmed: dimmed,
            glow: glows ? urgency : nil, tap: all.isEmpty ? .open : .waiting)

        func others(_ group: [GlanceSnapshot.Machine], stale: Bool) -> [Tile] {
            group.flatMap { m in
                (m.busy ?? []).enumerated().map { i, b in
                    (b.rank, Tile(id: "\(m.id):\(i)", kind: b.kind, symbol: b.symbol, state: Self.urgency(b.state), link: nil, stale: stale))
                }
            }
            .enumerated().sorted { ($0.element.0, $0.offset) < ($1.element.0, $1.offset) }.map(\.element.1)
        }
        let waiting = all.map { r in
            Tile(id: r.id, kind: r.agent.kind, symbol: r.agent.symbol, state: .waiting, link: r.link, stale: r.stale)
        }
        tiles = waiting + others(live, stale: false) + others(down, stale: true)
        listsAgents = (live + down).contains { $0.busy != nil }
        agents = (live + down).reduce(0) { $0 + $1.counts.busy + $1.counts.idle }
    }

    static func urgency(_ state: String) -> Urgency {
        switch state {
        case "error": .error
        case "working": .working
        case "done": .done
        default: .quiet
        }
    }

    /// No agent at all on the machines it knows: "No agents running", never "All quiet".
    public var noAgents: Bool { kind == .agents && agents == 0 && rows.isEmpty && urgency != .offline }

    /// The tiles a strip has room for after the `rows` drawn as rows, and how many agents are
    /// left over: "+N". With some left over, the last place goes to the "+N".
    public func strip(after rows: Int, limit: Int) -> (tiles: [Tile], more: Int) {
        let rest = Array(tiles.dropFirst(rows))
        let total = max(rest.count, agents - min(rows, self.rows.count))
        if total <= limit, total == rest.count { return (rest, 0) }
        let shown = Array(rest.prefix(max(0, limit - 1)))
        return (shown, total - shown.count)
    }

    /// The one line under Glide where nothing needs a look: "All quiet · 4 idle". Nil where the
    /// widget shows agents instead.
    public var calmLine: String? {
        switch kind {
        case .placeholder: return Self.openText
        case .unpaired: return Self.pairText
        case .agents:
            if noAgents { return Self.noAgentsText }
            guard rows.isEmpty, case .text(let t) = headline, urgency == .quiet || urgency == .done else { return nil }
            return counts.idle > 0 ? "\(t) · \(counts.idle) idle" : t
        }
    }

    /// Their names while all are connected and there are at most two, else how many are connected.
    static func machineLine(_ machines: [GlanceSnapshot.Machine]) -> String {
        let live = machines.filter { $0.link == .live }.count
        if machines.count <= 2, live == machines.count || live == 0 { return machines.map(\.name).joined(separator: " · ") }
        if live == 0 { return "\(machines.count) machines" }
        return "\(live) of \(machines.count) machines connected"
    }

    /// The rows a size has room for, and how many waiting agents are left over: "+N more".
    public func shown(_ limit: Int) -> (rows: [Row], more: Int) {
        let rows = Array(self.rows.prefix(limit))
        return (rows, self.rows.count - rows.count + unlisted)
    }

    /// A machine's counts in words: "2 waiting · 3 working · 4 idle". "No agents" when it has none.
    public static func words(_ c: GlanceSnapshot.Counts) -> String {
        let parts = parts(c)
        return parts.isEmpty ? "No agents" : parts.map(\.text).joined(separator: " · ")
    }

    /// One count of `words`, with the state it counts, for a view that colors each by its state.
    public struct Part: Equatable, Sendable {
        public var urgency: Urgency
        public var text: String
    }

    /// The counts of `words`, in its order; idle counts as quiet. Empty when there are none.
    public static func parts(_ c: GlanceSnapshot.Counts) -> [Part] {
        var parts: [Part] = []
        if c.waiting > 0 { parts.append(Part(urgency: .waiting, text: "\(c.waiting) waiting")) }
        if c.error > 0 { parts.append(Part(urgency: .error, text: c.error == 1 ? "1 error" : "\(c.error) errors")) }
        if c.working > 0 { parts.append(Part(urgency: .working, text: "\(c.working) working")) }
        if c.done > 0 { parts.append(Part(urgency: .done, text: "\(c.done) done")) }
        if c.idle > 0 { parts.append(Part(urgency: .quiet, text: "\(c.idle) idle")) }
        return parts
    }

    // MARK: Lock Screen

    /// What the Lock Screen accessories say. They never carry a message, and with `private`
    /// (the phone is locked and the system asks for redaction) they carry no agent's name or
    /// place either: counts only.
    ///
    /// They never ask for anything. From a snapshot over an hour old they keep their counts,
    /// dimmed, with no "Open … to refresh" line (`age` is never `.refresh` here) and no running
    /// wait time; only the Home Screen sizes carry that line.
    public struct Accessory: Equatable, Sendable {
        /// Circular: a raised hand over the waiting count, or the mark over the working count.
        /// No count when neither waits nor works: the mark alone.
        public var hand: Bool
        public var count: Int?
        /// Rectangular, first line. Never private.
        public var title: Headline
        /// Rectangular, second line: "Claude · api › work". Nil when private or when nobody waits.
        public var detail: String?
        /// Rectangular, second line when there is no detail to show.
        public var fallback: String?
        /// The oldest wait's start, for "12m". Only with a wait, and nil when dimmed: a wait from
        /// an old snapshot is not counted on.
        public var since: Date?
        /// `.current` or `.asOf`, never `.refresh`.
        public var age: Age
        /// Inline: "2 need you · 3 working".
        public var inline: Headline
        public var dimmed: Bool
    }

    public func accessory(private hidden: Bool) -> Accessory {
        guard kind == .agents else {
            return Accessory(hand: false, count: nil, title: headline, detail: nil, fallback: nil, since: nil, age: .current,
                             inline: headline, dimmed: false)
        }
        let first = rows.first(where: { !$0.stale })
        var inline = headline
        if case .text(let t) = headline, urgency == .waiting, counts.working > 0 { inline = .text("\(t) · \(counts.working) working") }
        let detail = first.map { r in [r.agent.name, r.agent.place].filter { !$0.isEmpty }.joined(separator: " · ") }
        let others = counts.waiting > 0 ? (counts.working > 0 ? "\(counts.working) working" : nil) : Self.words(counts)
        // Nobody waits and nobody works: the mark alone, not a zero.
        let count = counts.waiting > 0 ? counts.waiting : counts.working > 0 ? counts.working : nil
        return Accessory(hand: counts.waiting > 0, count: count,
                         title: headline, detail: hidden ? nil : detail,
                         fallback: urgency == .offline ? nil : others, since: dimmed ? nil : first?.agent.since,
                         age: age == .refresh ? .current : age, inline: inline, dimmed: dimmed)
    }
}

/// A widget's timeline for a snapshot: one entry now and one for each moment its age changes
/// what is shown, so the widget ages without a reload and without the app.
public enum GlanceTimeline {
    public struct Entry: Equatable, Sendable {
        public var date: Date
        public var digest: GlanceDigest
        /// The colors: the snapshot's, or the default themes' when there is no snapshot.
        public var palette: GlanceSnapshot.Palette
    }

    public static func entries(_ reading: GlanceReading, now: Date) -> [Entry] {
        guard var s = reading.snapshot else { return [Entry(date: now, digest: .placeholder, palette: .standard)] }
        // A snapshot dated in the future (the clock was set back) is taken as written now.
        s.asOf = min(s.asOf, now)
        return GlanceFreshness.entryDates(asOf: s.asOf, now: now).map { Entry(date: $0, digest: GlanceDigest(s, now: $0), palette: s.palette) }
    }
}
