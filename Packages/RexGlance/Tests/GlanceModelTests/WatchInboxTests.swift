import Foundation
import Testing
@testable import GlanceModel

/// The watch's file: which payload replaces it, and what a phone with an older or a newer app
/// leaves there.
@Suite struct WatchInboxTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func inbox() throws -> WatchInbox {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("watch-inbox-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return WatchInbox(store: GlanceStore(directory: dir))
    }

    private func snap(seq: Int?, at: TimeInterval, _ name: String = "one") -> GlanceSnapshot {
        var s = GlanceDemo.snapshot(name, now: now)!
        s.seq = seq
        s.asOf = now.addingTimeInterval(at)
        return s
    }

    private func payload(_ s: GlanceSnapshot) throws -> [String: Any] {
        WatchPayload.dictionary(try s.encoded())
    }

    @Test func thePayloadIsAPropertyListWithTheBytesUnderOneKey() throws {
        let data = try snap(seq: 1, at: 0).encoded()
        let p = WatchPayload.dictionary(data)
        #expect(p.keys.sorted() == ["s"])
        #expect(PropertyListSerialization.propertyList(p, isValidFor: .binary))
        #expect(WatchPayload.snapshot(in: p) == data)
        #expect(WatchPayload.snapshot(in: ["s": "text"]) == nil)
        #expect(WatchPayload.snapshot(in: [:]) == nil)
    }

    @Test func theFirstPayloadIsWritten() throws {
        let box = try inbox()
        #expect(box.receive(try payload(snap(seq: 7, at: 0)), now: now))
        #expect(box.store.read().snapshot?.seq == 7)
    }

    @Test func aHigherSeqWinsAndALateOneIsDropped() throws {
        let box = try inbox()
        #expect(box.receive(try payload(snap(seq: 7, at: -10, "several")), now: now))
        // Late: written before, arrived after.
        #expect(!box.receive(try payload(snap(seq: 6, at: -20, "one")), now: now))
        // The same again, as a complication transfer beside the context.
        #expect(!box.receive(try payload(snap(seq: 7, at: -10, "several")), now: now))
        #expect(box.store.read().snapshot?.seq == 7)
        #expect(box.receive(try payload(snap(seq: 8, at: -5)), now: now))
        #expect(box.store.read().snapshot?.seq == 8)
    }

    @Test func seqOrdersWhenThePhonesClockWentBack() throws {
        let box = try inbox()
        #expect(box.receive(try payload(snap(seq: 7, at: -10)), now: now))
        #expect(box.receive(try payload(snap(seq: 8, at: -3000)), now: now))
        #expect(box.store.read().snapshot?.seq == 8)
    }

    @Test func withoutSeqTheDateDecides() throws {
        let box = try inbox()
        #expect(box.receive(try payload(snap(seq: nil, at: -10)), now: now))
        #expect(!box.receive(try payload(snap(seq: nil, at: -20)), now: now))
        #expect(!box.receive(try payload(snap(seq: 3, at: -20)), now: now))
        #expect(box.receive(try payload(snap(seq: 3, at: -5)), now: now))
        #expect(box.receive(try payload(snap(seq: nil, at: -1)), now: now))
    }

    @Test func aFileDatedInTheWatchsFutureIsReplaced() throws {
        let box = try inbox()
        #expect(box.receive(try payload(snap(seq: 9, at: 3600)), now: now))
        // The phone's clock went back, and its count too (a late payload by both).
        #expect(box.receive(try payload(snap(seq: 2, at: -10)), now: now))
        #expect(box.store.read().snapshot?.seq == 2)
        // A clock a little ahead is no future.
        let near = try inbox()
        #expect(near.receive(try payload(snap(seq: 9, at: 60)), now: now))
        #expect(!near.receive(try payload(snap(seq: 2, at: -10)), now: now))
    }

    @Test func aCountThatStartedAgainIsTakenByItsLaterDate() throws {
        // The app was removed and installed again: `seq` restarts at 1.
        let box = try inbox()
        #expect(box.receive(try payload(snap(seq: 4182, at: -600)), now: now))
        #expect(box.receive(try payload(snap(seq: 1, at: -5)), now: now))
        #expect(box.store.read().snapshot?.seq == 1)
        // The same count with a later date is another snapshot, not the same one twice.
        #expect(box.receive(try payload(snap(seq: 1, at: -2, "several")), now: now))
        #expect(!box.receive(try payload(snap(seq: 1, at: -2, "several")), now: now))
    }

    @Test func whatIsNoSnapshotIsDropped() throws {
        let box = try inbox()
        #expect(box.receive(try payload(snap(seq: 7, at: 0)), now: now))
        #expect(!box.receive(["s": Data("not json".utf8)], now: now))
        #expect(!box.receive(["other": Data()], now: now))
        #expect(!box.receive(Data(#"{"hello":1}"#.utf8), now: now))
        #expect(box.store.read().snapshot?.seq == 7)
    }

    // MARK: Phones with another version of the app

    @Test func aNewerPhonesBreakingFileIsKeptAndReadsAsNewer() throws {
        let box = try inbox()
        #expect(box.receive(try payload(snap(seq: 7, at: 0)), now: now))
        #expect(box.receive(WatchPayload.dictionary(GlanceDemo.newerFile), now: now))
        #expect(box.store.read() == .newer)
        #expect(WatchScreen(box.store.read(), now: now).kind == .message(WatchText.open))
        // The phone's app went back to this version: its snapshot is taken again.
        #expect(box.receive(try payload(snap(seq: 8, at: 0)), now: now))
        #expect(box.store.read().snapshot?.seq == 8)
    }

    @Test func aNewerPhonesAddedFieldsAreIgnoredAndStayOnDisk() throws {
        let box = try inbox()
        var object = try #require(JSONSerialization.jsonObject(with: try snap(seq: 7, at: 0).encoded()) as? [String: Any])
        object["hostKey"] = "added later"
        object["extra"] = ["a": 1]
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(box.receive(data, now: now))
        #expect(box.store.read().snapshot?.seq == 7)
        #expect(try Data(contentsOf: box.store.file) == data)
    }

    @Test func anOlderPhonesFileWithoutLaterFieldsIsShown() throws {
        let url = try #require(Bundle.module.url(forResource: "snapshot-v1", withExtension: "json", subdirectory: "Fixtures"))
        let box = try inbox()
        #expect(box.receive(try Data(contentsOf: url), now: now))
        let reading = box.store.read()
        #expect(reading.snapshot != nil && reading.snapshot?.seq == nil)
        #expect(WatchScreen(reading, now: now).kind == .agents)
    }

    // MARK: The background task

    final class Pending: @unchecked Sendable {
        // Only this test's one task touches it.
        var left: Int
        var asked = 0
        init(_ n: Int) { left = n }
        func next() -> Bool { asked += 1; left -= 1; return left >= 0 }
    }

    @Test func theBackgroundTaskEndsOnlyWhenNothingIsPending() async {
        let p = Pending(3)
        let slept = Pending(0)
        let done = await WatchDrain.wait(pending: { p.next() }, sleep: { _ in slept.asked += 1 })
        #expect(done && p.asked == 4 && slept.asked == 3)
    }

    @Test func nothingPendingEndsItAtOnce() async {
        let slept = Pending(0)
        #expect(await WatchDrain.wait(pending: { false }, sleep: { _ in slept.asked += 1 }))
        #expect(slept.asked == 0)
    }

    @Test func aSessionThatNeverSettlesIsLeftAfterTheLimit() async {
        let slept = Pending(0)
        let done = await WatchDrain.wait(pending: { true }, sleep: { _ in slept.asked += 1 })
        #expect(!done)
        #expect(slept.asked == 50)
    }
}
