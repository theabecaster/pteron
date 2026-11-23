import Foundation
import GlanceModel
import Testing
@testable import PteronWatch

/// The watch app's model: it shows what the file holds, and works the screen out again when
/// the snapshot's age changes what is shown.
@MainActor
@Suite struct WatchModelTests {
    /// Time the test moves by hand.
    @MainActor
    final class Clock {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        private var waiting: [(until: Date, wake: CheckedContinuation<Void, Never>)] = []

        func sleep(_ seconds: TimeInterval) async {
            let until = now.addingTimeInterval(seconds)
            await withCheckedContinuation { waiting.append((until, $0)) }
        }

        func advance(by seconds: TimeInterval) async {
            for _ in 0..<20 { await Task.yield() }
            now = now.addingTimeInterval(seconds)
            let due = waiting.filter { $0.until <= now }
            waiting.removeAll { $0.until <= now }
            for sleeper in due { sleeper.wake.resume() }
            for _ in 0..<20 { await Task.yield() }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }

        func release() {
            let all = waiting
            waiting = []
            for sleeper in all { sleeper.wake.resume() }
        }
    }

    private func store() throws -> GlanceStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("watch-model-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return GlanceStore(directory: dir)
    }

    private func model(_ store: GlanceStore, _ clock: Clock) -> WatchModel {
        WatchModel(parts: .init(now: { clock.now }, sleep: { [clock] in await clock.sleep($0) })) { store.read() }
    }

    @Test func beforeTheFirstReadAndWithNoFileItAsksForTheAppOnThePhone() async throws {
        let clock = Clock()
        let m = model(try store(), clock)
        #expect(m.screen.kind == .message(WatchText.open))
        // Not shown yet: the app draws nothing until the file was read.
        #expect(!m.loaded)
        await m.reload()
        #expect(m.screen.kind == .message(WatchText.open) && m.loaded)
    }

    @Test func aDeliveryShowsAfterAReload() async throws {
        let clock = Clock(), s = try store()
        let m = model(s, clock)
        let inbox = WatchInbox(store: s)
        #expect(inbox.receive(try #require(GlanceDemo.snapshot("several", now: clock.now)).encoded(), now: clock.now))
        await m.reload()
        #expect(m.screen.kind == .agents && m.screen.rows.count == 2)
        clock.release()
    }

    @Test func anOpenAppAgesTheSnapshotByItself() async throws {
        let clock = Clock(), s = try store()
        let m = model(s, clock)
        let written = clock.now
        try s.write(try #require(GlanceDemo.snapshot("one", now: written)).encoded())
        await m.reload()
        #expect(m.screen.age == nil && !m.screen.dimmed)
        await clock.advance(by: GlanceFreshness.agingAfter)
        #expect(m.screen.age == .asOf(written))
        await clock.advance(by: GlanceFreshness.staleAfter)
        #expect(m.screen.age == .refresh && m.screen.dimmed)
        clock.release()
    }

    #if DEBUG
    @Test func aDemoWritesItsScenarioRemovesTheFileOrWritesANewerOne() throws {
        let s = try store()
        // A whole second, as the file's dates are.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        WatchDemo.write("several", to: s, now: now)
        #expect(s.read().snapshot == GlanceDemo.snapshot("several", now: now))
        WatchDemo.write("newer", to: s, now: now)
        #expect(s.read() == .newer)
        WatchDemo.write("none", to: s, now: now)
        #expect(s.read() == .missing)
    }
    #endif

    @Test func theWatchAppIsNamedAfterTheBrandAndBoundToThePhonesApp() throws {
        let info = try #require(Bundle.main.infoDictionary)
        #expect(info["CFBundleDisplayName"] as? String == Brand.appName)
        #expect(info["WKCompanionAppBundleIdentifier"] as? String == "dev.abrahamgonzalez.rexduo")
        #expect(info["WKRunsIndependentlyOfCompanionApp"] as? Bool == false)
        #expect(Bundle.main.bundleIdentifier == "dev.abrahamgonzalez.rexduo.watchkitapp")
    }
}
