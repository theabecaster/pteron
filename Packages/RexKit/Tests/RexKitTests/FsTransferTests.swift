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
    /// `closing: false` leaves the connection open after the data.
    func serve(_ data: Data, piece: Int = 32_768, then code: Int? = 1000, closing: Bool = true) {
        var i = 0
        while i < data.count {
            deliver(.success(data.subdata(in: i..<min(i + piece, data.count))))
            i += piece
        }
        guard closing else { return }
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

    // MARK: Waiting for the server to put everything in place

    /// 30,032 small files took the server 143 s after the stream began (probed): far past the
    /// 60 s once waited, and well inside the wait now.
    func testTheConfirmationWaitGrowsWithTheEntriesAndContent() {
        func seconds(_ entries: Int, _ size: Int64) -> Double { UploadRate.seconds(FsUploader.confirmWait(entries: entries, size: size)) }
        XCTAssertEqual(seconds(3, 0), 60.15, accuracy: 0.001)
        XCTAssertEqual(seconds(30_032, 1_920_000), 60 + 1_501.6 + 0.229, accuracy: 0.01)
        XCTAssertEqual(seconds(3, 2 << 30), 60.15 + 256, accuracy: 0.001)
    }

    /// A single large file shows its bytes; many small ones show what the server has likely put
    /// in place; nothing shows the whole archive before the server confirms.
    func testTheProgressIsTheLesserOfTheBytesAndThePlacing() {
        // One file: the bytes.
        XCTAssertEqual(FsUploader.shown(sent: 500, archive: 1_000, entries: 1, elapsed: .seconds(1)), 500)
        XCTAssertEqual(FsUploader.shown(sent: 1_000, archive: 1_000, entries: 1, elapsed: .seconds(1)), 999)
        // 30,000 entries, all sent after 1 s: the placing, about 150 s in all.
        XCTAssertEqual(Double(FsUploader.shown(sent: 30_000_000, archive: 30_000_000, entries: 30_000, elapsed: .seconds(1))),
                       200_000, accuracy: 1)
        XCTAssertEqual(Double(FsUploader.shown(sent: 30_000_000, archive: 30_000_000, entries: 30_000, elapsed: .seconds(75))),
                       15_000_000, accuracy: 1)
        // A server slower than expected: 99% until it confirms.
        XCTAssertEqual(FsUploader.shown(sent: 30_000_000, archive: 30_000_000, entries: 30_000, elapsed: .seconds(600)), 29_999_999)
        XCTAssertEqual(FsUploader.shown(sent: 0, archive: 1_024, entries: 1, elapsed: .zero), 0)
    }

    /// The server takes its time over many entries: the wait is the plan's, and the progress
    /// keeps moving short of the whole until the server confirms.
    func testTheProgressMovesWhileTheServerPutsEntriesInPlace() async throws {
        for i in 0..<300 { try write("Many/f\(i).txt", Data("x".utf8)) }
        let plan = try TarPlan.build([.init(url: dir.appendingPathComponent("Many"), name: "Many")], inside: "pteron-test")
        let link = link(), socket = FsFakeSocket()
        socket.closeOnEnd = nil
        let up = uploader(link, [socket])
        var waits: [Duration] = []
        up.sleep = { d in
            if d >= FsUploader.closeWait { waits.append(d); try? await Task.sleep(for: .seconds(30)) } else { await Task.yield() }
        }
        var seen: [Int64] = []
        let task = Task { try await up.send(plan, to: "/tmp") { sent, _ in seen.append(sent) } }
        let ended = await eventually { socket.sawEnd }
        XCTAssertTrue(ended)
        let atEnd = seen.last ?? 0
        XCTAssertLessThan(atEnd, plan.archiveSize)
        // 301 entries: about 1.5 s of placing.
        try await Task.sleep(for: .milliseconds(800))
        let later = seen.last ?? 0
        XCTAssertGreaterThan(later, atEnd)
        XCTAssertLessThan(later, plan.archiveSize)
        socket.serve(Data(), then: 1000)
        let dest = try await task.value
        XCTAssertEqual(dest, "/private/tmp")
        XCTAssertEqual(seen.last, plan.archiveSize)
        XCTAssertEqual(waits, [FsUploader.confirmWait(entries: plan.entries, size: plan.size)])
    }

    /// A server that never confirms still ends, once the plan's wait is over.
    func testAServerThatNeverConfirmsEndsAfterThePlansWait() async throws {
        let link = link(), socket = FsFakeSocket(), plan = try plan()
        socket.closeOnEnd = nil
        let up = uploader(link, [socket])
        var waits: [Duration] = []
        up.sleep = { d in
            if d >= FsUploader.closeWait { waits.append(d) } else { await Task.yield() }
        }
        do {
            _ = try await up.send(plan, to: "/tmp") { _, _ in }
            XCTFail("should fail")
        } catch {
            XCTAssertEqual(error as? FsUploader.Failure, .unconfirmed)
        }
        XCTAssertEqual(waits, [FsUploader.confirmWait(entries: plan.entries, size: plan.size)])
    }

    // MARK: Cancelling an upload

    /// A slow link: the start's answer is still on its way at the cancel. The upload ends at
    /// once, and the answer that comes later opens nothing: its ticket is never used.
    func testCancelWhileTheStartIsAnsweredEndsAtOnce() async throws {
        let link = link()
        link.held = [FsBlock.upload]
        var opened = 0
        let up = uploader(link, [FsFakeSocket()], opened: { opened = $0 })
        let plan = try plan()
        let task = Task { try await up.send(plan, to: "/tmp") { _, _ in } }
        let asked = await eventually { link.waitingCount == 1 }
        XCTAssertTrue(asked)
        up.cancel()
        do {
            _ = try await task.value
            XCTFail("should fail")
        } catch {
            XCTAssertEqual(error as? FsUploader.Failure, .cancelled)
        }
        // The server's late answer, with a ticket: dropped.
        link.release()
        await settle()
        XCTAssertEqual(opened, 0)
    }

    /// A cancel before the upload starts asks the server for nothing.
    func testCancelBeforeTheUploadStartsAsksForNothing() async throws {
        let link = link()
        let up = uploader(link, [FsFakeSocket()])
        up.cancel()
        do {
            _ = try await up.send(try plan(), to: "/tmp") { _, _ in }
            XCTFail("should fail")
        } catch {
            XCTAssertEqual(error as? FsUploader.Failure, .cancelled)
        }
        XCTAssertEqual(link.count(FsBlock.upload), 0)
    }

    /// A slow link: the data connection is still on its way at the cancel. The upload ends at
    /// once, and the connection is closed when it comes, before any byte goes.
    func testCancelWhileTheUploadsConnectionOpensClosesItWhenItComes() async throws {
        let link = link(), socket = FsFakeSocket()
        var handshake: CheckedContinuation<Void, Never>?
        let up = FsUploader(link: link, sessionID: "session:s", blockID: "block:fs") { _ in
            await withCheckedContinuation { handshake = $0 }
            return socket
        }
        let plan = try plan()
        let task = Task { try await up.send(plan, to: "/tmp") { _, _ in } }
        let opening = await eventually { handshake != nil }
        XCTAssertTrue(opening)
        up.cancel()
        do {
            _ = try await task.value
            XCTFail("should fail")
        } catch {
            XCTAssertEqual(error as? FsUploader.Failure, .cancelled)
        }
        XCTAssertFalse(socket.closedByClient)
        handshake?.resume()
        let closed = await eventually { socket.closedByClient }
        XCTAssertTrue(closed)
        XCTAssertEqual(socket.messageCount, 0)
    }

    /// Cancel at 100%: the end has gone out and the server is still putting the archive in
    /// place (13 s for 3,000 small files, probed). The upload ends at once as cancelled, never as
    /// sent, so the caller types no path; closing the fs block then stops the server.
    func testCancelAfterTheEndEndsAtOnceAndConfirmsNothing() async throws {
        let link = link(), socket = FsFakeSocket()
        socket.closeOnEnd = nil
        let up = uploader(link, [socket])
        let plan = try plan()
        let task = Task { try await up.send(plan, to: "/tmp") { _, _ in } }
        let ended = await eventually { socket.sawEnd }
        XCTAssertTrue(ended)
        up.cancel()
        do {
            _ = try await task.value
            XCTFail("should fail")
        } catch {
            XCTAssertEqual(error as? FsUploader.Failure, .cancelled)
        }
        XCTAssertTrue(socket.closedByClient)
    }

    /// A lost stream waits a second before it starts over. A cancel in that pause ends the upload
    /// at once, and nothing starts again.
    func testCancelInThePauseBeforeARetryEndsAtOnce() async throws {
        let link = link(), broken = FsFakeSocket()
        broken.breakAfter = 10_000
        let up = uploader(link, [broken, FsFakeSocket()])
        var pause: CheckedContinuation<Void, Never>?
        up.sleep = { d in
            if d == .seconds(1) { await withCheckedContinuation { pause = $0 } } else { await Task.yield() }
        }
        let plan = try plan()
        let task = Task { try await up.send(plan, to: "/tmp") { _, _ in } }
        let pausing = await eventually { pause != nil }
        XCTAssertTrue(pausing)
        up.cancel()
        do {
            _ = try await task.value
            XCTFail("should fail")
        } catch {
            XCTAssertEqual(error as? FsUploader.Failure, .cancelled)
        }
        pause?.resume()
        await settle()
        XCTAssertEqual(link.count(FsBlock.upload), 1)
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

    // MARK: Cancelling a download

    /// The server answers `download_begin` only once it has walked the whole tree, seconds for a
    /// large folder. A cancel meanwhile ends the download at once, and the answer that comes
    /// later opens nothing: its ticket is never used.
    func testCancelWhileTheServerWalksTheFolderEndsAtOnce() async throws {
        let link = downloadLink(size: 1_000_000), socket = FsFakeSocket()
        link.held = [FsBlock.download]
        var opened = 0
        let d = FsDownloader(link: link, sessionID: "session:s", blockID: "block:fs") { _ in opened += 1; return socket }
        let task = Task { try await d.download(["/big"], into: self.dir, hasRoom: { _ in true }) { _, _ in } }
        let asked = await eventually { link.waitingCount == 1 }
        XCTAssertTrue(asked)
        d.cancel()
        do {
            _ = try await task.value
            XCTFail("should fail")
        } catch {
            XCTAssertEqual(error as? FsDownloader.Failure, .cancelled)
        }
        // The server's late answer, with a ticket: dropped.
        link.release()
        await settle()
        XCTAssertEqual(opened, 0)
    }

    /// A cancel before the download starts asks the server for nothing.
    func testCancelBeforeTheStartAsksForNothing() async throws {
        let link = downloadLink(size: 1), socket = FsFakeSocket()
        let d = downloader(link, socket)
        d.cancel()
        do {
            _ = try await d.download(["/x"], into: dir, hasRoom: { _ in true }) { _, _ in }
            XCTFail("should fail")
        } catch {
            XCTAssertEqual(error as? FsDownloader.Failure, .cancelled)
        }
        XCTAssertEqual(link.count(FsBlock.download), 0)
    }

    /// A slow link: the data connection is still on its way at the cancel. The download ends at
    /// once, and the connection is closed when it comes, before any byte is read.
    func testCancelWhileTheDataConnectionOpensClosesItWhenItComes() async throws {
        let link = downloadLink(size: 1_000_000), socket = FsFakeSocket()
        var handshake: CheckedContinuation<Void, Never>?
        let d = FsDownloader(link: link, sessionID: "session:s", blockID: "block:fs") { _ in
            await withCheckedContinuation { handshake = $0 }
            return socket
        }
        let task = Task { try await d.download(["/big"], into: self.dir, hasRoom: { _ in true }) { _, _ in } }
        let opening = await eventually { handshake != nil }
        XCTAssertTrue(opening)
        d.cancel()
        do {
            _ = try await task.value
            XCTFail("should fail")
        } catch {
            XCTAssertEqual(error as? FsDownloader.Failure, .cancelled)
        }
        XCTAssertFalse(socket.closedByClient)
        handshake?.resume()
        let closed = await eventually { socket.closedByClient }
        XCTAssertTrue(closed)
    }

    /// A cancel while the archive arrives, at 99% say, closes the stream and ends the download
    /// without waiting for the rest.
    func testCancelWhileTheArchiveArrivesClosesTheStream() async throws {
        try write("Src/b.bin", bytes(200_000))
        let data = try archive(of: "Src")
        let socket = FsFakeSocket()
        let out = dir.appendingPathComponent("o", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let d = downloader(downloadLink(size: 200_000), socket)
        var got: Int64 = 0
        let task = Task { try await d.download(["/x"], into: out, hasRoom: { _ in true }) { g, _ in got = g } }
        // All but the archive's end, and the stream stays open.
        socket.serve(data.prefix(data.count - 1024), then: nil, closing: false)
        let most = await eventually { got >= 190_000 }
        XCTAssertTrue(most)
        d.cancel()
        do {
            _ = try await task.value
            XCTFail("should fail")
        } catch {
            XCTAssertEqual(error as? FsDownloader.Failure, .cancelled)
        }
        XCTAssertTrue(socket.closedByClient)
    }

    func testRefusalsAreWorded() {
        XCTAssertEqual(FsDownloader.failure(beginning: RexError(code: "not_found", message: "not found: stat /x", status: 404)), .notFound)
        XCTAssertEqual(FsDownloader.failure(beginning: RexError(code: "bad_request", message: "open /x: permission denied", status: 400)),
                       .noPermission)
        XCTAssertEqual(FsUploader.failure(beginning: RexError(code: "bad_request", message: "/x: is not a directory", status: 400)),
                       .refused("/x: is not a directory"))
    }
}
