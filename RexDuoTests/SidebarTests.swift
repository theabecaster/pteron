import Foundation
import Observation
import Synchronization
import Testing
import RexKit
@testable import RexDuo

/// Set from an observation's `onChange`, which may run on any thread.
private final class Fired: Sendable {
    private let flag = Atomic(false)
    var value: Bool {
        get { flag.load(ordering: .sequentiallyConsistent) }
        set { flag.store(newValue, ordering: .sequentiallyConsistent) }
    }
}

/// The sidebar's pure logic: which rows show for a fold state, how fold state is saved and pruned,
/// the Agents mode's order, and the mode commands.
struct SidebarOutlineTests {
    private let mac = UUID()
    private let box = UUID()

    private var machines: [SidebarOutline.Machine] {
        [SidebarOutline.Machine(id: mac, sessions: [
            .init(id: "s1", windowIDs: ["w1", "w2"]),
            .init(id: "s2", windowIDs: ["w3"]),
        ]),
         SidebarOutline.Machine(id: box, sessions: [.init(id: "s3", windowIDs: [])])]
    }

    @Test func openShowsEveryLevelInOrder() {
        let rows = SidebarOutline.rows(machines, collapsed: [])
        #expect(rows.map(\.kind) == [
            .machine(mac), .session(mac, "s1"), .tab(mac, session: "s1", window: "w1"),
            .tab(mac, session: "s1", window: "w2"), .session(mac, "s2"), .tab(mac, session: "s2", window: "w3"),
            .machine(box), .session(box, "s3"),
        ])
        #expect(rows.first?.first == true)
        #expect(rows.filter(\.first).count == 1)
        // A session's last tab closes its guide.
        #expect(rows.filter(\.last).map(\.id) == ["t:\(mac.uuidString):w2", "t:\(mac.uuidString):w3"])
    }

    @Test func foldingASessionHidesOnlyItsTabs() {
        let rows = SidebarOutline.rows(machines, collapsed: [SidebarCollapse.session(mac, "s1")])
        #expect(rows.map(\.kind) == [
            .machine(mac), .session(mac, "s1"), .session(mac, "s2"), .tab(mac, session: "s2", window: "w3"),
            .machine(box), .session(box, "s3"),
        ])
    }

    @Test func foldingAMachineHidesItsSessionsAndKeepsTheirOwnFolds() {
        let folded: Set = [SidebarCollapse.machine(mac), SidebarCollapse.session(mac, "s1")]
        let rows = SidebarOutline.rows(machines, collapsed: folded)
        #expect(rows.map(\.kind) == [.machine(mac), .machine(box), .session(box, "s3")])
        // Opening the machine again shows s1 still folded.
        let reopened = SidebarOutline.rows(machines, collapsed: folded.subtracting([SidebarCollapse.machine(mac)]))
        #expect(!reopened.contains { $0.kind == .tab(mac, session: "s1", window: "w1") })
        #expect(reopened.contains { $0.kind == .tab(mac, session: "s2", window: "w3") })
    }

    @Test func idsStayTheSameWhateverIsFolded() {
        let open = Dictionary(uniqueKeysWithValues: SidebarOutline.rows(machines, collapsed: []).map { ($0.id, $0.kind) })
        let folded = SidebarOutline.rows(machines, collapsed: [SidebarCollapse.session(mac, "s1")])
        for r in folded { #expect(open[r.id] == r.kind) }
        #expect(Set(open.keys).count == open.count)
    }

    @Test func pruningDropsGoneSessionsAndServersButKeepsDownServers() {
        let down = UUID()
        let keys: Set = [
            SidebarCollapse.machine(mac), SidebarCollapse.session(mac, "s1"), SidebarCollapse.session(mac, "gone"),
            SidebarCollapse.session(down, "old"), SidebarCollapse.machine(UUID()), "junk",
        ]
        let kept = SidebarCollapse.pruned(keys, servers: [mac, down], live: [mac: ["s1", "s2"]])
        #expect(kept == [SidebarCollapse.machine(mac), SidebarCollapse.session(mac, "s1"), SidebarCollapse.session(down, "old")])
    }

    @Test func sessionIDsWithColonsSurviveTheKey() {
        let sid = "session:01a1e84f-cd5a"
        let key = SidebarCollapse.session(mac, sid)
        #expect(SidebarCollapse.pruned([key], servers: [mac], live: [mac: [sid]]) == [key])
        #expect(SidebarCollapse.pruned([key], servers: [mac], live: [mac: []]).isEmpty)
    }
}

@MainActor
struct SidebarCollapsePrefsTests {
    @Test func foldStateIsSavedAndRestored() {
        let name = "RexDuoTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        defer { d.removePersistentDomain(forName: name) }
        let p = Prefs(defaults: d)
        #expect(p.sidebarCollapsed.isEmpty)
        p.sidebarCollapsed = ["m:A", "s:A:session:1"]
        #expect(Prefs(defaults: d).sidebarCollapsed == ["m:A", "s:A:session:1"])
    }
}

struct AgentOrderTests {
    private struct Row: Equatable { var id: String; var state: String? }

    private func sorted(_ rows: [Row], since: [String: Date] = [:]) -> [String] {
        AgentOrder.sorted(rows, state: \.state, id: \.id, since: since).map(\.id)
    }

    @Test func waitingFirstThenErrorWorkingDoneIdle() {
        let rows = [Row(id: "idle", state: "idle"), Row(id: "done", state: "done"), Row(id: "work", state: "working"),
                    Row(id: "wait", state: "blocked"), Row(id: "err", state: "error"), Row(id: "none", state: nil)]
        #expect(sorted(rows) == ["wait", "err", "work", "done", "idle", "none"])
    }

    @Test func theLongestWaitingComesFirst() {
        let now = Date()
        let rows = [Row(id: "a", state: "blocked"), Row(id: "b", state: "blocked"), Row(id: "c", state: "blocked")]
        let since = ["a": now, "b": now.addingTimeInterval(-60), "c": now.addingTimeInterval(-30)]
        #expect(sorted(rows, since: since) == ["b", "c", "a"])
    }

    @Test func sameStateKeepsTheServersOrder() {
        let rows = (0..<20).map { Row(id: "\($0)", state: "working") }
        #expect(sorted(rows) == rows.map(\.id))
    }
}

@MainActor
struct SidebarModeTests {
    @Test func activityToggleShowsAgentsThenGoesBackToSessions() {
        var s = SidebarState()
        #expect(s.mode == .sessions)
        let handled = s.perform(.toggleAgents)
        #expect(handled)
        #expect(s.open && s.mode == .agents)
        _ = s.perform(.toggleAgents)
        #expect(s.open && s.mode == .sessions)
    }

    @Test func activityToggleOpensAHiddenSidebarInAgentsMode() {
        var s = SidebarState()
        s.mode = .agents
        _ = s.perform(.toggleSidebar)
        #expect(!s.open)
        _ = s.perform(.toggleAgents)
        #expect(s.open && s.mode == .agents)
    }

    @Test func cmdPeriodIsTheActivityToggle() {
        guard case .command(let c) = AppAction.resolve("client.sidebar.activity.toggle", nil) else {
            Issue.record("not a command")
            return
        }
        #expect(c == .toggleAgents)
        #expect(!RexCommand.toggleAgents.isWindowCommand)
    }

    @Test func jumpToWaitingHasItsOwnActionAndKey() throws {
        guard case .command(let c) = AppAction.resolve("client.agents.jump_to_waiting", nil) else {
            Issue.record("not a command")
            return
        }
        #expect(c == .jumpToWaiting)
        let s = try #require(AppShortcuts.list(KeyDefaults.resolved).first { $0.command == .jumpToWaiting })
        #expect(s.key.character == ".")
        #expect(s.modifiers == [.command, .option])
        #expect(s.title == "Jump to Waiting")
        // ⌘. stays the Agents toggle.
        #expect(AppShortcuts.list(KeyDefaults.resolved).first { $0.id == "cmd+." }?.command == .toggleAgents)
    }

    @Test func machineGlyphFollowsThePlatform() {
        #expect(MachineGlyph.symbol(platform: "darwin_arm64") == "apple.logo")
        #expect(MachineGlyph.symbol(platform: "linux_amd64") == "server.rack")
        #expect(MachineGlyph.symbol(platform: "windows_amd64") == "pc")
        #expect(MachineGlyph.symbol(platform: nil) == "desktopcomputer")
    }
}

/// The sidebar's state against a real `ServerConnection`: the agent index, the rows' `==`, prune
/// keys and folding.
@MainActor
struct SidebarRowStateTests {
    private func fixture() -> (Prefs, ServerConnection) {
        let name = "RexDuoTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        let prefs = Prefs(defaults: d)
        let model = AppModel(prefs: prefs, connect: false)
        let server = ServerConnection(config: ServerConfig(name: "Desk", url: "https://desk-rex.tail1.ts.net"),
                                      prefs: prefs, notifier: model.notifier, deviceID: "a1b2c3d4")
        return (prefs, server)
    }

    private func windowJSON(_ id: String, label: String = "", blocks: [String]) -> JSONObject {
        ["window_id": id, "label": label,
         "layers": [["kind": "tiled", "blocks": blocks.map { ["block_id": $0, "creator_name": "com.superlogical.terminal"] }]]]
    }

    private func window(_ id: String, label: String = "", blocks: [String] = ["b"]) -> WindowInfo {
        WindowInfo(windowJSON(id, label: label, blocks: blocks))
    }

    private func status(_ state: String, app: String = "claude") -> BlockMeta {
        var m = BlockMeta()
        m.statuses[""] = ProgramStatus(["state": state, "app": app])
        return m
    }

    /// Lets the coalesced agent index update.
    private func settle() async {
        for _ in 0..<3 { await Task.yield() }
    }

    @Test func agentKeysChangeOnlyForAgentStateNotForOtherMetadata() async {
        let (_, server) = fixture()
        server.sessions = [SessionEntry(id: "s1", label: "work")]
        server.views = ["s1": SessionView(["session_id": "s1", "label": "work",
                                           "windows": [windowJSON("w1", blocks: ["b1", "b2"])]])]
        server.meta["b1"] = status("working")
        await settle()
        #expect(server.agentKeys.map(\.blockID) == ["b1"])
        #expect(server.agentKeys.first?.state == "working")

        // A title or status line change leaves the index as it was.
        let before = server.agentKeys
        var titled = status("working")
        titled.title = "new title"
        titled.statuses[""]?.text = "step 2"
        server.meta["b1"] = titled
        server.meta["b2"] = { var m = BlockMeta(); m.title = "zsh"; return m }()
        await settle()
        #expect(server.agentKeys == before)

        // Waiting changes it.
        server.meta["b1"] = status("blocked")
        await settle()
        #expect(server.agentKeys.first?.state == "blocked")
    }

    /// The title bar's waiting pill reads `Waiting.all`: a title or status line change in some pane
    /// mustn't re-render it, an agent starting to wait must.
    @Test func waitingListReadsOnlyTheAgentIndex() async {
        let (_, server) = fixture()
        server.sessions = [SessionEntry(id: "s1", label: "work")]
        server.views = ["s1": SessionView(["session_id": "s1", "label": "work",
                                           "windows": [windowJSON("w1", blocks: ["b1", "b2"])]])]
        server.meta["b1"] = status("working")
        await settle()

        let fired = Fired()
        let initial = withObservationTracking { Waiting.all([server]) } onChange: { fired.value = true }
        #expect(initial.isEmpty)
        var titled = status("working")
        titled.title = "new title"
        titled.statuses[""]?.text = "step 2"
        server.meta["b1"] = titled
        server.meta["b2"] = { var m = BlockMeta(); m.title = "zsh"; return m }()
        await settle()
        #expect(!fired.value)

        server.meta["b1"] = status("blocked")
        await settle()
        #expect(fired.value)
        let items = Waiting.all([server])
        #expect(items.map(\.id) == ["b1"])
        #expect(items.first?.key.windowID == "w1")
        #expect(items.first?.key.sessionID == "s1")
    }

    @Test func rowsCompareWhatTheyShow() {
        let (_, server) = fixture()
        let theme = ThemeStore.fallback
        let actions = SidebarActions()
        let tab = TabRow(server: server, sessionID: "s1", window: window("w1"), selected: false,
                         dim: false, theme: theme, actions: actions)
        #expect(tab == TabRow(server: server, sessionID: "s1", window: window("w1"), selected: false,
                              dim: false, theme: theme, actions: actions))
        #expect(tab != TabRow(server: server, sessionID: "s1", window: window("w1"), selected: true,
                              dim: false, theme: theme, actions: actions))
        #expect(tab != TabRow(server: server, sessionID: "s1", window: window("w1", label: "renamed"),
                              selected: false, dim: false, theme: theme, actions: actions))
        #expect(tab != TabRow(server: server, sessionID: "s1", window: window("w1", blocks: ["b", "c"]),
                              selected: false, dim: false, theme: theme, actions: actions))
        #expect(tab != TabRow(server: server, sessionID: "s1", window: window("w1"), selected: false,
                              dim: true, theme: theme, actions: actions))

        let entry = SessionEntry(id: "s1", label: "work")
        let session = SessionRow(server: server, session: entry, windows: [window("w1")], collapsed: false, topGap: 6,
                                 dim: false, theme: theme, actions: actions)
        #expect(session == SessionRow(server: server, session: entry, windows: [window("w1")], collapsed: false,
                                      topGap: 6, dim: false, theme: theme, actions: actions))
        #expect(session != SessionRow(server: server, session: entry, windows: [window("w1")], collapsed: true,
                                      topGap: 6, dim: false, theme: theme, actions: actions))
        #expect(session != SessionRow(server: server, session: entry, windows: [window("w1"), window("w2")],
                                      collapsed: false, topGap: 6, dim: false, theme: theme, actions: actions))
        #expect(session != SessionRow(server: server, session: SessionEntry(id: "s1", label: "renamed"),
                                      windows: [window("w1")], collapsed: false, topGap: 6, dim: false, theme: theme,
                                      actions: actions))

        let machine = MachineRow(server: server, sessionCount: 1, windows: [window("w1")], collapsed: false, topGap: 4,
                                 theme: theme, actions: actions)
        #expect(machine == MachineRow(server: server, sessionCount: 1, windows: [window("w1")], collapsed: false,
                                      topGap: 4, theme: theme, actions: actions))
        #expect(machine != MachineRow(server: server, sessionCount: 2, windows: [window("w1")], collapsed: false,
                                      topGap: 4, theme: theme, actions: actions))
        #expect(machine != MachineRow(server: server, sessionCount: 1, windows: [window("w1")], collapsed: true,
                                      topGap: 4, theme: theme, actions: actions))
    }

    @Test func pruneKeyListsOnlyConnectedSyncedSessions() {
        let (_, server) = fixture()
        server.sessions = [SessionEntry(id: "s1", label: "")]
        // Not connected yet: its sessions don't count as the truth.
        #expect(SessionsList.PruneKey([server]).live == [[]])
        server.phase = .online
        server.synced = true
        #expect(SessionsList.PruneKey([server]).live == [["s1"]])
        #expect(SessionsList.PruneKey([server]).ids == [server.id])
    }

    @Test func toggleFoldFoldsThenOpensAndSaves() {
        let (prefs, _) = fixture()
        toggleFold("s:A:s1", prefs)
        #expect(prefs.sidebarCollapsed == ["s:A:s1"])
        toggleFold("s:A:s1", prefs)
        #expect(prefs.sidebarCollapsed.isEmpty)
    }

    @Test func sidebarModeIsSaved() {
        let name = "RexDuoTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        defer { d.removePersistentDomain(forName: name) }
        let p = Prefs(defaults: d)
        #expect(p.sidebarMode == .sessions)
        p.sidebarMode = .agents
        #expect(Prefs(defaults: d).sidebarMode == .agents)
    }
}

struct SidebarFoldPolicyTests {
    private let mac = UUID()

    private func open(_ tabs: Int) -> [SidebarOutline.Row] {
        SidebarOutline.rows([.init(id: mac, sessions: [.init(id: "s1", windowIDs: (0..<tabs).map { "w\($0)" })])],
                            collapsed: [])
    }

    @Test func rowsKnowTheirPlaceAmongSiblings() {
        let rows = open(3)
        #expect(rows.map(\.index) == [0, 0, 0, 1, 2])
    }

    @Test func steppedAddsTheFirstNewRowsAndKeepsTheShownOnes() {
        let all = open(5)
        let shown: Set = [all[0].id, all[1].id]
        let step = SidebarOutline.stepped(all, shown: shown, adding: 2)
        #expect(step.map(\.id) == all.prefix(4).map(\.id))
        #expect(SidebarOutline.stepped(all, shown: shown, adding: 0).map(\.id) == [all[0].id, all[1].id])
    }

    /// Opening 50 tabs adds `rowsPerStep` rows a frame, then the rest at once after `maxSteps`.
    @MainActor @Test func revealStepsABigOpenAndCapsIt() {
        let reveal = SidebarReveal()
        let key = SidebarCollapse.session(mac, "s1")
        let folded = SidebarOutline.rows([.init(id: mac, sessions: [.init(id: "s1", windowIDs: (0..<50).map { "w\($0)" })])],
                                         collapsed: [key])
        #expect(reveal.rows(folded, collapsed: [key]).count == 2)
        let all = open(50)
        var counts: [Int] = []
        for _ in 0..<(SidebarMotion.maxSteps + 1) {
            counts.append(reveal.rows(all, collapsed: []).count)
        }
        let step = SidebarMotion.rowsPerStep
        let expected: [Int] = [2 + step, 2 + 2 * step, 2 + 3 * step]
        #expect(Array(counts.prefix(3)) == expected)
        #expect(counts.last == all.count)
        // A change that isn't a fold (a server loading, a new tab) shows at once.
        #expect(reveal.rows(open(60), collapsed: []).count == 62)
    }

    @Test func swipeRestsWhereTheFingerLeavesIt() {
        // Two trailing actions (144 pt), one leading (72 pt), a 300 pt row.
        func rest(_ x: CGFloat, _ v: CGFloat = 0, full: Bool = true) -> SwipeSnap.Rest {
            SwipeSnap.rest(offset: x, velocity: v, leading: 72, trailing: 144, width: 300, fullLeading: full)
        }
        #expect(rest(-80) == .trailing)
        #expect(rest(-60) == .closed)
        #expect(rest(-30, -900) == .trailing)
        #expect(rest(-130, 900) == .closed)
        #expect(rest(50) == .leading)
        #expect(rest(200) == .fullLeading)
        #expect(rest(200, full: false) == .leading)
        #expect(SwipeSnap.rest(offset: 40, velocity: 0, leading: 0, trailing: 144, width: 300, fullLeading: false) == .closed)
    }

    @Test func swipeResistsPastItsActions() {
        #expect(SwipeSnap.dragged(-100, leading: 72, trailing: 144, fullLeading: false) == -100)
        #expect(SwipeSnap.dragged(-184, leading: 72, trailing: 144, fullLeading: false) == -154)
        #expect(SwipeSnap.dragged(200, leading: 72, trailing: 144, fullLeading: true) == 200)
        #expect(SwipeSnap.dragged(40, leading: 0, trailing: 144, fullLeading: false) == 0)
    }

    @Test func revealingOpensTheSelectedTabsSessionAndMachine() {
        let server = UUID(), other = UUID()
        let keys: Set = [SidebarCollapse.machine(server), SidebarCollapse.session(server, "s1"),
                         SidebarCollapse.session(server, "s2"), SidebarCollapse.machine(other)]
        let open = SidebarCollapse.revealing(keys, Selection(serverID: server, sessionID: "s1", windowID: "w1"))
        #expect(open == [SidebarCollapse.session(server, "s2"), SidebarCollapse.machine(other)])
    }

    @Test func toggledFlipsOneKey() {
        #expect(SidebarCollapse.toggled([], "m:A") == ["m:A"])
        #expect(SidebarCollapse.toggled(["m:A", "m:B"], "m:A") == ["m:B"])
    }

    @Test func twoServersWithTheSameSessionIDStayApart() {
        let a = UUID(), b = UUID()
        let machines = [SidebarOutline.Machine(id: a, sessions: [.init(id: "s1", windowIDs: ["w1"])]),
                        SidebarOutline.Machine(id: b, sessions: [.init(id: "s1", windowIDs: ["w1"])])]
        let rows = SidebarOutline.rows(machines, collapsed: [SidebarCollapse.session(a, "s1")])
        #expect(Set(rows.map(\.id)).count == rows.count)
        // Folding a's s1 leaves b's s1 open.
        #expect(rows.map(\.kind) == [.machine(a), .session(a, "s1"), .machine(b), .session(b, "s1"),
                                     .tab(b, session: "s1", window: "w1")])
    }

    @Test func aConnectedMachineWithoutSessionsSaysSo() {
        let a = UUID()
        let rows = SidebarOutline.rows([SidebarOutline.Machine(id: a, sessions: [], empty: true)], collapsed: [])
        #expect(rows.map(\.kind) == [.machine(a), .empty(a)])
        #expect(SidebarOutline.rows([SidebarOutline.Machine(id: a, sessions: [], empty: true)],
                                    collapsed: [SidebarCollapse.machine(a)]).map(\.kind) == [.machine(a)])
        #expect(SidebarOutline.rows([SidebarOutline.Machine(id: a, sessions: [])], collapsed: []).map(\.kind) == [.machine(a)])
    }
}

struct AgentRowOrderTests {
    private func row(_ id: String, _ state: String?) -> ServerConnection.AgentRow {
        ServerConnection.AgentRow(sessionID: "s", windowID: "w", blockID: id, kind: .claude,
                                  status: state.map { ProgramStatus(["state": $0]) }, title: "", place: "")
    }

    @Test func realRowsSortWaitingFirstAndWaitingWithoutATimeLast() {
        let now = Date()
        let rows = [row("idle", "idle"), row("new", "blocked"), row("work", "working"), row("old", "blocked"),
                    row("none", nil), row("err", "error")]
        let sorted = AgentOrder.sorted(rows, state: { $0.status?.state }, id: \.blockID, since: ["old": now])
        // "new" is waiting but hasn't been seen waiting yet: after the one that has.
        #expect(sorted.map(\.blockID) == ["old", "new", "err", "work", "idle", "none"])
    }
}

/// An agent's tile is a circle (half the 18 pt tile), a shell's a rounded square.
@MainActor
struct SidebarTileShapeTests {
    @Test func agentsGetACircleAndShellsASquare() {
        for kind in [AgentKind.claude, .codex, .gemini] {
            #expect(TabRowLabel.tile(kind).cornerSize == CGSize(width: 9, height: 9))
        }
        #expect(TabRowLabel.tile(nil).cornerSize == CGSize(width: 5, height: 5))
    }
}
