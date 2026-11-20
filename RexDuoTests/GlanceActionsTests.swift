import Foundation
import GlanceModel
@testable import RexKit
import Testing
@testable import RexDuo

/// An action from the watch, on the phone: the status is read first, the guard decides, and
/// one write goes out at most, on a connection that starts no server.
@MainActor
@Suite struct GlanceActionsTests {
    static let terminal = "com.superlogical.terminal"
    static let write = "\(terminal).write"
    static let status = "\(terminal).program_status"

    static let fp = ActionGuard.fingerprint(state: "blocked", kind: "permission", message: "Run it?")
    static let target = WatchAction.Target(server: "server", session: "session:1", block: "block:1a", record: "claude", fp: fp)
    static let waiting: JSONObject = ["id": "claude", "app": "claude", "state": "blocked", "kind": "permission", "msg": "Run it?"]

    static func action(_ kind: WatchAction.Kind = .enter, id: String = UUID().uuidString, target: WatchAction.Target = target) -> WatchAction {
        WatchAction(id: id, kind: kind, target: target)
    }

    /// A stand-in channel that records what was asked of it.
    @MainActor
    final class FakeChannel: ActionChannel {
        var calls: [String] = []
        var label: String? = "zz-test"
        var records: [String: ProgramStatus]? = ["claude": ProgramStatus(GlanceActionsTests.waiting)]
        var delivery = TerminalStream.Delivery.delivered
        /// Calls that never answer.
        var silent: Set<String> = []
        var written: [String] = []

        private func hang() async { await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in } }

        func label(session: String) async -> String? {
            calls.append("label")
            if silent.contains("label") { await hang() }
            return label
        }

        func statuses(session: String, block: String) async -> [String: ProgramStatus]? {
            calls.append("status")
            if silent.contains("status") { await hang() }
            return records
        }

        func write(_ text: String, session: String, block: String, within limit: TimeInterval,
                   mayWrite: @escaping @MainActor () -> Bool) async -> TerminalStream.Delivery {
            // As the real connections do: asked as the last thing before the text leaves.
            guard mayWrite() else { return .unsent }
            calls.append("write")
            written.append(text)
            if silent.contains("write") { await hang() }
            return delivery
        }

        func close() { calls.append("close") }
    }

    /// A clock the test moves. Read from the actions' `@Sendable` clock and written by the
    /// test, both on the main actor only, so the lock is never contended; it is there
    /// because the closure's type can't say so.
    final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var date = Date(timeIntervalSince1970: 1_800_000_000)

        var now: Date {
            lock.lock()
            defer { lock.unlock() }
            return date
        }

        func advance(_ seconds: TimeInterval) {
            lock.lock()
            date.addTimeInterval(seconds)
            lock.unlock()
        }
    }

    private func actions(_ channel: FakeChannel?, only: String? = nil, enabled: Bool = true, clock: TestClock? = nil) -> GlanceActions {
        // Limits that pass at once, so a call that never answers ends the test quickly.
        var parts = GlanceActions.Parts(sleep: { _ in try? await Task.sleep(nanoseconds: 50_000_000) })
        if let clock { parts.now = { clock.now } }
        let a = GlanceActions(parts: parts)
        a.channel = { _ in channel }
        a.enabled = { enabled }
        a.only = { only }
        return a
    }

    // MARK: The order, and one write

    @Test func itReadsTheStatusThenTypesOnceThenCloses() async {
        let channel = FakeChannel()
        let result = await actions(channel).handle(Self.action(.enter))
        #expect(result == .sent)
        #expect(channel.calls == ["status", "write", "close"])
        #expect(channel.written == ["\r"])
    }

    @Test func interruptTypesControlC() async {
        let channel = FakeChannel()
        #expect(await actions(channel).handle(Self.action(.interrupt)) == .sent)
        #expect(channel.written == ["\u{03}"])
    }

    @Test func aCallerWhoseTimeRanOutStopsTheWriteAfterTheRead() async {
        // Asked once, after the status was read and the guard passed, right before the write.
        let channel = FakeChannel()
        var asked: [[String]] = []
        let result = await actions(channel).handle(Self.action()) {
            asked.append(channel.calls)
            return false
        }
        #expect(result == .unreachable)
        #expect(asked == [["status"]])
        #expect(channel.calls == ["status", "close"] && channel.written.isEmpty)
        // A wait that changed is refused before it is asked at all.
        let changed = FakeChannel()
        changed.records = [:]
        #expect(await actions(changed).handle(Self.action()) { Issue.record("asked"); return false } == .changed)
        // True, and by default: typed.
        let open = FakeChannel()
        #expect(await actions(open).handle(Self.action()) { true } == .sent)
        #expect(open.written == ["\r"])
    }

    @Test func theConnectionAsksOnceMoreAsTheLastThingBeforeTheTextLeaves() async {
        // Time that runs out after the first question and before the text is handed over:
        // the connection's own question stops it.
        let channel = FakeChannel()
        var asked = 0
        let result = await actions(channel).handle(Self.action()) {
            asked += 1
            return asked == 1
        }
        #expect(asked == 2)
        #expect(result == .unreachable)
        #expect(channel.written.isEmpty && channel.calls == ["status", "close"])
        // The one call both real connections make: refused, it sends nothing and reaches no server.
        let control = RexControl(address: "https://unused.example.ts.net", client: ClientInfo(name: "t", version: "0", label: "t"))
        #expect(await ActionCalls.write(control, "\r", session: "session:1", block: "block:1a", mayWrite: { false }) == .unsent)
        #expect(control.state != .connected)
    }

    // MARK: One wait is answered once, whoever asks

    @Test func aWaitThatWasJustAnsweredIsNotAnsweredAgainByAnotherAction() async {
        let clock = TestClock()
        let channel = FakeChannel()
        let a = actions(channel, clock: clock)
        #expect(await a.take(Self.action(.enter)) == .fresh(.sent))
        // Another tap, from anywhere, for the same wait: the pane still reads `blocked`,
        // because the agent's status has not caught up, and nothing is typed.
        clock.advance(3)
        #expect(await a.take(Self.action(.enter)) == .answered)
        #expect(await a.take(Self.action(.interrupt)) == .answered)
        // The watch hears that the agent no longer waits for this.
        #expect(await a.handle(Self.action(.enter)) == .changed)
        #expect(channel.written == ["\r"])
        #expect(channel.calls == ["status", "write", "close"])
        // Another wait is not held back: another pane, another record, other words.
        for other in [WatchAction.Target(server: "server", session: "session:1", block: "block:2b", record: "claude", fp: Self.fp),
                      WatchAction.Target(server: "other", session: "session:1", block: "block:1a", record: "claude", fp: Self.fp)] {
            #expect(await a.take(Self.action(target: other)) == .fresh(.sent), "\(other)")
        }
        // After the hold the pane's status decides again.
        clock.advance(GlanceActions.Parts().answeredFor)
        #expect(await a.take(Self.action(.enter)) == .fresh(.sent))
        #expect(GlanceActions.Parts().answeredFor == 15)
    }

    @Test func aWriteNobodyKnowsTheEndOfHoldsTheWaitToo() async {
        let clock = TestClock()
        let channel = FakeChannel()
        channel.delivery = .unknown
        let a = actions(channel, clock: clock)
        #expect(await a.take(Self.action()) == .fresh(.unconfirmed))
        #expect(await a.take(Self.action()) == .answered)
        #expect(channel.calls.filter { $0 == "write" }.count == 1)
    }

    @Test func aWriteThatNeverLeftHoldsNothing() async {
        for (delivery, result) in [(TerminalStream.Delivery.unsent, WatchActionResult.unreachable), (.refused, .changed)] {
            let channel = FakeChannel()
            channel.delivery = delivery
            let a = actions(channel, clock: TestClock())
            #expect(await a.take(Self.action()) == .fresh(result))
            // The next tap is tried in its own right.
            channel.delivery = .delivered
            #expect(await a.take(Self.action()) == .fresh(.sent), "\(delivery)")
        }
        // A wait that changed, or a status that can't be read: nothing left, nothing held.
        let unread = FakeChannel()
        unread.records = nil
        let b = actions(unread, clock: TestClock())
        #expect(await b.take(Self.action()) == .fresh(.unreachable))
        unread.records = ["claude": ProgramStatus(Self.waiting)]
        #expect(await b.take(Self.action()) == .fresh(.sent))
    }

    @Test func twoActionsForOneWaitAtTheSameTimeTypeOnce() async {
        // The second arrives while the first still reads the status: it waits for the
        // first's answer and never types.
        let channel = FakeChannel()
        let a = actions(channel, clock: TestClock())
        async let first = a.take(Self.action(.enter))
        async let second = a.take(Self.action(.enter))
        let both = await [first, second]
        #expect(both.sorted { "\($0)" < "\($1)" } == [.answered, .fresh(.sent)])
        #expect(channel.calls == ["status", "write", "close"])
        // When the first could not type, the second failed as it did, and still did not try.
        let down = FakeChannel()
        down.records = nil
        let b = actions(down, clock: TestClock())
        async let one = b.take(Self.action())
        async let two = b.take(Self.action())
        #expect(await [one, two] == [.fresh(.unreachable), .fresh(.unreachable)])
        #expect(down.calls == ["status", "close"])
    }

    @Test func theSameTapAgainIsSaidToBeARepeat() async {
        let channel = FakeChannel()
        let a = actions(channel, clock: TestClock())
        let action = Self.action()
        #expect(await a.take(action) == .fresh(.sent))
        #expect(await a.take(action) == .repeated(.sent))
        #expect(await a.handle(action) == .sent)
        #expect(channel.written == ["\r"])
    }

    @Test func nothingIsTypedWhenTheWaitChanged() async {
        let changes: [JSONObject] = [
            ["id": "claude", "app": "claude", "state": "working"],
            ["id": "claude", "app": "claude", "state": "blocked", "kind": "permission", "msg": "Run it again?"],
            ["id": "claude", "app": "claude", "state": "blocked", "kind": "question", "msg": "Run it?"],
            ["id": "claude-2", "app": "claude", "state": "blocked", "kind": "permission", "msg": "Run it?"],
        ]
        for record in changes {
            let channel = FakeChannel()
            channel.records = [record.str("id") ?? "": ProgramStatus(record)]
            #expect(await actions(channel).handle(Self.action()) == .changed, "\(record)")
            #expect(channel.calls == ["status", "close"] && channel.written.isEmpty)
        }
        // The pane has no status at all any more.
        let gone = FakeChannel()
        gone.records = [:]
        #expect(await actions(gone).handle(Self.action()) == .changed)
        #expect(gone.written.isEmpty)
    }

    @Test func aHigherRecordThanTheOneTheWatchSawRefuses() async {
        // The pane's top record is what the snapshot named: another record that now ranks
        // above it (an error beside the wait is lower; a second wait with a lower id is not).
        let channel = FakeChannel()
        channel.records = ["claude": ProgramStatus(Self.waiting),
                           "aaa": ProgramStatus(["id": "aaa", "state": "blocked", "kind": "question", "msg": "Which?"])]
        #expect(await actions(channel).handle(Self.action()) == .changed)
        #expect(channel.written.isEmpty)
    }

    @Test func nothingIsTypedWhenTheStatusCannotBeRead() async {
        let channel = FakeChannel()
        channel.records = nil
        #expect(await actions(channel).handle(Self.action()) == .unreachable)
        #expect(channel.calls == ["status", "close"])
        let slow = FakeChannel()
        slow.silent = ["status"]
        #expect(await actions(slow).handle(Self.action()) == .unreachable)
        #expect(slow.written.isEmpty && slow.calls.last == "close")
    }

    @Test func eachWayAWriteEndsIsSaidAndNoneIsTriedAgain() async {
        for (delivery, result) in [(TerminalStream.Delivery.delivered, WatchActionResult.sent), (.unsent, .unreachable),
                                   (.refused, .changed), (.unknown, .unconfirmed)] {
            let channel = FakeChannel()
            channel.delivery = delivery
            #expect(await actions(channel).handle(Self.action()) == result, "\(delivery)")
            #expect(channel.calls.filter { $0 == "write" }.count == 1)
        }
        // A write whose answer never comes: not confirmed, and not sent again.
        let silent = FakeChannel()
        silent.silent = ["write"]
        #expect(await actions(silent).handle(Self.action()) == .unconfirmed)
        #expect(silent.calls == ["status", "write", "close"])
    }

    @Test func theSameTapTwiceIsTypedOnce() async {
        let channel = FakeChannel()
        let a = actions(channel)
        let tap = Self.action(id: "tap-1")
        #expect(await a.handle(tap) == .sent)
        #expect(await a.handle(tap) == .sent)
        #expect(channel.written.count == 1 && channel.calls.filter { $0 == "status" }.count == 1)
        // Arriving again while the first is still out: nothing more is typed, and nothing is claimed.
        let slow = FakeChannel()
        slow.silent = ["write"]
        let b = actions(slow)
        let again = Self.action(id: "tap-2")
        async let first = b.handle(again)
        for _ in 0..<50 where slow.written.isEmpty { try? await Task.sleep(nanoseconds: 2_000_000) }
        #expect(await b.handle(again) == .unconfirmed)
        _ = await first
        #expect(slow.written.count == 1)
    }

    @Test func itRemembersOnlyTheNewestTaps() async {
        let channel = FakeChannel()
        // Each tap long enough after the one before that the wait counts as a new one.
        let clock = TestClock()
        let a = actions(channel, clock: clock)
        for i in 0...GlanceActions.memory {
            _ = await a.handle(Self.action(id: "tap-\(i)"))
            clock.advance(60)
        }
        #expect(channel.written.count == GlanceActions.memory + 1)
        // The newest is still known.
        _ = await a.handle(Self.action(id: "tap-\(GlanceActions.memory)"))
        #expect(channel.written.count == GlanceActions.memory + 1)
    }

    @Test func bytesThatAreNoActionTypeNothing() async {
        let channel = FakeChannel()
        let a = actions(channel)
        #expect(await a.answer(Data("nonsense".utf8)) == .changed)
        #expect(channel.calls.isEmpty)
        let data = WatchActionWire.actionData(in: WatchActionWire.message(Self.action()))!
        #expect(await a.answer(data) == .sent)
    }

    @Test func aLaunchThatMustTypeNothingTypesNothing() async {
        let channel = FakeChannel()
        #expect(await actions(channel, enabled: false).handle(Self.action()) == .changed)
        #expect(channel.calls.isEmpty)
        // A server that is not one of the app's.
        #expect(await actions(nil).handle(Self.action()) == .changed)
    }

    @Test func aTestLaunchTypesOnlyIntoItsOwnSession() async {
        let other = FakeChannel()
        other.label = "work"
        #expect(await actions(other, only: "zz-test").handle(Self.action()) == .changed)
        #expect(other.calls == ["label", "close"])
        let own = FakeChannel()
        #expect(await actions(own, only: "zz-test").handle(Self.action()) == .sent)
        #expect(own.calls == ["label", "status", "write", "close"])
        let unread = FakeChannel()
        unread.label = nil
        #expect(await actions(unread, only: "zz-test").handle(Self.action()) == .unreachable)
        #expect(unread.written.isEmpty)
    }

    @Test func thePhoneAnswersBeforeTheWatchStopsWaiting() {
        let parts = GlanceActions.Parts()
        // A test launch's label read, the status read and the write, each at its limit.
        #expect(parts.readLimit * 2 + parts.answerLimit < WatchActionOutcome.replyLimit)
        #expect(parts.leaveLimit < parts.answerLimit)
    }

    @Test func theGuardReadsTheRecordTheSnapshotWriterPicks() {
        let statuses = ["claude": ProgramStatus(Self.waiting), "zsh": ProgramStatus(["id": "zsh", "state": "working"])]
        let current = GlanceActions.current(statuses)
        #expect(current == ActionGuard.Current(record: "claude", state: "blocked", kind: "permission", message: "Run it?"))
        #expect(current?.fingerprint == Self.fp)
        #expect(GlanceActions.current([:]) == nil)
        // The snapshot's own fingerprint is made from the same record.
        var meta = BlockMeta()
        meta.statuses = statuses
        #expect(GlanceSource.current(meta)?.fingerprint == Self.fp)
    }

    // MARK: Against a server

    /// A server whose one pane waits, with every request recorded.
    @MainActor
    final class World {
        let fake: FakeRexServer
        let address: String
        let model: AppModel
        let prefs: Prefs
        var started: [String] = []

        init(record: JSONObject = GlanceActionsTests.waiting) async throws {
            fake = try FakeRexServer(revision: RexControl.apiRevision, serverRevision: RexControl.apiRevision)
            address = await fake.start()
            let name = "GlanceActionsTests-\(UUID().uuidString)"
            let d = UserDefaults(suiteName: name)!
            d.removePersistentDomain(forName: name)
            prefs = Prefs(defaults: d)
            prefs.servers = [ServerConfig(name: "Desk", url: address)]
            // As the app builds it: the servers are made and none is started.
            model = AppModel(prefs: prefs, connect: true)
            model.startServer = { [weak self] in self?.started.append($0.config.name) }
            fake.reply(GlanceActionsTests.status, ["records": [record]])
            fake.reply(GlanceActionsTests.write, [:])
            fake.reply("session.attach", ["view": [:] as JSONObject])
            fake.reply("session.list", ["sessions": [["session_id": "session:1", "label": "zz-test"] as JSONObject]])
        }

        var server: ServerConnection { model.servers[0] }

        func action(_ kind: WatchAction.Kind = .enter) -> WatchAction {
            var target = GlanceActionsTests.target
            target.server = server.id.uuidString
            return WatchAction(id: UUID().uuidString, kind: kind, target: target)
        }

        func actions(only: String? = nil) -> GlanceActions {
            let a = GlanceActions()
            a.enabled = { true }
            a.only = { only }
            a.channel = { [model] in model.actionChannel($0) }
            return a
        }

        var methods: [String] { fake.requests.map(\.method) }
        var writes: [JSONObject] { fake.calls(GlanceActionsTests.write) }
    }

    @Test func anActionThatWakesTheAppStartsNoServerAndTypesOnceOverOneShortConnection() async throws {
        let w = try await World()
        defer { w.fake.stop() }
        // A launch the system made in the background: no scene, so nothing may connect.
        for step in ScenePhases.steps(for: .background, initial: true) where step == .sceneVisible { w.model.sceneVisible() }
        #expect(!w.model.mayConnect)
        #expect(w.model.actionChannel(w.action()) is OneShotActionChannel)
        let result = await w.actions().handle(w.action(.enter))
        #expect(result == .sent)
        // No server was started, and the server's own connection was never asked for anything.
        #expect(w.started.isEmpty && !w.model.mayConnect)
        #expect(w.server.phase == .idle && w.server.connectionSerial == 0 && w.server.control.state == .idle)
        // One connection, attached to the pane's session alone, which read the status and
        // typed once: no bootstrap, no session list, no events of the whole server, no pane opened.
        #expect(w.fake.helloCount == 1)
        #expect(w.methods == ["session.attach", Self.status, Self.write])
        #expect(w.fake.calls("session.attach").map { $0.str("session_id") } == ["session:1"])
        #expect(w.writes.count == 1)
        #expect(w.writes.first?.str("session_id") == "session:1" && w.writes.first?.str("block_id") == "block:1a")
        #expect(w.writes.first?.obj("args")?.str("data") == "\r")
        // Its label carries no device id, so no Beacon takes it for the app being open.
        let hello = try #require(w.fake.lastHello)
        let label = try #require(hello.obj("client")?.str("label") ?? hello.str("label"))
        #expect(!label.contains("#") && !label.contains(w.model.push.deviceID))
    }

    @Test func aWakeWhoseWaitChangedTypesNothing() async throws {
        let w = try await World(record: ["id": "claude", "app": "claude", "state": "working"])
        defer { w.fake.stop() }
        #expect(await w.actions().handle(w.action(.interrupt)) == .changed)
        #expect(w.methods == ["session.attach", Self.status])
        #expect(w.writes.isEmpty && w.started.isEmpty)
    }

    @Test func aWakeThatCannotReachTheComputerTypesNothingAndTriesOnce() async throws {
        let w = try await World()
        w.fake.stop()
        #expect(await w.actions().handle(w.action()) == .unreachable)
        #expect(w.started.isEmpty && w.writes.isEmpty)
    }

    @Test func aPaneThatIsGoneRefusesWithoutTyping() async throws {
        let w = try await World()
        defer { w.fake.stop() }
        w.fake.reply(Self.status, .error(code: "block_not_found", status: 404))
        #expect(await w.actions().handle(w.action()) == .changed)
        #expect(w.writes.isEmpty)
    }

    @Test func aSessionThatIsGoneRefusesWithoutTyping() async throws {
        let w = try await World()
        defer { w.fake.stop() }
        w.fake.reply("session.attach", .error(code: "session_not_found", status: 404))
        #expect(await w.actions().handle(w.action()) == .changed)
        #expect(w.methods == ["session.attach"] && w.writes.isEmpty)
    }

    @Test func aWriteTheServerRefusesIsNotSentAgain() async throws {
        let w = try await World()
        defer { w.fake.stop() }
        w.fake.reply(Self.write, .error(code: "block_not_found", status: 404))
        #expect(await w.actions().handle(w.action()) == .changed)
        #expect(w.fake.count(Self.write) == 1)
    }

    @Test func aTestLaunchOverAShortConnectionChecksTheSessionsLabelFirst() async throws {
        let w = try await World()
        defer { w.fake.stop() }
        #expect(await w.actions(only: "zz-other").handle(w.action()) == .changed)
        #expect(w.methods == ["session.list"] && w.writes.isEmpty)
        w.fake.forget()
        #expect(await w.actions(only: "zz-test").handle(w.action()) == .sent)
        #expect(w.methods == ["session.list", "session.attach", Self.status, Self.write])
    }

    @Test func inFrontTheServersOwnConnectionIsUsedAndAPaneOnScreenTypesThroughItsQueue() async throws {
        let w = try await World()
        defer { w.fake.stop() }
        try await w.server.control.connect()
        defer { w.server.control.disconnect() }
        // In front: a scene has shown and the app is not in the background.
        w.model.startServer = { _ in }
        w.model.sceneVisible()
        #expect(w.model.actionChannel(w.action()) is LiveActionChannel)
        w.fake.forget()
        let hellos = w.fake.helloCount

        // A pane that is not on screen has no stream: one call on the same connection.
        #expect(await w.actions().handle(w.action(.enter)) == .sent)
        #expect(w.methods == [Self.status, Self.write] && w.fake.helloCount == hellos)

        // A pane on screen: the text goes through its stream's queue, behind what was typed.
        w.fake.forget()
        let stream = TerminalStream(control: w.server.control, sessionID: "session:1", blockID: "block:1a")
        stream.start()
        defer { stream.stop() }
        // This world serves no data socket, so the stream would stay behind its catch-up fence,
        // where nothing is typed. The pane here is one whose screen is current.
        stream.fence.reset()
        w.fake.delay(Self.write, seconds: 0.15)
        stream.send(text: "typed first")
        let result = await w.actions().handle(w.action(.interrupt))
        #expect(result == .sent)
        #expect(w.writes.compactMap { $0.obj("args")?.str("data") } == ["typed first", "\u{03}"])
        #expect(w.fake.helloCount == hellos)

        // In the background the same server is not trusted to be up: a short connection.
        w.model.enteredBackground()
        #expect(w.model.actionChannel(w.action()) is OneShotActionChannel)
    }

    @Test func anActionForAServerTheAppDoesNotHaveHasNoChannel() async throws {
        let w = try await World()
        defer { w.fake.stop() }
        var action = w.action()
        action.target.server = UUID().uuidString
        #expect(w.model.actionChannel(action) == nil)
        #expect(await w.actions().handle(action) == .changed)
        #expect(w.methods.isEmpty)
    }
}
