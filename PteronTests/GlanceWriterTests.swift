import Foundation
import GlanceModel
import Testing
@testable import Pteron

/// The snapshot's writer over a temporary directory, never an App Group container.
@MainActor
@Suite struct GlanceWriterTests {
    private func store() throws -> GlanceStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("glance-writer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return GlanceStore(directory: dir)
    }

    @MainActor
    final class World {
        let clock = TestClock()
        var reloads = 0
        var machines: [GlanceInput.Machine] = []
        var sourceReads = 0

        init() { clock.passes = false }

        var parts: GlanceWriter.Parts {
            GlanceWriter.Parts(now: { self.clock.now }, sleep: { [clock] in await clock.sleep($0) }, reload: { self.reloads += 1 })
        }

        func writer(_ store: GlanceStore?, mode: GlanceWriter.Mode = .live(only: nil)) -> GlanceWriter {
            let w = GlanceWriter(mode: mode, store: store, parts: parts)
            w.source = { self.sourceReads += 1; return self.machines }
            w.anyLive = { self.machines.contains { $0.link == .live } }
            return w
        }

        func eventually(_ done: () -> Bool) async {
            for _ in 0..<400 where !done() { try? await Task.sleep(nanoseconds: 5_000_000) }
        }

        /// Lets a timer that was just set reach its sleep, moves the clock, and lets what woke
        /// up finish.
        func pass(_ seconds: TimeInterval) async {
            for _ in 0..<20 { await Task.yield() }
            clock.advance(by: seconds)
            for _ in 0..<20 { await Task.yield() }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
    }

    private func wait(_ block: String, record: String = "r1", msg: String = "Run the tests?") -> GlanceInput.Wait {
        GlanceInput.Wait(session: "s1", window: "w1", block: block, kind: "claude", name: "Claude", symbol: "asterisk",
                         why: "permission", place: "api › tests", record: record, msg: msg, firstSeen: nil)
    }

    private func machine(waiting: [GlanceInput.Wait] = [], working: Int = 0, link: GlanceSnapshot.Link = .live) -> GlanceInput.Machine {
        GlanceInput.Machine(id: "m1", name: "Studio", link: link, known: true,
                            states: waiting.map { _ in "blocked" } + Array(repeating: "working", count: working), waiting: waiting)
    }

    // MARK: The file writer

    private func bytes(_ seq: Int) throws -> Data {
        try GlanceSnapshot(seq: seq, asOf: Date(timeIntervalSince1970: 1_800_000_000 + Double(seq)), palette: .standard, machines: []).encoded()
    }

    @Test func aHundredWritesOutOfOrderEndAsTheNewest() async throws {
        let s = try store()
        let file = SnapshotFileWriter { s }
        let payloads = try (1...100).map { ($0, try bytes($0)) }.shuffled()
        await withTaskGroup(of: Void.self) { group in
            for (seq, data) in payloads { group.addTask { await file.write(data, seq: seq) } }
        }
        #expect(s.read().snapshot?.seq == 100)
        #expect(s.lastSeq() == 100)
        // And one at a time, newest first: the older ones are dropped, not written over it.
        let t = try store()
        let other = SnapshotFileWriter { t }
        for seq in [7, 3, 9, 1, 8] { await other.write(try bytes(seq), seq: seq) }
        #expect(t.read().snapshot?.seq == 9)
    }

    /// The background flush is the newest snapshot. A write that was built before it and
    /// reaches the file writer after it must not replace it.
    @Test func anOlderWriteThatLandsAfterTheFlushIsDropped() async throws {
        let s = try store()
        let file = SnapshotFileWriter { s }
        let older = try bytes(4), flush = try bytes(5)
        await file.write(flush, seq: 5)
        await file.write(older, seq: 4)
        #expect(s.read().snapshot?.seq == 5)
    }

    // MARK: The writer

    @Test func aNewWaitingAgentIsOnDiskWithinHalfASecondAndReloadsOnce() async throws {
        let s = try store()
        let world = World()
        let w = world.writer(s)
        w.becameActive()
        world.machines = [machine(waiting: [wait("b1")], working: 2)]
        w.changed(newWaiting: true)
        #expect(s.read() == .missing)
        await world.pass(0.25)
        #expect(s.read() == .missing)
        await world.pass(0.25)
        await world.eventually { s.read() != .missing }
        let snap = try #require(s.read().snapshot)
        // Whole seconds, as the file keeps them.
        #expect(snap.seq == 1 && snap.asOf == world.clock.now.addingTimeInterval(-0.5))
        #expect(snap == w.latest)
        #expect(snap.machines[0].counts == GlanceSnapshot.Counts(waiting: 1, working: 2))
        #expect(snap.machines[0].waiting.map(\.block) == ["b1"])
        await world.eventually { world.reloads == 1 }
        #expect(world.reloads == 1)
        world.clock.release()
    }

    @Test func aChangeWithNobodyNewWaitingIsWrittenTwoSecondsLater() async throws {
        let s = try store()
        let world = World()
        let w = world.writer(s)
        w.becameActive()
        world.machines = [machine(working: 1)]
        w.changed(newWaiting: false)
        await world.pass(1.5)
        #expect(s.read() == .missing)
        await world.pass(0.5)
        await world.eventually { s.read() != .missing }
        #expect(s.read().snapshot?.machines[0].counts.working == 1)
        world.clock.release()
    }

    @Test func goingToTheBackgroundWritesAtOnceAndWaitsForTheFile() async throws {
        let s = try store()
        let world = World()
        let w = world.writer(s)
        w.becameActive()
        world.machines = [machine(waiting: [wait("b1")])]
        w.changed(newWaiting: false)
        // The two seconds are not over: the flush doesn't wait for them.
        await w.flush()
        let snap = try #require(s.read().snapshot)
        #expect(snap.seq == 1 && snap.machines[0].waiting.count == 1 && world.reloads == 1)
        // Nothing changed since: written again with a new "as of", not reloaded.
        world.clock.advance(by: 60)
        await w.flush()
        #expect(s.read().snapshot?.seq == 2 && s.read().snapshot?.asOf == world.clock.now && world.reloads == 1)
        world.clock.release()
    }

    /// A write is on its way to the file when the app goes to the background: whichever lands
    /// last, the file ends as the flush, the newest.
    @Test func aFlushDuringAWriteLeavesTheNewestOnDisk() async throws {
        let s = try store()
        let world = World()
        let w = world.writer(s)
        w.becameActive()
        world.machines = [machine(working: 1)]
        w.changed(newWaiting: true)
        for _ in 0..<20 { await Task.yield() }
        world.clock.advance(by: 0.5)
        // The timer's write and the flush now run side by side.
        world.machines = [machine(waiting: [wait("b1")], working: 1)]
        await w.flush()
        await world.pass(0)
        await world.eventually { (s.read().snapshot?.seq ?? 0) >= 2 }
        let snap = try #require(s.read().snapshot)
        #expect(snap == w.latest)
        #expect(snap.seq == s.lastSeq())
        world.clock.release()
    }

    @Test func seqKeepsCountingAcrossWritersAndLaunches() async throws {
        let s = try store()
        for expected in 1...3 {
            let world = World()
            let w = world.writer(s)
            world.machines = [machine(working: expected)]
            await w.flush()
            #expect(s.read().snapshot?.seq == expected)
            world.clock.release()
        }
        // The snapshot was lost; the count goes on.
        s.remove()
        let world = World()
        await world.writer(s).flush()
        #expect(s.read().snapshot?.seq == 4)
    }

    /// The file isn't read when the writer is made (before the first unlock it couldn't be),
    /// only at the first write, where the wait's start and the count carry on from it.
    @Test func theSnapshotBeforeIsReadAtTheFirstWriteNotAtInit() async throws {
        let s = try store()
        let world = World()
        let began = world.clock.now.addingTimeInterval(-3600)
        let agent = GlanceSnapshot.Agent(session: "s1", window: "w1", block: "b1", kind: "claude", name: "Claude", symbol: "asterisk",
                                         why: "permission", place: "api › tests", since: began, record: "r1", msg: "Run the tests?")
        let before = GlanceSnapshot(seq: 41, asOf: world.clock.now.addingTimeInterval(-600), palette: .standard, machines: [
            .init(id: "m1", name: "Studio", link: .live, counts: .init(waiting: 1), waiting: [agent], seen: nil)])
        try s.write(try before.encoded())
        let w = world.writer(s)
        for _ in 0..<20 { await Task.yield() }
        #expect(w.latest == nil && world.sourceReads == 0)
        #expect(s.read() == .snapshot(before))
        world.machines = [machine(waiting: [wait("b1")])]
        await w.flush()
        let snap = try #require(s.read().snapshot)
        #expect(snap.seq == 42)
        // The same wait: it began when the snapshot before says.
        #expect(snap.machines[0].waiting[0].since == began)
        // A new question on the same record began now.
        world.machines = [machine(waiting: [wait("b1", msg: "Another question?")])]
        await w.flush()
        #expect(s.read().snapshot?.machines[0].waiting[0].since == world.clock.now)
        world.clock.release()
    }

    /// The App Group's container is looked up at the first write, never at launch, and a
    /// timer is set without building the rows.
    @Test func theStoreIsFoundAtTheFirstWriteAndSettingATimerBuildsNoRows() async throws {
        let s = try store()
        let world = World()
        final class Asked: @unchecked Sendable { var count = 0 }
        let asked = Asked()
        let w = GlanceWriter(mode: .live(only: nil), parts: world.parts) { asked.count += 1; return s }
        w.source = { world.sourceReads += 1; return world.machines }
        var liveAsked = 0
        w.anyLive = { liveAsked += 1; return true }
        world.machines = [machine(waiting: [wait("b1")])]
        w.becameActive()
        w.changed(newWaiting: true)
        for _ in 0..<20 { await Task.yield() }
        #expect(asked.count == 0 && world.sourceReads == 0 && liveAsked > 0)
        await w.flush()
        #expect(asked.count == 1 && s.read().snapshot != nil)
        await w.flush()
        #expect(asked.count == 1)
        world.clock.release()
    }

    @Test func itRestampsWhileActiveAndLiveOnly() async throws {
        let s = try store()
        let world = World()
        let w = world.writer(s)
        w.becameActive()
        world.machines = [machine(working: 1)]
        w.changed(newWaiting: false)
        await world.pass(2)
        await world.eventually { s.read().snapshot?.seq == 1 }
        await world.pass(899)
        #expect(s.read().snapshot?.seq == 1)
        await world.pass(1)
        await world.eventually { s.read().snapshot?.seq == 2 }
        #expect(s.read().snapshot?.seq == 2 && s.read().snapshot?.asOf == world.clock.now)
        await world.eventually { world.reloads == 2 }
        #expect(world.reloads == 2)
        // No machine live: nothing is restamped.
        world.machines = [machine(working: 1, link: .stale)]
        w.changed(newWaiting: false)
        await world.pass(2)
        await world.eventually { s.read().snapshot?.seq == 3 }
        await world.pass(2000)
        #expect(s.read().snapshot?.seq == 3)
        world.clock.release()
    }

    // MARK: Off

    private func defaults(_ values: [String: Any]) throws -> UserDefaults {
        let suite = "glance-mode-\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: suite))
        d.removePersistentDomain(forName: suite)
        for (k, v) in values { d.set(v, forKey: k) }
        return d
    }

    @Test func theWriterIsOffInTheTestHostAndInEveryTestLaunch() throws {
        #expect(GlanceWriter.Mode.current(defaults: try defaults([:]), testHost: true) == .off)
        #expect(GlanceWriter.Mode.current(defaults: try defaults([:]), testHost: false) == .live(only: nil))
        for key in ["servers", "boardDemo", "autoOpen", "simulateOffline"] {
            #expect(GlanceWriter.Mode.current(defaults: try defaults([key: "x"]), testHost: false) == .off, "\(key)")
        }
        #expect(GlanceWriter.Mode.current(defaults: try defaults(["simulateOffline": "noInternet", "autoOpen": "zz-none"]), testHost: false) == .off)
        // The host of these tests itself.
        #expect(GlanceWriter.Mode.current() == .off)
        #if DEBUG
        // A test launch may ask to write, and then only its own session's agents.
        #expect(GlanceWriter.Mode.current(defaults: try defaults(["autoOpen": "zz-test", "glanceLive": true]), testHost: false) == .live(only: "zz-test"))
        #expect(GlanceWriter.Mode.current(defaults: try defaults(["servers": "x", "glanceLive": true]), testHost: false) == .off)
        #expect(GlanceWriter.Mode.current(defaults: try defaults(["glanceLive": true]), testHost: true) == .off)
        #expect(GlanceWriter.Mode.current(defaults: try defaults(["glanceDemo": "several", "autoOpen": "zz-none"]), testHost: false) == .demo("several"))
        #expect(GlanceWriter.Mode.current(defaults: try defaults(["glanceDemo": "several"]), testHost: true) == .off)
        #endif
    }

    @Test func anOffWriterWritesNothing() async throws {
        let s = try store()
        let world = World()
        world.machines = [machine(waiting: [wait("b1")])]
        for w in [world.writer(s, mode: .off), world.writer(nil), world.writer(s, mode: .demo("several"))] {
            w.becameActive()
            w.changed(newWaiting: true)
            await world.pass(5)
            await w.flush()
            #expect(await w.current() == nil || w.mode != .off)
        }
        #expect(s.read() == .missing && world.reloads == 0 && world.sourceReads == 0)
        #expect(world.clock.sleeps.isEmpty)
    }

    #if DEBUG
    @Test func aDemoLaunchWritesItsScenarioOnce() async throws {
        let s = try store()
        let world = World()
        await world.writer(s, mode: .demo("several")).writeDemo()
        #expect(s.read().snapshot == GlanceDemo.snapshot("several", now: world.clock.now) && world.reloads == 1)
        await world.writer(s, mode: .demo("newer")).writeDemo()
        #expect(s.read() == .newer)
        await world.writer(s, mode: .demo("none")).writeDemo()
        #expect(s.read() == .missing)
        // Only a demo launch writes a demo.
        await world.writer(s).writeDemo()
        #expect(s.read() == .missing)
    }
    #endif

    @Test func theAppReloadsTheKindTheExtensionDeclares() {
        #expect(GlanceKind.agents == "dev.abrahamgonzalez.rexduo.widget.agents")
        #expect(GlanceStore.appGroup == "group.dev.abrahamgonzalez.rexduo")
    }
}
