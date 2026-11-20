import Foundation

/// Made-up snapshots: what the widget gallery shows (so it never shows real sessions), what
/// `-glanceDemo <scenario>` writes in a Debug build, and the tests' fixtures. The scenarios
/// follow the agent board's (`-boardDemo`).
public enum GlanceDemo {
    public static let scenarios = ["quiet", "working", "error", "one", "several", "many", "machines", "stale", "offline", "aging",
                                   "old", "long", "empty", "unpaired", "light-in-dark", "newer", "none"]

    /// What the gallery shows.
    public static func gallery(now: Date) -> GlanceSnapshot {
        snapshot("several", now: now) ?? GlanceSnapshot(seq: nil, asOf: now, palette: .standard, machines: [])
    }

    static let studio = "00000000-0000-0000-0000-0000000000A1"
    static let laptop = "00000000-0000-0000-0000-0000000000A2"
    static let mini = "00000000-0000-0000-0000-0000000000A3"

    static func wait(_ n: Int, _ kind: String?, _ name: String, _ symbol: String, _ msg: String, _ place: String, why: String,
                     minutes: Double, now: Date) -> GlanceSnapshot.Agent {
        GlanceSnapshot.Agent(session: "session:\(n)", window: "window:\(n)", block: "block:\(n)", kind: kind, name: name,
                             symbol: symbol, why: why, place: place, since: now.addingTimeInterval(-minutes * 60),
                             record: "demo-\(n)", msg: msg,
                             fp: ActionGuard.fingerprint(state: ActionGuard.waiting, kind: why, message: msg))
    }

    /// Agents that don't wait, as the app lists them: `"claude:working"`, or `":idle"` for a shell.
    static func busy(_ list: String) -> [GlanceSnapshot.Busy] {
        let symbols = ["claude": "asterisk", "codex": "hexagon", "gemini": "sparkle"]
        return list.split(separator: " ").map { item in
            let parts = item.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            let kind = parts[0].isEmpty ? nil : parts[0]
            return GlanceSnapshot.Busy(kind: kind, symbol: kind.map { symbols[$0] ?? "cpu" } ?? "terminal", state: parts[1])
        }
    }

    /// Nil for `none` (no file), for `newer` (see `newerFile`) and for a name that isn't a scenario.
    public static func snapshot(_ name: String, now: Date) -> GlanceSnapshot? {
        typealias M = GlanceSnapshot.Machine
        typealias C = GlanceSnapshot.Counts
        let ask = wait(1, "claude", "Claude", "asterisk", "Run `npm test` in api?", "api › tests", why: "permission", minutes: 12, now: now)
        let question = wait(5, "aider", "Aider", "cpu", "Which branch should this go on?", "infra › deploy", why: "question", minutes: 3, now: now)
        let password = wait(10, "codex", "Codex", "hexagon", "sudo needs your password", "ops › upgrade", why: "auth", minutes: 95, now: now)
        func one(_ counts: C, _ waiting: [GlanceSnapshot.Agent], _ others: String, link: GlanceSnapshot.Link = .live, asOf: Date? = nil,
                 palette: GlanceSnapshot.Palette = .standard) -> GlanceSnapshot {
            let at = asOf ?? now
            return GlanceSnapshot(seq: 1, asOf: at, palette: palette, machines: [
                M(id: studio, name: "Studio", link: link, counts: counts, waiting: waiting, seen: at, busy: busy(others))])
        }
        let nine = "claude:error codex:working claude:working gemini:working :done claude:idle codex:idle :idle :idle"
        let seven = "claude:working codex:working gemini:working claude:idle codex:idle :idle :idle"
        switch name {
        case "unpaired":
            return GlanceSnapshot(seq: 1, asOf: now, palette: .standard, machines: [])
        case "quiet":
            return one(C(idle: 4), [], "claude:idle codex:idle gemini:idle :idle")
        case "working":
            return one(C(working: 3, done: 1, idle: 2), [], "claude:working codex:working :working claude:done gemini:idle :idle")
        case "error":
            return one(C(error: 1, working: 2, idle: 1), [], "codex:error claude:working gemini:working :idle")
        case "one":
            return one(C(waiting: 1, working: 1, done: 1), [ask], "codex:working :done")
        case "several":
            return one(C(waiting: 2, error: 1, working: 3, done: 1, idle: 4), [ask, question], nine)
        case "many":
            let more = (20..<26).map { wait($0, $0 % 2 == 0 ? "codex" : "gemini", $0 % 2 == 0 ? "Codex" : "Gemini",
                                            $0 % 2 == 0 ? "hexagon" : "sparkle", "Apply step \($0) of the migration?",
                                            "data › shard \($0)", why: "permission", minutes: Double($0 - 18), now: now) }
            return one(C(waiting: 11, working: 2, idle: 1), [password, ask] + more, "claude:working codex:working :idle")
        case "machines":
            let sudo = wait(9, "codex", "Codex", "hexagon", "Enter the sudo password", "ops › upgrade", why: "auth", minutes: 1, now: now)
            return GlanceSnapshot(seq: 1, asOf: now, palette: .standard, machines: [
                M(id: studio, name: "Studio", link: .live, counts: C(waiting: 1, working: 1), waiting: [ask], seen: now,
                  busy: busy("gemini:working")),
                M(id: laptop, name: "Laptop", link: .live, counts: C(waiting: 1, working: 1, done: 1), waiting: [sudo], seen: now,
                  busy: busy("claude:working :done")),
                M(id: mini, name: "Mini", link: .never, counts: C(), waiting: [], seen: nil)])
        case "stale":
            // One of three is down: its agents are last known.
            let seen = now.addingTimeInterval(-25 * 60)
            return GlanceSnapshot(seq: 1, asOf: now, palette: .standard, machines: [
                M(id: studio, name: "Studio", link: .live, counts: C(idle: 2), waiting: [], seen: now, busy: busy("claude:idle :idle")),
                M(id: laptop, name: "Laptop", link: .stale, counts: C(waiting: 1, done: 1), waiting: [ask], seen: seen,
                  busy: busy("codex:done")),
                M(id: mini, name: "Mini", link: .live, counts: C(idle: 1), waiting: [], seen: now, busy: busy("gemini:idle"))])
        case "offline":
            let seen = now.addingTimeInterval(-40 * 60)
            var s = one(C(waiting: 1, working: 1, done: 1), [ask], "codex:working :done", link: .stale)
            s.machines[0].seen = seen
            return s
        case "aging":
            return one(C(waiting: 2, working: 3, idle: 4), [ask, question], seven, asOf: now.addingTimeInterval(-10 * 60))
        case "old":
            return one(C(waiting: 2, working: 3, idle: 4), [ask, question], seven, asOf: now.addingTimeInterval(-3 * 3600))
        case "long":
            let a = wait(1, nil, "An agent with a very long program name", "cpu",
                         "Allow the agent to run a very long command that goes on and on, with many flags and a path that never seems to end?",
                         "a-session-with-a-rather-long-name › a tab title that is long as well", why: "permission", minutes: 180, now: now)
            // More agents than a snapshot lists: it keeps the most urgent twelve.
            let others = (0..<12).map { ["codex:error", "claude:working", "gemini:working", ":working"][$0 % 4] }.joined(separator: " ")
            return one(C(waiting: 1, error: 12, working: 34, done: 56, idle: 78), [a], others)
        case "empty":
            // Connected, and nothing runs an agent.
            return GlanceSnapshot(seq: 1, asOf: now, palette: .standard, machines: [
                M(id: studio, name: "Studio", link: .live, counts: C(), waiting: [], seen: now, busy: []),
                M(id: laptop, name: "Laptop", link: .live, counts: C(), waiting: [], seen: now, busy: [])])
        case "light-in-dark":
            // The light theme chosen for Dark Mode too: both slots draw it as the light theme it is.
            return one(C(waiting: 1, working: 1, done: 1), [ask], "codex:working :done",
                       palette: .init(dark: .standardLight, light: .standardLight))
        default:
            return nil
        }
    }

    /// A file from an app with a breaking change: readers show their placeholder.
    public static let newerFile = Data(#"{"v":99,"agents":"another shape"}"#.utf8)
}
