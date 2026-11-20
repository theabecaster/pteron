import Foundation
import Testing
@testable import GlanceModel

/// Actions from the wrist, as far as they are pure: how an action travels, what the guard
/// passes, what the watch may start and what it says.
@Suite struct WatchActionTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let target = WatchAction.Target(server: "s", session: "session:1", block: "block:1", record: "claude",
                                                   fp: ActionGuard.fingerprint(state: "blocked", kind: "permission", message: "Run it?"))

    private func action(_ kind: WatchAction.Kind = .enter, target: WatchAction.Target = target) -> WatchAction {
        WatchAction(id: "tap-1", kind: kind, target: target)
    }

    private func current(record: String = "claude", state: String = "blocked", kind: String? = "permission",
                         message: String? = "Run it?") -> ActionGuard.Current {
        ActionGuard.Current(record: record, state: state, kind: kind, message: message)
    }

    // MARK: What is typed

    @Test func enterTypesReturnAndInterruptTypesControlC() {
        #expect(Array(WatchAction.Kind.enter.text.utf8) == [0x0d])
        #expect(Array(WatchAction.Kind.interrupt.text.utf8) == [0x03])
        #expect(WatchAction.Kind.allCases == [.enter, .interrupt])
    }

    // MARK: On the wire

    @Test func anActionTravelsAsAPropertyListAndBack() throws {
        let sent = action(.interrupt)
        let message = WatchActionWire.message(sent)
        #expect(message.keys.sorted() == ["a"])
        // What a session carries: a property list.
        #expect(PropertyListSerialization.propertyList(message, isValidFor: .binary))
        let data = try #require(WatchActionWire.actionData(in: message))
        #expect(WatchActionWire.action(from: data) == sent)
    }

    @Test func bytesThatAreNoActionOfThisVersionAreNoAction() throws {
        #expect(WatchActionWire.action(from: Data("{}".utf8)) == nil)
        #expect(WatchActionWire.action(from: Data()) == nil)
        #expect(WatchActionWire.actionData(in: ["s": Data()]) == nil)
        var later = action()
        later.v = 2
        #expect(WatchActionWire.action(from: try JSONEncoder().encode(later)) == nil)
        // A kind this app doesn't know types nothing.
        let json = String(decoding: try JSONEncoder().encode(action()), as: UTF8.self).replacingOccurrences(of: "\"enter\"", with: "\"paste\"")
        #expect(WatchActionWire.action(from: Data(json.utf8)) == nil)
    }

    @Test func everyResultTravelsAsOneWordAndBack() {
        for result in WatchActionResult.allCases {
            let reply = WatchActionWire.reply(result)
            #expect(reply[WatchActionWire.resultKey] as? String == result.rawValue)
            #expect(WatchActionWire.result(in: reply) == result)
        }
        #expect(WatchActionWire.result(in: [:]) == nil)
        #expect(WatchActionWire.result(in: ["r": "later"]) == nil)
    }

    // MARK: The result, as the watch says it

    @Test func theReplyBecomesAnOutcome() {
        #expect(WatchActionOutcome(reply: WatchActionWire.reply(.sent)) == .sent)
        #expect(WatchActionOutcome(reply: WatchActionWire.reply(.changed)) == .changed)
        #expect(WatchActionOutcome(reply: WatchActionWire.reply(.unreachable)) == .unreachable)
        #expect(WatchActionOutcome(reply: WatchActionWire.reply(.unconfirmed)) == .unconfirmed)
        // No reply: the phone wasn't reached, and nothing was typed.
        #expect(WatchActionOutcome(reply: nil) == .noPhone)
        // The message arrived and its reply was lost, or the reply can't be read: the phone may have typed.
        #expect(WatchActionOutcome(reply: nil, arrived: true) == .unconfirmed)
        #expect(WatchActionOutcome(reply: ["r": "later"]) == .unconfirmed)
        #expect(WatchActionOutcome(reply: [:]) == .unconfirmed)
        #expect(WatchActionOutcome.replyLimit >= 20)
    }

    @Test func everyOutcomeHasAQuietLineThatSaysWhetherItWasSent() {
        #expect(WatchText.outcome(.sent, .enter) == "Sent Enter")
        #expect(WatchText.outcome(.sent, .interrupt) == "Sent Interrupt")
        for outcome in WatchActionOutcome.allCases where outcome != .sent && outcome != .unconfirmed {
            #expect(WatchText.outcome(outcome, .enter).hasPrefix("Not sent."), "\(outcome)")
        }
        // Not claimed either way.
        #expect(!WatchText.outcome(.unconfirmed, .enter).contains("Sent") && !WatchText.outcome(.unconfirmed, .enter).contains("Not sent"))
        for outcome in WatchActionOutcome.allCases {
            let line = WatchText.outcome(outcome, .interrupt)
            #expect(!line.contains("!") && line.count <= 50, "\(line)")
        }
        #expect(WatchText.confirm(.enter, name: "Claude") == "Send Enter to Claude?")
        #expect(WatchText.confirm(.interrupt, name: "Claude") == "Interrupt Claude?")
    }

    // MARK: The guard

    @Test func theGuardPassesOnlyTheWaitTheWatchShowed() {
        #expect(ActionGuard.allows(action(), current: current()))
        // No status any more, or not waiting.
        #expect(!ActionGuard.allows(action(), current: nil))
        for state in ["working", "done", "idle", "error", ""] {
            #expect(!ActionGuard.allows(action(), current: current(state: state)), "\(state)")
        }
        // Another record, even with the same words.
        #expect(!ActionGuard.allows(action(), current: current(record: "claude-2")))
        // The same record asks something else, or for another reason.
        #expect(!ActionGuard.allows(action(), current: current(message: "Run it again?")))
        #expect(!ActionGuard.allows(action(), current: current(kind: "question")))
        #expect(!ActionGuard.allows(action(), current: current(message: nil)))
    }

    @Test func theGuardNeverPassesAWaitItCannotName() {
        // An empty record id tells no two waits apart.
        var loose = Self.target
        loose.record = ""
        #expect(!ActionGuard.allows(action(target: loose), current: current(record: "")))
        var blind = Self.target
        blind.fp = ""
        #expect(!ActionGuard.allows(action(target: blind), current: current()))
    }

    @Test func theFingerprintIsStableAndTellsWaitsApart() {
        let fp = ActionGuard.fingerprint(state: "blocked", kind: "permission", message: "Run it?")
        // The same on every launch and device: the watch and the phone compare them as text.
        #expect(fp == ActionGuard.fingerprint(state: "blocked", kind: "permission", message: "Run it?"))
        #expect(fp.count == 16 && fp.allSatisfy { $0.isHexDigit })
        var seen: Set<String> = [fp]
        for other in [("blocked", "permission", "Run it? "), ("blocked", "question", "Run it?"), ("working", "permission", "Run it?"),
                      ("blocked", nil, "Run it?"), ("blocked", "permission", nil), ("blocked", "", "Run it?"), ("blocked", "permission", ""),
                      // The parts don't run into each other.
                      ("blocked", "permissionRun", " it?"), ("blockedpermission", "", "Run it?")] as [(String, String?, String?)] {
            #expect(seen.insert(ActionGuard.fingerprint(state: other.0, kind: other.1, message: other.2)).inserted, "\(other)")
        }
        #expect(current().fingerprint == fp)
    }

    @Test func theFingerprintCoversTheWholeMessageNotTheClippedOne() {
        let head = String(repeating: "a", count: GlanceSnapshot.messageLimit)
        #expect(ActionGuard.fingerprint(state: "blocked", kind: nil, message: head + "1")
            != ActionGuard.fingerprint(state: "blocked", kind: nil, message: head + "2"))
    }

    // MARK: The snapshot carries what an action needs

    @Test func anAgentWithARecordAndAFingerprintCanBeActedOn() throws {
        let snapshot = try #require(GlanceDemo.snapshot("one", now: Self.now))
        let agent = try #require(snapshot.machines.first?.waiting.first)
        let target = try #require(WatchAction.Target(server: snapshot.machines[0].id, agent: agent))
        #expect(target.block == agent.block && target.session == agent.session && target.record == agent.record)
        #expect(target.fp == ActionGuard.fingerprint(state: "blocked", kind: agent.why, message: agent.msg))
        var loose = agent
        loose.record = ""
        #expect(WatchAction.Target(server: "s", agent: loose) == nil)
        var old = agent
        old.fp = nil
        #expect(WatchAction.Target(server: "s", agent: old) == nil)
    }

    @Test func aSnapshotFromAnOlderAppHasNoFingerprintAndOffersNoAction() throws {
        // The fixture is a file as the first version wrote it.
        let url = try #require(Bundle.module.url(forResource: "snapshot-v1", withExtension: "json", subdirectory: "Fixtures"))
        let reading = GlanceReading(try Data(contentsOf: url))
        let snapshot = try #require(reading.snapshot)
        #expect(snapshot.machines.flatMap(\.waiting).allSatisfy { $0.fp == nil })
        let screen = WatchScreen(reading, now: snapshot.asOf)
        #expect(!screen.rows.isEmpty && screen.rows.allSatisfy { $0.target == nil })
    }

    @Test func theFingerprintIsAnOptionalFieldThatKeepsTheVersion() throws {
        let snapshot = try #require(GlanceDemo.snapshot("one", now: Self.now))
        let text = String(decoding: try snapshot.encoded(), as: UTF8.self)
        #expect(text.contains("\"fp\":\"") && text.contains("\"v\":1"))
        var bare = snapshot
        bare.machines[0].waiting[0].fp = nil
        #expect(!String(decoding: try bare.encoded(), as: UTF8.self).contains("\"fp\""))
        #expect(GlanceReading(try snapshot.encoded()).snapshot == snapshot)
    }

    @Test func onlyACurrentRowOffersAnAction() throws {
        func rows(_ scenario: String) throws -> [WatchScreen.Row] {
            WatchScreen(.snapshot(try #require(GlanceDemo.snapshot(scenario, now: Self.now))), now: Self.now).rows
        }
        // `aging` is under an hour old: still offered; the phone checks before it types.
        for scenario in ["one", "several", "aging"] {
            let offered = try rows(scenario)
            #expect(!offered.isEmpty && offered.allSatisfy { $0.target != nil }, "\(scenario)")
        }
        // Last known only: a machine that was down, or a snapshot over an hour old.
        for scenario in ["stale", "offline", "old"] {
            let known = try rows(scenario)
            #expect(!known.isEmpty && known.allSatisfy { $0.target == nil }, "\(scenario)")
        }
        // The row's target names its own machine.
        let two = try rows("machines")
        #expect(Set(two.compactMap(\.target?.server)).count == 2)
    }

    @Test func theSummaryCarriesTheFingerprintIntoTheSnapshot() {
        let wait = GlanceInput.Wait(session: "s", window: "w", block: "b", kind: "claude", name: "Claude", symbol: "asterisk",
                                    why: "permission", place: "", record: "r", msg: "Run it?", fp: "abc", firstSeen: nil)
        let machine = GlanceInput.Machine(id: "m", name: "M", link: .live, known: true, states: ["blocked"], waiting: [wait])
        let snapshot = GlanceSummary.snapshot(machines: [machine], palette: .standard, previous: nil, seq: 1, now: Self.now)
        #expect(snapshot.machines[0].waiting[0].fp == "abc")
    }

    // MARK: What the watch may start

    @Test func oneActionAtATimeAndNeverTwiceForAWaitThePhoneAnswered() {
        var state = WatchActionState()
        #expect(state.canAct(on: Self.target) && state.line(for: Self.target) == nil)
        let first = state.begin(.enter, on: Self.target, id: "a")
        #expect(first == WatchAction(id: "a", kind: .enter, target: Self.target))
        // A second tap while the first is on its way starts nothing.
        #expect(!state.canAct(on: Self.target))
        #expect(state.begin(.interrupt, on: Self.target, id: "b") == nil)
        #expect(state.line(for: Self.target) == WatchText.sending)
        state.finish(id: "a", .sent)
        #expect(state.phase == .done(.enter, .sent))
        #expect(state.line(for: Self.target) == "Sent Enter")
        // The watch may still show the wait (the phone sends no new snapshot from the
        // background): nothing more is offered for it.
        #expect(!state.canAct(on: Self.target))
        #expect(state.begin(.enter, on: Self.target, id: "c") == nil)
    }

    @Test func eachSettledOutcomeEndsTheWaitAndAnUnreachedOneMayBeTappedAgain() {
        for outcome in WatchActionOutcome.allCases {
            var state = WatchActionState()
            _ = state.begin(.enter, on: Self.target, id: "a")
            state.finish(id: "a", outcome)
            #expect(state.canAct(on: Self.target) == !outcome.settled, "\(outcome)")
        }
        #expect(WatchActionOutcome.allCases.filter { !$0.settled } == [.unreachable, .noPhone])
    }

    @Test func aNewWaitInTheSamePaneCanBeAnsweredAndShowsNoOldLine() {
        var state = WatchActionState()
        _ = state.begin(.enter, on: Self.target, id: "a")
        state.finish(id: "a", .sent)
        var next = Self.target
        next.record = "claude-2"
        #expect(state.canAct(on: next))
        #expect(state.line(for: next) == nil)
        // The agent stopped waiting: the line stays under "No longer waiting".
        #expect(state.line(for: nil) == "Sent Enter")
        #expect(state.begin(.interrupt, on: next, id: "b") != nil)
        #expect(state.line(for: next) == WatchText.sending)
    }

    @Test func anAnswerForAnotherActionChangesNothing() {
        var state = WatchActionState()
        _ = state.begin(.enter, on: Self.target, id: "a")
        state.finish(id: "other", .sent)
        #expect(state.phase == .sending(.enter))
        state.finish(id: "a", .noPhone)
        // A late answer for the same id doesn't overwrite the first.
        state.finish(id: "a", .sent)
        #expect(state.phase == .done(.enter, .noPhone))
    }
}
