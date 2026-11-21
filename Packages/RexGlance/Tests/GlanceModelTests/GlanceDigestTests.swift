import Foundation
import Testing
@testable import GlanceModel

@Suite struct GlanceDigestTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func digest(_ name: String, after: TimeInterval = 0) throws -> GlanceDigest {
        GlanceDigest(try #require(GlanceDemo.snapshot(name, now: now)), now: now.addingTimeInterval(after))
    }

    @Test func noSnapshotIsThePlaceholder() {
        let d = GlanceDigest(.missing, now: now)
        #expect(d.kind == .placeholder && d.headline == .text("Open \(Brand.appName)") && d.tap == .open && d.rows.isEmpty)
        #expect(d.accessory(private: false).inline == .text("Open \(Brand.appName)"))
    }

    @Test func noServersAsksToPair() throws {
        let d = try digest("unpaired")
        #expect(d.kind == .unpaired && d.headline == .text("No computers yet") && d.tap == .pair)
    }

    @Test func nobodyWaitingOpensTheAppAndSomebodyWaitingJumps() throws {
        #expect(try digest("quiet").tap == .open)
        #expect(try digest("working").tap == .open)
        #expect(try digest("one").tap == .waiting)
        let d = try digest("one")
        #expect(d.rows.count == 1 && d.rows[0].machineName == nil && d.machineLine == nil && d.glow == .waiting)
        #expect(d.rows[0].link == PaneLink(server: GlanceDemo.studio, session: "session:1", window: "window:1", block: "block:1"))
        #expect(try digest("working").glow == .working && (try digest("quiet").glow) == nil)
    }

    @Test func rowsAreTheLongestWaitFirstAcrossMachines() throws {
        let d = try digest("machines")
        #expect(d.counts.waiting == 2 && d.counts.working == 2)
        #expect(d.rows.map(\.agent.block) == ["block:1", "block:9"])
        #expect(d.rows.map(\.machineName) == ["Studio", "Laptop"])
        #expect(d.machineLine == "2 of 3 computers connected")
        #expect(d.machines.map(\.name) == ["Studio", "Laptop"])
    }

    @Test func roomRunsOutIntoMore() throws {
        let d = try digest("many")
        #expect(d.rows.count == 8 && d.unlisted == 3)
        #expect(d.shown(3).rows.count == 3 && d.shown(3).more == 8)
        #expect(d.shown(6).more == 5)
        #expect(d.shown(20).rows.count == 8 && d.shown(20).more == 3)
        // The longest wait leads.
        #expect(d.rows[0].agent.block == "block:10")
        #expect(try digest("one").shown(3).more == 0)
    }

    /// One of three is down: its agents are last known, dimmed and last, and the headline
    /// doesn't say "All quiet" over them.
    @Test func aDownMachineIsNeverShownAsCurrent() throws {
        let d = try digest("stale")
        #expect(d.headline == .lastSeen(now.addingTimeInterval(-25 * 60)) && d.urgency == .offline)
        #expect(d.counts == GlanceSnapshot.Counts(idle: 3))
        #expect(d.rows.count == 1 && d.rows[0].stale && d.rows[0].machineName == "Laptop")
        #expect(d.machines.map(\.live) == [true, true, false] && d.machines.last?.name == "Laptop")
        #expect(d.glow == nil && !d.dimmed)
        // A live machine with someone waiting still leads, and the down one's rows come after.
        var s = try #require(GlanceDemo.snapshot("stale", now: now))
        s.machines[2].counts = .init(waiting: 1)
        s.machines[2].waiting = [GlanceDemo.wait(40, "codex", "Codex", "hexagon", "Go on?", "x › y", why: "question", minutes: 1, now: now)]
        let e = GlanceDigest(s, now: now)
        #expect(e.headline == .text("1 waiting") && e.rows.map(\.stale) == [false, true])
        #expect(e.rows[0].agent.since > e.rows[1].agent.since)
    }

    @Test func allMachinesDownSaysWhenTheyWereLastSeen() throws {
        let d = try digest("offline")
        #expect(d.headline == .lastSeen(now.addingTimeInterval(-40 * 60)) && d.urgency == .offline && d.dimmed && d.glow == nil)
        #expect(d.counts == GlanceSnapshot.Counts() && d.rows.count == 1 && d.rows[0].stale)
        // Never seen, in a file from before `seen`: the write's own time.
        var s = try #require(GlanceDemo.snapshot("offline", now: now))
        s.machines[0].seen = nil
        #expect(GlanceDigest(s, now: now).headline == .lastSeen(now))
        // Not connected yet and never written: nothing to show but the way in.
        s.machines[0].linkName = "never"
        #expect(GlanceDigest(s, now: now) == .placeholder)
    }

    @Test func ageShowsAndThenDims() throws {
        #expect(try digest("several").age == .current)
        let aging = try digest("several", after: 600)
        #expect(aging.age == .asOf(now) && !aging.dimmed && aging.headline == .text("2 waiting") && aging.glow == .waiting)
        let old = try digest("several", after: 2 * 3600)
        #expect(old.age == .refresh && old.dimmed && old.glow == nil && old.headline == .text("2 waiting"))
        #expect(try digest("aging").age == .asOf(now.addingTimeInterval(-600)))
        #expect(try digest("old").age == .refresh)
    }

    /// The Lock Screen never asks to be refreshed: an old snapshot keeps its counts, dimmed,
    /// with no refresh line and no running wait time. Only the Home Screen sizes get the line.
    @Test func anOldSnapshotLeavesTheAccessoriesTheirCountsAndNoRefreshLine() throws {
        let old = try digest("several", after: 2 * 3600)
        #expect(old.age == .refresh)
        for hidden in [false, true] {
            let a = old.accessory(private: hidden)
            #expect(a.age == .current && a.dimmed && a.since == nil)
            #expect(a.hand && a.count == 2 && a.title == .text("2 waiting") && a.inline == .text("2 waiting · 3 working"))
            let said = [a.detail, a.fallback].compactMap { $0 }
            #expect(!said.contains { $0.contains("refresh") })
        }
        // Between two minutes and an hour the date still shows, and the wait still counts.
        let aging = try digest("several", after: 600).accessory(private: false)
        #expect(aging.age == .asOf(now) && !aging.dimmed && aging.since != nil)
        // Whatever the scenario and the age, no accessory is given the refresh age.
        for name in GlanceDemo.scenarios {
            let ages: [TimeInterval] = [0, 600, 7200, 259_200]
            for after in ages {
                guard let s = GlanceDemo.snapshot(name, now: now) else { continue }
                let age = GlanceDigest(s, now: now.addingTimeInterval(after)).accessory(private: false).age
                #expect(age != GlanceDigest.Age.refresh, "\(name) \(after)")
            }
        }
    }

    @Test func theTimelineAgesWithoutAReload() throws {
        let s = try #require(GlanceDemo.snapshot("several", now: now))
        let entries = GlanceTimeline.entries(.snapshot(s), now: now.addingTimeInterval(10))
        #expect(entries.map { $0.date.timeIntervalSince(now) } == [10, 120, 3600])
        #expect(entries.map(\.digest.age) == [.current, .asOf(now), .refresh])
        #expect(entries.map(\.digest.dimmed) == [false, false, true])
        #expect(GlanceTimeline.entries(.missing, now: now).map(\.digest) == [.placeholder])
        #expect(GlanceTimeline.entries(.newer, now: now).map(\.digest) == [.placeholder])
        // The clock was set back after the write: fresh now, and aged from now on.
        var future = s
        future.asOf = now.addingTimeInterval(5000)
        let later = GlanceTimeline.entries(.snapshot(future), now: now)
        #expect(later.map { $0.date.timeIntervalSince(now) } == [0, 120, 3600])
        #expect(later.map(\.digest.age) == [.current, .asOf(now), .refresh])
    }

    @Test func countsInWords() {
        #expect(GlanceDigest.words(.init(waiting: 2, error: 1, working: 3, done: 1, idle: 4)) == "2 waiting · 1 error · 3 working · 1 done · 4 idle")
        #expect(GlanceDigest.words(.init(error: 2)) == "2 errors")
        #expect(GlanceDigest.words(.init()) == "No agents")
    }

    // MARK: Privacy

    @Test func theLockScreenNeverCarriesAMessage() throws {
        for name in GlanceDemo.scenarios {
            guard let s = GlanceDemo.snapshot(name, now: now) else { continue }
            let messages = s.machines.flatMap(\.waiting).compactMap(\.msg)
            for hidden in [false, true] {
                let a = GlanceDigest(s, now: now).accessory(private: hidden)
                let said = [a.detail, a.fallback].compactMap { $0 } + [a.title, a.inline].map { h -> String in
                    if case .text(let t) = h { return t }
                    return ""
                }
                for m in messages { #expect(!said.contains { $0.contains(m) }, "\(name)") }
            }
        }
    }

    @Test func lockedItCarriesCountsOnly() throws {
        let d = try digest("several")
        let open = d.accessory(private: false)
        #expect(open.hand && open.count == 2 && open.title == .text("2 waiting"))
        #expect(open.detail == "Claude · api › tests" && open.since == now.addingTimeInterval(-12 * 60))
        #expect(open.inline == .text("2 waiting · 3 working"))
        let locked = d.accessory(private: true)
        #expect(locked.detail == nil)
        // The counts stay.
        #expect(locked.hand && locked.count == 2 && locked.title == .text("2 waiting") && locked.fallback == "3 working")
        #expect(locked.inline == .text("2 waiting · 3 working"))
        // No name and no place of any agent is left in it.
        let words = [locked.fallback ?? "", "2 waiting · 3 working"]
        for row in d.rows { for w in words { #expect(!w.contains(row.agent.name) && !w.contains(row.agent.place)) } }
    }

    @Test func withNobodyWaitingTheCircleCountsTheWorking() throws {
        let a = try digest("working").accessory(private: false)
        #expect(!a.hand && a.count == 3 && a.detail == nil && a.fallback == "3 working · 1 done · 2 idle" && a.inline == .text("3 working"))
        let q = try digest("quiet").accessory(private: false)
        #expect(!q.hand && q.count == nil && q.inline == .text("All quiet"))
        // A down machine's agent is not named as waiting now.
        let off = try digest("offline").accessory(private: false)
        #expect(!off.hand && off.count == nil && off.detail == nil && off.dimmed)
    }
}
