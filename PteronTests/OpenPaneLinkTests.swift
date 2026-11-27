import Foundation
import GlanceModel
import RexKit
import Testing
@testable import Pteron

@Suite struct OpenPaneLinkTests {
    private typealias World = OpenPaneLink.World
    private let tab = Selection(serverID: UUID(), sessionID: "s0", windowID: "w0")
    private let other = Selection(serverID: UUID(), sessionID: "s9", windowID: "w9")

    private func step(_ world: OpenPaneLink.World, at now: TimeInterval = 0, selection: Selection? = nil, auto: Selection? = nil,
                      before: Selection? = nil) -> OpenPaneLink.Step {
        OpenPaneLink(began: 0, before: before).step(world, now: now, selection: selection, autoSelected: auto)
    }

    @Test func anUnknownServerIsRefusedWhateverElseIsTrue() {
        #expect(step(World(serverKnown: false, loaded: false, inSnapshot: false)) == .nothing(.unknownServer))
        #expect(step(World(serverKnown: false, loaded: true, inSnapshot: true)) == .nothing(.unknownServer))
    }

    @Test func aLoadedPaneOpensAtOnce() {
        #expect(step(World(serverKnown: true, loaded: true, inSnapshot: false)) == .open)
        #expect(step(World(serverKnown: true, loaded: true, inSnapshot: true), at: 99) == .open)
    }

    @Test func aPaneNeitherLoadedNorListedIsRefused() {
        #expect(step(World(serverKnown: true, loaded: false, inSnapshot: false)) == .nothing(.unknownPane))
    }

    @Test func aListedPaneWaitsForItsSessionTenSecondsAtMost() {
        let listed = World(serverKnown: true, loaded: false, inSnapshot: true)
        #expect(step(listed) == .wait)
        #expect(step(listed, at: 9.9) == .wait)
        #expect(step(listed, at: 10) == .nothing(.timedOut))
    }

    @Test func itGivesUpOnlyOnThePersonsOwnMove() {
        let listed = World(serverKnown: true, loaded: false, inSnapshot: true)
        // The launch landed on the last tab by itself: the wait goes on, and then opens.
        #expect(step(listed, selection: tab, auto: tab) == .wait)
        #expect(step(World(serverKnown: true, loaded: true, inSnapshot: true), selection: tab, auto: tab) == .open)
        // The person opened a tab.
        #expect(step(listed, selection: other, auto: tab) == .nothing(.personMoved))
        #expect(step(listed, selection: tab, auto: nil) == .nothing(.personMoved))
        #expect(step(World(serverKnown: true, loaded: true, inSnapshot: true), selection: other, before: tab) == .nothing(.personMoved))
        // The tab that was there when the link arrived is no move.
        #expect(step(listed, selection: tab, before: tab) == .wait)
    }
}

/// `AppModel.openLink` with pane and pair links, on a model with servers that never connect.
@MainActor
@Suite struct OpenPaneLinkModelTests {
    private typealias FakeClock = OpenWaitingModelTests.FakeClock

    private func store() throws -> GlanceStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pane-link-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return GlanceStore(directory: dir)
    }

    /// A model whose snapshot lists `listed` (session, block) as waiting on `server`.
    private func model(store: GlanceStore? = nil) throws -> AppModel {
        let suite = "pane-link-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let glance = store.map { GlanceWriter(mode: .live(only: nil), store: $0) }
        let m = AppModel(prefs: Prefs(defaults: defaults), connect: false, glance: glance)
        m.firstSeenWaiting = { [:] }
        return m
    }

    private func server(_ model: AppModel, _ name: String) -> ServerConnection {
        let s = ServerConnection(config: ServerConfig(name: name, url: "https://\(name)-rex.tail1234.ts.net"),
                                 prefs: model.prefs, notifier: model.notifier, deviceID: "a1b2c3d4")
        model.servers.append(s)
        return s
    }

    private func load(_ s: ServerConnection, session: String = "s1", tabs: [String: [String]]) {
        let windows = tabs.keys.sorted().map { w -> JSONObject in
            ["window_id": w, "layers": [["kind": "tiled", "blocks": (tabs[w] ?? []).map {
                ["block_id": $0, "creator_name": "com.superlogical.terminal"] as JSONObject
            }] as JSONObject]]
        }
        s.sessions = [SessionEntry(id: session, label: session)]
        s.views = [session: SessionView(["revision": 1, "session_id": session, "active_window_id": tabs.keys.sorted().first ?? "",
                                         "windows": windows])]
        s.phase = .online
        s.synced = true
    }

    private func list(_ store: GlanceStore, server: ServerConnection, session: String, window: String, block: String) throws {
        let agent = GlanceSnapshot.Agent(session: session, window: window, block: block, kind: "claude", name: "Claude",
                                         symbol: "asterisk", why: nil, place: "", since: Date(timeIntervalSince1970: 1_800_000_000),
                                         record: "r1", msg: nil)
        let snap = GlanceSnapshot(seq: 1, asOf: Date(timeIntervalSince1970: 1_800_000_100), palette: .standard, machines: [
            .init(id: server.id.uuidString, name: "desk", link: .live, counts: .init(waiting: 1), waiting: [agent], seen: nil)])
        try store.write(try snap.encoded())
    }

    private func link(_ s: ServerConnection, session: String = "s1", window: String = "w1", block: String) -> PaneLink {
        PaneLink(server: s.id.uuidString, session: session, window: window, block: block)
    }

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }

    @Test func aLoadedPaneOpensAsAPushTapDoes() async throws {
        let m = try model()
        let s = server(m, "desk")
        load(s, tabs: ["w1": ["b1"], "w2": ["b2", "b3"]])
        let clock = FakeClock()
        let step = await m.openPane(link: link(s, window: "w2", block: "b3"), clock: clock.clock)
        #expect(step == .open)
        #expect(m.openRequest?.selection == Selection(serverID: s.id, sessionID: "s1", windowID: "w2"))
        #expect(m.focusedPane["w2"] == "b3" && clock.sleeps == 0)
        // The pane moved to another tab since the widget was drawn: the tab that holds it now.
        m.openRequest = nil
        #expect(await m.openPane(link: link(s, window: "w1", block: "b2"), clock: clock.clock) == .open)
        #expect(m.openRequest?.selection.windowID == "w2")
    }

    @Test func anUnknownServerIDDoesNothing() async throws {
        let st = try store()
        let m = try model(store: st)
        let s = server(m, "desk")
        load(s, tabs: ["w1": ["b1"]])
        try list(st, server: s, session: "s1", window: "w1", block: "b1")
        let clock = FakeClock()
        // Right session and pane, another server id, as a link made elsewhere would have.
        let forged = PaneLink(server: UUID().uuidString, session: "s1", window: "w1", block: "b1")
        #expect(await m.openPane(link: forged, clock: clock.clock) == .nothing(.unknownServer))
        // The server's host is not its id.
        let byHost = PaneLink(server: "desk-rex.tail1234.ts.net", session: "s1", window: "w1", block: "b1")
        #expect(await m.openPane(link: byHost, clock: clock.clock) == .nothing(.unknownServer))
        #expect(m.openRequest == nil && m.focusedPane.isEmpty && clock.sleeps == 0)
    }

    @Test func aPaneThatIsNeitherLoadedNorListedDoesNothing() async throws {
        let st = try store()
        let m = try model(store: st)
        let s = server(m, "desk")
        load(s, tabs: ["w1": ["b1"]])
        try list(st, server: s, session: "s1", window: "w1", block: "b1")
        let clock = FakeClock()
        #expect(await m.openPane(link: link(s, block: "b404"), clock: clock.clock) == .nothing(.unknownPane))
        #expect(m.openRequest == nil && clock.sleeps == 0)
        // A link that names another session for a pane the app has loaded is one written before
        // the pane's tab moved to another session (Move to Session): the pane keeps its ID, so
        // it opens where it is now.
        #expect(await m.openPane(link: link(s, session: "s404", block: "b1"), clock: clock.clock) == .open)
        #expect(m.openRequest?.selection == Selection(serverID: s.id, sessionID: "s1", windowID: "w1"))
        #expect(clock.sleeps == 0)
        // Without a snapshot at all (the writer is off), only loaded panes open.
        let plain = try model()
        let p = server(plain, "desk")
        #expect(await plain.openPane(link: link(p, block: "b1"), clock: clock.clock) == .nothing(.unknownPane))
    }

    /// A cold launch from a widget's row: the pane is only in the snapshot until its session loads.
    @Test func aPaneOnlyInTheSnapshotWaitsForItsSession() async throws {
        let st = try store()
        let m = try model(store: st)
        let s = server(m, "desk")
        try list(st, server: s, session: "s1", window: "w1", block: "b1")
        let clock = FakeClock()
        clock.at(3) { self.load(s, tabs: ["w1": ["b1"]]) }
        let step = await m.openPane(link: link(s, block: "b1"), clock: clock.clock)
        #expect(step == .open && clock.time >= 3 && clock.time < 3.5)
        #expect(m.openRequest?.selection == Selection(serverID: s.id, sessionID: "s1", windowID: "w1"))
    }

    @Test func itStopsWaitingAfterTenSeconds() async throws {
        let st = try store()
        let m = try model(store: st)
        let s = server(m, "desk")
        try list(st, server: s, session: "s1", window: "w1", block: "b1")
        let clock = FakeClock()
        #expect(await m.openPane(link: link(s, block: "b1"), clock: clock.clock) == .nothing(.timedOut))
        #expect(clock.time >= 10 && clock.time < 10.5 && m.openRequest == nil)
    }

    @Test func theLaunchLandingOnTheLastTabDoesNotCancelIt() async throws {
        let st = try store()
        let m = try model(store: st)
        let s = server(m, "desk")
        try list(st, server: s, session: "s1", window: "w2", block: "b2")
        let clock = FakeClock()
        // The sessions load, and `autoSelect()` puts the first tab on screen, mid-wait.
        clock.at(1) {
            self.load(s, tabs: ["w1": ["b1"]])
            m.autoSelect()
        }
        clock.at(2) { self.load(s, tabs: ["w1": ["b1"], "w2": ["b2"]]) }
        let step = await m.openPane(link: link(s, window: "w2", block: "b2"), clock: clock.clock)
        #expect(m.autoSelected?.windowID == "w1")
        #expect(step == .open && m.openRequest?.selection.windowID == "w2")
    }

    @Test func aTabThePersonOpensCancelsIt() async throws {
        let st = try store()
        let m = try model(store: st)
        let s = server(m, "desk")
        try list(st, server: s, session: "s1", window: "w2", block: "b2")
        let clock = FakeClock()
        clock.at(1) {
            self.load(s, tabs: ["w1": ["b1"]])
            m.select(s, session: "s1", window: "w1")
        }
        clock.at(2) { self.load(s, tabs: ["w1": ["b1"], "w2": ["b2"]]) }
        #expect(await m.openPane(link: link(s, window: "w2", block: "b2"), clock: clock.clock) == .nothing(.personMoved))
        #expect(m.openRequest == nil && m.selection?.windowID == "w1")
    }

    @Test func aPaneLinkURLTakesTheSamePath() async throws {
        let m = try model()
        let s = server(m, "desk")
        load(s, tabs: ["w1": ["b1"]])
        m.releaseLinks()
        m.openLink(link(s, block: "b1").url)
        await settle()
        #expect(m.openRequest?.selection == Selection(serverID: s.id, sessionID: "s1", windowID: "w1"))
        // A pane link with a value missing is no pane link: it is `open`, which does nothing.
        m.openRequest = nil
        m.openLink(try #require(URL(string: "rexduo://pane?server=\(s.id.uuidString)&session=s1&window=w1")))
        await settle()
        #expect(m.openRequest == nil)
    }

    // MARK: Pair

    @Test func pairOpensTheScannerOnlyOntoTheBareApp() async throws {
        let m = try model()
        m.releaseLinks()
        m.openLink(DeepLink.pair.url)
        #expect(m.showPairing && m.pairingStart == nil)
        // Settings is up: the link is ignored, and Settings stays.
        let busy = try model()
        busy.releaseLinks()
        busy.showSettings = true
        busy.openLink(DeepLink.pair.url)
        #expect(!busy.showPairing && busy.showSettings)
        // The scanner is already up at a computer's check: it stays as it is.
        let pairing = try model()
        pairing.releaseLinks()
        pairing.startPairing(prefilled: try #require(URL(string: "https://desk-rex.tail1234.ts.net")), name: "desk")
        let start = pairing.pairingStart
        pairing.openLink(DeepLink.pair.url)
        #expect(pairing.showPairing && pairing.pairingStart == start && start != nil)
    }

    @Test func aPairLinkBeforeTheFirstScreenWaits() async throws {
        let m = try model()
        m.openLink(DeepLink.pair.url)
        #expect(!m.showPairing)
        m.releaseLinks()
        #expect(m.showPairing)
    }
}
