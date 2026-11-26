import Foundation
import GlanceModel
import GlanceUI
import RexKit
import SwiftUI
import Testing
@testable import Pteron

/// The widgets draw from a package that knows nothing of the app. These tests hold the two
/// together: the same colors, the same tints, the same words for the same agents.
@MainActor
@Suite struct GlanceParityTests {
    private func same(_ a: Color, _ b: Color, _ note: String, sourceLocation: SourceLocation = #_sourceLocation) {
        for scheme in [ColorScheme.dark, .light] {
            var env = EnvironmentValues()
            env.colorScheme = scheme
            let x = a.resolve(in: env), y = b.resolve(in: env)
            let close = abs(x.red - y.red) < 1e-4 && abs(x.green - y.green) < 1e-4 && abs(x.blue - y.blue) < 1e-4
                && abs(x.opacity - y.opacity) < 1e-4
            #expect(close, "\(note): \(x) vs \(y)", sourceLocation: sourceLocation)
        }
    }

    private func prefs() throws -> Prefs {
        let suite = "glance-parity-\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: suite))
        d.removePersistentDomain(forName: suite)
        return Prefs(defaults: d)
    }

    /// Every theme, in the Dark Mode slot and in the Light Mode slot: so a light theme in the
    /// dark slot and a dark theme in the light slot too.
    @Test func everyThemeGivesTheWidgetsTheAppsChromeInBothSlots() throws {
        #expect(ThemeStore.all.count > 1)
        #expect(ThemeStore.all.contains { $0.isDark } && ThemeStore.all.contains { !$0.isDark })
        let p = try prefs()
        for theme in ThemeStore.all {
            for slot in [ColorScheme.dark, .light] {
                if slot == .dark { p.darkThemeID = theme.id } else { p.lightThemeID = theme.id }
                let colors = GlanceColors.pick(GlanceSource.palette(p), system: slot)
                let chrome = theme.chrome
                let note = "\(theme.id) in the \(slot == .dark ? "dark" : "light") slot"
                #expect(colors.scheme == (theme.isDark ? .dark : .light), "\(note)")
                same(colors.bg, theme.bg, note); same(colors.fg, theme.fg, note); same(colors.accent, theme.accent, note)
                same(colors.canvas, chrome.canvas, "canvas, \(note)")
                same(colors.sidebar, chrome.sidebar, "sidebar, \(note)")
                same(colors.secondary, chrome.secondary, note); same(colors.tertiary, chrome.tertiary, note)
                same(colors.blocked, chrome.blocked, note); same(colors.error, chrome.error, note)
                same(colors.working, chrome.working, note); same(colors.done, chrome.done, note)
            }
        }
    }

    @Test func everyAgentKindHasTheSidebarsTintInEveryTheme() throws {
        let kinds: [AgentKind?] = [.claude, .codex, .gemini, .opencode, .amp, .aider, .cursor, nil]
        let p = try prefs()
        for theme in ThemeStore.all {
            p.darkThemeID = theme.id
            let colors = GlanceColors.pick(GlanceSource.palette(p), system: .dark)
            for kind in kinds {
                same(AgentGlyph.tint(kind: kind?.rawValue, colors), TabRowLabel.tint(kind, theme), "\(kind?.rawValue ?? "none") in \(theme.id)")
                same(AgentGlyph.ink(kind: kind?.rawValue, colors), AgentGlyph.ink(agent: kind, theme), "ink, \(kind?.rawValue ?? "none") in \(theme.id)")
            }
        }
    }

    @Test func theDefaultThemesAreTheWidgetsDefaults() throws {
        #expect(GlanceSource.palette(try prefs()) == .standard)
        #expect(GlancePalette.standardDark.bg == ThemeStore.fallback.background)
        // A theme's sixteen ANSI colors: the file keeps the six the widgets use.
        #expect(GlanceSource.palette(try prefs()).dark.ansi.count == GlancePalette.ansiCount)
    }

    #if DEBUG
    /// The agent board's own scenarios, turned into a snapshot: the widget's headline is the
    /// board's wherever every machine is connected.
    @Test func theBoardsScenariosReadTheSameOnTheWidget() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for name in ["0", "idle", "1", "3", "6", "12", "machines", "states", "long", "churn", "kinds"] {
            let machines = try #require(BoardDemo.machines(name, now: now))
            let input = machines.map { m in
                GlanceInput.Machine(id: m.id.uuidString, name: m.name, link: m.link == .live ? .live : m.link == .stale ? .stale : .never,
                                    known: m.link != .never, states: m.agents.map(\.state),
                                    waiting: m.agents.filter { $0.state == "blocked" }.map { a in
                    GlanceInput.Wait(session: a.sessionID, window: a.windowID, block: a.blockID, kind: a.kind?.rawValue, name: a.name,
                                     symbol: a.kind?.symbol ?? "cpu", why: nil, place: a.place, record: "", msg: a.message,
                                     firstSeen: a.waitingSince)
                })
            }
            let snapshot = GlanceSummary.snapshot(machines: input, palette: .standard, previous: nil, seq: 1, now: now)
            let digest = GlanceDigest(snapshot, now: now)
            let board = AgentBoard.make(machines)
            #expect(digest.headline == .text(board.headline), "\(name)")
            // The same agents wait, the longest wait first.
            let waiting = board.tiles.filter { $0.agent.state == "blocked" }.map(\.agent.blockID)
            #expect(digest.rows.map(\.agent.block) == Array(waiting.prefix(GlanceSnapshot.waitingLimit)), "\(name)")
            #expect(digest.counts.idle == board.idleCount, "\(name)")
        }
        // No servers: both say so.
        #expect(AgentBoard.make([]).headline == GlanceDigest.unpairedText)
        // A machine that is down: the board says it is reconnecting, which only the app can
        // know; the widget dates what it shows instead, and neither says "All quiet".
        for name in ["offline", "stale"] {
            let machines = try #require(BoardDemo.machines(name, now: now))
            #expect(AgentBoard.make(machines).headline == "Reconnecting…")
        }
    }
    #endif

    @Test func theWidgetsNameTheAppFromBrand() {
        #expect(GlanceDigest.openText == "Open \(Brand.appName)")
        #expect(GlanceDigest.refreshText == "Open \(Brand.appName) to refresh")
    }
}

/// What the writer reads from the servers, and what the watcher reads to know when.
@MainActor
@Suite struct GlanceSourceTests {
    private func model() throws -> AppModel {
        let suite = "glance-source-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return AppModel(prefs: Prefs(defaults: defaults), connect: false)
    }

    private func server(_ model: AppModel, _ name: String) -> ServerConnection {
        let s = ServerConnection(config: ServerConfig(name: name, url: "https://\(name)-rex.tail1234.ts.net"),
                                 prefs: model.prefs, notifier: model.notifier, deviceID: "a1b2c3d4")
        model.servers.append(s)
        return s
    }

    /// `sessions` sessions of `tabs` tabs with one pane each; block ids are `<server>-<session>-<tab>`.
    private func load(_ s: ServerConnection, sessions: Int, tabs: Int, state: (Int) -> String) {
        var entries: [SessionEntry] = [], views: [String: SessionView] = [:]
        var n = 0
        for i in 0..<sessions {
            let sid = "s\(i)"
            let windows = (0..<tabs).map { t -> JSONObject in
                ["window_id": "\(sid)-w\(t)", "label": "tab \(t)", "layers": [["kind": "tiled", "blocks": [
                    ["block_id": "\(s.config.name)-\(sid)-\(t)", "creator_name": "com.superlogical.terminal"] as JSONObject,
                ]] as JSONObject]]
            }
            entries.append(SessionEntry(id: sid, label: i == 0 ? "zz-test" : "work \(i)"))
            views[sid] = SessionView(["revision": 1, "session_id": sid, "label": i == 0 ? "zz-test" : "work \(i)",
                                      "active_window_id": "\(sid)-w0", "windows": windows])
            for t in 0..<tabs {
                var m = BlockMeta()
                m.statuses = ["claude": ProgramStatus(["id": "claude", "app": "claude", "state": state(n), "msg": "Question \(n)?", "kind": "question"])]
                s.meta["\(s.config.name)-\(sid)-\(t)"] = m
                n += 1
            }
        }
        s.sessions = entries
        s.views = views
        s.phase = .online
        s.synced = true
        s.agentsWereRead()
    }

    @Test func rowsCarryWhatTheBoardShows() throws {
        let m = try model()
        let s = server(m, "desk")
        load(s, sessions: 2, tabs: 3) { ["blocked", "working", "done", "idle", "error", "blocked"][$0] }
        let since = ["desk-s0-0": Date(timeIntervalSince1970: 1_800_000_000)]
        let rows = GlanceSource.machines(m.servers, since: since)
        #expect(rows.count == 1 && rows[0].id == s.id.uuidString && rows[0].name == "desk")
        #expect(GlanceSummary.counts(rows[0].states) == GlanceSnapshot.Counts(waiting: 2, error: 1, working: 1, done: 1, idle: 1))
        let first = try #require(rows[0].waiting.first)
        #expect(first.block == "desk-s0-0" && first.session == "s0" && first.window == "s0-w0")
        #expect(first.kind == "claude" && first.name == "Claude" && first.symbol == "asterisk")
        #expect(first.why == "question" && first.msg == "Question 0?" && first.record == "claude")
        #expect(first.place == "zz-test › tab 0" && first.firstSeen == since["desk-s0-0"])
        #expect(rows[0].waiting.map(\.block) == ["desk-s0-0", "desk-s1-2"])
        // The same agents as the board's, and no address anywhere in a row.
        let board = BoardSource.machines(m.servers, since: since)
        #expect(board[0].agents.filter { $0.state == "blocked" }.map(\.blockID) == rows[0].waiting.map(\.block))
        #expect(!String(describing: rows).contains("tail1234"))
    }

    /// The agents that don't wait, for the widgets' tiles: one per agent the counts count, in
    /// the same pass, from the keys alone, and nothing that names a pane or a place.
    @Test func theOtherAgentsBecomeTiles() throws {
        let m = try model()
        let s = server(m, "desk")
        load(s, sessions: 2, tabs: 3) { ["blocked", "working", "done", "idle", "error", "blocked"][$0] }
        let rows = GlanceSource.machines(m.servers, since: [:])
        #expect(rows[0].busy.map(\.state) == ["working", "done", "idle", "error"])
        #expect(rows[0].busy.allSatisfy { $0.kind == "claude" && $0.symbol == "asterisk" })
        #expect(rows[0].busy.count + rows[0].waiting.count == rows[0].states.count)
        let snapshot = GlanceSummary.snapshot(machines: rows, palette: .standard, previous: nil, seq: 1, now: Date())
        #expect(snapshot.machines[0].busy?.map(\.state) == ["error", "working", "done", "idle"])
        #expect(!String(describing: rows[0].busy).contains("desk-") && !String(describing: rows[0].busy).contains("zz-test"))
        // A test launch's tiles are its own session's too.
        #expect(GlanceSource.machines(m.servers, since: [:], only: "zz-test")[0].busy.map(\.state) == ["working", "done"])
    }

    @Test func aPaneWhoseProgramExitedIsNoWaitingAgent() throws {
        let m = try model()
        let s = server(m, "desk")
        load(s, sessions: 1, tabs: 2) { _ in "blocked" }
        var meta = try #require(s.meta["desk-s0-1"])
        meta.exited = true
        s.meta["desk-s0-1"] = meta
        let rows = GlanceSource.machines(m.servers, since: [:])
        #expect(rows[0].waiting.map(\.block) == ["desk-s0-0"] && GlanceSummary.counts(rows[0].states).waiting == 1)
    }

    /// A test launch that writes (`-glanceLive`) names only its own session's agents.
    @Test func aTestLaunchWritesOnlyItsOwnSession() throws {
        let m = try model()
        let s = server(m, "desk")
        load(s, sessions: 3, tabs: 2) { _ in "blocked" }
        let rows = GlanceSource.machines(m.servers, since: [:], only: "zz-test")
        #expect(rows[0].waiting.map(\.session) == ["s0", "s0"] && rows[0].states.count == 2)
        #expect(!String(describing: rows).contains("work "))
        #expect(GlanceSource.machines(m.servers, since: [:], only: "zz-other")[0].states.isEmpty)
    }

    @Test func theLinkFollowsTheBoardsRule() throws {
        let m = try model()
        let s = server(m, "desk")
        #expect(GlanceSource.link(s) == .never)
        #expect(GlanceSource.machines(m.servers, since: [:])[0].known == false)
        s.phase = .connecting
        #expect(GlanceSource.link(s) == .never)
        s.phase = .offline(ConnectionProblem(kind: .notAnswering, detail: ""))
        #expect(GlanceSource.link(s) == .stale)
        s.phase = .online
        #expect(GlanceSource.link(s) == .never)
        s.synced = true
        #expect(GlanceSource.link(s) == .live)
        #expect(BoardSource.machines(m.servers, since: [:])[0].link == .live)
    }

    @Test func theTopRecordIsTheSameOneEveryTime() {
        var meta = BlockMeta()
        meta.statuses = ["b": ProgramStatus(["state": "blocked", "msg": "B?"]), "a": ProgramStatus(["state": "blocked", "msg": "A?"]),
                         "c": ProgramStatus(["state": "working"])]
        for _ in 0..<20 { #expect(GlanceSource.topRecord(meta)?.id == "a") }
        #expect(GlanceSource.topRecord(BlockMeta()) == nil && GlanceSource.topRecord(nil) == nil)
    }

    // MARK: The watcher

    /// Eight servers of forty agents whose titles, progress and messages change all the time:
    /// the watcher's body reads none of that, so it never runs again for it, and building a
    /// snapshot stays cheap.
    @Test func churnThatTheWidgetsDoNotShowNeverReRunsTheWatcher() async throws {
        let m = try model()
        for i in 0..<8 { load(server(m, "m\(i)"), sessions: 4, tabs: 10) { $0 % 8 == 0 ? "blocked" : $0 % 3 == 0 ? "working" : "idle" } }
        for _ in 0..<5 { await Task.yield() }
        #expect(m.servers.flatMap(\.agentKeys).count == 320 && m.waitingAgentIDs.count == 40)

        final class Flag: @unchecked Sendable { var fired = false }   // Only touched on the main actor.
        let flag = Flag()
        let before = withObservationTracking { GlanceWatcher.key(m, m.prefs) } onChange: { flag.fired = true }

        var costs: [TimeInterval] = []
        for tick in 0..<50 {
            for s in m.servers {
                for key in s.agentKeys {
                    guard var meta = s.meta[key.blockID], var status = meta.statuses["claude"] else { continue }
                    meta.title = "claude · step \(tick)"
                    meta.pwd = "/tmp/work/\(tick)"
                    status.progress = tick * 2
                    status.text = "Question \(tick)?"
                    status.label = "Title \(tick)"
                    meta.statuses["claude"] = status
                    s.meta[key.blockID] = meta
                }
            }
            for _ in 0..<3 { await Task.yield() }
            // What a write costs the main thread: reading the rows, building and encoding.
            let start = ProcessInfo.processInfo.systemUptime
            let rows = GlanceSource.machines(m.servers, since: [:])
            let snapshot = GlanceSummary.snapshot(machines: rows, palette: GlanceSource.palette(m.prefs), previous: nil, seq: tick, now: Date())
            let data = try snapshot.encoded()
            costs.append(ProcessInfo.processInfo.systemUptime - start)
            #expect(data.count < 32_000)
            #expect(snapshot.machines.allSatisfy { $0.waiting.count == 5 && $0.waiting[0].msg == "Question \(tick)?" })
        }
        #expect(!flag.fired, "the watcher's body would have run again for a title, a progress or a message")
        #expect(GlanceWatcher.key(m, m.prefs) == before)
        // An unoptimized build in a simulator; the budget is a frame at 60 Hz. The median, not the
        // worst: a shared machine can stop the test for longer than a frame at any moment, and a
        // snapshot that costs too much costs it every time.
        let median = costs.sorted()[costs.count / 2]
        #expect(median < 0.016, "building a snapshot took \(median * 1000) ms (median of \(costs.count))")

        // And it does run again for what the widgets show: an agent that starts to wait.
        let s = m.servers[0]
        let block = try #require(s.agentKeys.first { $0.state != "blocked" }?.blockID)
        var meta = try #require(s.meta[block])
        meta.statuses["claude"]?.state = "blocked"
        s.meta[block] = meta
        for _ in 0..<5 { await Task.yield() }
        #expect(flag.fired)
        #expect(GlanceWatcher.key(m, m.prefs).waiting.count == 41)
    }

    @Test func theWatcherSeesALinkAndAThemeChange() throws {
        let m = try model()
        let s = server(m, "desk")
        let a = GlanceWatcher.key(m, m.prefs)
        s.phase = .online
        let b = GlanceWatcher.key(m, m.prefs)
        s.synced = true
        let c = GlanceWatcher.key(m, m.prefs)
        m.prefs.lightThemeID = m.prefs.darkThemeID
        let d = GlanceWatcher.key(m, m.prefs)
        #expect(a != b && b != c && c != d)
    }
}
