import Foundation
import Testing
@testable import GlanceModel

/// Every test has its own temporary directory: none touches an App Group container.
@Suite struct GlanceStoreTests {
    private func store() throws -> GlanceStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("glance-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return GlanceStore(directory: dir)
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func nothingWrittenIsMissing() throws {
        let s = try store()
        #expect(s.read() == .missing)
        #expect(s.lastSeq() == 0)
        #expect(s.file.path.hasSuffix("glance/snapshot.json"))
        #expect(!s.directory.path.contains("group."))
    }

    @Test func itReadsBackWhatWasWrittenAndReplacesItWhole() throws {
        let s = try store()
        let a = try #require(GlanceDemo.snapshot("several", now: now))
        try s.write(try a.encoded())
        #expect(s.read() == .snapshot(a))
        let b = try #require(GlanceDemo.snapshot("quiet", now: now))
        try s.write(try b.encoded())
        #expect(s.read() == .snapshot(b))
        // Only the snapshot and nothing left behind by the atomic write.
        #expect(try FileManager.default.contentsOfDirectory(atPath: s.file.deletingLastPathComponent().path) == ["snapshot.json"])
        s.remove()
        #expect(s.read() == .missing)
        s.remove()
    }

    @Test func aCorruptOrNewerFileIsNotASnapshot() throws {
        let s = try store()
        try s.write(Data("{ half".utf8))
        #expect(s.read() == .missing)
        try s.write(GlanceDemo.newerFile)
        #expect(s.read() == .newer)
    }

    @Test func theCounterOutlivesTheSnapshot() throws {
        let s = try store()
        s.saveSeq(41)
        #expect(s.lastSeq() == 41)
        // A snapshot with a higher number than the counter (the counter was lost) wins.
        var snap = try #require(GlanceDemo.snapshot("quiet", now: now))
        snap.seq = 90
        try s.write(try snap.encoded())
        #expect(s.lastSeq() == 90)
        s.saveSeq(91)
        s.remove()
        #expect(s.lastSeq() == 91)
        #expect(GlanceStore(directory: s.directory).lastSeq() == 91)
    }
}
