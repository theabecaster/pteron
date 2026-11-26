import Foundation
import RexKit
import SwiftUI
import Testing
import XCTest
@testable import Pteron

/// Which tab a launch opens (`LaunchTab`): the one viewed last, else the top tab nearest it.
struct LaunchTabTests {
    private let desk = UUID()
    private let mini = UUID()

    private func session(_ id: String, _ tabs: [String], active: String? = nil) -> CloseNext.Session {
        CloseNext.Session(id: id, windows: tabs, active: active ?? tabs.last)
    }

    private func machine(_ id: UUID, _ sessions: [CloseNext.Session], state: LaunchTab.State = .synced) -> LaunchTab.Machine {
        LaunchTab.Machine(id: id, state: state, sessions: sessions)
    }

    @Test func theTabViewedLastOpens() {
        let last = Selection(serverID: desk, sessionID: "work", windowID: "w2")
        let rule = LaunchTab(last: last, machines: [machine(desk, [session("play", ["p1"]), session("work", ["w1", "w2", "w3"])])])
        #expect(rule.pick() == .show(last))
    }

    @Test func itsTabGoneOpensTheTopTabOfItsSessionNotTheActiveOne() {
        let last = Selection(serverID: desk, sessionID: "work", windowID: "gone")
        let rule = LaunchTab(last: last, machines: [machine(desk, [session("play", ["p1"]), session("work", ["w1", "w2", "w3"], active: "w3")])])
        #expect(rule.pick() == .show(Selection(serverID: desk, sessionID: "work", windowID: "w1")))
    }

    @Test func itsSessionGoneOpensTheFirstSessionsTopTabOnThatMachine() {
        let last = Selection(serverID: mini, sessionID: "gone", windowID: "x")
        let rule = LaunchTab(last: last, machines: [
            machine(desk, [session("a", ["a1", "a2"])]),
            machine(mini, [session("empty", []), session("play", ["p1", "p2"], active: "p2"), session("work", ["w1"])]),
        ])
        #expect(rule.pick() == .show(Selection(serverID: mini, sessionID: "play", windowID: "p1")))
    }

    @Test func nothingSavedShowsWhatALaunchShowedBefore() {
        let rule = LaunchTab(last: nil, machines: [machine(desk, [session("empty", []), session("play", ["p1", "p2"], active: "p2")])])
        #expect(rule.pick() == .show(Selection(serverID: desk, sessionID: "play", windowID: "p2")))
        #expect(LaunchTab(last: nil, machines: []).pick() == .none)
        #expect(LaunchTab(last: nil, machines: [machine(desk, [session("empty", [])])]).pick() == .none)
    }

    /// No flash: a machine that answers sooner doesn't put its tab on screen first.
    @Test func itWaitsForTheMachineViewedLast() {
        let last = Selection(serverID: mini, sessionID: "work", windowID: "w1")
        var machines = [machine(desk, [session("a", ["a1"])]), machine(mini, [], state: .waiting)]
        #expect(LaunchTab(last: last, machines: machines).pick() == .wait)
        machines[1] = machine(mini, [session("work", ["w1"])])
        #expect(LaunchTab(last: last, machines: machines).pick() == .show(last))
    }

    @Test func aMachineThatIsDownOrNotAddedShowsWhatALaunchShowedBefore() {
        let last = Selection(serverID: mini, sessionID: "work", windowID: "w1")
        let first = Selection(serverID: desk, sessionID: "a", windowID: "a2")
        #expect(LaunchTab(last: last, machines: [machine(desk, [session("a", ["a1", "a2"])]), machine(mini, [], state: .down)]).pick() == .show(first))
        #expect(LaunchTab(last: last, machines: [machine(desk, [session("a", ["a1", "a2"])])]).pick() == .show(first))
    }

    /// A test launch given real servers with `-servers` opens nothing by itself: only the session
    /// `-autoOpen` names. Once a test opened a real session's tab this way and resized its pane.
    @Test func aTestLaunchWithServersButNoAutoOpenPicksNothing() {
        let servers = "computer-a=https://computer-a.tail1234.ts.net"
        #expect(!LaunchTab.picksOnItsOwn(autoOpen: nil, arguments: ["servers": servers]))
        // The binary form a Release benchmark passes counts too.
        #expect(!LaunchTab.picksOnItsOwn(autoOpen: nil, arguments: ["servers": Data([0x5b])]))
        #expect(!LaunchTab.picksOnItsOwn(autoOpen: "zz-test", arguments: ["servers": servers, "autoOpen": "zz-test"]))
        #expect(!LaunchTab.picksOnItsOwn(autoOpen: "zz-test", arguments: [:]))
        // A user's launch passes neither: the tab viewed last opens, as before.
        #expect(LaunchTab.picksOnItsOwn(autoOpen: nil, arguments: [:]))
        #expect(LaunchTab.picksOnItsOwn(autoOpen: nil, arguments: ["sidebar": "closed"]))
    }

    @Test func aMachineWithNoTabsShowsWhatALaunchShowedBefore() {
        let last = Selection(serverID: mini, sessionID: "work", windowID: "w1")
        let rule = LaunchTab(last: last, machines: [machine(desk, [session("a", ["a1", "a2"])]), machine(mini, [session("work", [])])])
        #expect(rule.pick() == .show(Selection(serverID: desk, sessionID: "a", windowID: "a2")))
    }
}

/// A cold launch's drawer (`SidebarState.launchHold`).
@MainActor
struct LaunchHoldTests {
    @Test func aHeldDrawerStartsClosedAndABesideSidebarShows() {
        let s = SidebarState(launchHold: true)
        #expect(!s.shows(inline: false))
        #expect(s.shows(inline: true))
        // The stored state, the one a wide window shows, is the launch's as always.
        #expect(s.open)
        #expect(SidebarState().shows(inline: false))
    }

    @Test func aToggleOpensTheHeldDrawer() {
        var s = SidebarState(launchHold: true)
        s.resolve(inline: false)
        #expect(!s.shows(inline: false))
        _ = s.perform(.toggleSidebar)
        #expect(s.shows(inline: false) && !s.launchHold)
    }

    @Test func anUnfoldShowsTheSidebarBesideTheTabAndEndsTheHold() {
        var s = SidebarState(launchHold: true)
        s.resolve(inline: true)
        #expect(s.shows(inline: true) && !s.launchHold)
        // Folded again: the same state carries, as it always has.
        #expect(s.shows(inline: false))
    }

    @Test func anyChangeEndsTheHold() {
        var s = SidebarState(launchHold: true)
        s.reveal()
        #expect(s.shows(inline: false) && !s.launchHold)
        var t = SidebarState(launchHold: true)
        t.resolve(inline: false)
        t.tabShown(inline: false)
        #expect(!t.shows(inline: false) && !t.launchHold)
    }

    @Test func tabModeChangesNothing() {
        var s = SidebarState(launchHold: true)
        s.write(in: .tabs) { $0.resolve(inline: false) }
        #expect(s == SidebarState(launchHold: true))
    }

    @Test func onlyALaunchWithATabToShowHoldsTheDrawer() {
        let id = UUID()
        let last = Selection(serverID: id, sessionID: "s", windowID: "w")
        #expect(AppModel.launchHasTab(last: last, servers: [UUID(), id], autoOpen: false))
        #expect(!AppModel.launchHasTab(last: last, servers: [UUID()], autoOpen: false))
        #expect(!AppModel.launchHasTab(last: nil, servers: [id], autoOpen: false))
        #expect(!AppModel.launchHasTab(last: nil, servers: [], autoOpen: false))
        #expect(AppModel.launchHasTab(last: nil, servers: [id], autoOpen: true))
        #expect(!AppModel.launchHasTab(last: nil, servers: [], autoOpen: true))
    }
}

/// The root as a launch draws it: the tab it restores, and a narrow window's drawer closed from
/// the first layout on, never opened and then shut.
@MainActor
final class ColdLaunchHostTests: XCTestCase {
    private var window: UIWindow!
    private var prefs: Prefs!
    private var panes = PaneBaseline()

    override func setUp() async throws {
        panes = PaneBaseline()
        let suite = "cold-launch-host-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        prefs = Prefs(defaults: defaults)
        UserDefaults.standard.set("none", forKey: "focus")
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 600))
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first { window.windowScene = scene }
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: "focus")
        window.isHidden = true
        window.rootViewController = nil
        window = nil
        prefs = nil
        let cleared = await panes.cleared()
        XCTAssertTrue(cleared, "LEAKCHECK \(name): \(panes.left) panes left")
    }

    private func settle(_ turns: Int = 8) async {
        for _ in 0..<turns {
            window.layoutIfNeeded()
            await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
        }
    }

    private func view(_ sid: String, _ tabs: [String]) -> SessionView {
        CloseNextTests.view(sid, tabs, blocks: Dictionary(uniqueKeysWithValues: tabs.map { ($0, [String]()) }))
    }

    /// A server not synced yet, with the tab viewed last saved: a launch before the server answers.
    private func model(last: String?) -> (AppModel, ServerConnection) {
        let model = AppModel(prefs: prefs, connect: false)
        let s = ServerConnection(config: ServerConfig(name: "desk", url: "https://desk-rex.tail1234.ts.net"),
                                 prefs: prefs, notifier: model.notifier, deviceID: "a1b2c3d4")
        model.servers.append(s)
        if let last { prefs.lastSelection = Selection(serverID: s.id, sessionID: "work", windowID: last) }
        return (model, s)
    }

    /// The server answers, as its first sync sets it.
    private func sync(_ s: ServerConnection) async {
        s.sessions = [SessionEntry(id: "work", label: "work")]
        s.views["work"] = view("work", ["w1", "w2"])
        s.phase = .online
        s.synced = true
        await settle()
    }

    private func launch(_ model: AppModel, width: CGFloat) async {
        window.frame = CGRect(x: 0, y: 0, width: width, height: 600)
        window.rootViewController = UIHostingController(rootView: RootView(launchHold: model.launchHold).environment(model).environment(prefs))
        window.makeKeyAndVisible()
        await settle()
    }

    func testANarrowColdLaunchShowsTheTabWithTheDrawerClosedFromTheFirstLayout() async {
        let (model, s) = model(last: "w2")
        model.launchHold = AppModel.launchHasTab(last: prefs.lastSelection, servers: model.servers.map(\.id), autoOpen: false)
        XCTAssertTrue(model.launchHold)
        let drawers = RenderCount.value(.openDrawers)
        let widths = prefs.sidebarWidths, mode = prefs.sidebarMode, collapsed = prefs.sidebarCollapsed
        await launch(model, width: 402)
        XCTAssertNil(model.selection)
        await sync(s)
        XCTAssertEqual(model.selection, Selection(serverID: s.id, sessionID: "work", windowID: "w2"))
        XCTAssertEqual(RenderCount.value(.openDrawers), drawers, "the drawer never drew open")
        // Taken: a window made later starts as before.
        XCTAssertFalse(model.launchHold)
        // Off screen and back, as through the background: the root keeps the state the user left.
        window.isHidden = true
        await settle()
        window.makeKeyAndVisible()
        await settle()
        XCTAssertEqual(RenderCount.value(.openDrawers), drawers)
        // Nothing saved changed.
        XCTAssertEqual(prefs.sidebarWidths, widths)
        XCTAssertEqual(prefs.sidebarMode, mode)
        XCTAssertEqual(prefs.sidebarCollapsed, collapsed)
    }

    func testALaunchWithoutTheHoldOpensTheDrawerAsBefore() async {
        let (model, s) = model(last: "w2")
        let drawers = RenderCount.value(.openDrawers)
        await launch(model, width: 402)
        await sync(s)
        XCTAssertGreaterThan(RenderCount.value(.openDrawers), drawers)
    }

    func testTheSessionsTopTabOpensWhenTheTabViewedLastIsGone() async {
        let (model, s) = model(last: "gone")
        await launch(model, width: 402)
        await sync(s)
        XCTAssertEqual(model.selection, Selection(serverID: s.id, sessionID: "work", windowID: "w1"))
    }
}
