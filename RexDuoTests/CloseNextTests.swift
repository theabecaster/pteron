import Foundation
import RexKit
import Testing
@testable import RexDuo

/// What shows when the tab on screen closes: the rule (`CloseNext`), and the model applying it
/// only to the tab on screen, in the same turn as the change.
@MainActor
struct CloseNextTests {
    private let desk = UUID(), lab = UUID(), mini = UUID()

    private func sel(_ server: UUID, _ session: String, _ window: String) -> Selection {
        Selection(serverID: server, sessionID: session, windowID: window)
    }

    private func rule(closed: Selection, order: [String] = [], movedTo: String? = nil, machines: [CloseNext.Machine],
                      recent: [Selection] = [], anySession: Bool = true) -> Selection? {
        CloseNext(closed: closed, order: order, movedTo: movedTo, machines: machines, recent: recent, anySession: anySession).next()
    }

    private func machine(_ id: UUID, online: Bool = true, _ sessions: [(String, [String])]) -> CloseNext.Machine {
        CloseNext.Machine(id: id, online: online, sessions: sessions.map { CloseNext.Session(id: $0.0, windows: $0.1, active: $0.1.first) })
    }

    // MARK: A tab closed, the session has others

    @Test func goesBackToTheTabViewedBeforeInTheSession() {
        let closed = sel(desk, "work", "w2")
        let next = rule(closed: closed, order: ["w1", "w2", "w3"], machines: [machine(desk, [("work", ["w1", "w3"])])],
                        recent: [closed, sel(desk, "other", "o1"), sel(desk, "work", "w1"), sel(desk, "work", "w3")])
        #expect(next == sel(desk, "work", "w1"))
    }

    @Test func withNoTabViewedBeforeItShowsTheNextNeighbourThenThePrevious() {
        let m = [machine(desk, [("work", ["w1", "w3"])])]
        #expect(rule(closed: sel(desk, "work", "w2"), order: ["w1", "w2", "w3"], machines: m) == sel(desk, "work", "w3"))
        let last = [machine(desk, [("work", ["w1", "w2"])])]
        #expect(rule(closed: sel(desk, "work", "w3"), order: ["w1", "w2", "w3"], machines: last) == sel(desk, "work", "w2"))
    }

    @Test func aTabViewedBeforeThatClosedTooIsSkipped() {
        let next = rule(closed: sel(desk, "work", "w2"), order: ["w1", "w2", "w3"], machines: [machine(desk, [("work", ["w3"])])],
                        recent: [sel(desk, "work", "w1")])
        #expect(next == sel(desk, "work", "w3"))
    }

    @Test func aPaneThatMovedToAnotherTabIsFollowed() {
        let next = rule(closed: sel(desk, "work", "w2"), order: ["w1", "w2", "w3"], movedTo: "w3",
                        machines: [machine(desk, [("work", ["w1", "w3"])])], recent: [sel(desk, "work", "w1")])
        #expect(next == sel(desk, "work", "w3"))
    }

    // MARK: The session is empty or gone

    @Test func theSessionViewedLastOnTheSameMachineComesFirst() {
        let closed = sel(desk, "work", "w1")
        let machines = [machine(desk, [("work", []), ("docs", ["d1", "d2"]), ("play", ["p1"])]),
                        machine(lab, [("gpu", ["g1"])])]
        // The lab's session was viewed more recently, but it's on another machine.
        let next = rule(closed: closed, machines: machines,
                        recent: [closed, sel(lab, "gpu", "g1"), sel(desk, "play", "p1"), sel(desk, "docs", "d2")])
        #expect(next == sel(desk, "play", "p1"))
    }

    @Test func itLandsOnTheTabViewedLastThere() {
        let closed = sel(desk, "work", "w1")
        let machines = [machine(desk, [("docs", ["d1", "d2", "d3"])])]
        let next = rule(closed: closed, machines: machines, recent: [closed, sel(desk, "docs", "d3"), sel(desk, "docs", "d2")])
        #expect(next == sel(desk, "docs", "d3"))
        // The tab viewed there closed since: the session's active tab.
        let active = [CloseNext.Machine(id: desk, online: true, sessions: [CloseNext.Session(id: "docs", windows: ["d1", "d2"], active: "d2")])]
        #expect(rule(closed: closed, machines: active, recent: [sel(desk, "docs", "d3")]) == sel(desk, "docs", "d2"))
    }

    @Test func thenTheSessionViewedLastOnAnotherMachineThatIsOnline() {
        let closed = sel(desk, "work", "w1")
        let machines = [machine(desk, [("work", []), ("fresh", ["f1"])]),
                        machine(lab, online: false, [("gpu", ["g1"])]),
                        machine(mini, [("build", ["b1"])])]
        // Never viewed on this machine; viewed on the lab, which is down, and on the mini.
        let next = rule(closed: closed, machines: machines, recent: [closed, sel(lab, "gpu", "g1"), sel(mini, "build", "b1")])
        #expect(next == sel(mini, "build", "b1"))
    }

    @Test func aViewedSessionThatIsEmptyOrGoneIsSkipped() {
        let closed = sel(desk, "work", "w1")
        let machines = [machine(desk, [("empty", []), ("docs", ["d1"])])]
        let next = rule(closed: closed, machines: machines,
                        recent: [closed, sel(desk, "gone", "x1"), sel(desk, "empty", "e1"), sel(desk, "docs", "d1")])
        #expect(next == sel(desk, "docs", "d1"))
    }

    @Test func withNoneViewedTheFirstSessionOnTheSameMachineThenAnotherOne() {
        let closed = sel(desk, "work", "w1")
        let both = [machine(desk, [("work", []), ("empty", []), ("docs", ["d1"])]), machine(lab, [("gpu", ["g1"])])]
        #expect(rule(closed: closed, machines: both, recent: [closed]) == sel(desk, "docs", "d1"))
        let lone = [machine(desk, [("work", [])]), machine(lab, online: false, [("gpu", ["g1"])]), machine(mini, [("build", ["b1"])])]
        #expect(rule(closed: closed, machines: lone, recent: [closed]) == sel(mini, "build", "b1"))
    }

    @Test func aTestLaunchGoesOnlyWhereItWasBefore() {
        let closed = sel(desk, "zz-a", "w1")
        let machines = [machine(desk, [("zz-a", []), ("real", ["r1"]), ("zz-b", ["z1"])])]
        #expect(rule(closed: closed, machines: machines, recent: [closed], anySession: false) == nil)
        #expect(rule(closed: closed, machines: machines, recent: [closed, sel(desk, "zz-b", "z1")], anySession: false)
                == sel(desk, "zz-b", "z1"))
    }

    @Test func nothingLeftShowsTheEmptyState() {
        let closed = sel(desk, "work", "w1")
        #expect(rule(closed: closed, machines: [machine(desk, [("work", [])])], recent: [closed]) == nil)
        #expect(rule(closed: closed, machines: [machine(desk, [("work", [])]), machine(lab, online: false, [("gpu", ["g1"])])],
                     recent: [closed, sel(lab, "gpu", "g1")]) == nil)
    }

    @Test func theHistoryKeepsEachTabOnceNewestFirst() {
        let a = sel(desk, "s", "a"), b = sel(desk, "s", "b")
        #expect(TabHistory.visiting(a, [b, a]) == [a, b])
        let many = (0..<40).map { sel(desk, "s", "w\($0)") }
        #expect(TabHistory.visiting(a, many).count == TabHistory.limit)
    }

    // MARK: The model

    private func model() throws -> AppModel {
        let suite = "close-next-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return AppModel(prefs: Prefs(defaults: defaults), connect: false)
    }

    private func server(_ model: AppModel, _ name: String, sessions: [(String, [String])]) -> ServerConnection {
        let s = ServerConnection(config: ServerConfig(name: name, url: "https://\(name)-rex.tail1234.ts.net"),
                                 prefs: model.prefs, notifier: model.notifier, deviceID: "a1b2c3d4")
        model.servers.append(s)
        s.sessions = sessions.map { SessionEntry(id: $0.0, label: $0.0) }
        for (sid, tabs) in sessions { s.views[sid] = Self.view(sid, tabs) }
        s.phase = .online
        return s
    }

    /// A session's view with one pane per tab, named after the tab with a "b" in front.
    static func view(_ sid: String, _ tabs: [String], revision: Int = 1, blocks: [String: [String]] = [:]) -> SessionView {
        SessionView(["revision": revision, "session_id": sid, "label": sid, "active_window_id": tabs.first as Any,
                     "windows": tabs.map { w -> JSONObject in
                         ["window_id": w, "layers": [["kind": "tiled", "blocks": (blocks[w] ?? ["b" + w]).map {
                             ["block_id": $0, "creator_name": "com.superlogical.terminal"] as JSONObject
                         }] as JSONObject]]
                     }])
    }

    @Test func theLastPaneOfTheTabOnScreenClosingShowsTheTabBeforeAtOnce() throws {
        let m = try model()
        let s = server(m, "desk", sessions: [("work", ["w1", "w2", "w3"])])
        m.select(s, session: "work", window: "w1")
        m.select(s, session: "work", window: "w3")
        // The server closes the tab with its last pane; the next read of the view lacks it.
        s.views["work"] = Self.view("work", ["w1", "w2"], revision: 2)
        #expect(m.selection == sel(s.id, "work", "w1"))
        #expect(m.current != nil)
    }

    @Test func theSessionOnScreenEmptyingShowsTheSessionViewedBefore() throws {
        let m = try model()
        let s = server(m, "desk", sessions: [("docs", ["d1"]), ("play", ["p1", "p2"]), ("work", ["w1"])])
        m.select(s, session: "play", window: "p2")
        m.select(s, session: "work", window: "w1")
        // Rex keeps the session with no tabs.
        s.views["work"] = Self.view("work", [], revision: 2)
        #expect(m.selection == sel(s.id, "play", "p2"))
    }

    @Test func theSessionOnScreenEndingShowsAnotherMachinesWhenItsOwnHasNone() throws {
        let m = try model()
        let s = server(m, "desk", sessions: [("work", ["w1"])])
        let l = server(m, "lab", sessions: [("gpu", ["g1"])])
        m.select(l, session: "gpu", window: "g1")
        m.select(s, session: "work", window: "w1")
        // session_destroyed: the list first, then the view, in one turn.
        s.sessions.removeAll { $0.id == "work" }
        s.views["work"] = nil
        #expect(m.selection == sel(l.id, "gpu", "g1"))
    }

    @Test func aTabOrSessionClosingOffScreenMovesNothing() throws {
        let m = try model()
        let s = server(m, "desk", sessions: [("docs", ["d1", "d2"]), ("work", ["w1"])])
        let l = server(m, "lab", sessions: [("gpu", ["g1"])])
        m.select(s, session: "work", window: "w1")
        m.select(s, session: "docs", window: "d1")
        let shown = m.selection
        s.views["docs"] = Self.view("docs", ["d1"], revision: 2)
        s.sessions.removeAll { $0.id == "work" }
        s.views["work"] = nil
        l.views["gpu"] = Self.view("gpu", [], revision: 2)
        #expect(m.selection == shown)
    }

    @Test func aSessionWhoseViewIsOutForAMomentIsNotLeft() throws {
        let m = try model()
        let s = server(m, "desk", sessions: [("docs", ["d1"]), ("work", ["w1"])])
        m.select(s, session: "docs", window: "d1")
        m.select(s, session: "work", window: "w1")
        // A sync that couldn't read the view of a session it still lists.
        s.views = ["docs": Self.view("docs", ["d1"], revision: 2)]
        #expect(m.selection == sel(s.id, "work", "w1"))
    }

    @Test func aPaneMovedOutOfTheTabOnScreenIsFollowed() throws {
        let m = try model()
        let s = server(m, "desk", sessions: [("work", ["w1", "w2", "w3"])])
        m.select(s, session: "work", window: "w1")
        m.select(s, session: "work", window: "w2")
        s.views["work"] = Self.view("work", ["w1", "w3"], revision: 2, blocks: ["w3": ["bw3", "bw2"]])
        #expect(m.selection == sel(s.id, "work", "w3"))
    }

    @Test func closeTabShowsTheNextTabBeforeTheViewIsReadAgain() throws {
        let m = try model()
        let s = server(m, "desk", sessions: [("work", ["w1", "w2", "w3"])])
        m.select(s, session: "work", window: "w2")
        m.closedTab(sel(s.id, "work", "w2"))
        #expect(m.selection == sel(s.id, "work", "w3"))
        // Then the view without it changes nothing more.
        s.views["work"] = Self.view("work", ["w1", "w3"], revision: 2)
        #expect(m.selection == sel(s.id, "work", "w3"))
        // A Close Tab whose tab is no longer on screen leaves the screen alone.
        m.closedTab(sel(s.id, "work", "w1"))
        #expect(m.selection == sel(s.id, "work", "w3"))
    }
}
