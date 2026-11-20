import Foundation
import Testing
@testable import GlanceModel

@Suite struct GlanceSnapshotTests {
    private func fixture() throws -> Data {
        let url = try #require(Bundle.module.url(forResource: "snapshot-v1", withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    private func date(_ s: String) throws -> Date { try #require(ISO8601DateFormatter().date(from: s)) }

    /// The file as the first version wrote it, before `seq` and `seen` existed. It never changes.
    @Test func theFrozenV1FileStillDecodes() throws {
        let s = try #require(GlanceReading(try fixture()).snapshot)
        #expect(s.v == 1 && s.seq == nil)
        #expect(s.asOf == (try date("2026-11-19T12:04:00Z")))
        #expect(s.palette == .standard)
        let m = try #require(s.machines.first)
        #expect(m.name == "studio" && m.link == .live && m.seen == nil)
        #expect(m.counts == GlanceSnapshot.Counts(waiting: 2, error: 0, working: 3, done: 1, idle: 4))
        #expect(m.waiting.count == 2)
        #expect(m.waiting[0].kind == "claude" && m.waiting[0].why == "question" && m.waiting[0].msg == "Which database should I use?")
        #expect(m.waiting[0].since == (try date("2026-11-19T11:52:00Z")))
        // Optional values left out, and an empty record id.
        #expect(m.waiting[1].kind == nil && m.waiting[1].why == nil && m.waiting[1].msg == nil && m.waiting[1].record.isEmpty)
    }

    @Test func fieldsThisReaderDoesNotKnowAreIgnored() throws {
        var o = try #require(try JSONSerialization.jsonObject(with: try fixture()) as? [String: Any])
        o["hostKey"] = "abc"
        o["seq"] = 7
        var machines = try #require(o["machines"] as? [[String: Any]])
        machines[0]["hostKey"] = "0123"
        machines[0]["later"] = ["a": 1]
        o["machines"] = machines
        let s = try #require(GlanceReading(try JSONSerialization.data(withJSONObject: o)).snapshot)
        #expect(s.seq == 7 && s.machines[0].counts.waiting == 2)
    }

    @Test func aNewerVersionIsNotRead() throws {
        var o = try #require(try JSONSerialization.jsonObject(with: try fixture()) as? [String: Any])
        o["v"] = 2
        #expect(GlanceReading(try JSONSerialization.data(withJSONObject: o)) == .newer)
        // Whatever shape it has.
        #expect(GlanceReading(GlanceDemo.newerFile) == .newer)
        #expect(GlanceDigest(.newer, now: Date()) == .placeholder)
    }

    @Test func aMissingOrCorruptFileIsMissing() throws {
        #expect(GlanceReading(nil) == .missing)
        #expect(GlanceReading(Data()) == .missing)
        #expect(GlanceReading(Data("not json".utf8)) == .missing)
        #expect(GlanceReading(Data("[1,2]".utf8)) == .missing)
        #expect(GlanceReading(Data(#"{"v":1}"#.utf8)) == .missing)
        #expect(GlanceReading(Data(#"{"v":"1"}"#.utf8)) == .missing)
        // Cut short by a write that isn't atomic: never the case here, and not a snapshot.
        let whole = try fixture()
        #expect(GlanceReading(whole.prefix(whole.count / 2)) == .missing)
        #expect(GlanceDigest(.missing, now: Date()) == .placeholder)
    }

    @Test func itRoundTrips() throws {
        let now = try date("2026-11-19T12:00:00Z")
        for name in GlanceDemo.scenarios {
            guard let s = GlanceDemo.snapshot(name, now: now) else { continue }
            #expect(GlanceReading(try s.encoded()) == .snapshot(s), "\(name)")
        }
    }

    @Test func anUnknownLinkWordIsStale() throws {
        var o = try #require(try JSONSerialization.jsonObject(with: try fixture()) as? [String: Any])
        var machines = try #require(o["machines"] as? [[String: Any]])
        machines[0]["link"] = "sleeping"
        o["machines"] = machines
        let s = try #require(GlanceReading(try JSONSerialization.data(withJSONObject: o)).snapshot)
        #expect(s.machines[0].link == .stale)
    }

    @Test func snapshotsOrderBySeqAndByDateWithoutOne() throws {
        let t = try date("2026-11-19T12:00:00Z")
        func s(_ seq: Int?, _ offset: TimeInterval) -> GlanceSnapshot {
            GlanceSnapshot(seq: seq, asOf: t.addingTimeInterval(offset), palette: .standard, machines: [])
        }
        // The clock was set back an hour between the two writes: `seq` still orders them.
        #expect(s(5, -3600).isNewer(than: s(4, 0)))
        #expect(!s(4, 0).isNewer(than: s(5, -3600)))
        #expect(!s(5, 0).isNewer(than: s(5, 0)))
        // One has no `seq` (the frozen file): the dates decide.
        #expect(s(nil, 10).isNewer(than: s(9, 0)))
        #expect(!s(9, 0).isNewer(than: s(nil, 10)))
        #expect(s(nil, 10).isNewer(than: s(nil, 0)))
    }

    @Test func aMessageIsClipped() {
        let a = GlanceSnapshot.Agent(session: "s", window: "w", block: "b", kind: nil, name: "n", symbol: "cpu", why: nil,
                                     place: "", since: Date(), record: "", msg: String(repeating: "x", count: 500))
        #expect(a.msg?.count == GlanceSnapshot.messageLimit)
    }

    /// The file names no address and holds no secret: only these keys are ever written.
    @Test func theFileHoldsOnlyTheseKeys() throws {
        let now = try date("2026-11-19T12:00:00Z")
        let allowed: Set<String> = ["v", "seq", "asOf", "palette", "dark", "light", "appearance", "bg", "fg", "accent", "ansi",
                                    "machines", "id", "name", "link", "counts", "waiting", "error", "working", "done", "idle",
                                    "seen", "session", "window", "block", "kind", "symbol", "why", "place", "since", "record", "msg"]
        func keys(_ any: Any) -> Set<String> {
            var found = Set<String>()
            if let d = any as? [String: Any] {
                found.formUnion(d.keys)
                for v in d.values { found.formUnion(keys(v)) }
            } else if let a = any as? [Any] {
                for v in a { found.formUnion(keys(v)) }
            }
            return found
        }
        for name in GlanceDemo.scenarios {
            guard let s = GlanceDemo.snapshot(name, now: now) else { continue }
            let found = keys(try JSONSerialization.jsonObject(with: try s.encoded()))
            #expect(found.isSubset(of: allowed), "\(name): \(found.subtracting(allowed))")
        }
        for banned in ["host", "url", "token", "secret", "key"] { #expect(!allowed.contains(banned)) }
    }

    @Test func theVisibleKeyLeavesOutWhatAgesByItself() throws {
        let now = try date("2026-11-19T12:00:00Z")
        let a = try #require(GlanceDemo.snapshot("several", now: now))
        var b = a
        b.asOf = now.addingTimeInterval(900)
        b.seq = 99
        b.machines[0].seen = b.asOf
        #expect(a.visibleKey == b.visibleKey)
        var c = a
        c.machines[0].counts.working += 1
        #expect(a.visibleKey != c.visibleKey)
        var d = a
        d.machines[0].waiting.removeLast()
        #expect(a.visibleKey != d.visibleKey)
        var e = a
        e.machines[0].linkName = "stale"
        #expect(a.visibleKey != e.visibleKey)
        var f = a
        f.palette.dark = .standardLight
        #expect(a.visibleKey != f.visibleKey)
    }

    /// An agent that was answered and asks again in the same pane: the same block waits, with
    /// another question, another reason or another start. Each is another picture.
    @Test func aNewWaitInTheSamePaneChangesTheVisibleKey() throws {
        let now = try date("2026-11-19T12:00:00Z")
        let a = try #require(GlanceDemo.snapshot("several", now: now))
        var asked = a
        asked.machines[0].waiting[0].msg = "Another question"
        #expect(a.visibleKey != asked.visibleKey)
        var again = a
        again.machines[0].waiting[0].since = now
        #expect(a.visibleKey != again.visibleKey)
        var why = a
        why.machines[0].waiting[0].why = why.machines[0].waiting[0].why == "auth" ? "question" : "auth"
        #expect(a.visibleKey != why.visibleKey)
        // The same snapshot read back from its file gives the same key: nothing in it depends
        // on the process.
        #expect(GlanceReading(try a.encoded()).snapshot?.visibleKey == a.visibleKey)
    }
}
