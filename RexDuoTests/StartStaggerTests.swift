import Foundation
import GlanceModel
import Testing
@testable import RexDuo

/// The order and the times of a launch's starts (`StartStagger`), and the model that follows
/// them: the computer of the tab the launch opens first, the others a second later, one at a
/// time; nobody waits when there is no tab to open, when the user opens a computer, or after a
/// return from the background.
@MainActor
@Suite struct StartStaggerTests {
    private let a = UUID(), b = UUID(), c = UUID()

    @Test func theComputerOfTheLaunchsTabStartsNowAndTheOthersFollowOneAtATime() {
        let plan = StartStagger.plan(servers: [a, b, c], first: b, unit: { 0 })
        #expect(plan.now == [b])
        #expect(plan.later == [.init(id: a, pause: 0), .init(id: c, pause: 0.25)])
        #expect(StartStagger.plan(servers: [a, b, c], first: b, unit: { 1 }).later.map(\.pause) == [0, 0.5])
        // A number out of range is taken as its nearest end.
        #expect(StartStagger.plan(servers: [a, b, c], first: a, unit: { 7 }).later.map(\.pause) == [0, 0.5])
        #expect(StartStagger.lead == 1)
    }

    @Test func withNoTabToOpenEveryComputerStartsAtOnceAsBefore() {
        for first in [nil, UUID()] as [UUID?] {
            let plan = StartStagger.plan(servers: [a, b, c], first: first, unit: { 0.5 })
            #expect(plan == .init(now: [a, b, c], later: []))
        }
        #expect(StartStagger.plan(servers: [a], first: a, unit: { 0.5 }) == .init(now: [a], later: []))
        #expect(StartStagger.plan(servers: [], first: nil, unit: { 0.5 }) == .init(now: [], later: []))
    }

    @Test func theFirstHasSettledOnceItSyncedFailedOrWentDormant() {
        #expect(!StartStagger.settled(synced: false, failed: false, dormant: false))
        #expect(StartStagger.settled(synced: true, failed: false, dormant: false))
        #expect(StartStagger.settled(synced: false, failed: true, dormant: false))
        #expect(StartStagger.settled(synced: false, failed: false, dormant: true))
    }

    // MARK: The model

    /// The waits of the model's turns, ended by the test.
    @MainActor private final class Waits {
        var asked: [Double] = []
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait(_ seconds: Double) async {
            asked.append(seconds)
            await withCheckedContinuation { waiters.append($0) }
        }
        /// The oldest wait ends.
        func pass() { if !waiters.isEmpty { waiters.removeFirst().resume() } }
    }

    /// Three saved computers, the tab viewed last on the second, and every start recorded.
    private func model(cellular: Bool? = true) throws -> (AppModel, Waits, started: () -> [String]) {
        let suite = "stagger-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let prefs = Prefs(defaults: defaults)
        // An address nothing listens on: the one real start below (a resume) is refused at once.
        prefs.servers = ["desk", "laptop", "mini"].map { ServerConfig(name: $0, url: "http://127.0.0.1:1") }
        prefs.lastSelection = Selection(serverID: prefs.servers[1].id, sessionID: "s", windowID: "w")
        let m = AppModel(prefs: prefs, connect: true)
        final class Record { var names: [String] = [] }
        let record = Record()
        m.startServer = { record.names.append($0.config.name) }
        let waits = Waits()
        m.staggerSleep = { await waits.wait($0) }
        // A cellular launch: the only one that takes turns.
        m.launchPathExpensive = { cellular }
        return (m, waits, { record.names })
    }

    private func turn() async { for _ in 0..<20 { await Task.yield() } }

    /// The computer of the launch's tab starts inside `sceneVisible`, before any wait is asked for.
    @Test func theLaunchsComputerStartsAtOnceWithNoWaitBeforeIt() async throws {
        let (m, waits, started) = try model()
        m.sceneVisible()
        #expect(started() == ["laptop"], "in the same turn")
        #expect(waits.asked.isEmpty, "and no wait was asked for before it")
        #expect(m.waitingToStart.count == 2)
        for s in m.servers { s.stop() }
    }

    /// The cap: a second after the first, the others start whatever the first is doing.
    @Test func afterASecondTheOthersStartOneAtATime() async throws {
        let (m, waits, started) = try model()
        m.sceneVisible()
        // The launch's first `.active` phase resumes the servers: those that wait keep waiting.
        m.foregroundResumed()
        await turn()
        #expect(started() == ["laptop"])
        #expect(waits.asked == [1], "one wait, a second at most")
        waits.pass()
        await turn()
        #expect(started() == ["laptop", "desk"], "the first of the others with no pause")
        #expect(waits.asked.count == 2 && (0.25...0.5).contains(waits.asked[1]))
        waits.pass()
        await turn()
        #expect(started() == ["laptop", "desk", "mini"])
        #expect(m.waitingToStart.isEmpty)
        // Nothing starts twice.
        m.sceneVisible()
        waits.pass()
        await turn()
        #expect(started() == ["laptop", "desk", "mini"])
        for s in m.servers { s.stop() }
    }

    /// The three things that settle the first computer each start the others before the second is over.
    @Test(arguments: ["synced", "failed", "dormant"])
    func theOthersStartAsSoonAsTheFirstHasSettled(_ how: String) async throws {
        let (m, waits, started) = try model()
        m.sceneVisible()
        await turn()
        let laptop = m.servers[1].id, desk = m.servers[0].id
        // Another computer's news changes nothing, nor does the first one still connecting.
        m.leadReported(desk, synced: true, failed: false, dormant: false)
        m.leadReported(laptop, synced: false, failed: false, dormant: false)
        await turn()
        #expect(started() == ["laptop"])
        m.leadReported(laptop, synced: how == "synced", failed: how == "failed", dormant: how == "dormant")
        await turn()
        #expect(started() == ["laptop", "desk"], "\(how): at once, the second not over")
        // The pause between the others; the first one's second is given up.
        waits.pass()
        await turn()
        waits.pass()
        await turn()
        #expect(started() == ["laptop", "desk", "mini"])
        // Its news a second time starts nobody again.
        m.leadReported(laptop, synced: true, failed: false, dormant: false)
        waits.pass()
        await turn()
        #expect(started() == ["laptop", "desk", "mini"])
        for s in m.servers { s.stop() }
    }

    @Test func aComputerTheUserOpensDoesNotWaitItsTurnAndIsNotStartedAgainWhenItComes() async throws {
        let (m, waits, started) = try model()
        m.sceneVisible()
        let mini = try #require(m.servers.last)
        m.select(mini, session: "s", window: "w")
        #expect(started() == ["laptop", "mini"])
        await turn()
        waits.pass()
        await turn()
        waits.pass()
        await turn()
        #expect(started() == ["laptop", "mini", "desk"])
        for s in m.servers { s.stop() }
    }

    @Test func nothingStartsInTheBackgroundAndTheReturnStartsWhoeverWaits() async throws {
        let (m, waits, started) = try model()
        m.sceneVisible()
        await turn()
        m.enteredBackground()
        // The first settles and the pauses pass, all in the background.
        m.leadReported(m.servers[1].id, synced: true, failed: false, dormant: false)
        await turn()
        waits.pass()
        await turn()
        waits.pass()
        await turn()
        #expect(started() == ["laptop"], "their turns came in the background: nothing started")
        m.foregroundResumed()
        #expect(Set(started()) == ["laptop", "desk", "mini"])
        #expect(started().count == 3)
        #expect(m.waitingToStart.isEmpty)
        for s in m.servers { s.stop() }
    }

    @Test func aChangedListEndsTheTurnsAndStartsEveryone() async throws {
        let (m, waits, started) = try model()
        m.sceneVisible()
        await turn()
        m.rebuildServers()
        #expect(m.waitingToStart.isEmpty)
        let after = started().count
        #expect(after >= 3, "the rebuilt list is started whole")
        waits.pass()
        await turn()
        waits.pass()
        await turn()
        #expect(started().count == after, "the old turns start nobody")
    }

    // MARK: Only a cellular launch takes turns

    /// On Wi-Fi, and when the path has not been reported yet, a launch is as it always was:
    /// every computer starts in the same turn, in Settings' order, and no wait is asked for.
    @Test(arguments: [false, nil] as [Bool?])
    func onWiFiOrWithThePathUnknownEveryComputerStartsAtOnce(_ path: Bool?) async throws {
        let (m, waits, started) = try model(cellular: path)
        m.sceneVisible()
        #expect(started() == ["desk", "laptop", "mini"])
        #expect(m.waitingToStart.isEmpty)
        await turn()
        #expect(waits.asked.isEmpty)
    }

    // MARK: Whatever the user asks of a computer, it does not wait its turn

    /// A cellular launch with the last tab on the second computer: the third waits its turn.
    private func waiting() throws -> (AppModel, ServerConnection, started: () -> [String]) {
        let (m, _, started) = try model()
        m.sceneVisible()
        #expect(started() == ["laptop"])
        return (m, try #require(m.servers.last), started)
    }

    @Test func aPaneLinkStartsItsComputerInTheSameTurn() throws {
        let (m, mini, started) = try waiting()
        m.openLink(PaneLink(server: mini.id.uuidString, session: "s", window: "w", block: "b").url)
        #expect(started() == ["laptop", "mini"], "a tapped notification or widget row")
        #expect(m.waitingToStart.count == 1, "the other one keeps its turn")
    }

    @Test func openingAPaneLinkStartsItsComputerBeforeItWaitsForAnything() async throws {
        let (m, mini, started) = try waiting()
        let link = PaneLink(server: mini.id.uuidString, session: "s", window: "w", block: "b")
        let opening = Task { @MainActor in await m.openPane(link: link) }
        await turn()
        #expect(started() == ["laptop", "mini"])
        opening.cancel()
        _ = await opening.value
    }

    @Test func theLinkToWhoeverWaitsStartsEveryComputer() throws {
        let (m, _, started) = try waiting()
        m.openLink(DeepLink.waiting.url)
        #expect(Set(started()) == ["laptop", "desk", "mini"])
        #expect(m.waitingToStart.isEmpty)
    }

    @Test func thePlainOpenLinkStartsNobodyEarly() throws {
        let (m, _, started) = try waiting()
        m.openLink(DeepLink.open.url)
        #expect(started() == ["laptop"])
    }

    @Test func anActionFromTheWatchStartsItsComputerInTheSameTurn() throws {
        let (m, mini, started) = try waiting()
        let target = WatchAction.Target(server: mini.id.uuidString, session: "s", block: "b", record: "r", fp: "f")
        _ = m.actionChannel(WatchAction(id: "tap-1", kind: .enter, target: target))
        #expect(started() == ["laptop", "mini"], "Enter or Interrupt from the watch, or on a notification")
    }

    @Test func openingAPaneOfAComputerStartsItInTheSameTurn() throws {
        let (m, mini, started) = try waiting()
        _ = m.openPane(mini, session: "s", window: nil, block: nil)
        #expect(started() == ["laptop", "mini"], "a toast, the board, the palette's pick, a port's pane")
    }

    @Test(arguments: ["retry", "reconnect", "refresh", "new session"])
    func askingAComputerForSomethingStartsItInTheSameTurn(_ what: String) async throws {
        let (m, mini, started) = try waiting()
        switch what {
        case "retry": mini.retryNow()
        case "reconnect": mini.reconnect()
        case "refresh": Task { @MainActor in await mini.refresh() }
        default: Task { @MainActor in _ = await mini.createSession(label: nil) }
        }
        await turn()
        #expect(started() == ["laptop", "mini"], "\(what)")
        for s in m.servers { s.stop() }
    }

    @Test func thePaletteAPullToRefreshAndTheWaitingAgentStartEveryComputer() async throws {
        for what in ["all", "refresh", "waiting"] {
            let (m, _, started) = try waiting()
            let task: Task<Void, Never>?
            switch what {
            case "all": m.startAllWaiting(); task = nil
            case "refresh": task = Task { @MainActor in await m.refresh() }
            default: task = Task { @MainActor in _ = await m.openWaiting() }
            }
            await turn()
            #expect(Set(started()) == ["laptop", "desk", "mini"], "\(what)")
            #expect(m.waitingToStart.isEmpty)
            task?.cancel()
            for s in m.servers { s.stop() }
        }
    }
}
