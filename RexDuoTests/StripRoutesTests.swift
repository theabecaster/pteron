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

        r.model.prefs.navigation = .tabs
        r.routes.run(.useSidebar)
        #expect(r.model.prefs.navigation == .sidebar)
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
                                              .closeSession(id, session: "s", name: "s"), .goTo, .agents, .settings]
        let atOnce: [SessionPopover.Action] = [.open(sel), .newSession(id), .reconnect(id), .useSidebar]
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

    /// Tab mode changes the bar's first item and nothing else: Sessions for the sidebar toggle,
    /// in every state of the bar, so it holds as many items either way.
    @Test func theVerticalBarTradesTheSidebarToggleForSessions() {
        for zoomed in [false, true] {
            for typing in [false, true] {
                let sidebar = TabActions.verticalBar(.sidebar, zoomed: zoomed, hidesKeyboard: typing)
                let tabs = TabActions.verticalBar(.tabs, zoomed: zoomed, hidesKeyboard: typing)
                #expect(sidebar.first == .sidebar && tabs.first == .sessions)
                #expect(Array(sidebar.dropFirst()) == Array(tabs.dropFirst()))
                #expect(Array(sidebar.dropFirst()) == TabActions.verticalBar(zoomed: zoomed, hidesKeyboard: typing))
            }
        }
        // With the keyboard up the bar has room for three.
        #expect(TabActions.verticalBar(.tabs, zoomed: false, hidesKeyboard: true) == [.sessions, .hideKeyboard, .paneActions])
        #expect(TabActions.verticalBar(.tabs, zoomed: false, hidesKeyboard: false) == [.sessions, .allTabs, .paneActions])
        #expect(TabActions.verticalBar(.sidebar, zoomed: false, hidesKeyboard: false) == [.sidebar, .allTabs, .paneActions])
        #expect(TabAction.sessions.title == "Sessions" && TabAction.sidebar.symbol == "sidebar.left")
    }

    /// The palette lists Toggle Sidebar only where there is a sidebar.
    @Test func thePaletteHasNoToggleSidebarInTabMode() throws {
        let r = try rig()
        func titles(_ navigation: NavigationStyle) -> [String] {
            var copy = GoToSource.Copy()
            GoToCommands.add(r.model.servers, target: nil, waitingCount: 0, navigation: navigation, into: &copy)
            return copy.items.map(\.title)
        }
        #expect(titles(.sidebar).contains("Toggle Sidebar"))
        #expect(!titles(.tabs).contains("Toggle Sidebar"))
        #expect(titles(.tabs).count == titles(.sidebar).count - 1)
    }
}
