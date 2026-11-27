import XCTest
@testable import RexKit

/// The archive writer and reader, the upload plan's walk, and the paths that are safe to write.
final class TarTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("tar-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ path: String, _ data: Data = Data("x".utf8)) throws {
        let url = dir.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private func mkdir(_ path: String) throws {
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(path), withIntermediateDirectories: true)
    }

    /// The whole archive of a plan, read in pieces of `piece` bytes.
    private func archive(_ plan: TarPlan, piece: Int = 7_000) throws -> Data {
        let s = TarStream(plan)
        var out = Data()
        while true {
            let d = try s.next(upTo: piece)
            if d.isEmpty { break }
            XCTAssertLessThanOrEqual(d.count, piece)
            out.append(d)
        }
        return out
    }

    /// The entries and file bytes of an archive, fed in pieces of `piece` bytes.
    private func read(_ data: Data, piece: Int = 997) throws -> (entries: [TarEntry], files: [String: Data], finished: Bool) {
        var entries: [TarEntry] = []
        var files: [String: Data] = [:]
        var current: String?
        var reader = TarReader { e in
            switch e {
            case .begin(let entry):
                entries.append(entry)
                current = entry.kind == .file ? entry.path : nil
                if let current { files[current] = Data() }
            case .bytes(let d): if let current { files[current]!.append(d) }
            case .end: current = nil
            }
        }
        var i = 0
        while i < data.count {
            try reader.feed(data.subdata(in: i..<min(i + piece, data.count)))
            i += piece
        }
        try reader.finish()
        return (entries, files, reader.finished)
    }

    // MARK: Writer and reader

    func testATreeGoesAndComesBackWithUnicodeLongPathsAndEmptyFolders() throws {
        let long = String(repeating: "d", count: 90) + "/" + String(repeating: "é", count: 80)
        try write("Fold/a.txt", Data("hello\n".utf8))
        try mkdir("Fold/empty")
        try write("Fold/ünï cødé 😀/\(long).bin", Data((0..<70_000).map { UInt8($0 % 251) }))
        try write("Fold/.hidden", Data())
        let plan = try TarPlan.build([.init(url: dir.appendingPathComponent("Fold"), name: "Fold")])
        XCTAssertEqual(plan.roots, 1)
        // Fold, a.txt, empty, the Unicode folder, its long folder, the file, .hidden.
        XCTAssertEqual(plan.entries, 7)
        XCTAssertEqual(plan.size, 6 + 70_000)
        let data = try archive(plan)
        XCTAssertEqual(Int64(data.count), plan.archiveSize)
        XCTAssertEqual(data.count % 512, 0)
        let back = try read(data)
        XCTAssertTrue(back.finished)
        XCTAssertEqual(back.entries.map(\.path), plan.items.map(\.entry.path))
        XCTAssertEqual(back.files["Fold/a.txt"], Data("hello\n".utf8))
        XCTAssertEqual(back.files["Fold/ünï cødé 😀/\(long).bin"]?.count, 70_000)
        XCTAssertEqual(back.entries.first { $0.path == "Fold/empty" }?.kind, .directory)
        XCTAssertEqual(back.files["Fold/.hidden"], Data())
    }

    func testFoldersComeBeforeWhatIsInThem() throws {
        // The server refuses an entry whose folder came in no entry before it (4006).
        try write("A/B/C/f.txt")
        let plan = try TarPlan.build([.init(url: dir.appendingPathComponent("A"), name: "A")])
        XCTAssertEqual(plan.items.map(\.entry.path), ["A", "A/B", "A/B/C", "A/B/C/f.txt"])
    }

    func testEverythingCanGoInsideOneFolderOfItsOwn() throws {
        try write("one.txt")
        try write("two/t.txt")
        let plan = try TarPlan.build([.init(url: dir.appendingPathComponent("one.txt"), name: "one.txt"),
                                      .init(url: dir.appendingPathComponent("two"), name: "two")], inside: "pteron-abc")
        XCTAssertEqual(plan.roots, 1)
        XCTAssertEqual(plan.items.map(\.entry.path), ["pteron-abc", "pteron-abc/one.txt", "pteron-abc/two", "pteron-abc/two/t.txt"])
        XCTAssertEqual(plan.items[0].entry.mode, 0o700)
    }

    func testItemsGoUnderTheNamesGiven() throws {
        try write("x/IMG_1.jpg")
        let plan = try TarPlan.build([.init(url: dir.appendingPathComponent("x/IMG_1.jpg"), name: "Photo 1.jpg")])
        XCTAssertEqual(plan.items.map(\.entry.path), ["Photo 1.jpg"])
        XCTAssertEqual(plan.roots, 1)
    }

    func testModesAndTimesAreKept() throws {
        try write("run.sh")
        let url = dir.appendingPathComponent("run.sh")
        try FileManager.default.setAttributes([.posixPermissions: 0o755, .modificationDate: Date(timeIntervalSince1970: 1_700_000_000)],
                                              ofItemAtPath: url.path)
        let plan = try TarPlan.build([.init(url: url, name: "run.sh")])
        let back = try read(archive(plan))
        XCTAssertEqual(back.entries[0].mode, 0o755)
        XCTAssertEqual(back.entries[0].mtime, 1_700_000_000)
    }

    func testAHugeSizeGoesInAPAXRecord() throws {
        let e = TarEntry(path: "big.bin", kind: .file, size: 10_000_000_000)
        let header = TarFormat.header(e)
        XCTAssertEqual(header.count, 3 * 512)
        var got: TarEntry?
        var reader = TarReader { if case .begin(let x) = $0 { got = x } }
        try reader.feed(header)
        XCTAssertEqual(got?.size, 10_000_000_000)
    }

    func testPAXLengthsCountTheirOwnDigits() {
        // " path=" + 93 bytes + "\n" is 100 bytes, so the length is "103", one digit longer.
        let records = TarFormat.paxRecords([("path", String(repeating: "a", count: 93))])
        XCTAssertEqual(records.count, 103)
        XCTAssertTrue(String(decoding: records, as: UTF8.self).hasPrefix("103 path="))
        XCTAssertEqual(TarReader.records(records)["path"], String(repeating: "a", count: 93))
    }

    func testAFileThatChangedFailsTheArchive() throws {
        try write("f.bin", Data(count: 10_000))
        let url = dir.appendingPathComponent("f.bin")
        let plan = try TarPlan.build([.init(url: url, name: "f.bin")])
        try Data(count: 100).write(to: url)
        XCTAssertThrowsError(try archive(plan)) { XCTAssertEqual($0 as? TarStream.Failure, .changed("f.bin")) }
        try Data(count: 20_000).write(to: url)
        XCTAssertThrowsError(try archive(plan)) { XCTAssertEqual($0 as? TarStream.Failure, .changed("f.bin")) }
    }

    func testABrokenHeaderIsRefused() {
        var block = [UInt8](TarFormat.header(TarEntry(path: "a", kind: .file, size: 0)))
        block[0] = UInt8(ascii: "b")
        var reader = TarReader { _ in }
        XCTAssertThrowsError(try reader.feed(Data(block))) { XCTAssertEqual($0 as? TarReader.Failure, .badHeader) }
    }

    func testAnArchiveThatStopsInsideAnEntryIsTruncated() throws {
        let header = TarFormat.header(TarEntry(path: "a", kind: .file, size: 1000))
        var reader = TarReader { _ in }
        try reader.feed(header + Data(count: 10))
        XCTAssertThrowsError(try reader.finish()) { XCTAssertEqual($0 as? TarReader.Failure, .truncated) }
    }

    func testAnOversizedRecordIsRefused() {
        var b = [UInt8](TarFormat.header(TarEntry(path: "a", kind: .file, size: Int64(TarFormat.maxMetaBytes + 1))))
        b[156] = UInt8(ascii: "x")
        // Fix the checksum for the new type.
        for i in 148..<156 { b[i] = 0x20 }
        let sum = String(b.reduce(0) { $0 + Int($1) }, radix: 8)
        let field = Array((String(repeating: "0", count: 6 - sum.count) + sum).utf8) + [0, 0x20]
        for (i, c) in field.enumerated() { b[148 + i] = c }
        var reader = TarReader { _ in }
        XCTAssertThrowsError(try reader.feed(Data(b))) { XCTAssertEqual($0 as? TarReader.Failure, .oversizedRecord) }
    }

    /// A download from Rex (revision 24, Go's archive/tar): PAX headers with fractional times, a
    /// file, an empty folder, a link inside and one outside, Unicode and a long path.
    func testAnArchiveFromRexReads() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil)).appendingPathComponent("fs-download.tar")
        let back = try read(try Data(contentsOf: url))
        XCTAssertTrue(back.finished)
        let paths = back.entries.map(\.path)
        XCTAssertTrue(paths.contains("src/a.txt"))
        XCTAssertEqual(back.files["src/a.txt"], Data("hi\n".utf8))
        XCTAssertEqual(back.entries.first { $0.path == "src/empty" }?.kind, .directory)
        XCTAssertEqual(back.entries.first { $0.path == "src/link" }?.kind, .symlink("a.txt"))
        XCTAssertEqual(back.entries.first { $0.path == "src/outlink" }?.kind, .symlink("/etc/hosts"))
        let deep = try XCTUnwrap(paths.first { $0.hasSuffix(".txt") && $0.contains("ünï cødé") })
        XCTAssertGreaterThan(deep.utf8.count, 200)
        XCTAssertEqual(back.files[deep], Data("deep\n".utf8))
        XCTAssertEqual(back.entries.first { $0.path == "src/a.txt" }?.mode, 0o755)
    }

    func testGNULongNamesRead() throws {
        let name = String(repeating: "n", count: 150)
        var meta = [UInt8](TarFormat.header(TarEntry(path: "././@LongLink", kind: .file, size: Int64(name.utf8.count + 1))))
        meta[156] = UInt8(ascii: "L")
        for i in 148..<156 { meta[i] = 0x20 }
        let sum = String(meta.reduce(0) { $0 + Int($1) }, radix: 8)
        for (i, c) in (Array((String(repeating: "0", count: 6 - sum.count) + sum).utf8) + [0, 0x20]).enumerated() { meta[148 + i] = c }
        var data = Data(meta) + Data(name.utf8) + Data([0])
        data.append(Data(count: TarFormat.padding(Int64(name.utf8.count + 1))))
        data.append(TarFormat.header(TarEntry(path: "short", kind: .file, size: 0)))
        let back = try read(data)
        XCTAssertEqual(back.entries.map(\.path), [name])
    }

    // MARK: Paths

    func testUnsafePathsAreRefused() {
        XCTAssertNil(TarPath.components("../evil"))
        XCTAssertNil(TarPath.components("a/../../evil"))
        XCTAssertNil(TarPath.components("a/.."))
        XCTAssertNil(TarPath.components("/etc/passwd"))
        XCTAssertNil(TarPath.components(""))
        XCTAssertNil(TarPath.components("./"))
        XCTAssertNil(TarPath.components("a\u{0}b"))
        XCTAssertEqual(TarPath.components("./a//b/./c"), ["a", "b", "c"])
        XCTAssertEqual(TarPath.components("..a/b.."), ["..a", "b.."])
    }

    func testDownloadPathsAreTakenLiterally() {
        XCTAssertEqual(TarPath.literal("/home/u/a*b?[1]\\x"), "/home/u/a\\*b\\?\\[1]\\\\x")
        XCTAssertEqual(TarPath.literal("~/Plain Folder"), "~/Plain Folder")
    }

    // MARK: Links

    func testLinksAreNeverFollowed() throws {
        try write("top/real.txt", Data("r".utf8))
        try mkdir("top/sub")
        try write("outside.txt")
        let fm = FileManager.default
        try fm.createSymbolicLink(atPath: dir.appendingPathComponent("top/in").path, withDestinationPath: "real.txt")
        try fm.createSymbolicLink(atPath: dir.appendingPathComponent("top/sub/up").path, withDestinationPath: "../real.txt")
        try fm.createSymbolicLink(atPath: dir.appendingPathComponent("top/out").path, withDestinationPath: "../outside.txt")
        try fm.createSymbolicLink(atPath: dir.appendingPathComponent("top/abs").path, withDestinationPath: "/etc/hosts")
        try fm.createSymbolicLink(atPath: dir.appendingPathComponent("top/dirlink").path, withDestinationPath: dir.path)
        let plan = try TarPlan.build([.init(url: dir.appendingPathComponent("top"), name: "top")])
        let kinds = Dictionary(uniqueKeysWithValues: plan.items.map { ($0.entry.path, $0.entry.kind) })
        XCTAssertEqual(kinds["top/in"], .symlink("real.txt"))
        XCTAssertEqual(kinds["top/sub/up"], .symlink("../real.txt"))
        XCTAssertNil(kinds["top/out"])
        XCTAssertNil(kinds["top/abs"])
        XCTAssertNil(kinds["top/dirlink"])
        XCTAssertEqual(plan.skipped, 3)
        XCTAssertFalse(plan.items.contains { $0.entry.path.contains("outside") })
    }

    func testAChosenLinkIsLeftOut() throws {
        try write("real.txt")
        try FileManager.default.createSymbolicLink(atPath: dir.appendingPathComponent("l").path, withDestinationPath: "real.txt")
        XCTAssertThrowsError(try TarPlan.build([.init(url: dir.appendingPathComponent("l"), name: "l")])) {
            XCTAssertEqual($0 as? TarPlan.Failure, .empty)
        }
    }

    // MARK: Extracting

    func testExtractingWritesFilesAndFoldersAndSkipsLinks() throws {
        try write("S/a.txt", Data("aaa".utf8))
        try mkdir("S/empty")
        try write("S/ü/b.bin", Data(count: 3000))
        try FileManager.default.createSymbolicLink(atPath: dir.appendingPathComponent("S/l").path, withDestinationPath: "a.txt")
        let data = try archive(try TarPlan.build([.init(url: dir.appendingPathComponent("S"), name: "S")]))
        let out = dir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let x = TarExtractor(root: out)
        var i = 0
        while i < data.count { try x.feed(data.subdata(in: i..<min(i + 1500, data.count))); i += 1500 }
        try x.finish()
        XCTAssertEqual(x.tops, ["S"])
        XCTAssertEqual(x.skipped, 1)
        XCTAssertEqual(x.written, 3003)
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("S/a.txt")), Data("aaa".utf8))
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("S/ü/b.bin")).count, 3000)
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent("S/empty").path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: out.appendingPathComponent("S/l").path))
    }

    func testExtractingRefusesPathsThatLeaveTheFolder() throws {
        let out = dir.appendingPathComponent("out2", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for bad in ["../evil.txt", "/tmp/evil.txt", "ok/../../evil.txt"] {
            let x = TarExtractor(root: out)
            let data = TarFormat.header(TarEntry(path: bad, kind: .file, size: 4)) + Data("evil".utf8) + Data(count: 508)
            XCTAssertThrowsError(try x.feed(data)) { XCTAssertEqual($0 as? TarExtractor.Failure, .unsafePath(bad)) }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("evil.txt").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.path), [])
    }

    // MARK: Large trees

    func testTenThousandFilesPlanQuickly() throws {
        for d in 0..<100 {
            for f in 0..<100 { try write("Big/d\(d)/f\(f).txt", Data("\(d)-\(f)".utf8)) }
        }
        let start = Date()
        let plan = try TarPlan.build([.init(url: dir.appendingPathComponent("Big"), name: "Big")])
        XCTAssertEqual(plan.entries, 1 + 100 + 10_000)
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
        var reader = TarReader { _ in }
        let s = TarStream(plan)
        var total: Int64 = 0
        while true {
            let d = try s.next(upTo: 65_536)
            if d.isEmpty { break }
            total += Int64(d.count)
            try reader.feed(d)
        }
        XCTAssertEqual(total, plan.archiveSize)
        XCTAssertTrue(reader.finished)
    }
}
