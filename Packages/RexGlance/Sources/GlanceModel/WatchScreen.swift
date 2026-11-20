import Foundation

/// The words only the watch says. The name comes from `Brand`.
public enum WatchText {
    /// No snapshot yet, or one from a newer app than this watch app reads.
    public static var open: String { "Open \(Brand.appName) on iPhone" }
    /// Over an hour old.
    public static var refresh: String { "Open \(Brand.appName) on iPhone to refresh" }
    /// The watch only shows: it has nothing to answer with.
    public static let answer = "Answer on your iPhone or computer"
}

/// What the watch app shows for the snapshot it holds, at a moment. Pure: it is the widgets'
/// `GlanceDigest`, so the watch counts, orders, dates and dims exactly as they do, with the
/// watch's own words where it differs. The views only lay it out.
public struct WatchScreen: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// Nothing to list: one line says why (`WatchText.open`, "No machines paired").
        case message(String)
        case agents
    }

    public enum Age: Equatable, Sendable {
        case asOf(Date)
        /// Over an hour old: `WatchText.refresh`.
        case refresh
    }

    /// A waiting agent, in the list and on its detail screen.
    public struct Row: Equatable, Sendable, Identifiable, Hashable {
        public var id: String
        public var name: String
        public var kind: String?
        public var symbol: String
        /// "Needs permission": the app's words for what it waits for.
        public var words: String
        public var place: String
        /// The machine's name, for the detail screen.
        public var machine: String
        /// The same, for the list: only when there are several machines.
        public var listedMachine: String?
        public var since: Date
        /// From a machine that was down at the write, or a snapshot over an hour old: last
        /// known, dimmed, with no running wait time.
        public var lastKnown: Bool
        var msg: String?

        /// What the agent asks. Nil when it said nothing, and always while the screen is
        /// dimmed with the wrist down, where anyone nearby can read it.
        public func message(wristDown: Bool) -> String? {
            guard !wristDown, let msg, !msg.isEmpty else { return nil }
            return msg
        }
    }

    public struct Machine: Equatable, Sendable, Identifiable {
        public var id: String
        public var name: String
        /// "2 waiting · 3 working".
        public var words: String
        public var dimmed: Bool
    }

    public var kind: Kind
    public var headline: GlanceDigest.Headline
    public var urgency: GlanceDigest.Urgency
    /// "Studio · Laptop". Nil with one machine.
    public var machineLine: String?
    /// Nil while the snapshot is current.
    public var age: Age?
    /// Every waiting agent the snapshot lists, the longest wait first; the list scrolls.
    public var rows: [Row]
    /// Waiting agents counted beyond the rows.
    public var more: Int
    public var machines: [Machine]
    public var dimmed: Bool
    public var palette: GlancePalette

    public init(_ reading: GlanceReading, now: Date) {
        let digest = GlanceDigest(reading, now: now)
        let byID = Dictionary((reading.snapshot?.machines ?? []).map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        palette = Self.palette(reading.snapshot?.palette)
        headline = digest.headline
        urgency = digest.urgency
        machineLine = digest.machineLine
        dimmed = digest.dimmed
        more = digest.unlisted
        switch digest.kind {
        case .placeholder: kind = .message(WatchText.open)
        case .unpaired: kind = .message(GlanceDigest.unpairedText)
        case .agents: kind = .agents
        }
        age = switch digest.age {
        case .current: nil
        case .asOf(let date): .asOf(date)
        case .refresh: .refresh
        }
        let old = digest.age == .refresh
        rows = digest.rows.map { r in
            Row(id: r.id, name: r.agent.name, kind: r.agent.kind, symbol: r.agent.symbol, words: Self.words(why: r.agent.why),
                place: r.agent.place, machine: byID[r.machine] ?? "", listedMachine: r.machineName, since: r.agent.since,
                lastKnown: r.stale || old, msg: r.agent.msg)
        }
        machines = digest.machines.map {
            Machine(id: $0.id, name: $0.name, words: GlanceDigest.words($0.counts), dimmed: !$0.live || digest.dimmed)
        }
    }

    /// What a waiting agent waits for, as the app's sidebar and board say it (a test in the app
    /// holds the two together).
    public static func words(why: String?) -> String {
        switch why {
        case "permission": "Needs permission"
        case "question": "Has a question"
        case "auth": "Needs password"
        default: "Waiting for you"
        }
    }

    /// The watch's colors: the theme chosen for Dark Mode when it is a dark theme, else the
    /// default dark theme. The watch's ground is black, where a light theme can't be read.
    public static func palette(_ palette: GlanceSnapshot.Palette?) -> GlancePalette {
        guard let dark = palette?.dark, dark.isDark else { return .standardDark }
        return dark
    }

    /// The moments the screen must be worked out again, as the widgets' timeline has them.
    public static func nextChange(_ reading: GlanceReading, after now: Date) -> Date? {
        guard let s = reading.snapshot else { return nil }
        return GlanceFreshness.entryDates(asOf: min(s.asOf, now), now: now).dropFirst().first
    }
}

public extension GlanceDigest {
    /// How much this entry matters in the watch's Smart Stack: something while an agent waits
    /// on a connected machine and the snapshot is not old, nothing otherwise. It only orders
    /// the stack; it never alerts.
    var relevance: Float {
        urgency == .waiting && !dimmed ? Float(min(counts.waiting, 10)) : 0
    }
}

public extension GlanceDigest.Accessory {
    /// The words a watch face curves beside the corner's count. Nil when the corner shows the
    /// mark alone.
    var cornerLabel: String? {
        guard let count else { return nil }
        return hand ? (count == 1 ? "needs you" : "need you") : "working"
    }
}
