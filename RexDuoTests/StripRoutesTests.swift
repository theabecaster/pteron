import Foundation
import RexKit
import Testing
@testable import RexDuo

/// What tab mode's strip runs (`StripRoutes`): each row of the session popover and each action
/// of a chip's menu ends where the sidebar's own does, and the sidebar's state is never part of it.
@MainActor
@Suite struct StripRoutesTests {
    private final class Opened {
        var selections: [Selection] = []
    }

    @MainActor
    private struct Rig {
        let model: AppModel
        let server: ServerConnection
        let dialogs = SidebarActions()
        let opened = Opened()
        var routes: StripRoutes { StripRoutes(model: model, dialogs: dialogs, open: { [opened] in opened.selections.append($0) }) }
    }

    /// One server, session "work" with tabs api, web (an agent) and logs, and session "play".
    private func rig(revision: Int = 0) throws -> Rig {
        let suite = "strip-routes-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let model = AppModel(prefs: Prefs(defaults: defaults), connect: false)
        let s = ServerConnection(config: ServerConfig(name: "desk", url: "https://desk-rex.tail1234.ts.net"),
                                 prefs: model.prefs, notifier: model.notifier, deviceID: "a1b2c3d4")
        model.servers.append(s)
        func window(_ id: String) -> JSONObject {
            ["window_id": id, "label": id, "layers": [["kind": "tiled", "blocks": [
                ["block_id": "b-\(id)", "creator_name": "com.superlogical.terminal"] as JSONObject,
            ]] as JSONObject]]
        }
        s.sessions = [SessionEntry(id: "work", label: "work"), SessionEntry(id: "play", label: "")]
        s.views = [
            "work": SessionView(["revision": 1, "session_id": "work", "label": "work", "active_window_id": "api",
                                 "windows": ["api", "web", "logs"].map(window)]),
            "play": SessionView(["revision": 1, "session_id": "play", "label": "", "active_window_id": "game",
                                 "windows": [window("game")]]),
        ]
        var agent = BlockMeta()
        agent.statuses = ["claude": ProgramStatus(["id": "claude", "app": "claude", "state": "working"])]
        s.meta["b-web"] = agent
        s.phase = .online
        s.synced = true
        s.agentsWereRead()
        if revision > 0 { s.capabilities.connected(serial: 1, revision: revision, serverRevision: revision, features: []) }
        model.selection = Selection(serverID: s.id, sessionID: "work", windowID: "api")
        return Rig(model: model, server: s)
    }

    // MARK: The session popover

    @Test func aSessionRowShowsItsTab() throws {
        let r = try rig()
        let play = Selection(serverID: r.server.id, sessionID: "play", windowID: "game")
        r.routes.run(.open(play))
        #expect(r.opened.selections == [play])
        // The tab on screen is on screen already.
        r.routes.run(.open(try #require(r.model.selection)))
        #expect(r.opened.selections == [play])
    }

    @Test func theFooterLeadsWhereTheSidebarDid() throws {
        let r = try rig()
        r.routes.run(.settings)
        #expect(r.model.showSettings)
        r.model.showSettings = false

        r.routes.run(.agents)
        #expect(r.model.agentsShown)
        r.model.agentsShown = false

        r.routes.run(.goTo)
        #expect(r.model.lastCommand?.command == .goTo(.anything))
        r.routes.changeSession()
        #expect(r.model.lastCommand?.command == .goTo(.sessions))
    }

    /// Rename Session… and Close Session… put up the sidebar's own alert and confirmation, and
    /// change nothing before the answer.
    @Test func renameAndCloseSessionAskAsTheSidebarDoes() throws {
        let r = try rig()
        r.routes.run(.renameSession(r.server.id, session: "work", name: "work"))
        #expect(r.dialogs.renaming?.sessionID == "work" && r.dialogs.renaming?.windowID == nil)
        #expect(r.dialogs.renameText == "work")
        r.dialogs.renaming = nil

        // A session without a name: the popover calls it "session", the alert starts empty.
        r.routes.run(.renameSession(r.server.id, session: "play", name: "session"))
        #expect(r.dialogs.renaming?.sessionID == "play" && r.dialogs.renameText.isEmpty)
        // Answered: one question at a time.
        r.dialogs.renaming = nil

        r.routes.run(.closeSession(r.server.id, session: "work", name: "work"))
        #expect(r.dialogs.closing?.sessionID == "work" && r.dialogs.closing?.label == "work")
        #expect(r.server.sessions.count == 2)
    }

    @Test func addOpensPairingForThatComputer() throws {
        let r = try rig()
        // No address is known for it: the scanner.
        r.routes.run(.add(KnownHost(id: "h1", label: "attic", candidate: nil)))
        #expect(r.model.showPairing)
    }

    /// The actions that put a sheet, an alert or the palette on screen wait for the popover.
    @Test func whatPresentsWaitsForThePopoverToClose() {
        let id = UUID(), sel = Selection(serverID: id, sessionID: "s", windowID: "w")
        let host = KnownHost(id: "h", label: "h", candidate: nil)
        let waits: [SessionPopover.Action] = [.add(host), .renameSession(id, session: "s", name: "s"),
                                              .closeSession(id, session: "s", name: "s"), .goTo, .agents, .settings,
                                              .ports(id)]
        let atOnce: [SessionPopover.Action] = [.open(sel), .newSession(id), .reconnect(id)]
        #expect(waits.allSatisfy { $0.presents })
        #expect(!atOnce.contains { $0.presents })
    }

    // MARK: A chip's menu

    @Test func renameTabStartsFromTheTabsOwnName() throws {
        let r = try rig()
        r.routes.run(.rename, tab: "logs", session: "work", server: r.server)
        #expect(r.dialogs.renaming?.windowID == "logs" && r.dialogs.renaming?.sessionID == "work")
        #expect(r.dialogs.renameText == "logs")
    }

    /// The rule the sidebar's rows and the title bar have: a tab with an agent asks first.
    @Test func closingATabWithAnAgentAsks() throws {
        let r = try rig()
        r.routes.run(.close, tab: "web", session: "work", server: r.server)
        #expect(r.dialogs.closingTab?.windowID == "web")
        // Nothing closed yet.
        #expect(r.server.views["work"]?.windows.count == 3)
    }

    @Test func closingATabWithoutAnAgentDoesNotAsk() throws {
        let r = try rig()
        r.routes.run(.close, tab: "logs", session: "work", server: r.server)
        #expect(r.dialogs.closingTab == nil)
    }

    /// A tab with two panes asks before it closes, as Close Other Panes does (`CloseTabAsk`).
    @Test func closingATabWithTwoPanesAsks() throws {
        let r = try rig()
        let pane: (String) -> JSONObject = { ["block_id": $0, "creator_name": "com.superlogical.terminal"] }
        r.server.views["play"] = SessionView(["revision": 2, "session_id": "play", "label": "", "active_window_id": "game",
                                              "windows": [["window_id": "game", "label": "game", "layers": [
                                                  ["kind": "tiled", "blocks": [pane("b-g1"), pane("b-g2")]] as JSONObject,
                                              ]] as JSONObject]])
        r.routes.run(.close, tab: "game", session: "play", server: r.server)
        #expect(r.dialogs.closingTab?.windowID == "game")
        #expect(r.dialogs.closingTabAsk == CloseTabAsk(panes: 2, agent: false))
    }

    /// Close Other Tabs always asks, with exactly the other tabs and whether an agent runs there.
    @Test func closeOtherTabsAlwaysAsks() throws {
        let r = try rig()
        r.routes.run(.closeOthers, tab: "web", session: "work", server: r.server)
        #expect(r.dialogs.closingOthers?.tabs == ["api", "logs"])
        #expect(r.dialogs.closingOthers?.agent == false)
        #expect(r.dialogs.closingOthers?.target.windowID == "web")

        r.dialogs.closingOthers = nil
        r.routes.run(.closeOthers, tab: "api", session: "work", server: r.server)
        #expect(r.dialogs.closingOthers?.tabs == ["web", "logs"] && r.dialogs.closingOthers?.agent == true)

        // The only tab has no others.
        r.dialogs.closingOthers = nil
        r.routes.run(.closeOthers, tab: "game", session: "play", server: r.server)
        #expect(r.dialogs.closingOthers == nil)
    }

    /// Close Tab's question holds the tab that was tapped, by its id: the tabs reordered by
    /// the computer and another tab on screen meanwhile, the answer closes that tab and no other.
    @Test func closeTabAnswersForTheTabThatWasTapped() throws {
        let r = try rig()
        r.routes.run(.close, tab: "web", session: "work", server: r.server)
        #expect(r.dialogs.closingTab?.windowID == "web" && r.dialogs.closingTab?.sessionID == "work")

        // An event from the computer: the tabs in another order, web no longer second.
        func window(_ id: String) -> JSONObject {
            ["window_id": id, "label": id, "layers": [["kind": "tiled", "blocks": [
                ["block_id": "b-\(id)", "creator_name": "com.superlogical.terminal"] as JSONObject,
            ]] as JSONObject]]
        }
        r.server.views["work"] = SessionView(["revision": 2, "session_id": "work", "label": "work", "active_window_id": "api",
                                              "windows": ["logs", "api", "web"].map(window)])
        r.model.selection = Selection(serverID: r.server.id, sessionID: "work", windowID: "logs")
        #expect(r.server.orderedWindowIDs("work") == ["logs", "api", "web"])

        let closed = try #require(r.routes.confirmCloseTab())
        #expect(closed.windowID == "web" && closed.sessionID == "work" && closed.server === r.server)
        #expect(r.dialogs.closingTab == nil)
        // Answered once.
        #expect(r.routes.confirmCloseTab() == nil)
    }

    /// While a question is up, another tap asks nothing and closes nothing: the first question
    /// stays as it was.
    @Test func oneQuestionAtATime() throws {
        let r = try rig()
        r.routes.run(.close, tab: "web", session: "work", server: r.server)
        r.routes.run(.close, tab: "api", session: "work", server: r.server)
        r.routes.run(.closeOthers, tab: "api", session: "work", server: r.server)
        r.routes.run(.rename, tab: "logs", session: "work", server: r.server)
        r.routes.run(.closeSession(r.server.id, session: "play", name: "session"))
        r.routes.run(.renameSession(r.server.id, session: "play", name: "session"))
        #expect(r.dialogs.closingTab?.windowID == "web")
        #expect(r.dialogs.closingOthers == nil && r.dialogs.renaming == nil && r.dialogs.closing == nil)

        // Answered, the next tap asks again.
        r.dialogs.closingTab = nil
        r.routes.run(.closeOthers, tab: "api", session: "work", server: r.server)
        #expect(r.dialogs.closingOthers?.target.windowID == "api")
    }

    /// The chips' questions show at the asked tab's close button, the end of its chip a hit
    /// target wide, where the chip has one; at its chip where it hasn't.
    @Test func theQuestionShowsByTheTappedControl() {
        let frames = ["a": CGRect(x: 0, y: 0, width: 100, height: 44), "b": CGRect(x: 106, y: 0, width: 160, height: 44)]
        #expect(ChipsAnchor.anchor(for: "b", frames: frames, active: "b", showsClose: true)
            == CGRect(x: 266 - StripLayout.hit, y: 0, width: StripLayout.hit, height: 44))
        // No close button: the chip.
        #expect(ChipsAnchor.anchor(for: "b", frames: frames, active: "b", showsClose: false) == frames["b"])
        // Another tab's chip, from its menu.
        #expect(ChipsAnchor.anchor(for: "a", frames: frames, active: "b", showsClose: true) == frames["a"])
        // A chip never laid out: the tab on screen's.
        #expect(ChipsAnchor.anchor(for: "z", frames: frames, active: "a", showsClose: true) == frames["a"])
    }

    /// Move Left and Move Right take the sidebar drag's path: the new order shows at once and is
    /// held for the server (`PendingOrder`).
    @Test func movingATabShowsItsNewPlaceAtOnce() throws {
        let r = try rig(revision: PaneSupport.minimumRevision)
        r.routes.run(.moveRight, tab: "api", session: "work", server: r.server)
        #expect(r.server.orderedWindowIDs("work") == ["web", "api", "logs"])
        r.routes.run(.moveLeft, tab: "logs", session: "work", server: r.server)
        #expect(r.server.orderedWindowIDs("work") == ["web", "logs", "api"])
        // Nowhere to go: nothing moves.
        r.routes.run(.moveLeft, tab: "web", session: "work", server: r.server)
        #expect(r.server.orderedWindowIDs("work") == ["web", "logs", "api"])
    }

    /// A server without `session.move_window` moves nothing, and its chips offer no Move rows.
    @Test func aServerThatCantMoveTabsMovesNothing() throws {
        let r = try rig(revision: 0)
        r.routes.run(.moveRight, tab: "api", session: "work", server: r.server)
        #expect(r.server.orderedWindowIDs("work") == ["api", "web", "logs"])
        #expect(r.server.pendingOrder.tabs.isEmpty)
    }

    /// A tab that closed between the long press and the tap: nothing runs.
    @Test func aTabThatIsGoneRunsNothing() throws {
        let r = try rig()
        for action in TabChip.Action.allCases {
            r.routes.run(action, tab: "gone", session: "work", server: r.server)
        }
        #expect(r.dialogs.renaming == nil && r.dialogs.closingTab == nil && r.dialogs.closingOthers == nil)
    }

    // MARK: Sidebar state

    /// Tab mode writes nothing to the sidebar's state: a tab shown, the edge swipe, the toggle
    /// and cmd+. leave it, and it is exactly as it was when the sidebar is back.
    @Test func tabModeLeavesTheSidebarAsItWas() {
        for start in [SidebarState(open: true, mode: .sessions), SidebarState(open: false, mode: .agents),
                      SidebarState(open: true, mode: .agents), SidebarState(open: false, mode: .sessions)] {
            var sidebar = start
            sidebar.write(in: .tabs) { $0.toggle() }
            sidebar.write(in: .tabs) { $0.reveal() }
            sidebar.write(in: .tabs) { $0.tabShown(inline: false) }
            sidebar.write(in: .tabs) { $0.toggleAgents() }
            sidebar.write(in: .tabs) { _ = $0.perform(.toggleSidebar) }
            sidebar.write(in: .tabs) { $0 = SidebarState(open: !start.open, mode: .agents) }
            #expect(sidebar == start)
            // Back in sidebar mode it is written as ever.
            sidebar.write(in: .sidebar) { $0.toggle() }
            #expect(sidebar.open == !start.open && sidebar.mode == start.mode)
        }
    }

    // MARK: The vertical bar and the palette

    /// Tab mode drops the sidebar toggle and puts nothing in its place: the strip's session chip
    /// opens the sessions. Keyboard down, the rest is sidebar mode's; typing, the toggle's room
    /// keeps All Tabs below Hide Keyboard where three fit.
    @Test func theVerticalBarDropsTheSidebarToggleInTabMode() {
        for zoomed in [false, true] {
            for typing in [false, true] {
                let sidebar = TabActions.verticalBar(.sidebar, zoomed: zoomed, hidesKeyboard: typing)
                let tabs = TabActions.verticalBar(.tabs, zoomed: zoomed, hidesKeyboard: typing)
                let lead = typing ? 1 : 0
                #expect(sidebar[lead] == .sidebar && !tabs.contains(.sidebar))
                #expect(tabs.count <= sidebar.count, "never more than sidebar mode's bar")
                if !typing { #expect(Array(sidebar.dropFirst()) == tabs) }
            }
        }
        // With the keyboard up the bar has room for three, Hide Keyboard on top.
        #expect(TabActions.verticalBar(.tabs, zoomed: false, hidesKeyboard: true) == [.hideKeyboard, .allTabs, .paneActions])
        #expect(TabActions.verticalBar(.tabs, zoomed: false, hidesKeyboard: false) == [.allTabs, .paneActions])
        #expect(TabActions.verticalBar(.sidebar, zoomed: false, hidesKeyboard: false) == [.sidebar, .allTabs, .paneActions])
        #expect(TabAction.sidebar.symbol == "sidebar.left")
    }

    /// The palette lists Toggle Sidebar only where there is a sidebar.
    @Test func thePaletteHasNoToggleSidebarInTabMode() throws {
        let r = try rig()
        func titles(_ navigation: NavigationStyle) -> [String] {
            var copy = GoToSource.Copy()
            GoToCommands.add(r.model.servers, target: nil, waitingCount: 0, navigation: navigation, into: &copy)
            return copy.items.map(\.title)
        }
        #expect(titles(.sidebar).contains("Show/Hide Sidebar"))
        #expect(!titles(.tabs).contains("Show/Hide Sidebar"))
        #expect(titles(.tabs).count == titles(.sidebar).count - 1)
    }
}
