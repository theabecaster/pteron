import Foundation
import Testing
@testable import RexDuo

/// The sidebar's pure logic: which rows show for a fold state, how fold state is saved and pruned,
/// the Agents mode's order, the hosts listed as not added, and the mode commands.
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

struct NotAddedHostsTests {
    private func host(_ label: String) -> HostEntry {
        HostEntry(id: "host:\(label)", label: label, endpoints: ["ssh://\(label)"])
    }

    @Test func savedServersAreLeftOutByNameAddressOrTailnetName() {
        let saved = [
            NotAddedHosts.Saved(name: "This Mac", url: "https://studio-rex.tail1.ts.net", hostName: nil),
            NotAddedHosts.Saved(name: "Box", url: "https://box.tail1.ts.net", hostName: "builder-rex.tail1.ts.net"),
        ]
        let listed = [[host("studio"), host("this mac"), host("builder"), host("workdesk")], [host("Workdesk"), host("macdesk")]]
        let list = NotAddedHosts.list(listed: listed, saved: saved)
        // studio: the address's name; this mac: the saved name; builder: the tailnet name. One row per machine.
        #expect(list.map(\.label) == ["workdesk", "macdesk"])
    }

    @Test func nothingListedIsNothingToAdd() {
        #expect(NotAddedHosts.list(listed: [], saved: []).isEmpty)
        #expect(NotAddedHosts.list(listed: [[HostEntry(id: "x", label: "", endpoints: [])]], saved: []).isEmpty)
    }
}

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

    @Test func machineGlyphFollowsThePlatform() {
        #expect(MachineGlyph.symbol(platform: "darwin_arm64") == "apple.logo")
        #expect(MachineGlyph.symbol(platform: "linux_amd64") == "server.rack")
        #expect(MachineGlyph.symbol(platform: "windows_amd64") == "pc")
        #expect(MachineGlyph.symbol(platform: nil) == "desktopcomputer")
    }
}
