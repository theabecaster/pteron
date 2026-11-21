import Foundation
import XCTest
import UIKit
import RexKit
@testable import RexDuo

/// Progress bars (OSC 9;4) and notices (OSC 9 / 777) through a real connection to a fake Rex
/// server, at the revisions and creator lists the app meets.
@MainActor
final class AlertEventsTests: XCTestCase {
    typealias Rig = ServerEventsTests.Rig
    nonisolated static let terminal = "com.superlogical.terminal"

    /// A creator list whose terminal sends these events.
    nonisolated static func creators(events: [String]) -> JSONObject {
        var ev: JSONObject = [:]
        for e in events { ev[e] = [:] as JSONObject }
        return ["creators": [[
            "name": terminal, "host_id": "host-a", "flavors": [["flavor": "\(terminal).shell"]],
            "api": ["events": ev, "methods": ["write": [:]]],
        ] as JSONObject]]
    }

    static let both = ["bell", "progress_report", "desktop_notification"]

    /// A connected rig whose panes run shells: no OSC 7501 record, no agent title.
    private func shells(revision: Int? = 18, creators: FakeRexServer.Reply? = nil) async throws -> Rig {
        let rig = try await Rig(revision: revision, creators: creators ?? .result(Self.creators(events: Self.both)))
        rig.fake.reply("\(Self.terminal).program_status", ["records": [JSONObject]()])
        await rig.connect()
        return rig
    }

    private func blockEvent(_ rig: Rig, _ name: String, _ payload: JSONObject, block: String = "block:1a",
                            session: String = "session:1") {
        rig.fake.send(session: session, event: "block_event",
                      ["block_id": block, "creator_name": Self.terminal, "name": name, "payload": payload])
    }

    private func progress(_ rig: Rig, _ state: String, _ percent: Int? = nil, block: String = "block:1a") {
        var p: JSONObject = ["state": state]
        if let percent { p["progress"] = percent }
        blockEvent(rig, "progress_report", p, block: block)
    }

    private func bar(_ rig: Rig, _ block: String = "block:1a") -> TermProgress? { rig.server.progress.value(block) }

    // MARK: Progress

    func testABarAppliesOnItsOwnFlushAndNeverTouchesMetadata() async throws {
        let rig = try await shells()
        defer { rig.stop() }
        let metaBefore = rig.server.meta["block:1a"]
        progress(rig, "set", 40)
        let applied = await eventually { self.bar(rig) != nil }
        XCTAssertTrue(applied)
        XCTAssertEqual(bar(rig), TermProgress(state: .set, percent: 40))
        XCTAssertEqual(rig.server.meta["block:1a"], metaBefore, "progress is never metadata")
        XCTAssertNil(bar(rig, "block:1b"))
        progress(rig, "remove")
        let removed = await eventually { self.bar(rig) == nil }
        XCTAssertTrue(removed)
    }

    func testAFloodWritesAtMostTwiceASecondAndNeverStagesMetadata() async throws {
        let rig = try await shells()
        defer { rig.stop() }
        let writes = RenderCount.value(.progressWrites)
        let start = Date()
        for i in 0..<10_000 { progress(rig, "set", i % 101) }
        // Every report is in when the last value shows.
        progress(rig, "set", 7)
        let drained = await eventually(seconds: 10) { self.bar(rig)?.percent == 7 }
        XCTAssertTrue(drained)
        let elapsed = Date().timeIntervalSince(start)
        let n = RenderCount.value(.progressWrites) - writes
        XCTAssertGreaterThan(n, 0)
        XCTAssertLessThanOrEqual(Double(n), 3 * elapsed.rounded(.up),
                                 "\(n) writes in \(elapsed) s: at most 3 a second for one block")
        print("FLOOD writes=\(n) elapsed=\(elapsed)")
        XCTAssertTrue(rig.server.pendingMeta.isEmpty, "progress never goes through the meta flush")
        XCTAssertNil(rig.server.flushTask)
    }

    /// Titles keep showing, each before the next is sent, while a program floods progress
    /// reports, and a waiting agent in another pane shows too.
    ///
    /// How fast they show (the meta flush's pace is 0.15 s) is a measurement: it failed on a busy
    /// machine, so the limit is checked only by the benchmark (`scripts/bench/flood.sh`, with
    /// the budget from `scripts/bench/budgets.mjs`, `flood.lagSeconds`). Here the lags are
    /// printed and each title has 3 s to show.
    func testATitleShowsAtItsUsualPaceDuringAProgressFlood() async throws {
        let rig = try await shells()
        defer { rig.stop() }
        let fake = rig.fake
        let flood = Task.detached {
            for i in 0..<3_000 {
                fake.send(session: "session:1", event: "block_event", [
                    "block_id": "block:1a", "creator_name": AlertEventsTests.terminal, "name": "progress_report",
                    "payload": ["state": "set", "progress": i % 101] as JSONObject])
                if i % 10 == 0 { usleep(10_000) }
            }
        }
        var lags: [Double] = []
        for k in 0..<4 {
            try await Task.sleep(for: .milliseconds(250))
            let title = "zz title \(k)"
            let sent = Date()
            blockEvent(rig, "title_changed", ["title": title])
            let shown = await eventually(seconds: 3) { rig.server.meta["block:1a"]?.title == title }
            XCTAssertTrue(shown)
            lags.append(Date().timeIntervalSince(sent))
        }
        // A waiting agent in another pane shows at once (a new "blocked" skips the status hold).
        let sent = Date()
        blockEvent(rig, "program_status_changed", ["id": "s", "record": ["id": "s", "app": "claude", "state": "blocked"] as JSONObject],
                   block: "block:1b")
        let blocked = await eventually(seconds: 3) { rig.server.meta["block:1b"]?.topStatus?.state == "blocked" }
        XCTAssertTrue(blocked)
        let blockedLag = Date().timeIntervalSince(sent)
        await flood.value
        print("FLOOD title lags=\(lags) blocked lag=\(blockedLag)")
        XCTAssertEqual(lags.count, 4, "every title showed during the flood, in the order sent")
        guard let limit = ProcessInfo.processInfo.environment["REXDUO_BENCH_FLOOD_LAG"].flatMap(Double.init) else { return }
        XCTAssertLessThan(lags.max() ?? 0, limit, "title lags during the flood: \(lags)")
        XCTAssertLessThan(blockedLag, limit, "the waiting badge waited \(blockedLag) s")
    }

    func testEqualReportsWriteNothingButKeepTheBarAlive() async throws {
        let rig = try await shells()
        defer { rig.stop() }
        progress(rig, "set", 30)
        _ = await eventually { self.bar(rig) != nil }
        let writes = RenderCount.value(.progressWrites)
        for _ in 0..<20 { progress(rig, "set", 30) }
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(RenderCount.value(.progressWrites), writes, "the same value writes nothing")
        XCTAssertTrue(rig.server.sweepProgress(now: .now + .seconds(14)), "a repeat keeps it fresh")
        XCTAssertNotNil(bar(rig))
        XCTAssertFalse(rig.server.sweepProgress(now: .now + .seconds(16)), "15 s without a report clears it")
        XCTAssertNil(bar(rig))
    }

    func testPauseAndErrorKeepThePercentAndAnExitClears() async throws {
        let rig = try await shells()
        defer { rig.stop() }
        progress(rig, "set", 60)
        _ = await eventually { self.bar(rig)?.percent == 60 }
        progress(rig, "error")
        let failed = await eventually { self.bar(rig)?.state == .error }
        XCTAssertTrue(failed)
        XCTAssertEqual(bar(rig)?.percent, 60)
        blockEvent(rig, "child_exited", ["exit_code": 1])
        let cleared = await eventually { self.bar(rig) == nil }
        XCTAssertTrue(cleared)
    }

    func testAClosedBlockOrSessionTakesItsBox() async throws {
        let rig = try await shells()
        defer { rig.stop() }
        progress(rig, "set", 10, block: "block:1a")
        progress(rig, "set", 20, block: "block:2a")
        blockEvent(rig, "progress_report", ["state": "set", "progress": 30], block: "block:2b", session: "session:2")
        _ = await eventually { self.bar(rig, "block:2b") != nil && self.bar(rig) != nil }
        rig.fake.send(session: "session:1", event: "block_closed", ["block_id": "block:1a"])
        rig.fake.send(event: "session_destroyed", ["session_id": "session:2"])
        let gone = await eventually { rig.server.progress.isEmpty }
        XCTAssertTrue(gone, "boxes left: \(rig.server.progress.ids)")
    }

    func testAReconnectClearsEveryBarUntilTheNextReport() async throws {
        let rig = try await shells()
        defer { rig.stop() }
        progress(rig, "set", 50)
        _ = await eventually { self.bar(rig) != nil }
        rig.fake.dropAll()
        _ = await eventually { rig.server.connectionSerial == 2 }
        await rig.settle(keymapLoads: 2)
        XCTAssertNil(bar(rig))
        progress(rig, "set", 55)
        let back = await eventually { self.bar(rig)?.percent == 55 }
        XCTAssertTrue(back)
    }

    /// A sync clears the bars that may be stale and keeps the ones reported while it ran.
    func testASyncKeepsTheBarsReportedDuringIt() async throws {
        let rig = try await shells()
        defer { rig.stop() }
        progress(rig, "set", 40, block: "block:1a")
        progress(rig, "set", 10, block: "block:1b")
        _ = await eventually { self.bar(rig, "block:1a") != nil && self.bar(rig, "block:1b") != nil }
        rig.fake.delay("session.bootstrap", seconds: 1.2)
        rig.server.scheduleResync(after: 0)
        try await Task.sleep(for: .milliseconds(300))
        progress(rig, "set", 20, block: "block:1b")
        // Flushed (0.5 s) while the sync still waits for its answer.
        let flushed = await eventually { self.bar(rig, "block:1b")?.percent == 20 }
        XCTAssertTrue(flushed)
        await rig.settle(keymapLoads: 2)
        rig.fake.delay("session.bootstrap", seconds: 0)
        XCTAssertNil(bar(rig, "block:1a"), "no report since the sync began: it may be stale")
        XCTAssertEqual(bar(rig, "block:1b")?.percent, 20, "reported during the sync: live")
    }

    func testADroppedReportClearsTheBarAndReadsNoMore() async throws {
        let rig = try await shells()
        defer { rig.stop() }
        progress(rig, "set", 70)
        _ = await eventually { self.bar(rig) != nil }
        rig.fake.forget()
        rig.fake.send(event: "event_dropped", ["event_type": "block_event", "session_id": "session:1",
                                               "block_id": "block:1a", "creator_name": Self.terminal,
                                               "block_event_name": "progress_report", "size": 2_000_000])
        let cleared = await eventually { self.bar(rig) == nil }
        XCTAssertTrue(cleared)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(rig.fake.count("session.bootstrap"), 0, "never a full sync")
        XCTAssertEqual(rig.fake.count("\(Self.terminal).program_status"), 1, "the block's metadata, once")
    }

    /// Servers whose creator list lacks the event, or that have no list, show no bar and no
    /// notice: exactly today's app. Those that list it show both, from revision 13 on.
    func testOnlyAServerThatListsTheEventsGetsBarsAndNotices() async throws {
        let cases: [(String, Int?, FakeRexServer.Reply, Bool)] = [
            ("0 without the events", nil, .result(Self.creators(events: ["bell"])), false),
            ("13 without the events", 13, .result(Self.creators(events: ["bell"])), false),
            ("13 with the events", 13, .result(Self.creators(events: Self.both)), true),
            ("16 with the events", 16, .result(Self.creators(events: Self.both)), true),
            ("18 with the events", 18, .result(Self.creators(events: Self.both)), true),
            ("18 without a creator list", 18, .error(code: "method_not_found", status: 404), false),
            ("0 answering not_found", nil, .error(code: "not_found", status: 404), false),
        ]
        for (name, revision, creators, works) in cases {
            let rig = try await shells(revision: revision, creators: creators)
            let notices = rig.server.notifier.noticeSerial
            progress(rig, "set", 40)
            blockEvent(rig, "desktop_notification", ["title": "", "body": "zz probe"])
            try await Task.sleep(for: .milliseconds(1400))
            XCTAssertEqual(bar(rig) != nil, works, name)
            XCTAssertEqual(rig.server.notifier.noticeSerial != notices, works, name)
            if !works {
                XCTAssertEqual(rig.server.progress.generation, 0, "\(name): no box was ever made")
            }
            XCTAssertNil(rig.server.lastError, name)
            _ = rig.server.notifier.takeNotices()
            rig.stop()
        }
    }

    // MARK: Notices

    func testANoticeIsJudgedAfterASecondAndSaysWhereItCameFrom() async throws {
        let rig = try await shells()
        defer { rig.stop() }
        let serial = rig.server.notifier.noticeSerial
        blockEvent(rig, "desktop_notification", ["title": "", "body": "zz probe"])
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(rig.server.notifier.noticeSerial, serial, "not before the wait")
        let posted = await eventually { rig.server.notifier.noticeSerial != serial }
        XCTAssertTrue(posted)
        let n = try XCTUnwrap(rig.server.notifier.takeNotices().first)
        XCTAssertEqual(n.kind, .notice)
        XCTAssertEqual(n.blockID, "block:1a")
        XCTAssertEqual(n.windowID, "window:1")
        XCTAssertEqual(n.title, "tab", "OSC 9 has no title: the tab names it")
        XCTAssertEqual(n.body, "label session:1 › tab — zz probe")

        blockEvent(rig, "desktop_notification", ["title": "zz T", "body": "zz B"], block: "block:1b")
        _ = await eventually { rig.server.notifier.noticeSerial != serial + 1 }
        let m = try XCTUnwrap(rig.server.notifier.takeNotices().first)
        XCTAssertEqual(m.title, "zz T")
        XCTAssertEqual(m.body, "label session:1 › tab — zz B")
    }

    func testAnAgentsNoticesAreDropped() async throws {
        let rig = try await Rig(revision: 18, creators: .result(Self.creators(events: Self.both)))
        defer { rig.stop() }
        // The rig's panes report a Claude status (OSC 7501).
        await rig.connect()
        let serial = rig.server.notifier.noticeSerial
        blockEvent(rig, "desktop_notification", ["title": "", "body": "zz Claude needs your permission"])
        try await Task.sleep(for: .milliseconds(1500))
        XCTAssertEqual(rig.server.notifier.noticeSerial, serial)
    }

    func testANoticeJustBeforeItsAgentStatusIsDropped() async throws {
        let rig = try await shells()
        defer { rig.stop() }
        let serial = rig.server.notifier.noticeSerial
        blockEvent(rig, "desktop_notification", ["title": "", "body": "zz waiting"])
        try await Task.sleep(for: .milliseconds(400))
        blockEvent(rig, "program_status_changed", ["id": "s", "record": ["id": "s", "app": "my-agent", "state": "blocked"] as JSONObject])
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertEqual(rig.server.notifier.noticeSerial, serial)
    }

    func testANoticeSoonAfterAnAgentStatusWentIsDropped() async throws {
        let rig = try await shells()
        defer { rig.stop() }
        blockEvent(rig, "program_status_changed", ["id": "s", "record": ["id": "s", "app": "my-agent", "state": "done"] as JSONObject])
        try await Task.sleep(for: .milliseconds(300))
        blockEvent(rig, "program_status_removed", ["ids": ["s"]])
        try await Task.sleep(for: .milliseconds(300))
        let serial = rig.server.notifier.noticeSerial
        blockEvent(rig, "desktop_notification", ["title": "", "body": "zz after the agent"])
        try await Task.sleep(for: .milliseconds(1400))
        XCTAssertEqual(rig.server.notifier.noticeSerial, serial, "within 10 s of the removal")
    }

    func testEmptyAndProgressLookingNoticesAreDropped() async throws {
        let rig = try await shells()
        defer { rig.stop() }
        let serial = rig.server.notifier.noticeSerial
        blockEvent(rig, "desktop_notification", ["title": "", "body": ""])
        blockEvent(rig, "desktop_notification", ["title": "", "body": "4;1;40"])
        try await Task.sleep(for: .milliseconds(1400))
        XCTAssertEqual(rig.server.notifier.noticeSerial, serial)
    }

    func testANoticeWaitingAcrossAReconnectIsDropped() async throws {
        let rig = try await shells()
        defer { rig.stop() }
        let old = rig.server.connectionSerial
        let serial = rig.server.notifier.noticeSerial
        rig.fake.dropAll()
        _ = await eventually { rig.server.connectionSerial == old + 1 }
        await rig.settle(keymapLoads: 2)
        // The wait ends on the new connection: its filter would read another connection's state.
        rig.server.postNotice(serial: old, "session:1", "block:1a", title: "", body: "zz across")
        XCTAssertEqual(rig.server.notifier.noticeSerial, serial)
        rig.server.postNotice(serial: old + 1, "session:1", "block:1a", title: "", body: "zz across")
        XCTAssertNotEqual(rig.server.notifier.noticeSerial, serial, "the same notice on the new connection posts")
        rig.server.postNotice(serial: old + 1, "session:1", "block:gone", title: "", body: "zz gone")
        XCTAssertEqual(rig.server.notifier.noticeSerial, serial + 1, "a block that went posts nothing")
    }

    /// A pane that floods notices is held back before any wait: repeats go, and at most five of
    /// its notices wait at once. Another pane's notice still comes through.
    func testANoticeFloodIsCappedPerPaneBeforeItWaits() async throws {
        let rig = try await shells()
        defer { rig.stop() }
        _ = rig.server.notifier.takeNotices()
        for _ in 0..<50 { blockEvent(rig, "desktop_notification", ["title": "", "body": "zz same"]) }
        for i in 0..<40 { blockEvent(rig, "desktop_notification", ["title": "", "body": "zz \(i)"]) }
        blockEvent(rig, "desktop_notification", ["title": "", "body": "zz other pane"], block: "block:1b")
        try await Task.sleep(for: .milliseconds(1600))
        let posted = rig.server.notifier.takeNotices()
        let noisy = posted.filter { $0.blockID == "block:1a" }
        XCTAssertLessThanOrEqual(noisy.count, AgentNotifier.perPaneLimit, "\(noisy.map(\.body))")
        XCTAssertEqual(noisy.filter { $0.body.hasSuffix("zz same") }.count, 1, "repeats are dropped")
        XCTAssertEqual(posted.filter { $0.blockID == "block:1b" }.count, 1)
        XCTAssertTrue(rig.server.noticesInWait.isEmpty)
    }

    func testADroppedNoticeIsLostAndOnlyItsMetadataIsRead() async throws {
        let rig = try await shells()
        defer { rig.stop() }
        rig.fake.forget()
        let serial = rig.server.notifier.noticeSerial
        rig.fake.send(event: "event_dropped", ["event_type": "block_event", "session_id": "session:1",
                                               "block_id": "block:1a", "creator_name": Self.terminal,
                                               "block_event_name": "desktop_notification", "size": 2_000_000])
        try await Task.sleep(for: .milliseconds(1400))
        XCTAssertEqual(rig.server.notifier.noticeSerial, serial)
        XCTAssertEqual(rig.fake.count("\(Self.terminal).program_status"), 1)
        XCTAssertEqual(rig.fake.count("session.bootstrap"), 0)
    }
}

/// `VisiblePanes` keeps the two rules it took over unchanged: the toast's UIKit walk and the
/// Waiting pill's panes of a tab.
@MainActor
final class VisiblePanesTests: XCTestCase {
    private func host(_ block: String, _ frame: CGRect, in parent: UIView) -> TerminalHost {
        let control = RexControl(address: "", client: ClientInfo(name: "test", version: "0", label: "test"))
        let h = TerminalHost(stream: TerminalStream(control: control, sessionID: "s", blockID: block), sizing: .mirror,
                             fontSize: 12, theme: ThemeStore.fallback)
        // Too small to lay out, so the host never starts its stream.
        h.frame = frame
        parent.addSubview(h)
        return h
    }

    func testAPaneCountsWhenAtLeastHalfOfItIsInTheWindowAndShown() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        window.isHidden = false
        defer { window.isHidden = true }
        let root = UIView(frame: window.bounds)
        window.addSubview(root)
        _ = host("block:in", CGRect(x: 0, y: 0, width: 10, height: 10), in: root)
        _ = host("block:half", CGRect(x: 95, y: 0, width: 10, height: 10), in: root)
        _ = host("block:mostlyOut", CGRect(x: 96, y: 20, width: 10, height: 10), in: root)
        host("block:hidden", CGRect(x: 0, y: 40, width: 10, height: 10), in: root).isHidden = true
        let faded = UIView(frame: window.bounds)
        faded.alpha = 0
        root.addSubview(faded)
        _ = host("block:faded", CGRect(x: 0, y: 60, width: 10, height: 10), in: faded)
        XCTAssertEqual(VisiblePanes.onScreen(in: window), ["block:in", "block:half"])
    }

    func testATabShowsItsActivePaneAloneOrAllItsSplits() {
        let w = WindowInfo(ServerEventsTests.view("session:1").arr("windows")[0])
        XCTAssertEqual(VisiblePanes.inTab(w, active: "block:1b", single: true), ["block:1b"])
        XCTAssertEqual(VisiblePanes.inTab(w, active: "block:1b", single: false), ["block:1a", "block:1b"])
    }
}

@MainActor
private func eventually(seconds: Double = 5, _ condition: @MainActor () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while !condition(), Date() < end { try? await Task.sleep(for: .milliseconds(10)) }
    return condition()
}
