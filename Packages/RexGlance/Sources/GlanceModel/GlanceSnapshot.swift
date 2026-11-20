import Foundation

/// What the app last knew about the agents, as the widgets read it: one small file in the App
/// Group, written only by the app (`GlanceStore`).
///
/// **Version rule.** `v` changes only for a breaking change. A field added later keeps `v` and
/// is optional, so a file from an older app still decodes and a newer file's extra fields are
/// ignored. `seq`, a machine's `seen` and `busy`, and an agent's `fp` are such fields. A reader that meets a higher `v` shows
/// its placeholder (`GlanceReading.newer`).
///
/// The file holds no server address: links back into the app key on the server's random id.
public struct GlanceSnapshot: Codable, Equatable, Sendable {
    public static let version = 1
    /// Waiting agents kept per machine. The widgets show at most six.
    public static let waitingLimit = 8
    /// A message is clipped to this many characters.
    public static let messageLimit = 200
    /// Agents that don't wait, kept over all machines together, the most urgent first.
    public static let busyLimit = 12

    public var v: Int
    /// Counts the app's writes, across launches. Orders snapshots when the clock doesn't.
    public var seq: Int?
    /// When the app wrote this, from what it knew then.
    public var asOf: Date
    public var palette: Palette
    public var machines: [Machine]

    public init(seq: Int?, asOf: Date, palette: Palette, machines: [Machine]) {
        v = Self.version
        self.seq = seq
        self.asOf = asOf
        self.palette = palette
        self.machines = machines
    }

    /// The colors for the system's Dark and Light Mode: the themes chosen in the app.
    public struct Palette: Codable, Equatable, Sendable {
        public var dark: GlancePalette
        public var light: GlancePalette

        public init(dark: GlancePalette, light: GlancePalette) {
            self.dark = dark
            self.light = light
        }

        public static let standard = Palette(dark: .standardDark, light: .standardLight)
    }

    public struct Machine: Codable, Equatable, Sendable, Identifiable {
        /// The server's id in the app (`ServerConfig.id`), a random UUID.
        public var id: String
        public var name: String
        /// `live`, `stale` or `never`, at the time of the write; `link` reads it.
        public var linkName: String
        public var counts: Counts
        /// The agents waiting for the person, the longest wait first.
        public var waiting: [Agent]
        /// When the app last wrote this machine while it was connected. Nil when it never was.
        public var seen: Date?
        /// Its agents that don't wait, the most urgent first: error, working, done, idle. Added
        /// later: nil in a file from an older app, and a widget then draws no tiles for it.
        public var busy: [Busy]?

        public init(id: String, name: String, link: Link, counts: Counts, waiting: [Agent], seen: Date?, busy: [Busy]? = nil) {
            self.id = id
            self.name = name
            linkName = link.rawValue
            self.counts = counts
            self.waiting = waiting
            self.seen = seen
            self.busy = busy
        }

        /// A word this reader doesn't know is taken as `stale`: never shown as current.
        public var link: Link { Link(rawValue: linkName) ?? .stale }

        enum CodingKeys: String, CodingKey {
            case id, name, counts, waiting, seen, busy
            case linkName = "link"
        }
    }

    public enum Link: String, Sendable {
        /// Connected, with its agents' states current.
        case live
        /// The connection was down: what it holds is the last known.
        case stale
        /// Not connected since the app was launched, and never written before.
        case never
    }

    public struct Counts: Codable, Equatable, Sendable {
        public var waiting, error, working, done, idle: Int

        public init(waiting: Int = 0, error: Int = 0, working: Int = 0, done: Int = 0, idle: Int = 0) {
            self.waiting = waiting
            self.error = error
            self.working = working
            self.done = done
            self.idle = idle
        }

        public static func + (a: Counts, b: Counts) -> Counts {
            Counts(waiting: a.waiting + b.waiting, error: a.error + b.error, working: a.working + b.working,
                   done: a.done + b.done, idle: a.idle + b.idle)
        }

        /// Agents that are not idle.
        public var busy: Int { waiting + error + working + done }
    }

    /// An agent that doesn't wait, as a widget's tile draws it: what it is and its state. No
    /// name, place or pane, so nothing private: about 40 bytes.
    public struct Busy: Codable, Equatable, Sendable {
        /// The agent's kind (`claude`, `codex`, …), for its tint and its tile's shape. Nil for
        /// another program, drawn as a shell.
        public var kind: String?
        /// An SF Symbol name.
        public var symbol: String
        /// `error`, `working`, `done` or `idle`.
        public var state: String

        /// A state that isn't one of `order` is idle, as in the counts.
        public init(kind: String?, symbol: String, state: String?) {
            self.kind = kind
            self.symbol = symbol
            self.state = state.flatMap { Self.order.contains($0) ? $0 : nil } ?? "idle"
        }

        /// The states, the most urgent first.
        public static let order = ["error", "working", "done", "idle"]

        /// Its place in `order`. A word this reader doesn't know ranks as idle.
        public var rank: Int { Self.order.firstIndex(of: state) ?? Self.order.count - 1 }
    }

    /// One waiting agent.
    public struct Agent: Codable, Equatable, Sendable {
        public var session: String
        public var window: String
        public var block: String
        /// The agent's kind (`claude`, `codex`, …), for its tint. Nil for another program.
        public var kind: String?
        public var name: String
        /// An SF Symbol name.
        public var symbol: String
        /// What it waits for (`permission`, `question`, …), when it says.
        public var why: String?
        /// "session › tab".
        public var place: String
        /// Waiting at least since then: the first time the phone saw this wait.
        public var since: Date
        /// The id of the status record that reports the wait. May be empty.
        public var record: String
        /// What it asks. Private: never shown on the Lock Screen.
        public var msg: String?
        /// `ActionGuard.fingerprint` of the wait: its state, kind and whole message. Added
        /// later, so a file from an older app has none, and the watch then offers no action.
        public var fp: String?

        public init(session: String, window: String, block: String, kind: String?, name: String, symbol: String,
                    why: String?, place: String, since: Date, record: String, msg: String?, fp: String? = nil) {
            self.session = session
            self.window = window
            self.block = block
            self.kind = kind
            self.name = name
            self.symbol = symbol
            self.why = why
            self.place = place
            self.since = since
            self.record = record
            self.msg = msg.map { String($0.prefix(GlanceSnapshot.messageLimit)) }
            self.fp = fp
        }
    }

    // MARK: Order

    /// Whether `self` is the newer of two snapshots: by `seq`, which the phone's clock can't
    /// turn back, and by `asOf` when either has none.
    public func isNewer(than other: GlanceSnapshot) -> Bool {
        if let a = seq, let b = other.seq { return a > b }
        return asOf > other.asOf
    }

    // MARK: What the widgets redraw for

    /// The parts a widget shows that don't age by themselves: the counts, the links, the colors,
    /// and for each waiting agent which wait it is: since when, why, and what it asks. While it
    /// is the same, a reload would draw the same picture. An agent that was answered and asks
    /// again in the same pane changes it, so the widgets never keep the old question and time.
    ///
    /// `busy` is left out on purpose: the tiles add no reload. A change of state changes the
    /// counts and reloads anyway; agents that only trade states show at the next reload.
    ///
    /// The key lives in memory only: it is compared within one run of the app and never saved,
    /// so it holds the message itself and needs no hash.
    public var visibleKey: VisibleKey {
        VisibleKey(machines: machines.map { m in
            VisibleKey.Machine(id: m.id, name: m.name, link: m.linkName, counts: m.counts, waiting: m.waiting.map {
                VisibleKey.Wait(block: $0.block, since: $0.since, why: $0.why, msg: $0.msg)
            })
        }, palette: palette)
    }

    public struct VisibleKey: Equatable, Sendable {
        struct Wait: Equatable, Sendable {
            var block: String
            var since: Date
            var why, msg: String?
        }
        struct Machine: Equatable, Sendable {
            var id, name, link: String
            var counts: Counts
            var waiting: [Wait]
        }
        var machines: [Machine]
        var palette: Palette
    }

    // MARK: Bytes

    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return try e.encode(self)
    }
}

/// What a reader makes of the snapshot file.
public enum GlanceReading: Equatable, Sendable {
    case snapshot(GlanceSnapshot)
    /// Written by a newer app with a breaking change: this reader can't trust its meaning.
    case newer
    /// No file, a file that can't be read yet (before the first unlock) or one that isn't a
    /// snapshot.
    case missing

    public init(_ data: Data?) {
        guard let data else { self = .missing; return }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        struct Head: Decodable { var v: Int }
        guard let head = try? d.decode(Head.self, from: data) else { self = .missing; return }
        guard head.v <= GlanceSnapshot.version else { self = .newer; return }
        guard let s = try? d.decode(GlanceSnapshot.self, from: data) else { self = .missing; return }
        self = .snapshot(s)
    }

    public var snapshot: GlanceSnapshot? {
        if case .snapshot(let s) = self { return s }
        return nil
    }
}
