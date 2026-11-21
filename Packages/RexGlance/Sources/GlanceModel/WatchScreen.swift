import Foundation

/// The words only the watch says. The name comes from `Brand`.
public enum WatchText {
    /// No snapshot yet, or one from a newer app than this watch app reads.
    public static var open: String { "Open \(Brand.appName) on iPhone" }
    /// Over an hour old.
    public static var refresh: String { "Open \(Brand.appName) on iPhone to refresh" }
    /// Under an agent the watch can't act on (last known, or named too loosely to act on).
    public static let answer = "Answer on your iPhone or computer"

    // Actions from the wrist.
    public static func title(_ kind: WatchAction.Kind) -> String {
        switch kind {
        case .enter: "Enter"
        case .interrupt: "Interrupt"
        }
    }

    /// The question before anything is sent.
    public static func confirm(_ kind: WatchAction.Kind, name: String) -> String {
        switch kind {
        case .enter: "Send Enter to \(name)?"
        case .interrupt: "Interrupt \(name)?"
        }
    }

    /// The button that says yes.
    public static func confirmButton(_ kind: WatchAction.Kind) -> String {
        switch kind {
        case .enter: "Send Enter"
        case .interrupt: "Interrupt"
        }
    }

    public static let sending = "Sending…"

    /// How an action ended: one quiet line.
    public static func outcome(_ outcome: WatchActionOutcome, _ kind: WatchAction.Kind) -> String {
        switch outcome {
        case .sent: "Sent \(title(kind))"
        case .changed: "Not sent. It no longer waits for this."
        case .unreachable: "Not sent. Your iPhone can't reach the computer."
        case .unconfirmed: "Couldn't confirm. Check the pane."
        case .noPhone: "Not sent. Can't reach your iPhone."
        }
    }
}

/// What the watch app shows for the snapshot it holds, at a moment. Pure: it is the widgets'
/// `GlanceDigest`, so the watch counts, orders, dates and dims exactly as they do, with the
/// watch's own words where it differs. The views only lay it out.
public struct WatchScreen: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// Nothing to list: one line says why (`WatchText.open`, "No computers yet").
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
        /// "Needs your permission": the app's words for what it waits for.
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
        /// The wait an action from the wrist would answer. Nil when none is offered: the row is
        /// only last known, or the snapshot doesn't name the wait well enough.
        public var target: WatchAction.Target?
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
        /// The same counts one by one, each with its state, for the app to color.
        public var parts: [GlanceDigest.Part]
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
                lastKnown: r.stale || old,
                target: r.stale || old ? nil : WatchAction.Target(server: r.machine, agent: r.agent), msg: r.agent.msg)
        }
        machines = digest.machines.map {
            Machine(id: $0.id, name: $0.name, words: GlanceDigest.words($0.counts), parts: GlanceDigest.parts($0.counts),
                    dimmed: !$0.live || digest.dimmed)
        }
    }

    /// What a waiting agent waits for: the one wording for the app's sidebar, board, toasts and
    /// palette, the widgets and the watch (a test in the app holds them together). Beacon's
    /// notifications say the same (Relay/src/push.rs).
    public static func words(why: String?) -> String {
        switch why {
        case "permission": "Needs your permission"
        case "question": "Has a question"
        case "auth": "Needs your password"
        default: "Waiting for you"
        }
    }

    /// The same after a name, in a sentence: "Claude needs your permission".
    public static func sentence(_ who: String, why: String?) -> String {
        let said = words(why: why)
        let verb = said == words(why: nil) ? "is waiting for you" : said.prefix(1).lowercased() + said.dropFirst()
        return "\(who) \(verb)"
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
        guard count != nil else { return nil }
        return hand ? "waiting" : "working"
    }
}
