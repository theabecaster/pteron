import Foundation
import RexKit
import Testing
@testable import RexDuo

/// What a tab chip and the session chip show (`TabChip`, `SessionChip`).
struct TabChipTests {
    private let roomy = StripLayout(.init(width: 402))
    private let tight = StripLayout(.init(width: 300, panes: 3, waiting: 1))

    private func chip(active: Bool = false, position: Int = 2, count: Int = 5, panes: [AgentKind?] = [nil],
                      status: String? = nil, progress: [TermProgress] = [], waking: Bool = false,
                      movable: Bool = true, strip: StripLayout? = nil) -> TabChip {
        TabChip(id: "w\(position)", title: "build", active: active, position: position, count: count, panes: panes,
                status: status, progress: progress, waking: waking, movable: movable, strip: strip)
    }

    /// The active chip is the title bar in small: the shown pane's status and nothing of the
    /// other panes' progress. Any other chip is its sidebar row: a ring where no agent status
    /// outranks it.
    @Test func theBadgeIsThePanesOnTheActiveChipAndTheTabsOnTheOthers() {
        let bar = TermProgress(state: .set, percent: 40)
        #expect(chip(active: true, status: "working", progress: [bar]).badge == .status("working"))
        #expect(chip(active: true, status: nil, progress: [bar]).badge == .status(nil))
        #expect(chip(active: true, status: "done", progress: [bar]).badge == .status("done"))

        #expect(chip(status: nil, progress: [bar]).badge == .ring(bar))
        #expect(chip(status: "done", progress: [bar]).badge == .ring(bar))
        for state in ["blocked", "error", "working"] {
            #expect(chip(status: state, progress: [bar]).badge == .status(state))
        }
        #expect(chip(status: "blocked").badge == .status("blocked"))
        #expect(chip().badge == .status(nil))
    }

    /// Up to three pane icons, in the tab's order, agents and shells told apart; the rest is a count.
    @Test func atMostThreePaneIcons() {
        #expect(chip(panes: []).icons.isEmpty)
        #expect(chip(panes: [.claude]).icons == [.init(agent: .claude)])
        let many = chip(panes: [nil, .claude, .codex, .gemini, nil])
        #expect(many.icons == [.init(agent: nil), .init(agent: .claude), .init(agent: .codex)])
        #expect(many.morePanes == 2)
        #expect(chip(panes: [nil, nil, nil]).morePanes == 0)
        #expect(TabChip.iconLimit == 3)
    }

    /// The close button is on the active chip only, and only where the strip has room for it.
    @Test func onlyTheActiveChipClosesAndOnlyWithRoom() {
        #expect(roomy.showsClose && !tight.showsClose)
        #expect(chip(active: true, strip: roomy).showsClose)
        #expect(!chip(active: false, strip: roomy).showsClose)
        #expect(!chip(active: true, strip: tight).showsClose)
        #expect(!chip(active: true, strip: nil).showsClose)
    }

    /// The waking mark rides the active chip, as it rides the title.
    @Test func onlyTheActiveChipShowsTheWakingMark() {
        #expect(chip(active: true, waking: true).waking)
        #expect(!chip(active: false, waking: true).waking)
        #expect(!chip(active: true, waking: false).waking)
    }

    @Test func theMenuFitsTheTabsPlace() {
        #expect(chip(position: 2, count: 5).menu == [.rename, .moveLeft, .moveRight, .close, .closeOthers])
        #expect(chip(position: 1, count: 5).menu == [.rename, .moveRight, .close, .closeOthers])
        #expect(chip(position: 5, count: 5).menu == [.rename, .moveLeft, .close, .closeOthers])
        // A server without `session.move_window`: no Move rows, and no drag.
        let fixed = chip(position: 2, count: 5, movable: false)
        #expect(fixed.menu == [.rename, .close, .closeOthers] && !fixed.movable)
        // The only tab has nothing to move past and no others to close.
        let only = chip(position: 1, count: 1)
        #expect(only.menu == [.rename, .close] && !only.movable)
        #expect(TabChip.Action.allCases.filter(\.destructive) == [.close, .closeOthers])
        #expect(TabChip.Action.rename.title == TabAction.rename.title)
    }

    @Test func voiceOverReadsTitlePlaceAndStatus() {
        #expect(chip().spoken == "build, tab 2 of 5")
        #expect(chip(status: "working").spoken == "build, tab 2 of 5, Working")
        #expect(chip(status: "blocked").spoken == "build, tab 2 of 5, Waiting for you")
        #expect(chip(active: true, status: "done").spoken == "build, tab 2 of 5, Done")
        #expect(chip(progress: [TermProgress(state: .set, percent: 40)]).spoken == "build, tab 2 of 5, Working, 40 percent")
    }

    @Test func theSessionChipNamesItsSessionAndItsMachineAmongSeveral() {
        let one = SessionChip(name: "work", machine: nil, waiting: 0)
        #expect(one.spoken == "Session work")
        let two = SessionChip(name: "work", machine: "studio", waiting: 1)
        #expect(two.spoken == "Session work, studio, 1 agent waiting")
        #expect(SessionChip(name: "work", machine: nil, waiting: 3).spoken == "Session work, 3 agents waiting")
        // A session without a name reads as the title bar says it.
        #expect(SessionChip(name: "", machine: nil, waiting: 0).name == "session")
        #expect(SessionChip.none().spoken == "Sessions")
        #expect(SessionChip.none(form: .glyph).form == .glyph && one.form == .name)
    }
}

/// The chips and the popover built from servers as the app holds them.
@MainActor
@Suite struct TabStripSourceTests {
    private func model() throws -> AppModel {
        let suite = "tab-strip-\(UUID().uuidString)"
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

    /// Sessions of tabs of panes; a pane's id is `<server>-<tab>-<n>`, and `agents` gives a pane
    /// an agent in that state.
    private func load(_ s: ServerConnection, _ sessions: [(String, [(String, Int)])], agents: [String: String] = [:]) {
        var views: [String: SessionView] = [:]
        for (sid, tabs) in sessions {
            let windows = tabs.map { wid, panes -> JSONObject in
                ["window_id": wid, "label": wid, "layers": [["kind": "tiled", "blocks": (0..<panes).map { n in
                    ["block_id": "\(s.config.name)-\(wid)-\(n)", "creator_name": "com.superlogical.terminal"] as JSONObject
                }] as JSONObject]]
            }
            views[sid] = SessionView(["revision": 1, "session_id": sid, "label": sid,
                                      "active_window_id": tabs.last?.0 ?? "", "windows": windows])
        }
        for (block, state) in agents {
            var m = BlockMeta()
            m.statuses = ["claude": ProgramStatus(["id": "claude", "app": "claude", "state": state])]
            s.meta[block] = m
        }
        s.sessions = sessions.map { SessionEntry(id: $0.0, label: $0.0) }
        s.views = views
        s.phase = .online
        s.synced = true
        s.agentsWereRead()
    }

    @Test func aChipIsBuiltFromItsTab() throws {
        let m = try model()
        let s = server(m, "desk")
        load(s, [("work", [("api", 1), ("web", 4), ("logs", 1)])],
             agents: ["desk-web-1": "blocked", "desk-web-2": "working", "desk-api-0": "working"])
        let view = try #require(s.views["work"])
        let strip = StripLayout(.init(width: 402))

        // The tab on screen: the pane on screen decides its glyph, not the tab's top status.
        let web = TabChip.of(view.windows[1], position: 2, count: 3, server: s, active: true, block: "desk-web-2", strip: strip)
        #expect(web.id == "web" && web.title == "web" && web.active)
        #expect(web.position == 2 && web.count == 3)
        #expect(web.icons == [.init(agent: nil), .init(agent: .claude), .init(agent: .claude)] && web.morePanes == 1)
        #expect(web.badge == .status("working"))
        #expect(web.showsClose)

        // Any other tab: its top status, and no close button.
        let hidden = TabChip.of(view.windows[1], position: 2, count: 3, server: s, active: false, block: nil, strip: strip)
        #expect(hidden.badge == .status("blocked") && !hidden.showsClose)
        let api = TabChip.of(view.windows[0], position: 1, count: 3, server: s, active: false, block: nil, strip: strip)
        #expect(api.position == 1 && api.badge == .status("working") && api.icons == [.init(agent: .claude)])
        let logs = TabChip.of(view.windows[2], position: 3, count: 3, server: s, active: false, block: nil, strip: strip)
        #expect(logs.badge == .status(nil) && logs.spoken == "logs, tab 3 of 3")
        // No revision is known for this server, so nothing says it can move a tab.
        #expect(!web.movable && web.menu == [.rename, .close, .closeOthers])
    }

    @Test func theSessionChipCountsItsSessionsWaitingAgents() throws {
        let m = try model()
        let s = server(m, "desk")
        load(s, [("work", [("api", 2)]), ("play", [("game", 1)])],
             agents: ["desk-api-0": "blocked", "desk-api-1": "blocked", "desk-game-0": "blocked"])
        #expect(SessionChip.of("work", server: s, servers: 1) == SessionChip(name: "work", machine: nil, waiting: 2))
        #expect(SessionChip.of("play", server: s, servers: 2) == SessionChip(name: "play", machine: "desk", waiting: 1))
    }

    @Test func thePopoverListsTheServersAsTheSidebarDoes() throws {
        let m = try model()
        let desk = server(m, "desk"), cloud = server(m, "cloud"), attic = server(m, "attic")
        load(desk, [("work", [("api", 1), ("web", 1)]), ("play", [("game", 1)])], agents: ["desk-game-0": "blocked"])
        load(cloud, [])
        load(attic, [("old", [("job", 1)])])
        attic.phase = .offline(ConnectionProblem(kind: .notAnswering, detail: "test"))
        m.selection = Selection(serverID: desk.id, sessionID: "work", windowID: "api")

        let p = SessionPopover(m)
        #expect(p.rows.map(\.id) == [
            "m:\(desk.id.uuidString)", "s:\(desk.id.uuidString):work", "s:\(desk.id.uuidString):play",
            "m:\(cloud.id.uuidString)", "e:\(cloud.id.uuidString)",
            "m:\(attic.id.uuidString)", "s:\(attic.id.uuidString):old",
            "f:Go to Anything…", "f:Agents", "f:Settings",
        ])
        guard case .session(let work) = p.rows[1], case .session(let play) = p.rows[2],
              case .machine(let down) = p.rows[5], case .session(let old) = p.rows[6],
              case .footer(let agents) = p.rows[8] else {
            Issue.record("rows are not what their ids say")
            return
        }
        // A session's row opens the tab the session has in front.
        #expect(work.current && work.open == .open(Selection(serverID: desk.id, sessionID: "work", windowID: "web")))
        #expect(!play.current && play.waiting == 1)
        // Any session that isn't down renames and closes from its row, as in the sidebar.
        #expect(play.menu == [.renameSession(desk.id, session: "play", name: "play"), .closeSession(desk.id, session: "play", name: "play")])
        #expect(down.status == .down("Not answering") && down.reconnect == .reconnect(attic.id) && down.newSession == nil)
        #expect(old.dim)
        // Its tap moves to a computer that is down: that one is asked to try again.
        #expect(old.retries && !work.retries && !play.retries)
        #expect(agents.count == 1)
    }
}

/// The session chip's popover as rows (`SessionPopover`).
struct SessionPopoverTests {
    private let desk = UUID(), cloud = UUID()

    private func machine(_ id: UUID, _ name: String, status: SessionPopover.Status = .connected,
                         synced: Bool = true, ports: Int = 0, _ sessions: [SessionPopover.Source.Session]) -> SessionPopover.Source {
        SessionPopover.Source(id: id, name: name, platform: "darwin_arm64", status: status, synced: synced, sessions: sessions,
                              ports: ports)
    }

    private func session(_ id: String, tab: String? = "w1", waiting: Int = 0) -> SessionPopover.Source.Session {
        .init(id: id, name: id, tab: tab, waiting: waiting)
    }

    private func sessions(_ p: SessionPopover) -> [SessionPopover.Session] {
        p.rows.compactMap { row -> SessionPopover.Session? in
            if case .session(let s) = row { return s }
            return nil
        }
    }

    private func machines(_ p: SessionPopover) -> [SessionPopover.Machine] {
        p.rows.compactMap { row -> SessionPopover.Machine? in
            if case .machine(let m) = row { return m }
            return nil
        }
    }

    /// One list for one scroll view: each machine with its sessions, the computers that aren't
    /// added, then the footer.
    @Test func theRowsAreOneListInTheSidebarsOrder() {
        let host = KnownHost(id: "h1", label: "attic", candidate: nil)
        let p = SessionPopover(machines: [machine(desk, "desk", [session("work"), session("play")]),
                                          machine(cloud, "cloud", [session("deploy")])],
                               hosts: [host], current: nil)
        #expect(p.rows.map(\.id) == [
            "m:\(desk.uuidString)", "s:\(desk.uuidString):work", "s:\(desk.uuidString):play",
            "m:\(cloud.uuidString)", "s:\(cloud.uuidString):deploy",
            "not-added", "h:h1",
            "f:Go to Anything…", "f:Agents", "f:Settings",
        ])
        #expect(Set(p.rows.map(\.id)).count == p.rows.count)
        #expect(p.rows[6].action == .add(host))
        // Headings take no tap.
        #expect(p.rows[0].action == nil && p.rows[5].action == nil)
    }

    #if DEBUG
    /// `-stripRow <name>` taps what a finger would: the footer's rows, the menu of the session
    /// on screen, the first computer that isn't added and the first heading's ports. A row the
    /// popover lacks is nothing.
    @Test func theTestArgumentFindsEachRow() {
        let host = KnownHost(id: "h1", label: "attic", candidate: nil)
        let p = SessionPopover(machines: [machine(desk, "desk", [session("work"), session("play")]),
                                          machine(cloud, "cloud", ports: 2, [session("deploy")])],
                               hosts: [host], current: Selection(serverID: desk, sessionID: "play", windowID: "w1"))
        func action(_ row: StripPopoverTest.Row) -> SessionPopover.Action? { StripPopoverTest.action(row, in: p) }
        #expect(action(.settings) == .settings && action(.agents) == .agents && action(.goTo) == .goTo)
        #expect(action(.renameSession) == .renameSession(desk, session: "play", name: "play"))
        #expect(action(.closeSession) == .closeSession(desk, session: "play", name: "play"))
        #expect(action(.add) == .add(host))
        #expect(action(.ports) == .ports(cloud))
        // Every row puts something on screen, so each waits for the popover.
        for row in StripPopoverTest.Row.allCases {
            #expect(action(row)?.presents == true, "\(row)")
        }

        let bare = SessionPopover(machines: [machine(desk, "desk", [])], current: nil)
        #expect(StripPopoverTest.action(.add, in: bare) == nil && StripPopoverTest.action(.ports, in: bare) == nil)
        #expect(StripPopoverTest.action(.renameSession, in: bare) == nil && StripPopoverTest.action(.settings, in: bare) == .settings)
        #expect(StripPopoverTest.Row(rawValue: "ribbon") == nil)
    }
    #endif

    /// The footer: Go to Anything, Agents and Settings. Change
    /// Session isn't a row: the popover is that list already.
    @Test func theFooterIsTheSidebarsOtherPlaces() {
        let footer = SessionPopover.footer(waiting: 2)
        #expect(footer.map(\.action) == [.goTo, .agents, .settings])
        #expect(footer.map(\.title) == ["Go to Anything…", "Agents", "Settings"])
        #expect(footer.map(\.count) == [0, 2, 0])
        #expect(footer.allSatisfy { !$0.symbol.isEmpty })
        #expect(SessionPopover(machines: [], current: nil).firstFooterID == "f:Go to Anything…")
        let p = SessionPopover(machines: [], current: nil, waiting: 2)
        #expect(p.rows == footer.map { SessionPopover.Row.footer($0) })
        #expect(!p.rows.contains { $0.id.contains("Change Session") })
    }

    /// A heading's buttons follow the connection: "+" while connected, Reconnect while down,
    /// neither while a connection is being made.
    @Test func aHeadingOffersWhatItsMachineCanDo() {
        let p = SessionPopover(machines: [
            machine(desk, "desk", status: .connected, []),
            machine(cloud, "cloud", status: .down("Not answering"), [session("deploy")]),
            machine(UUID(), "attic", status: .connecting, []),
            machine(UUID(), "shed", status: .down("Not answering", retrying: true), []),
            machine(UUID(), "lab", status: .waking, []),
        ], current: nil)
        let m = machines(p)
        #expect(m[0].newSession == .newSession(desk) && m[0].reconnect == nil)
        #expect(m[1].newSession == nil && m[1].reconnect == .reconnect(cloud))
        #expect(m[2].newSession == nil && m[2].reconnect == nil)
        // A retry the user asked for is under way: no second Reconnect.
        #expect(m[3].newSession == nil && m[3].reconnect == nil)
        // Waking is still connected.
        #expect(m[4].newSession != nil && m[4].reconnect == nil)
        #expect(m.map(\.status.spoken) == ["Connected", "Not answering", "Connecting", "Not answering", "Reconnecting"])
        #expect(m[0].platform == "darwin_arm64" && m[0].name == "desk")
    }

    /// A heading's ports button: only while its machine has a web port, kept while it is down
    /// (its last known ports), and adding no row.
    @Test func aHeadingOffersPortsOnlyWhileTheMachineHasThem() {
        let p = SessionPopover(machines: [
            machine(desk, "desk", ports: 2, [session("work")]),
            machine(cloud, "cloud", status: .down("Not answering"), ports: 1, []),
            machine(UUID(), "attic", []),
        ], current: nil)
        let m = machines(p)
        #expect(m.map(\.ports) == [.ports(desk), .ports(cloud), nil])
        #expect(m.map(\.portCount) == [2, 1, 0])
        #expect(m[1].status.isDown && !m[0].status.isDown)
        #expect(p.rows.count == SessionPopover(machines: [machine(desk, "desk", [session("work")]), machine(cloud, "cloud", status: .down("Not answering"), []),
                                                          machine(UUID(), "attic", [])], current: nil).rows.count)
        #expect(SessionPopover.title(.ports(desk)) == "Ports")
    }

    /// "No sessions" only under a machine that is connected and has told its sessions.
    @Test func noSessionsShowsOnlyWhenItIsKnown() {
        func empties(_ status: SessionPopover.Status, synced: Bool) -> Int {
            SessionPopover(machines: [machine(desk, "desk", status: status, synced: synced, [])], current: nil).rows
                .filter { if case .empty = $0 { true } else { false } }.count
        }
        #expect(empties(.connected, synced: true) == 1)
        #expect(empties(.connected, synced: false) == 0)
        #expect(empties(.connecting, synced: true) == 0)
        #expect(empties(.down("Not answering"), synced: true) == 0)
    }

    /// A session's row switches to it on tap. Every session has a menu, as in the sidebar: Rename
    /// Session… and Close Session.
    @Test func sessionRowsSwitchAndEachHasAMenu() {
        let current = Selection(serverID: desk, sessionID: "work", windowID: "w9")
        let p = SessionPopover(machines: [machine(desk, "desk", [session("work", tab: "w2", waiting: 2), session("play"),
                                                                 session("new", tab: nil)]),
                                          machine(cloud, "cloud", [session("work")])], current: current)
        let s = sessions(p)
        #expect(s.map(\.current) == [true, false, false, false])
        #expect(s[0].open == .open(Selection(serverID: desk, sessionID: "work", windowID: "w2")))
        #expect(s[1].open == .open(Selection(serverID: desk, sessionID: "play", windowID: "w1")))
        // A session whose tabs aren't in yet has nothing to open.
        #expect(s[2].open == nil)
        #expect(s[0].menu == [.renameSession(desk, session: "work", name: "work"),
                              .closeSession(desk, session: "work", name: "work")])
        #expect(s[0].menu.compactMap(SessionPopover.title) == ["Rename Session…", "Close Session"])
        #expect(s[1].menu == [.renameSession(desk, session: "play", name: "play"), .closeSession(desk, session: "play", name: "play")])
        #expect(s[2].menu.count == 2)
        // The same session id on another machine is another session, with its own menu.
        #expect(!s[3].current && s[3].menu == [.renameSession(cloud, session: "work", name: "work"),
                                               .closeSession(cloud, session: "work", name: "work")] && s[3].id != s[0].id)
        #expect(s.map(\.waiting) == [2, 0, 0, 0])
    }

    /// A down machine keeps its last known sessions, dimmed: they open read-only, and nothing
    /// renames or closes a session there.
    @Test func aDownMachinesSessionsAreDimAndHaveNoMenu() {
        let current = Selection(serverID: desk, sessionID: "work", windowID: "w1")
        let p = SessionPopover(machines: [machine(desk, "desk", status: .down("Not answering"), [session("work")])], current: current)
        let s = sessions(p)
        #expect(s[0].dim && s[0].current && s[0].menu.isEmpty)
        // The computer on screen: its rows show what is there and ask for no attempt.
        #expect(!s[0].retries)
        #expect(s[0].open == .open(current))
    }

    @Test func aSessionWithoutANameReadsAsTheTitleBarSaysIt() {
        let p = SessionPopover(machines: [machine(desk, "desk", [.init(id: "s1", name: "", tab: "w1")])],
                               current: Selection(serverID: desk, sessionID: "s1", windowID: "w1"))
        #expect(sessions(p)[0].name == "session")
        #expect(sessions(p)[0].menu.first == .renameSession(desk, session: "s1", name: "session"))
    }
}
