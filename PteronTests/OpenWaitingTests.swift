import Foundation
import GlanceModel
import Testing
import RexKit
@testable import Pteron

/// The decision step by itself: plain values in, a step out.
@Suite struct OpenWaitingStepTests {
    private typealias Server = OpenWaiting.Server
    private typealias Waiter = OpenWaiting.Waiter

    private let arrived = Date(timeIntervalSince1970: 1_000_000)
    private let tabA = Selection(serverID: UUID(), sessionID: "s", windowID: "a")
    private let tabB = Selection(serverID: UUID(), sessionID: "s", windowID: "b")

    private func wait(before: Selection? = nil) -> OpenWaiting {
        OpenWaiting(began: 100, arrived: arrived, before: before)
    }

    private func ago(_ seconds: TimeInterval) -> Date { arrived.addingTimeInterval(-seconds) }

    @Test func noServersJustOpens() {
        var w = wait()
        #expect(w.step(servers: [], now: 100, selection: nil, autoSelected: nil) == .nothing(.noServers))
    }

    @Test func everyServerKnownAndNobodyWaitingJustOpens() {
        var w = wait()
        let servers = [Server(known: true, problem: false), Server(known: true, problem: false)]
        #expect(w.step(servers: servers, now: 100, selection: nil, autoSelected: nil) == .nothing(.noneWaiting))
    }

    @Test func everyServerKnownOpensAtOnce() {
        var w = wait()
        let servers = [Server(known: true, problem: false, waiting: [Waiter(block: "b1", since: ago(5))])]
        #expect(w.step(servers: servers, now: 100, selection: nil, autoSelected: nil)
                == .open(OpenWaiting.Target(server: 0, block: "b1")))
    }

    @Test func waitsWhileAServerIsStillSyncing() {
        var w = wait()
        let syncing = [Server(known: false, problem: false), Server(known: true, problem: false)]
        #expect(w.step(servers: syncing, now: 100, selection: nil, autoSelected: nil) == .wait)
        #expect(w.step(servers: syncing, now: 109.9, selection: nil, autoSelected: nil) == .wait)
    }

    @Test func aServerThatSyncsLateIsWaitedFor() {
        var w = wait()
        var servers = [Server(known: false, problem: false), Server(known: true, problem: false)]
        #expect(w.step(servers: servers, now: 103, selection: nil, autoSelected: nil) == .wait)
        servers[0] = Server(known: true, problem: false, waiting: [Waiter(block: "late", since: nil)])
        #expect(w.step(servers: servers, now: 104, selection: nil, autoSelected: nil)
                == .open(OpenWaiting.Target(server: 0, block: "late")))
    }

    @Test func aServerShowingAProblemIsNotWaitedFor() {
        var w = wait()
        var servers = [Server(known: false, problem: false), Server(known: true, problem: false, waiting: [Waiter(block: "b", since: nil)])]
        #expect(w.step(servers: servers, now: 100, selection: nil, autoSelected: nil) == .wait)
        // The stuck server shows its offline screen: the wait ends there and then.
        servers[0].problem = true
        #expect(w.step(servers: servers, now: 100.5, selection: nil, autoSelected: nil)
                == .open(OpenWaiting.Target(server: 1, block: "b")))
    }

    @Test func aProblemServersStaleAgentsAreIgnored() {
        var w = wait()
        let servers = [Server(known: false, problem: true, waiting: [Waiter(block: "stale", since: ago(900))])]
        #expect(w.step(servers: servers, now: 100, selection: nil, autoSelected: nil) == .nothing(.noneWaiting))
    }

    @Test func everyServerOfflineJustOpens() {
        var w = wait()
        let servers = [Server(known: false, problem: true), Server(known: false, problem: true)]
        #expect(w.step(servers: servers, now: 100, selection: nil, autoSelected: nil) == .nothing(.noneWaiting))
    }

    @Test func givesUpAfterTenSeconds() {
        var w = wait()
        let servers = [Server(known: false, problem: false)]
        #expect(w.step(servers: servers, now: 100 + OpenWaiting.cap - 0.01, selection: nil, autoSelected: nil) == .wait)
        #expect(w.step(servers: servers, now: 100 + OpenWaiting.cap, selection: nil, autoSelected: nil) == .nothing(.timedOut))
        #expect(OpenWaiting.cap == 10)
    }

    @Test func afterTheFirstWaitingAgentTheOthersGetTwoSecondsMore() {
        var w = wait()
        var servers = [Server(known: false, problem: false), Server(known: false, problem: false)]
        #expect(w.step(servers: servers, now: 101, selection: nil, autoSelected: nil) == .wait)
        servers[1] = Server(known: true, problem: false, waiting: [Waiter(block: "b", since: nil)])
        // The two seconds run from when the agent was first known, not from the link.
        #expect(w.step(servers: servers, now: 103, selection: nil, autoSelected: nil) == .wait)
        #expect(w.step(servers: servers, now: 104.9, selection: nil, autoSelected: nil) == .wait)
        #expect(w.step(servers: servers, now: 105, selection: nil, autoSelected: nil)
                == .open(OpenWaiting.Target(server: 1, block: "b")))
        #expect(OpenWaiting.capAfterFirst == 2)
    }

    @Test func aSyncedServerWithNobodyWaitingStartsNoTwoSecondCap() {
        var w = wait()
        let servers = [Server(known: true, problem: false), Server(known: false, problem: false)]
        #expect(w.step(servers: servers, now: 101, selection: nil, autoSelected: nil) == .wait)
        #expect(w.step(servers: servers, now: 108, selection: nil, autoSelected: nil) == .wait)
        #expect(w.step(servers: servers, now: 110, selection: nil, autoSelected: nil) == .nothing(.timedOut))
    }

    @Test func thePersonSelectingSomethingGivesUp() {
        var w = wait(before: tabA)
        let servers = [Server(known: true, problem: false, waiting: [Waiter(block: "b", since: nil)]), Server(known: false, problem: false)]
        #expect(w.step(servers: servers, now: 100, selection: tabA, autoSelected: nil) == .wait)
        #expect(w.step(servers: servers, now: 100.5, selection: tabB, autoSelected: nil) == .nothing(.personMoved))
        // Even with everything known by then.
        let known = [Server(known: true, problem: false, waiting: [Waiter(block: "b", since: nil)])]
        #expect(w.step(servers: known, now: 100.6, selection: tabB, autoSelected: tabA) == .nothing(.personMoved))
    }

    @Test func autoSelectLandingOnTheLastTabDoesNotGiveUp() {
        // A cold launch: nothing on screen when the link arrives, then `autoSelect()` lands.
        var w = wait(before: nil)
        var servers = [Server(known: false, problem: false)]
        #expect(w.step(servers: servers, now: 100, selection: nil, autoSelected: nil) == .wait)
        #expect(w.step(servers: servers, now: 101, selection: tabA, autoSelected: tabA) == .wait)
        servers[0] = Server(known: true, problem: false, waiting: [Waiter(block: "b", since: nil)])
        #expect(w.step(servers: servers, now: 102, selection: tabA, autoSelected: tabA)
                == .open(OpenWaiting.Target(server: 0, block: "b")))
    }

    @Test func aTapAfterAutoSelectStillGivesUp() {
        var w = wait(before: nil)
        let servers = [Server(known: false, problem: false)]
        #expect(w.step(servers: servers, now: 101, selection: tabA, autoSelected: tabA) == .wait)
        #expect(w.step(servers: servers, now: 102, selection: tabB, autoSelected: tabA) == .nothing(.personMoved))
    }

    // MARK: Order

    @Test func theOldestWaitWinsAcrossMachines() {
        let servers = [
            Server(known: true, problem: false, waiting: [Waiter(block: "a1", since: ago(60)), Waiter(block: "a2", since: ago(30))]),
            Server(known: true, problem: false, waiting: [Waiter(block: "b1", since: ago(10)), Waiter(block: "b2", since: ago(600))]),
        ]
        #expect(OpenWaiting.oldest(servers, arrived: arrived) == OpenWaiting.Target(server: 1, block: "b2"))
    }

    @Test func anEqualSinceGoesByServerOrderThenBlockOrder() {
        let same = ago(60)
        let servers = [
            Server(known: true, problem: false, waiting: [Waiter(block: "a1", since: ago(5)), Waiter(block: "a2", since: same), Waiter(block: "a3", since: same)]),
            Server(known: true, problem: false, waiting: [Waiter(block: "b1", since: same)]),
        ]
        for _ in 0..<20 {
            #expect(OpenWaiting.oldest(servers, arrived: arrived) == OpenWaiting.Target(server: 0, block: "a2"))
        }
        #expect(OpenWaiting.oldest(servers.reversed(), arrived: arrived) == OpenWaiting.Target(server: 0, block: "b1"))
    }

    @Test func agentsFirstSeenAfterTheLinkArrivedTie() {
        // After a cold launch the first-seen times only say which server synced first.
        let servers = [
            Server(known: true, problem: false, waiting: [Waiter(block: "a1", since: arrived.addingTimeInterval(4))]),
            Server(known: true, problem: false, waiting: [Waiter(block: "b1", since: arrived.addingTimeInterval(1)), Waiter(block: "b2", since: nil)]),
        ]
        #expect(OpenWaiting.oldest(servers, arrived: arrived) == OpenWaiting.Target(server: 0, block: "a1"))
        // One seen before the link still beats them.
        var older = servers
        older[1].waiting[1].since = ago(1)
        #expect(OpenWaiting.oldest(older, arrived: arrived) == OpenWaiting.Target(server: 1, block: "b2"))
    }

    @Test func onlyServersThatKnowTheirAgentsCount() {
        let servers = [
            Server(known: false, problem: false, waiting: [Waiter(block: "a1", since: ago(900))]),
            Server(known: true, problem: false, waiting: [Waiter(block: "b1", since: ago(1))]),
        ]
        #expect(OpenWaiting.oldest(servers, arrived: arrived) == OpenWaiting.Target(server: 1, block: "b1"))
        #expect(OpenWaiting.oldest([servers[0]], arrived: arrived) == nil)
    }
}

/// `AppModel.openLink` and `openWaiting` on a model with servers that never connect, and a clock
/// the test moves.
@MainActor
@Suite struct OpenWaitingModelTests {
    /// A clock that only moves when the wait sleeps, and runs a script at given times.
    @MainActor
    final class FakeClock {
        var time: TimeInterval = 0
        var sleeps = 0
        private var events: [(at: TimeInterval, run: @MainActor () -> Void)] = []

        func at(_ t: TimeInterval, _ run: @escaping @MainActor () -> Void) { events.append((t, run)) }

        var clock: OpenWaiting.Clock {
            OpenWaiting.Clock(now: { self.time }, sleep: { d in
                self.sleeps += 1
                self.time += d
                let due = self.events.filter { $0.at <= self.time }
                self.events.removeAll { $0.at <= self.time }
                for e in due { e.run() }
                await Task.yield()
            })
        }
    }

    private func model() throws -> AppModel {
        let suite = "open-waiting-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let m = AppModel(prefs: Prefs(defaults: defaults), connect: false)
        m.firstSeenWaiting = { [:] }
        return m
    }

    private func server(_ model: AppModel, _ name: String) -> ServerConnection {
        let s = ServerConnection(config: ServerConfig(name: name, url: "https://\(name)-rex.tail1234.ts.net"),
                                 prefs: model.prefs, notifier: model.notifier, deviceID: "a1b2c3d4")
        model.servers.append(s)
        return s
    }

    /// Loads one session with one tab per entry of `tabs`, each holding the given blocks, and
    /// marks the listed blocks as waiting. The server then knows its agents.
    private func load(_ s: ServerConnection, session: String = "s1", tabs: [String: [String]], blocked: Set<String>) {
        let windows = tabs.keys.sorted().map { w -> JSONObject in
            ["window_id": w, "layers": [["kind": "tiled", "blocks": (tabs[w] ?? []).map {
                ["block_id": $0, "creator_name": "com.superlogical.terminal"] as JSONObject
            }] as JSONObject]]
        }
        let first = tabs.keys.sorted().first ?? ""
        s.sessions = [SessionEntry(id: session, label: session)]
        s.views = [session: SessionView(["revision": 1, "session_id": session, "active_window_id": first, "windows": windows])]
        for b in tabs.values.joined() {
            var m = BlockMeta()
            m.statuses = ["claude": ProgramStatus(["id": "claude", "app": "claude", "state": blocked.contains(b) ? "blocked" : "working"])]
            s.meta[b] = m
        }
        s.phase = .online
        s.synced = true
        s.agentsWereRead()
    }

    private func url(_ s: String) throws -> URL { try #require(URL(string: s)) }

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }

    // MARK: openWaiting

    @Test func opensTheWaitingAgentAsAPushTapDoes() async throws {
        let m = try model()
        let s = server(m, "desk")
        load(s, tabs: ["w1": ["b1"], "w2": ["b2", "b3"]], blocked: ["b3"])
        let clock = FakeClock()
        let step = await m.openWaiting(clock: clock.clock)
        #expect(step == .open(OpenWaiting.Target(server: 0, block: "b3")))
        #expect(m.openRequest?.selection == Selection(serverID: s.id, sessionID: "s1", windowID: "w2"))
        #expect(m.focusedPane["w2"] == "b3")
        #expect(clock.sleeps == 0)
    }

    @Test func nobodyWaitingShowsNoNoticeAndRunsNoCommand() async throws {
        let m = try model()
        let s = server(m, "desk")
        load(s, tabs: ["w1": ["b1"]], blocked: [])
        let notice = Notice.shared.message
        let step = await m.openWaiting(clock: FakeClock().clock)
        #expect(step == .nothing(.noneWaiting))
        #expect(m.openRequest == nil)
        #expect(m.lastCommand == nil)
        #expect(Notice.shared.message == notice)
        #expect(m.selection == nil)
    }

    @Test func noServersJustOpens() async throws {
        let m = try model()
        #expect(await m.openWaiting(clock: FakeClock().clock) == .nothing(.noServers))
        #expect(m.openRequest == nil && m.lastCommand == nil)
    }

    @Test func waitsForAServerThatSyncsLate() async throws {
        let m = try model()
        let s = server(m, "desk")
        s.phase = .connecting
        let clock = FakeClock()
        clock.at(3) { self.load(s, tabs: ["w1": ["b1"]], blocked: ["b1"]) }
        let step = await m.openWaiting(clock: clock.clock)
        #expect(step == .open(OpenWaiting.Target(server: 0, block: "b1")))
        #expect(abs(clock.time - 3) < 0.2)
        #expect(m.openRequest?.selection.windowID == "w1")
    }

    @Test func syncedIsNotEnoughTheAgentStatesMustBeRead() async throws {
        // The tabs are in (`synced`) before the states are: nobody seems to wait yet.
        let m = try model()
        let s = server(m, "desk")
        load(s, tabs: ["w1": ["b1"]], blocked: [])
        s.agentsWentStale()
        let clock = FakeClock()
        clock.at(1) {
            var meta = BlockMeta()
            meta.statuses = ["claude": ProgramStatus(["id": "claude", "app": "claude", "state": "blocked"])]
            s.meta["b1"] = meta
            s.agentsWereRead()
        }
        #expect(await m.openWaiting(clock: clock.clock) == .open(OpenWaiting.Target(server: 0, block: "b1")))
    }

    @Test func aServerStuckOfflineEndsTheWaitWhenItShowsItsProblem() async throws {
        let m = try model()
        let up = server(m, "desk"), down = server(m, "attic")
        // No agent known anywhere yet, so the two-second cap doesn't apply.
        load(up, tabs: ["w1": ["b1"]], blocked: [])
        down.phase = .connecting
        let clock = FakeClock()
        clock.at(4) { down.phase = .offline(ConnectionProblem(kind: .notAnswering, detail: "test")) }
        #expect(await m.openWaiting(clock: clock.clock) == .nothing(.noneWaiting))
        #expect(abs(clock.time - 4) < 0.2)
        #expect(m.openRequest == nil)
    }

    @Test func givesUpAfterTenSecondsOnTheInjectedClock() async throws {
        let m = try model()
        let s = server(m, "desk")
        s.phase = .connecting
        let clock = FakeClock()
        #expect(await m.openWaiting(clock: clock.clock) == .nothing(.timedOut))
        // Ten seconds of the wait's clock, not of the test's: that clock only moves in the sleeps
        // the wait asks of it.
        #expect(abs(clock.time - 10) < 0.2)
        #expect(clock.sleeps > 0)
        #expect(m.openRequest == nil && m.lastCommand == nil)
        // A server that comes up afterwards pulls nobody anywhere.
        load(s, tabs: ["w1": ["b1"]], blocked: ["b1"])
        await settle()
        #expect(m.openRequest == nil)
    }

    @Test func aSlowSecondServerGetsTwoSecondsOnceAnAgentIsKnown() async throws {
        let m = try model()
        let fast = server(m, "desk"), slow = server(m, "attic")
        load(fast, tabs: ["w1": ["b1"]], blocked: ["b1"])
        slow.phase = .connecting
        let clock = FakeClock()
        #expect(await m.openWaiting(clock: clock.clock) == .open(OpenWaiting.Target(server: 0, block: "b1")))
        #expect(abs(clock.time - 2) < 0.2)
    }

    @Test func thePersonSelectingSomethingMeanwhileGivesUp() async throws {
        let m = try model()
        let s = server(m, "desk")
        s.phase = .connecting
        let clock = FakeClock()
        clock.at(1) { m.selection = Selection(serverID: s.id, sessionID: "other", windowID: "w9") }
        clock.at(2) { self.load(s, tabs: ["w1": ["b1"]], blocked: ["b1"]) }
        #expect(await m.openWaiting(clock: clock.clock) == .nothing(.personMoved))
        #expect(abs(clock.time - 1) < 0.2)
        #expect(m.openRequest == nil)
    }

    @Test func autoSelectMidWaitDoesNotCancelTheJump() async throws {
        let m = try model()
        let s = server(m, "desk")
        s.phase = .connecting
        let clock = FakeClock()
        // The tabs arrive and the launch lands on one by itself; the states come a second later.
        clock.at(1) {
            self.load(s, tabs: ["w1": ["b1"], "w2": ["b2"]], blocked: [])
            s.agentsWentStale()
            m.autoSelect()
        }
        clock.at(2) {
            var meta = BlockMeta()
            meta.statuses = ["claude": ProgramStatus(["id": "claude", "app": "claude", "state": "blocked"])]
            s.meta["b2"] = meta
            s.agentsWereRead()
        }
        let step = await m.openWaiting(clock: clock.clock)
        #expect(m.autoSelected == Selection(serverID: s.id, sessionID: "s1", windowID: "w1"))
        #expect(step == .open(OpenWaiting.Target(server: 0, block: "b2")))
        #expect(m.openRequest?.selection == Selection(serverID: s.id, sessionID: "s1", windowID: "w2"))
    }

    @Test func aTapAfterAutoSelectStillCancelsTheJump() async throws {
        let m = try model()
        let s = server(m, "desk")
        s.phase = .connecting
        let clock = FakeClock()
        clock.at(1) {
            self.load(s, tabs: ["w1": ["b1"], "w2": ["b2"]], blocked: [])
            s.agentsWentStale()
            m.autoSelect()
        }
        clock.at(1.5) { m.selection = Selection(serverID: s.id, sessionID: "s1", windowID: "w2") }
        clock.at(2) { s.agentsWereRead() }
        #expect(await m.openWaiting(clock: clock.clock) == .nothing(.personMoved))
        #expect(m.openRequest == nil)
    }

    @Test func aTapOnATabAutoSelectedBeforeTheLinkStillCancelsTheJump() async throws {
        let m = try model()
        let s = server(m, "desk"), slow = server(m, "attic")
        load(s, tabs: ["w1": ["b1"], "w2": ["b2"]], blocked: [])
        slow.phase = .connecting
        // The launch landed on w1 long ago; the person has since moved to w2.
        m.autoSelect()
        let landed = try #require(m.autoSelected)
        m.selection = Selection(serverID: s.id, sessionID: "s1", windowID: "w2")
        let clock = FakeClock()
        // During the wait the person taps the tab the launch once landed on: their move.
        clock.at(1) { m.selection = landed }
        clock.at(2) { self.load(slow, tabs: ["w5": ["b5"]], blocked: ["b5"]) }
        #expect(await m.openWaiting(clock: clock.clock) == .nothing(.personMoved))
        #expect(abs(clock.time - 1) < 0.2)
        #expect(m.openRequest == nil)
    }

    @Test func agentKeysAreExactTheMomentAServerTurnsCurrent() throws {
        let m = try model()
        let s = server(m, "desk")
        s.sessions = [SessionEntry(id: "s1", label: "s1")]
        s.views = ["s1": SessionView(["revision": 1, "session_id": "s1", "active_window_id": "w1", "windows": [
            ["window_id": "w1", "layers": [["kind": "tiled", "blocks": [["block_id": "b1", "creator_name": "com.superlogical.terminal"] as JSONObject]] as JSONObject]] as JSONObject,
        ]])]
        var meta = BlockMeta()
        meta.statuses = ["claude": ProgramStatus(["id": "claude", "app": "claude", "state": "blocked"])]
        s.meta["b1"] = meta
        // Not a turn later: the wait reads `agentKeys` as soon as it sees `agentsCurrent`.
        #expect(s.agentKeys.isEmpty)
        s.agentsWereRead()
        #expect(s.agentsCurrent)
        #expect(s.agentKeys.map(\.blockID) == ["b1"] && s.agentKeys.first?.state == "blocked")
        s.agentsWentStale()
        #expect(!s.agentsCurrent)
    }

    // MARK: The controls' intent

    @Test func theIntentCarriesItsLinkAsARawValue() {
        for link in DeepLink.allCases {
            let intent = OpenLinkIntent(link: link)
            #expect(intent.link == link.rawValue)
            #expect(DeepLink(rawValue: intent.link) == link)
            #expect(intent.target == link)
            #expect(DeepLink(intent.target.url) == link)
        }
        #expect(OpenLinkIntent().target == .open)
    }

    @Test func anIntentWithAnUnknownLinkOnlyOpensTheApp() {
        let intent = OpenLinkIntent()
        for raw in ["", "bogus", "WAITING", "waiting ", "rexduo://waiting", "pane", "%77aiting"] {
            intent.link = raw
            #expect(intent.target == .open, "\(raw)")
        }
        intent.link = "waiting"
        #expect(intent.target == .waiting)
    }

    @Test func theOldestAcrossTwoMachinesWins() async throws {
        let m = try model()
        let a = server(m, "desk"), b = server(m, "attic")
        load(a, tabs: ["w1": ["a1"]], blocked: ["a1"])
        load(b, tabs: ["w5": ["b1", "b2"]], blocked: ["b1", "b2"])
        let now = Date()
        m.firstSeenWaiting = { ["a1": now.addingTimeInterval(-60), "b1": now.addingTimeInterval(-30), "b2": now.addingTimeInterval(-600)] }
        #expect(await m.openWaiting(clock: FakeClock().clock) == .open(OpenWaiting.Target(server: 1, block: "b2")))
        #expect(m.openRequest?.selection == Selection(serverID: b.id, sessionID: "s1", windowID: "w5"))
        #expect(m.focusedPane["w5"] == "b2")
    }

    @Test func withNoTimesKnownItGoesByServerThenBlockOrder() async throws {
        let m = try model()
        let a = server(m, "desk"), b = server(m, "attic")
        load(a, tabs: ["w1": ["a1"], "w2": ["a2"]], blocked: ["a2"])
        load(b, tabs: ["w5": ["b1"]], blocked: ["b1"])
        #expect(await m.openWaiting(clock: FakeClock().clock) == .open(OpenWaiting.Target(server: 0, block: "a2")))
        #expect(m.openRequest?.selection.serverID == a.id)
    }

    // MARK: openLink

    @Test func aLinkBeforeTheFirstScreenIsQueuedThenRun() async throws {
        let m = try model()
        let s = server(m, "desk")
        load(s, tabs: ["w1": ["b1"]], blocked: ["b1"])
        m.openLink(try url("rexduo://waiting"))
        await settle()
        #expect(m.openRequest == nil)
        m.releaseLinks()
        await settle()
        #expect(m.openRequest?.selection == Selection(serverID: s.id, sessionID: "s1", windowID: "w1"))
    }

    @Test func aQueuedJumpIsNotReplacedByOpen() async throws {
        let m = try model()
        let s = server(m, "desk")
        load(s, tabs: ["w1": ["b1"]], blocked: ["b1"])
        m.openLink(try url("rexduo://waiting"))
        m.openLink(try url("rexduo://open"))
        m.releaseLinks()
        await settle()
        #expect(m.openRequest?.selection.windowID == "w1")
    }

    @Test func openChangesNothing() async throws {
        let m = try model()
        let s = server(m, "desk")
        load(s, tabs: ["w1": ["b1"]], blocked: ["b1"])
        m.releaseLinks()
        m.boardShown = true
        m.showSettings = true
        for link in ["rexduo://open", "rexduo://open?x=1", "rexduo://settings", "rexduo://pane?block=b1", "rexduo://waiting/extra"] {
            m.openLink(try url(link))
        }
        await settle()
        #expect(m.openRequest == nil)
        #expect(m.lastCommand == nil)
        #expect(m.selection == nil)
        #expect(m.focusedPane.isEmpty)
        #expect(m.boardShown && m.showSettings)
    }

    @Test func otherSchemesAreIgnored() async throws {
        let m = try model()
        let s = server(m, "desk")
        load(s, tabs: ["w1": ["b1"]], blocked: ["b1"])
        m.releaseLinks()
        for link in ["javascript:alert(1)", "https://waiting", "file:///waiting", "rex://waiting", "rexduo2://waiting"] {
            m.openLink(try url(link))
        }
        await settle()
        #expect(m.openRequest == nil && m.lastCommand == nil && m.selection == nil)
        // And none of them is kept for later.
        let fresh = try model()
        let t = server(fresh, "desk")
        load(t, tabs: ["w1": ["b1"]], blocked: ["b1"])
        fresh.openLink(try url("https://waiting"))
        fresh.releaseLinks()
        await settle()
        #expect(fresh.openRequest == nil)
    }

    @Test func aWaitingLinkAfterReleaseJumps() async throws {
        let m = try model()
        let s = server(m, "desk")
        load(s, tabs: ["w1": ["b1"], "w2": ["b2"]], blocked: ["b2"])
        m.releaseLinks()
        m.openLink(try url("rexduo://waiting"))
        await settle()
        #expect(m.openRequest?.selection == Selection(serverID: s.id, sessionID: "s1", windowID: "w2"))
    }

    @Test func autoSelectRecordsWhatItSet() throws {
        let m = try model()
        let s = server(m, "desk")
        #expect(m.autoSelected == nil)
        load(s, tabs: ["w1": ["b1"]], blocked: [])
        m.autoSelect()
        #expect(m.selection == Selection(serverID: s.id, sessionID: "s1", windowID: "w1"))
        #expect(m.autoSelected == m.selection)
        // A tab the person picks is not recorded as the launch's.
        m.selection = Selection(serverID: s.id, sessionID: "s1", windowID: "w9")
        m.autoSelect()
        #expect(m.autoSelected != m.selection)
    }
}
