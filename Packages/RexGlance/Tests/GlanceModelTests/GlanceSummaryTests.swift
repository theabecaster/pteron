import Foundation
import Testing
@testable import GlanceModel

@Suite struct GlanceSummaryTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func wait(_ block: String, record: String = "r1", msg: String? = "Run the tests?", why: String? = "permission",
                      firstSeen: TimeInterval? = nil) -> GlanceInput.Wait {
        GlanceInput.Wait(session: "s", window: "w", block: block, kind: "claude", name: "Claude", symbol: "asterisk", why: why,
                         place: "api › tests", record: record, msg: msg, firstSeen: firstSeen.map { now.addingTimeInterval($0) })
    }

    private func machine(_ id: String = "m1", link: GlanceSnapshot.Link = .live, known: Bool = true, states: [String?] = [],
                         waiting: [GlanceInput.Wait] = []) -> GlanceInput.Machine {
        GlanceInput.Machine(id: id, name: id, link: link, known: known, states: states, waiting: waiting)
    }

    private func build(_ machines: [GlanceInput.Machine], previous: GlanceSnapshot? = nil, at: Date? = nil) -> GlanceSnapshot {
        GlanceSummary.snapshot(machines: machines, palette: .standard, previous: previous, seq: 1, now: at ?? now)
    }

    @Test func statesAreCounted() {
        let c = GlanceSummary.counts(["blocked", "working", "working", "done", "error", "idle", nil, "something new"])
        #expect(c == GlanceSnapshot.Counts(waiting: 1, error: 1, working: 2, done: 1, idle: 3))
        #expect(c.busy == 5)
    }

    @Test func waitingAgentsAreTheLongestWaitFirstAndAtMostEight() {
        let waits = (0..<12).map { wait("b\($0)", firstSeen: TimeInterval(-60 * $0)) }
        let s = build([machine(states: Array(repeating: "blocked", count: 12), waiting: waits)])
        #expect(s.machines[0].counts.waiting == 12)
        #expect(s.machines[0].waiting.map(\.block) == (4..<12).reversed().map { "b\($0)" })
        // Equal starts keep the server's order.
        let same = build([machine(waiting: [wait("x", firstSeen: -5), wait("y", firstSeen: -5), wait("z", firstSeen: -5)])])
        #expect(same.machines[0].waiting.map(\.block) == ["x", "y", "z"])
    }

    @Test func aLiveMachineIsSeenNowAndADownOneKeepsWhenItWas() {
        let first = build([machine(link: .live)])
        #expect(first.machines[0].seen == now && first.asOf == now && first.v == 1 && first.seq == 1)
        let later = now.addingTimeInterval(600)
        let down = build([machine(link: .stale, states: ["working"])], previous: first, at: later)
        #expect(down.machines[0].seen == now && down.machines[0].link == .stale && down.machines[0].counts.working == 1)
        #expect(build([machine(link: .stale)], at: later).machines[0].seen == nil)
    }

    /// A launch with a server down: the app knows nothing newer, so what was written stays.
    @Test func aMachineNotReachedYetKeepsWhatWasWritten() {
        let before = build([machine(states: ["blocked", "working"], waiting: [wait("b1", firstSeen: -300)])])
        let later = now.addingTimeInterval(3600)
        for link in [GlanceSnapshot.Link.never, .stale] {
            let s = build([machine(link: link, known: false)], previous: before, at: later)
            #expect(s.machines[0].link == .stale)
            #expect(s.machines[0].counts == before.machines[0].counts)
            #expect(s.machines[0].waiting == before.machines[0].waiting)
            #expect(s.machines[0].seen == now && s.asOf == later)
        }
        // With nothing written before, it is just not connected yet.
        let fresh = build([machine(link: .never, known: false)])
        #expect(fresh.machines[0].link == .never && fresh.machines[0].waiting.isEmpty && fresh.machines[0].seen == nil)
        // Once reached, what it says replaces what was kept.
        let reached = build([machine(link: .live, states: ["idle"])], previous: before, at: later)
        #expect(reached.machines[0].waiting.isEmpty && reached.machines[0].counts.idle == 1 && reached.machines[0].seen == later)
        // A machine that is gone from the app is gone from the file.
        #expect(build([machine("m2")], previous: before).machines.map(\.id) == ["m2"])
    }

    @Test func theDemoScenariosSayWhatTheBoardWouldSay() throws {
        func digest(_ name: String) throws -> GlanceDigest { GlanceDigest(try #require(GlanceDemo.snapshot(name, now: now)), now: now) }
        #expect(try digest("quiet").headline == .text("All quiet"))
        #expect(try digest("working").headline == .text("3 working"))
        #expect(try digest("one").headline == .text("1 waiting"))
        #expect(try digest("several").headline == .text("2 waiting"))
        #expect(try digest("many").headline == .text("11 waiting"))
        #expect(try digest("machines").headline == .text("2 waiting"))
        #expect(try digest("unpaired").kind == .unpaired)
        #expect(GlanceDemo.snapshot("none", now: now) == nil && GlanceDemo.snapshot("newer", now: now) == nil)
        for name in GlanceDemo.scenarios where !["none", "newer"].contains(name) { #expect(GlanceDemo.snapshot(name, now: now) != nil) }
    }
}

@Suite struct GlanceSinceTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func wait(record: String, msg: String?, why: String? = "question", firstSeen: TimeInterval? = 0) -> GlanceInput.Wait {
        GlanceInput.Wait(session: "s", window: "w", block: "b1", kind: "claude", name: "Claude", symbol: "asterisk", why: why,
                         place: "", record: record, msg: msg, firstSeen: firstSeen.map { now.addingTimeInterval($0) })
    }

    /// The snapshot before: block b1 on m1 has waited an hour, on record `r1`, asking "A?".
    private func before(record: String = "r1", msg: String? = "A?") -> GlanceSnapshot {
        let a = GlanceSnapshot.Agent(session: "s", window: "w", block: "b1", kind: "claude", name: "Claude", symbol: "asterisk",
                                     why: "question", place: "", since: now.addingTimeInterval(-3600), record: record, msg: msg)
        return GlanceSnapshot(seq: 1, asOf: now.addingTimeInterval(-60), palette: .standard, machines: [
            .init(id: "m1", name: "m1", link: .live, counts: .init(waiting: 1), waiting: [a], seen: nil)])
    }

    private func since(_ w: GlanceInput.Wait, server: String = "m1", previous: GlanceSnapshot?) -> TimeInterval {
        GlanceSince.since(server: server, wait: w, previous: previous, now: now).timeIntervalSince(now)
    }

    @Test func theSameWaitCarriesItsStart() {
        #expect(since(wait(record: "r1", msg: "A?"), previous: before()) == -3600)
        // And a message longer than the file keeps compares as the file kept it.
        let long = String(repeating: "x", count: 300)
        #expect(since(wait(record: "r1", msg: long), previous: before(msg: long)) == -3600)
    }

    /// Asked at 10:00, answered on the computer while the app was closed, asked again at 11:00
    /// on the same record: the second wait didn't begin at 10:00.
    @Test func aNewMessageOnTheSameRecordStartsAgain() {
        #expect(since(wait(record: "r1", msg: "B?"), previous: before()) == 0)
        #expect(since(wait(record: "r1", msg: nil), previous: before()) == 0)
        #expect(since(wait(record: "r1", msg: "A?", why: "permission"), previous: before()) == 0)
    }

    @Test func anEmptyRecordIDNeverCarries() {
        #expect(since(wait(record: "", msg: "A?"), previous: before(record: "")) == 0)
    }

    @Test func anotherRecordPaneOrServerStartsAgain() {
        #expect(since(wait(record: "r2", msg: "A?"), previous: before()) == 0)
        #expect(since(wait(record: "r1", msg: "A?"), server: "m2", previous: before()) == 0)
        var other = wait(record: "r1", msg: "A?")
        other.block = "b2"
        #expect(since(other, previous: before()) == 0)
        #expect(since(wait(record: "r1", msg: "A?"), previous: nil) == 0)
    }

    @Test func withoutACarriedStartItIsWhenThePhoneFirstSawIt() {
        #expect(since(wait(record: "r2", msg: "A?", firstSeen: -90), previous: before()) == -90)
        #expect(since(wait(record: "r2", msg: "A?", firstSeen: nil), previous: nil) == 0)
        // Never in the future, whatever the clock did.
        #expect(since(wait(record: "r2", msg: "A?", firstSeen: 500), previous: nil) == 0)
    }
}

@Suite struct GlanceFreshnessTests {
    private let asOf = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func ageDecides() {
        func at(_ s: TimeInterval) -> GlanceFreshness { GlanceFreshness(asOf: asOf, now: asOf.addingTimeInterval(s)) }
        #expect(at(0) == .fresh && at(119) == .fresh)
        #expect(at(120) == .aging && at(3599) == .aging)
        #expect(at(3600) == .stale && at(86_400 * 30) == .stale)
        // The clock was set back: a snapshot from the future is taken as fresh.
        #expect(at(-5) == .fresh && at(-86_400) == .fresh)
    }

    @Test func theTimelineHasAnEntryForEachChangeStillAhead() {
        func dates(_ s: TimeInterval) -> [TimeInterval] {
            GlanceFreshness.entryDates(asOf: asOf, now: asOf.addingTimeInterval(s)).map { $0.timeIntervalSince(asOf) }
        }
        #expect(dates(0) == [0, 120, 3600])
        #expect(dates(30) == [30, 120, 3600])
        #expect(dates(600) == [600, 3600])
        #expect(dates(7200) == [7200])
        // Dated in the future: aged from now, not from that date.
        #expect(dates(-1000) == [-1000, -880, 2600])
    }
}
