import Foundation
import Testing
@testable import GlanceModel

/// The agents that don't wait (`busy`), which the Home Screen widgets draw as a strip of tiles:
/// how the app keeps them, how every reader takes them, what the digest makes of them, and
/// what they must not change.
@Suite struct GlanceTilesTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func digest(_ name: String) throws -> GlanceDigest {
        GlanceDigest(try #require(GlanceDemo.snapshot(name, now: now)), now: now)
    }

    /// The same file with every machine's `busy` taken out: what an older app wrote.
    private func withoutBusy(_ data: Data) throws -> Data {
        var o = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let machines = try #require(o["machines"] as? [[String: Any]])
        o["machines"] = machines.map { m in m.filter { $0.key != "busy" } }
        return try JSONSerialization.data(withJSONObject: o)
    }

    // MARK: Hazard 2: every reader decodes the file with and without it

    @Test func theWidgetAndTheWatchReadTheFileWithAndWithoutBusy() throws {
        for name in GlanceDemo.scenarios {
            guard let s = GlanceDemo.snapshot(name, now: now) else { continue }
            let with = try s.encoded()
            let without = try withoutBusy(with)
            // The widget's reader.
            let a = try #require(GlanceReading(with).snapshot, "\(name)")
            let b = try #require(GlanceReading(without).snapshot, "\(name)")
            #expect(a == s, "\(name)")
            #expect(b.machines.allSatisfy { $0.busy == nil }, "\(name)")
            // The watch's: the same screen either way, and the inbox takes both.
            #expect(WatchScreen(.snapshot(a), now: now) == WatchScreen(.snapshot(b), now: now), "\(name)")
            #expect(WatchInbox.accepts(GlanceReading(with), over: .missing, now: now), "\(name)")
            #expect(WatchInbox.accepts(GlanceReading(without), over: .missing, now: now), "\(name)")
            // The widget's headline, counts, rows and links don't depend on it.
            let da = GlanceDigest(a, now: now), db = GlanceDigest(b, now: now)
            #expect(da.headline == db.headline && da.counts == db.counts && da.rows == db.rows && da.tap == db.tap, "\(name)")
            #expect(da.accessory(private: false) == db.accessory(private: false), "\(name)")
            #expect(!db.listsAgents && db.tiles.allSatisfy { $0.state == .waiting }, "\(name)")
        }
    }

    /// A reader built before `busy` existed: the shape of a machine as main had it.
    private struct OldSnapshot: Decodable {
        struct Machine: Decodable {
            var id, name, link: String
            var counts: GlanceSnapshot.Counts
            var waiting: [GlanceSnapshot.Agent]
            var seen: Date?
        }
        var v: Int
        var seq: Int?
        var asOf: Date
        var machines: [Machine]
    }

    @Test func anOlderBuildReadsTheNewFile() throws {
        let s = try #require(GlanceDemo.snapshot("several", now: now))
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        let old = try d.decode(OldSnapshot.self, from: try s.encoded())
        #expect(old.v == GlanceSnapshot.version && old.machines.map(\.counts) == s.machines.map(\.counts))
        #expect(old.machines[0].waiting == s.machines[0].waiting)
        // Adding `busy` kept the version: an older reader shows the file, not its placeholder.
        #expect(GlanceSnapshot.version == 1)
    }

    // MARK: Hazard 3: the size

    private func input(_ id: String, busy: Int) -> GlanceInput.Machine {
        let states = ["idle", "done", "working", "error", "idle", "working", "bogus", nil]
        let kinds = ["claude", "codex", "opencode", nil, "gemini"]
        let list = (0..<busy).map { i in
            GlanceSnapshot.Busy(kind: kinds[i % kinds.count], symbol: kinds[i % kinds.count] == nil ? "terminal" : "asterisk",
                                state: states[i % states.count])
        }
        return GlanceInput.Machine(id: id, name: "machine \(id)", link: .live, known: true, states: list.map(\.state), waiting: [],
                                   busy: list)
    }

    @Test func theAppKeepsTwelveAgentsOverAllMachinesTheMostUrgentFirst() throws {
        let ids = (1...3).map { "00000000-0000-0000-0000-00000000000\($0)" }
        let s = GlanceSummary.snapshot(machines: ids.map { input($0, busy: 40) }, palette: .standard, previous: nil, seq: 1, now: now)
        let all = s.machines.flatMap { $0.busy ?? [] }
        #expect(all.count == GlanceSnapshot.busyLimit)
        // Each machine's list is in the order of urgency, and nothing less urgent is kept while
        // something more urgent was left out.
        for m in s.machines {
            let ranks = (m.busy ?? []).map(\.rank)
            #expect(ranks == ranks.sorted())
        }
        let kept = all.map(\.rank).max() ?? 0
        let errors = 3 * (0..<40).filter { $0 % 8 == 3 }.count
        #expect(errors == 15 && kept == 0 && all.allSatisfy { $0.state == "error" })
        // An unknown word is idle.
        #expect(GlanceSnapshot.Busy(kind: nil, symbol: "terminal", state: "bogus").state == "idle")
        #expect(GlanceSnapshot.Busy(kind: nil, symbol: "terminal", state: nil).state == "idle")
    }

    @Test func aMachineTheAppHasNotReachedKeepsItsTiles() throws {
        let before = GlanceSummary.snapshot(machines: [input("a", busy: 3)], palette: .standard, previous: nil, seq: 1, now: now)
        var down = input("a", busy: 0)
        down.known = false
        let after = GlanceSummary.snapshot(machines: [down], palette: .standard, previous: before, seq: 2, now: now)
        #expect(after.machines[0].busy == before.machines[0].busy && after.machines[0].link == .stale)
    }

    @Test func atItsLargestBusyAddsUnderOneKilobyteAndTheFileStaysUnderFour() throws {
        // The longest kind and symbol the app writes, in every state, on many machines.
        let long = GlanceSnapshot.Busy(kind: "opencode", symbol: "asterisk", state: "working")
        let ids = (1...6).map { "00000000-0000-0000-0000-00000000000\($0)" }
        let machines = ids.map { id in
            GlanceInput.Machine(id: id, name: "studio", link: .live, known: true, states: Array(repeating: "working", count: 50),
                                waiting: [], busy: Array(repeating: long, count: 50))
        }
        let full = GlanceSummary.snapshot(machines: machines, palette: .standard, previous: nil, seq: 1, now: now)
        var bare = full
        for i in bare.machines.indices { bare.machines[i].busy = nil }
        let added = try full.encoded().count - (try bare.encoded().count)
        #expect(full.machines.flatMap { $0.busy ?? [] }.count == 12)
        #expect(added < 1024, "\(added) bytes")
        #expect(added / 12 <= 64, "\(added / 12) bytes an entry")
        // The demo snapshots, which hold waiting agents with their messages, with twelve listed.
        for name in GlanceDemo.scenarios {
            guard var s = GlanceDemo.snapshot(name, now: now), !s.machines.isEmpty else { continue }
            s.machines[0].busy = Array(repeating: long, count: 12)
            #expect(try s.encoded().count < 4096, "\(name)")
        }
    }

    // MARK: Hazard 6: no new reloads

    @Test func theTilesAddNoReload() throws {
        var a = try #require(GlanceDemo.snapshot("several", now: now))
        var b = a
        b.machines[0].busy = GlanceDemo.busy("gemini:error claude:working")
        #expect(a.visibleKey == b.visibleKey)
        a.machines[0].busy = nil
        #expect(a.visibleKey == b.visibleKey)
    }

    // MARK: Hazard 7: the links

    @Test func aWaitingTileOpensItsPaneAndNoOtherTileHasALink() throws {
        for name in GlanceDemo.scenarios {
            guard let s = GlanceDemo.snapshot(name, now: now) else { continue }
            let d = GlanceDigest(s, now: now)
            let waiting = d.tiles.filter { $0.state == .waiting }
            #expect(waiting.map(\.link) == d.rows.map(\.link), "\(name)")
            #expect(waiting.map(\.id) == d.rows.map(\.id), "\(name)")
            #expect(d.tiles.filter { $0.state != .waiting }.allSatisfy { $0.link == nil }, "\(name)")
        }
        // Where a tap on the widget goes is what it was.
        let taps: [String: DeepLink] = ["quiet": .open, "working": .open, "error": .open, "empty": .open, "one": .waiting,
                                        "several": .waiting, "many": .waiting, "stale": .waiting, "unpaired": .pair]
        for (name, link) in taps { #expect(try digest(name).tap == link, "\(name)") }
        #expect(GlanceDigest.placeholder.tap == .open)
    }

    // MARK: What the digest makes of them

    @Test func theTilesGoWaitingThenErrorWorkingDoneIdle() throws {
        let d = try digest("several")
        #expect(d.listsAgents && d.agents == 11)
        #expect(d.tiles.map(\.state) == [.waiting, .waiting, .error, .working, .working, .working, .done, .quiet, .quiet, .quiet, .quiet])
        #expect(d.tiles.prefix(2).map(\.symbol) == ["asterisk", "cpu"])
        // A shell has no kind: the widget draws it as a rounded square.
        #expect(d.tiles.contains { $0.kind == nil && $0.symbol == "terminal" })
        // Over machines: the most urgent first wherever it is; a down machine's last, dimmed.
        let m = try digest("machines")
        #expect(m.tiles.map(\.state) == [.waiting, .waiting, .working, .working, .done])
        let stale = try digest("stale")
        #expect(stale.tiles.map(\.state) == [.waiting, .quiet, .quiet, .quiet, .done])
        #expect(stale.tiles.map(\.stale) == [true, false, false, false, true])
    }

    @Test func aStripShowsWhatFitsAndCountsTheRest() throws {
        let d = try digest("several")
        // The top row is drawn as a row; the strip has the other ten, and room for eight.
        let (tiles, more) = d.strip(after: 1, limit: 8)
        #expect(tiles.count == 7 && more == 3)
        #expect(tiles.first?.state == .waiting)
        // Everything fits: no "+N".
        let q = try digest("quiet")
        #expect(q.strip(after: 0, limit: 8).tiles.count == 4 && q.strip(after: 0, limit: 8).more == 0)
        // More agents than the snapshot lists: "+N" counts them all.
        let long = try digest("long")
        #expect(long.agents == 181 && long.tiles.count == 13)
        let s = long.strip(after: 1, limit: 8)
        #expect(s.tiles.count == 7 && s.more == 173)
        // Exactly the limit: all shown.
        #expect(q.strip(after: 0, limit: 4).tiles.count == 4 && q.strip(after: 0, limit: 4).more == 0)
        #expect(q.strip(after: 0, limit: 3).tiles.count == 2 && q.strip(after: 0, limit: 3).more == 2)
    }

    @Test func theCalmLineSaysWhatIsQuiet() throws {
        #expect(GlanceDigest.placeholder.calmLine == "Open \(Brand.appName)")
        #expect(try digest("unpaired").calmLine == "Pair a computer")
        #expect(try digest("quiet").calmLine == "All quiet · 4 idle")
        let empty = try digest("empty")
        #expect(empty.noAgents && empty.calmLine == "No agents running" && empty.headline == .text("All quiet"))
        for name in ["working", "error", "one", "several", "offline"] { #expect(try digest(name).calmLine == nil, "\(name)") }
        // A down machine's agents are never called quiet.
        #expect(try !digest("offline").noAgents)
    }
}
