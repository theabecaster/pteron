import XCTest
@testable import RexKit

/// A data connection to an fs block, playing the server's side as a revision-24 server did when
/// probed: it takes an upload's archive and closes with 1000 at its empty end message, or sends a
/// download's archive and closes with 1000.
final class FsFakeSocket: TunnelSocket, @unchecked Sendable {
    // `@unchecked`: every var is only touched under `lock`.
    private let lock = NSLock()
    private var inbox: [Result<Data?, Error>] = []
    private var waiter: CheckedContinuation<Data?, Error>?
    private var bytes = Data()
    private var messages = 0
    private var largest = 0
    private var code = 0
    private var ended = false
    private var cleanClose = false
    /// How the server closes after the upload's end: 1000, or 4006 for a refused archive; nil
    /// leaves it open (it never confirms).
    var closeOnEnd: Int? = 1000
    /// The connection breaks once this many bytes have gone.
    var breakAfter: Int?
    /// Called on each send, outside the lock.
    var onSend: ((Int) -> Void)?

    var received: Data { lock.withLock { bytes } }
    var messageCount: Int { lock.withLock { messages } }
    var largestMessage: Int { lock.withLock { largest } }
    var sawEnd: Bool { lock.withLock { ended } }
    var closedByClient: Bool { lock.withLock { cleanClose } }
    var closeCode: Int { lock.withLock { code } }

    /// The server sends `data` in messages of `piece` bytes, then closes with `code` (nil: the
    /// connection just breaks, with no status).
    func serve(_ data: Data, piece: Int = 32_768, then code: Int? = 1000) {
        var i = 0
        while i < data.count {
            deliver(.success(data.subdata(in: i..<min(i + piece, data.count))))
            i += piece
        }
        lock.withLock { self.code = code ?? 0 }
        deliver(.failure(URLError(.networkConnectionLost)))
    }

    private func deliver(_ r: Result<Data?, Error>) {
        lock.lock()
        if let w = waiter {
            waiter = nil
            lock.unlock()
            w.resume(with: r)
        } else {
            inbox.append(r)
            lock.unlock()
        }
    }

    func send(_ data: Data) async throws {
        let (fail, close, count) = lock.withLock { () -> (Bool, Int?, Int) in
            if code != 0 { return (true, nil, 0) }
            if let b = breakAfter, bytes.count + data.count > b { return (true, nil, 0) }
            messages += 1
            largest = max(largest, data.count)
            bytes.append(data)
            if data.isEmpty { ended = true; return (false, closeOnEnd, bytes.count) }
            return (false, nil, bytes.count)
        }
        if fail {
            lock.withLock { if code == 0 { code = 1006 } }
            deliver(.failure(URLError(.networkConnectionLost)))
            throw URLError(.networkConnectionLost)
        }
        onSend?(count)
        if let close {
            lock.withLock { code = close }
            deliver(.failure(URLError(.networkConnectionLost)))
        }
    }

    func receive() async throws -> Data? {
        try await withCheckedThrowingContinuation { c in
            lock.lock()
            if !inbox.isEmpty {
                let r = inbox.removeFirst()
                lock.unlock()
                c.resume(with: r)
            } else {
                waiter = c
                lock.unlock()
            }
        }
    }

    func ping() async throws {}

    func close() {
        lock.withLock {
            cleanClose = true
            if code == 0 { code = 1000 }
        }
        deliver(.failure(URLError(.cancelled)))
    }

    func abort() {
        lock.withLock { if code == 0 { code = 1006 } }
        deliver(.failure(URLError(.cancelled)))
    }
}

@MainActor
final class FsTransferTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("fs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ path: String, _ data: Data) throws {
        let url = dir.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private func bytes(_ n: Int, seed: Int = 0) -> Data { Data((0..<n).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ seed) }) }

    private func link() -> FakeLink {
        let l = FakeLink()
        l.replies[FsBlock.upload] = ["ticket": "AAECAwQFBgcICQoLDA0ODw", "expires_in_ms": 60000, "path": "/private/tmp"]
        return l
    }

    /// An uploader whose sockets come from `sockets`, in turn; pauses are skipped.
    private func uploader(_ link: FakeLink, _ sockets: [FsFakeSocket], opened: @escaping (Int) -> Void = { _ in }) -> FsUploader {
        var left = sockets
        var n = 0
        let u = FsUploader(link: link, sessionID: "session:s", blockID: "block:fs") { _ in
            n += 1
            opened(n)
            return left.removeFirst()
        }
        u.sleep = { d in
            if d >= FsUploader.closeWait { try? await Task.sleep(for: .seconds(30)) } else { await Task.yield() }
        }
        return u
    }

    private func plan() throws -> TarPlan {
        try write("Fold/a.txt", Data("hello".utf8))
        try write("Fold/sub/b.bin", bytes(300_000))
        try write("c.txt", Data("c".utf8))
        return try TarPlan.build([.init(url: dir.appendingPathComponent("Fold"), name: "Fold"),
                                  .init(url: dir.appendingPathComponent("c.txt"), name: "c.txt")], inside: "pteron-test")
    }

    /// Reads an archive back into path → bytes.
    private func unpack(_ data: Data) throws -> [String: Data] {
        var files: [String: Data] = [:]
        var current: String?
        var r = TarReader { e in
            switch e {
            case .begin(let x): current = x.kind == .file ? x.path : nil; if let c = current { files[c] = Data() }
            case .bytes(let d): if let c = current { files[c]!.append(d) }
            case .end: current = nil
            }
        }
        try r.feed(data)
        XCTAssertTrue(r.finished)
        return files
    }

    // MARK: Upload

    func testAnUploadIsOneArchiveInSmallMessagesThenAnEmptyOne() async throws {
        let link = link(), socket = FsFakeSocket(), plan = try plan()
        var last: (Int64, Int64) = (0, 0)
        let dest = try await uploader(link, [socket]).send(plan, to: "/tmp") { last = ($0, $1) }
        XCTAssertEqual(dest, "/private/tmp")
        let begin = try XCTUnwrap(link.calls.first { $0.method == FsBlock.upload })
        XCTAssertEqual(begin.payload.str("block_id"), "block:fs")
        let args = try XCTUnwrap(begin.payload.obj("args"))
        XCTAssertEqual(args.str("path"), "/tmp")
        XCTAssertEqual(args.int("roots"), 1)
        XCTAssertEqual(args.int("entries"), plan.entries)
        XCTAssertEqual(args.int("size"), 300_006)
        XCTAssertTrue(args.str("ref")?.hasPrefix("upload:") == true)
        XCTAssertTrue(socket.sawEnd)
        XCTAssertLessThanOrEqual(socket.largestMessage, BytesStream.maxMessage)
        XCTAssertEqual(Int64(socket.received.count), plan.archiveSize)
        XCTAssertEqual(last.0, plan.archiveSize)
        XCTAssertEqual(last.1, plan.archiveSize)
        let files = try unpack(socket.received)
        XCTAssertEqual(files["pteron-test/Fold/a.txt"], Data("hello".utf8))
        XCTAssertEqual(files["pteron-test/Fold/sub/b.bin"], bytes(300_000))
        XCTAssertEqual(files["pteron-test/c.txt"], Data("c".utf8))
    }

    func testARefusedArchiveSays4006() async throws {
        let socket = FsFakeSocket()
        socket.closeOnEnd = BytesStream.brokeRule
        do {
            _ = try await uploader(link(), [socket]).send(try plan(), to: "/tmp") { _, _ in }
            XCTFail("should fail")
        } catch {
            XCTAssertEqual(error as? FsUploader.Failure, .brokeRule)
        }
    }

    func testTooLittleRoomIsSaidBeforeAnyByte() async throws {
        let link = link()
        link.failures[FsBlock.upload] = [RexError(code: "too_large", message: "too large: the upload needs …", status: 413)]
        var opened = 0
        do {
            _ = try await uploader(link, [], opened: { opened = $0 }).send(try plan(), to: "/tmp") { _, _ in }
            XCTFail("should fail")
        } catch {
            XCTAssertEqual(error as? FsUploader.Failure, .noRoom("too large: the upload needs …"))
        }
        XCTAssertEqual(opened, 0)
    }

    func testALostStreamStartsOverWithANewTicketAndThenSucceeds() async throws {
        let link = link(), broken = FsFakeSocket(), good = FsFakeSocket(), plan = try plan()
        broken.breakAfter = 100_000
        var retries: [Int] = []
        _ = try await uploader(link, [broken, good]).send(plan, to: "/tmp", progress: { _, _ in }, onRetry: { retries.append($0) })
        XCTAssertEqual(retries, [1])
        XCTAssertEqual(link.count(FsBlock.upload), 2)
        XCTAssertFalse(broken.sawEnd)
        XCTAssertEqual(Int64(good.received.count), plan.archiveSize)
    }

    func testAStreamThatKeepsDroppingGivesUp() async throws {
        let sockets = (0...FsUploader.retryLimit).map { _ in FsFakeSocket() }
        for s in sockets { s.breakAfter = 10_000 }
        do {
            _ = try await uploader(link(), sockets).send(try plan(), to: "/tmp") { _, _ in }
            XCTFail("should fail")
        } catch {
            guard case .lost = error as? FsUploader.Failure else { return XCTFail("\(error)") }
        }
    }

    func testCancelClosesTheStreamBeforeItsEnd() async throws {
        let link = link(), socket = FsFakeSocket()
        try write("big.bin", bytes(2_000_000))
        let plan = try TarPlan.build([.init(url: dir.appendingPathComponent("big.bin"), name: "big.bin")])
        let up = uploader(link, [socket])
        socket.onSend = { n in if n > 200_000 { Task { @MainActor in up.cancel() } } }
        do {
            _ = try await up.send(plan, to: "/tmp") { _, _ in }
            XCTFail("should fail")
        } catch {
            XCTAssertEqual(error as? FsUploader.Failure, .cancelled)
        }
        XCTAssertTrue(socket.closedByClient)
        XCTAssertFalse(socket.sawEnd)
        XCTAssertLessThan(socket.received.count, 2_000_000)
    }

    func testAnUnconfirmedEndIsNotSentAgain() async throws {
        let link = link(), socket = FsFakeSocket()
        socket.closeOnEnd = 1006
        do {
            _ = try await uploader(link, [socket]).send(try plan(), to: "/tmp") { _, _ in }
            XCTFail("should fail")
        } catch {
            XCTAssertEqual(error as? FsUploader.Failure, .unconfirmed)
        }
        XCTAssertEqual(link.count(FsBlock.upload), 1)
    }

    func testAFileThatChangesStopsTheUpload() async throws {
        let socket = FsFakeSocket(), plan = try plan()
        try bytes(10).write(to: dir.appendingPathComponent("Fold/sub/b.bin"))
        do {
            _ = try await uploader(link(), [socket]).send(plan, to: "/tmp") { _, _ in }
            XCTFail("should fail")
        } catch {
            XCTAssertEqual(error as? FsUploader.Failure, .changed("b.bin"))
        }
        XCTAssertFalse(socket.sawEnd)
        XCTAssertTrue(socket.closedByClient)
    }

    // MARK: Download

    private func downloader(_ link: FakeLink, _ socket: FsFakeSocket) -> FsDownloader {
        FsDownloader(link: link, sessionID: "session:s", blockID: "block:fs") { _ in socket }
    }

    private func archive(of name: String) throws -> Data {
        let plan = try TarPlan.build([.init(url: dir.appendingPathComponent(name), name: name)])
        let s = TarStream(plan)
        var out = Data()
        while true { let d = try s.next(upTo: 65_536); if d.isEmpty { break }; out.append(d) }
        return out
    }

    private func downloadLink(size: Int) -> FakeLink {
        let l = FakeLink()
        l.replies[FsBlock.download] = ["ticket": "AAECAwQFBgcICQoLDA0ODw", "expires_in_ms": 60000, "roots": 1, "entries": 4, "size": size]
        return l
    }

    func testADownloadIsWrittenAsItArrives() async throws {
        try write("Src/a.txt", Data("a".utf8))
        try write("Src/ü/b.bin", bytes(200_000, seed: 3))
        let data = try archive(of: "Src")
        let link = downloadLink(size: 200_001), socket = FsFakeSocket()
        socket.serve(data, piece: 10_000)
        let out = dir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var shown: [Int64] = []
        let r = try await downloader(link, socket).download(["/home/u/Src[1]"], into: out, hasRoom: { $0 == 200_001 }) { got, _ in
            shown.append(got)
        }
        XCTAssertEqual(r.tops, ["Src"])
        XCTAssertEqual(r.info.size, 200_001)
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("Src/ü/b.bin")), bytes(200_000, seed: 3))
        let args = try XCTUnwrap(link.calls.first { $0.method == FsBlock.download }?.payload.obj("args"))
        XCTAssertEqual(args["paths"] as? [String], ["/home/u/Src\\[1]"])
        XCTAssertEqual(args.bool("recursive"), true)
        // At most once per percent, plus the start.
        XCTAssertLessThanOrEqual(shown.count, 102)
    }

    func testTooLittleRoomOnThisDeviceStopsBeforeTheStream() async throws {
        let link = downloadLink(size: 5_000_000_000), socket = FsFakeSocket()
        do {
            _ = try await downloader(link, socket).download(["/x"], into: dir, hasRoom: { _ in false }) { _, _ in }
            XCTFail("should fail")
        } catch {
            XCTAssertEqual(error as? FsDownloader.Failure, .noRoom(5_000_000_000))
        }
        XCTAssertEqual(socket.messageCount, 0)
    }

    func testADownloadCutShortIsLost() async throws {
        try write("Src/b.bin", bytes(200_000))
        let data = try archive(of: "Src")
        let socket = FsFakeSocket()
        socket.serve(data.prefix(100_000), then: nil)
        do {
            _ = try await downloader(downloadLink(size: 200_000), socket).download(["/x"], into: dir, hasRoom: { _ in true }) { _, _ in }
            XCTFail("should fail")
        } catch {
            guard case .lost = error as? FsDownloader.Failure else { return XCTFail("\(error)") }
        }
    }

    func testAnArchiveThatEndsEarlyWithACleanCloseIsLost() async throws {
        try write("Src/b.bin", bytes(200_000))
        let data = try archive(of: "Src")
        let socket = FsFakeSocket()
        socket.serve(data.prefix(100_000), then: 1000)
        do {
            _ = try await downloader(downloadLink(size: 200_000), socket).download(["/x"], into: dir, hasRoom: { _ in true }) { _, _ in }
            XCTFail("should fail")
        } catch {
            guard case .lost = error as? FsDownloader.Failure else { return XCTFail("\(error)") }
        }
    }

    func testAnUnsafePathStopsTheDownload() async throws {
        let bad = TarFormat.header(TarEntry(path: "../evil", kind: .file, size: 1)) + Data("x".utf8) + Data(count: 511) + Data(count: 1024)
        let socket = FsFakeSocket()
        socket.serve(bad)
        let out = dir.appendingPathComponent("o", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        do {
            _ = try await downloader(downloadLink(size: 1), socket).download(["/x"], into: out, hasRoom: { _ in true }) { _, _ in }
            XCTFail("should fail")
        } catch {
            XCTAssertEqual(error as? FsDownloader.Failure, .unsafe("../evil"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("evil").path))
    }

    func testRefusalsAreWorded() {
        XCTAssertEqual(FsDownloader.failure(beginning: RexError(code: "not_found", message: "not found: stat /x", status: 404)), .notFound)
        XCTAssertEqual(FsDownloader.failure(beginning: RexError(code: "bad_request", message: "open /x: permission denied", status: 400)),
                       .noPermission)
        XCTAssertEqual(FsUploader.failure(beginning: RexError(code: "bad_request", message: "/x: is not a directory", status: 400)),
                       .refused("/x: is not a directory"))
    }
}
