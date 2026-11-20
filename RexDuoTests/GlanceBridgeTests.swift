import Foundation
import GlanceModel
import RexKit
import Testing
@testable import RexDuo

/// The bridge to the watch, against a stand-in session: it activates without asking first,
/// sends only to a watch that can take it, gives a session that opens the newest snapshot, and
/// lets go of a held change when the app leaves.
@MainActor
@Suite struct GlanceBridgeTests {
    @MainActor
    final class FakeLink: WatchLink {
        var onEvent: (@MainActor (WatchLinkEvent) -> Void)?
        var isSupported = true
        var isActivated = false
        var isPaired = false
        var isWatchAppInstalled = false
        var isComplicationEnabled = false
        var transfersLeft = 0
        var refuses = false
        /// Every call, in order.
        var calls: [String] = []
        var contexts: [Data] = []
        var transfers: [Data] = []

        func activate() { calls.append("activate") }

        func update(context: [String: Any]) throws {
            calls.append("context")
            if refuses { throw CocoaError(.featureUnsupported) }
            contexts.append(WatchPayload.snapshot(in: context) ?? Data())
        }

        func transferComplication(_ info: [String: Any]) {
            calls.append("transfer")
            transfers.append(WatchPayload.snapshot(in: info) ?? Data())
        }

        /// A paired watch with the app, activated.
        func open() {
            isActivated = true
            isPaired = true
            isWatchAppInstalled = true
            onEvent?(.activated)
        }
    }

    @MainActor
    final class World {
        let clock = TestClock()
        let link = FakeLink()
        var made = 0
        lazy var bridge = GlanceBridge(parts: .init(now: { self.clock.now }, sleep: { [clock] in await clock.sleep($0) })) {
            self.made += 1
            return self.link
        }

        init() { clock.passes = false }

        func snap(_ name: String, seq: Int) -> (GlanceSnapshot, Data) {
            var s = GlanceDemo.snapshot(name, now: Date(timeIntervalSince1970: 1_800_000_000))!
            s.asOf = clock.now
            s.seq = seq
            return (s, try! s.encoded())
        }

        func write(_ name: String, seq: Int, leaving: Bool = false) -> Data {
            let (s, data) = snap(name, seq: seq)
            bridge.wrote(s, data: data, leaving: leaving)
            return data
        }

        func pass(_ seconds: TimeInterval) async {
            for _ in 0..<20 { await Task.yield() }
            clock.advance(by: seconds)
            for _ in 0..<20 { await Task.yield() }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
    }

    @Test func theSessionIsNotMadeBeforeTheFirstSnapshot() {
        let world = World()
        _ = world.bridge
        #expect(world.made == 0 && world.link.calls.isEmpty)
    }

    @Test func itActivatesAtTheFirstSnapshotWithoutAskingAnythingFirst() {
        let world = World()
        _ = world.write("one", seq: 1)
        #expect(world.made == 1 && world.link.calls == ["activate"])
        _ = world.write("several", seq: 2)
        #expect(world.made == 1 && world.link.calls == ["activate"])
    }

    @Test func aDeviceWithNoSessionIsLeftAlone() {
        let world = World()
        world.link.isSupported = false
        _ = world.write("one", seq: 1)
        #expect(world.link.calls.isEmpty && world.link.onEvent == nil)
    }

    @Test func nothingIsSentWhileNotActivatedNotPairedOrNotInstalled() {
        for missing in 0..<3 {
            let world = World()
            _ = world.write("one", seq: 1)
            world.link.isActivated = missing != 0
            world.link.isPaired = missing != 1
            world.link.isWatchAppInstalled = missing != 2
            world.link.onEvent?(.activated)
            _ = world.write("several", seq: 2)
            _ = world.write("several", seq: 3, leaving: true)
            #expect(world.link.calls == ["activate"], "missing \(missing)")
        }
    }

    @Test func theNewestSnapshotGoesWhenActivationEnds() {
        let world = World()
        _ = world.write("one", seq: 1)
        let newest = world.write("several", seq: 2)
        world.link.open()
        #expect(world.link.contexts == [newest])
    }

    @Test func theStateGoesWhenTheWatchAppGetsInstalled() {
        let world = World()
        let data = world.write("one", seq: 1)
        world.link.isActivated = true
        world.link.isPaired = true
        world.link.onEvent?(.activated)
        #expect(world.link.contexts.isEmpty)
        world.link.isWatchAppInstalled = true
        world.link.onEvent?(.watchChanged)
        #expect(world.link.contexts == [data])
        // Another change of the watch's state (a complication was added) sends nothing again.
        world.link.onEvent?(.watchChanged)
        #expect(world.link.contexts == [data])
    }

    @Test func aChangeInWhoWaitsGoesAtOnceAndTheNextIsHeldForTheGap() async {
        let world = World()
        world.link.open()
        let quiet = world.write("quiet", seq: 1)
        #expect(world.link.contexts == [quiet])
        await world.pass(WatchDelivery.urgentGap)
        let one = world.write("one", seq: 2)
        #expect(world.link.contexts == [quiet, one])
        // Another agent waits five seconds later: held, then sent when the gap is over.
        await world.pass(5)
        let two = world.write("several", seq: 3)
        #expect(world.link.contexts == [quiet, one])
        await world.pass(WatchDelivery.urgentGap - 5)
        #expect(world.link.contexts == [quiet, one, two])
        world.clock.release()
    }

    @Test func aHeldChangeGoesWhenTheAppLeaves() async {
        let world = World()
        world.link.open()
        let quiet = world.write("quiet", seq: 1)
        await world.pass(3)
        _ = world.write("working", seq: 2)
        #expect(world.link.contexts == [quiet])
        let leaving = world.write("working", seq: 3, leaving: true)
        #expect(world.link.contexts == [quiet, leaving])
        // The timer that held it sends nothing more.
        await world.pass(120)
        #expect(world.link.contexts == [quiet, leaving])
        world.clock.release()
    }

    @Test func leavingWithNothingNewSendsNothing() {
        let world = World()
        world.link.open()
        let one = world.write("one", seq: 1)
        _ = world.write("one", seq: 2, leaving: true)
        #expect(world.link.contexts == [one])
    }

    @Test func aComplicationTransferNeedsAFaceAndBudget() {
        let world = World()
        world.link.isComplicationEnabled = true
        world.link.transfersLeft = 1
        world.link.open()
        let one = world.write("one", seq: 1)
        #expect(world.link.contexts == [one] && world.link.transfers == [one])
        #expect(world.link.calls == ["activate", "context", "transfer"])

        let none = World()
        none.link.open()
        _ = none.write("one", seq: 1)
        #expect(none.link.transfers.isEmpty)

        let spent = World()
        spent.link.isComplicationEnabled = true
        spent.link.open()
        _ = spent.write("one", seq: 1)
        #expect(spent.link.contexts.count == 1 && spent.link.transfers.isEmpty)
    }

    @Test func switchingWatchesStopsThenActivatesAgainAndSendsTheState() async {
        let world = World()
        world.link.open()
        let one = world.write("one", seq: 1)
        world.link.isActivated = false
        world.link.onEvent?(.inactive)
        _ = world.write("several", seq: 2)
        #expect(world.link.contexts == [one])
        world.link.onEvent?(.deactivated)
        #expect(world.link.calls.last == "activate")
        let newest = world.write("several", seq: 3)
        world.link.open()
        #expect(world.link.contexts == [one, newest])
    }

    @Test func aRefusedSendIsTriedAgainWhenTheGapIsOver() async {
        let world = World()
        world.link.open()
        world.link.refuses = true
        let one = world.write("one", seq: 1)
        #expect(world.link.contexts.isEmpty)
        world.link.refuses = false
        await world.pass(WatchDelivery.urgentGap)
        #expect(world.link.contexts == [one])
        world.clock.release()
    }

    @Test func whatIsSentIsTheFilesBytesUnderOneKey() {
        let world = World()
        world.link.open()
        let data = world.write("several", seq: 4)
        #expect(world.link.contexts == [data])
        #expect(GlanceReading(data).snapshot?.seq == 4)
    }

    #if DEBUG
    @Test func aDemoGoesAsItIsOnceTheSessionCanDeliver() {
        let world = World()
        world.bridge.wroteDemo(GlanceDemo.newerFile)
        #expect(world.link.calls == ["activate"])
        world.link.open()
        #expect(world.link.contexts == [GlanceDemo.newerFile])
    }
    #endif

    // MARK: The writer hands every written snapshot on

    @Test func theWriterHandsOnEachWriteAndSaysWhenTheAppLeaves() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("glance-bridge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = GlanceStore(directory: dir)
        var got: [(seq: Int?, bytes: Data, leaving: Bool)] = []
        let writer = GlanceWriter(mode: .live(only: nil), store: store, parts: .init(wrote: { s, d, leaving in got.append((s.seq, d, leaving)) }))
        await writer.flush()
        #expect(got.count == 1 && got[0].leaving && got[0].seq == 1)
        #expect(try Data(contentsOf: store.file) == got[0].bytes)
        // A writer that is off hands nothing on.
        var off = 0
        let quiet = GlanceWriter(mode: .off, store: store, parts: .init(wrote: { _, _, _ in off += 1 }))
        quiet.changed(newWaiting: true)
        await quiet.flush()
        #expect(off == 0)
    }

    @Test func aTestHostsModelNeverTouchesTheSession() {
        // The app's own bridge is made with the model and stays idle: no snapshot is written here.
        let model = AppModel(prefs: Prefs(defaults: UserDefaults(suiteName: "bridge-\(UUID().uuidString)")!), connect: false)
        #expect(model.glance.mode == .off)
        _ = model.bridge
    }

    // MARK: The watch's words are the app's

    @Test func theWatchSaysWhatAnAgentWaitsForAsTheSidebarDoes() {
        for why in ["permission", "question", "auth", "other", nil] as [String?] {
            var o: JSONObject = ["state": "blocked"]
            if let why { o["kind"] = why }
            #expect(WatchScreen.words(why: why) == AgentRowLabel.stateText(ProgramStatus(o)), "\(why ?? "nil")")
        }
    }
}
