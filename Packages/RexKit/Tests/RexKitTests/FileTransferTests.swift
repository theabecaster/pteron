import XCTest
@testable import RexKit

/// Uploads and downloads over `rex.data.bytes.v1`, against a fake server that follows the rules
/// found by probing a real one (`BytesStream`).
@MainActor
final class FileTransferTests: XCTestCase {
    private static let upload = "com.superlogical.terminal.upload_begin"
    private static let download = "com.superlogical.terminal.download_begin"
    private static let ticket: JSONObject = ["ticket": "AAECAwQFBgcICQoLDA0ODw", "expires_in_ms": 60000]

    private func link() -> FakeLink {
        let l = FakeLink()
        l.replies[Self.upload] = Self.ticket
        return l
    }

    private func uploader(_ link: FakeLink) -> FileUploader {
        let u = FileUploader(link: link, sessionID: "session:s", blockID: "block:b")
        // Pauses are skipped, except the wait for the server's close, which only a test that never
        // closes reaches.
        u.sleep = { d in
            if d >= FileUploader.closeWait { try? await Task.sleep(for: .seconds(10)) } else { await Task.yield() }
        }
        return u
    }

    private func item(_ name: String, _ data: Data) -> FileUploader.Item {
        FileUploader.Item(name: name, size: Int64(data.count)) { DataSource(data) }
    }

    private func bytes(_ n: Int, seed: UInt8 = 0) -> Data { Data((0..<n).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) }) }

    /// The server takes each file once its empty end message arrives, and closes with `code`.
    private func serve(_ socket: FakeSocket, closing code: Int = 1000) {
        socket.onSend = { [weak socket] d in if d.isEmpty { socket?.drop(code: code) } }
    }

    /// Serves every socket the link opens from now on, closing them with `codes` in turn, then 1000.
    private func serveAll(_ link: FakeLink, codes: [Int] = []) {
        var codes = codes
        link.onOpen = { [unowned self] s in self.serve(s, closing: codes.isEmpty ? 1000 : codes.removeFirst()) }
    }

    // MARK: Wire rules

    func testChunksAreAtMost64KiB() {
        XCTAssertEqual(BytesStream.chunks(size: 200_000), [65536, 65536, 65536, 3392])
        XCTAssertEqual(BytesStream.chunks(size: 65536), [65536])
        XCTAssertEqual(BytesStream.chunks(size: 0), [])
    }

    func testRefIsTheKindAndALowerCaseUUID() {
        let id = UUID(uuidString: "0869871C-9791-4D21-8E15-5CEB5ECE4EB5")!
        XCTAssertEqual(BytesStream.ref("upload", id), "upload:0869871c-9791-4d21-8e15-5ceb5ece4eb5")
    }

    func testAFileOnItsOwnHasNoBatch() {
        let a = BytesStream.uploadArgs(ref: "upload:x", name: "a.txt", size: 3, batch: nil, index: 0, count: 1)
        XCTAssertNil(a["batch"])
        XCTAssertNil(a["index"])
        let b = BytesStream.uploadArgs(ref: "upload:x", name: "a.txt", size: 3, batch: "b", index: 2, count: 3)
        XCTAssertEqual(b.str("batch"), "b")
        XCTAssertEqual(b.int("index"), 2)
        XCTAssertEqual(b.int("count"), 3)
    }

    // MARK: Upload

    func testOneFileIsAHelloItsBytesInChunksThenAnEmptyMessage() async throws {
        let link = link()
        serveAll(link)
        let data = bytes(200_000)
        var last: (Int64, Int64) = (0, 0)
        try await uploader(link).send([item("a b.bin", data)]) { last = ($0, $1) }
        XCTAssertEqual(link.subprotocols, [BytesStream.subprotocol])
        let begin = try XCTUnwrap(link.calls.first { $0.method == Self.upload })
        XCTAssertEqual(begin.payload.str("session_id"), "session:s")
        let args = try XCTUnwrap(begin.payload.obj("args"))
        XCTAssertEqual(args.str("name"), "a b.bin")
        XCTAssertEqual(args.int("size"), 200_000)
        // A batch of one: a retry after its end went out can't type its path twice.
        XCTAssertNotNil(args.str("batch"))
        XCTAssertEqual(args.int("index"), 0)
        XCTAssertEqual(args.int("count"), 1)
        XCTAssertTrue(args.str("ref")?.hasPrefix("upload:") == true)
        let sent = link.sockets[0].sent
        XCTAssertEqual(sent.first, [0x01] + Array(0..<16))
        XCTAssertEqual(sent.dropFirst().map(\.count), [65536, 65536, 65536, 3392, 0])
        XCTAssertEqual(Data(sent.dropFirst().joined()), data)
        XCTAssertEqual(last.0, 200_000)
        XCTAssertEqual(last.1, 200_000)
    }

    func testABatchSharesAnIDAndCountsItsFilesInOrder() async throws {
        let link = link()
        serveAll(link)
        let files = [item("a", bytes(10)), item("b", bytes(70_000)), item("c", bytes(0))]
        try await uploader(link).send(files) { _, _ in }
        let args = link.calls.filter { $0.method == Self.upload }.compactMap { $0.payload.obj("args") }
        XCTAssertEqual(args.map { $0.str("name") }, ["a", "b", "c"])
        XCTAssertEqual(args.map { $0.int("index") }, [0, 1, 2])
        XCTAssertEqual(args.map { $0.int("count") }, [3, 3, 3])
        XCTAssertEqual(Set(args.compactMap { $0.str("batch") }).count, 1)
        // One ticket and one connection per file, asked for just before it is sent.
        XCTAssertEqual(link.methods.filter { $0 == Self.upload }.count, 3)
        XCTAssertEqual(link.sockets.count, 3)
        XCTAssertEqual(link.sockets[2].sent.dropFirst().map(\.count), [0], "an empty file is only its end")
    }

    func testALostBatchIsSentAgainFromTheStartUnderANewID() async throws {
        let link = link()
        // The first file's connection drops before the server took it; then all goes well.
        serveAll(link, codes: [1006])
        var retries: [Int] = []
        try await uploader(link).send([item("a", bytes(10)), item("b", bytes(10))], progress: { _, _ in },
                                      onRetry: { retries.append($0) })
        XCTAssertEqual(retries, [1])
        let batches = link.calls.filter { $0.method == Self.upload }.compactMap { $0.payload.obj("args")?.str("batch") }
        XCTAssertEqual(batches.count, 3)
        XCTAssertNotEqual(batches[0], batches[1], "an aborted batch's ID can't be used again")
        XCTAssertEqual(batches[1], batches[2])
    }

    func testRetriesStopAtTheLimit() async {
        let link = link()
        // The first file of two is lost every time.
        serveAll(link, codes: Array(repeating: 1006, count: 10))
        do {
            try await uploader(link).send([item("a", bytes(10)), item("b", bytes(10))]) { _, _ in }
            XCTFail("expected a failure")
        } catch let f as FileUploader.Failure {
            XCTAssertTrue(f.isRetryable)
        } catch { XCTFail("\(error)") }
        XCTAssertEqual(link.sockets.count, 1 + FileUploader.retryLimit)
    }

    func testABatchWhoseLastFileWentOutWholeIsNotSentAgain() async {
        let link = link()
        // The end went out, then the connection was lost before the server confirmed: it may have
        // typed the path already.
        serveAll(link, codes: [1006])
        do {
            try await uploader(link).send([item("a", bytes(10))]) { _, _ in }
            XCTFail("expected a failure")
        } catch let f as FileUploader.Failure {
            XCTAssertEqual(f, .unconfirmed)
            XCTAssertFalse(f.isRetryable)
        } catch { XCTFail("\(error)") }
        XCTAssertEqual(link.sockets.count, 1)
    }

    func testCancelBetweenFilesCutsOffTheNextSoTheServerDropsTheBatch() async throws {
        let link = link()
        let u = uploader(link)
        // The server never confirms the first file; the test cancels while the upload waits for it.
        let task = Task { @MainActor in
            do {
                try await u.send([self.item("a", self.bytes(10)), self.item("b", self.bytes(10))]) { _, _ in }
                return FileUploader.Failure?.none
            } catch { return error as? FileUploader.Failure }
        }
        _ = await eventually { link.sockets.first?.sent.last == [] }
        u.cancel()
        let result = await task.value
        XCTAssertEqual(result, .cancelled)
        let args = link.calls.filter { $0.method == Self.upload }.compactMap { $0.payload.obj("args") }
        XCTAssertEqual(args.map { $0.int("index") }, [0, 1], "the next file is reserved…")
        XCTAssertEqual(args[0].str("batch"), args[1].str("batch"))
        XCTAssertEqual(link.sockets.count, 2)
        XCTAssertEqual(link.sockets[1].sent, [[0x01] + Array(0..<16)], "…opened, and cut off with no bytes")
        XCTAssertTrue(link.sockets[1].closed)
    }

    func testCancelAfterTheLastFileWentOutChangesNothing() async throws {
        let link = link()
        let u = uploader(link)
        let task = Task { @MainActor in try await u.send([self.item("a", self.bytes(10))]) { _, _ in } }
        _ = await eventually { link.sockets.first?.sent.last == [] }
        u.cancel()
        XCTAssertFalse(link.sockets[0].closed, "too late: the server may be typing the path")
        link.sockets[0].drop(code: 1000)
        try await task.value
    }

    func testAFileOfTheWrongSizeIsNotRetried() async {
        let link = link()
        serveAll(link, codes: [BytesStream.brokeRule])
        do {
            try await uploader(link).send([item("a", bytes(10))]) { _, _ in }
            XCTFail("expected a failure")
        } catch let f as FileUploader.Failure {
            XCTAssertEqual(f, .brokeRule)
        } catch { XCTFail("\(error)") }
        XCTAssertEqual(link.sockets.count, 1)
    }

    func testASourceShorterThanItsSizeStopsBeforeTheEnd() async {
        let link = link()
        serveAll(link)
        let short = FileUploader.Item(name: "a", size: 100) { DataSource(Data(repeating: 1, count: 40)) }
        do {
            try await uploader(link).send([short]) { _, _ in }
            XCTFail("expected a failure")
        } catch let f as FileUploader.Failure {
            XCTAssertEqual(f, .brokeRule)
        } catch { XCTFail("\(error)") }
        XCTAssertFalse(link.sockets[0].sent.contains([]), "no end message for a short file")
        XCTAssertTrue(link.sockets[0].closed)
    }

    func testCancelClosesTheConnectionAndIsNotRetried() async {
        let link = link()
        // The server takes the HELLO and says nothing: the file is on its way when the test cancels.
        link.defaultPlan = .silent
        let u = uploader(link)
        let task = Task { @MainActor in
            do {
                try await u.send([item("a", self.bytes(10))]) { _, _ in }
                return FileUploader.Failure?.none
            } catch { return error as? FileUploader.Failure }
        }
        _ = await eventually { link.sockets.first?.sent.count == 1 }
        u.cancel()
        let result = await task.value
        XCTAssertEqual(result, .cancelled)
        XCTAssertTrue(link.sockets[0].closed, "closing with 1000 makes the server drop the batch")
        XCTAssertEqual(link.sockets.count, 1)
    }

    func testAServerWithoutTheMethodIsUnsupported() async {
        let link = link()
        link.failures[Self.upload] = [RexError(code: "method_not_found", message: "method not found", status: 404)]
        do {
            try await uploader(link).send([item("a", bytes(1))]) { _, _ in }
            XCTFail("expected a failure")
        } catch let f as FileUploader.Failure {
            XCTAssertEqual(f, .unsupported)
        } catch { XCTFail("\(error)") }
        XCTAssertTrue(link.sockets.isEmpty)
    }

    func testARefusedBeginIsTheServersMessage() {
        let e = RexError(code: "conflict", message: "batch was aborted", status: 409)
        XCTAssertEqual(FileUploader.failure(beginning: e), .refused("batch was aborted"))
        XCTAssertEqual(FileUploader.failure(beginning: RexError.unsent("not connected")), .lost("not connected"))
        let big = RexError(code: "too_large", message: "too large: the file is 150000000 bytes, more than the 104857600 a terminal accepts", status: 413)
        XCTAssertEqual(FileUploader.failure(beginning: big), .tooLarge)
    }

    // MARK: Download

    private func downloader(_ link: FakeLink) -> FileDownloader {
        FileDownloader(link: link, sessionID: "session:s", blockID: "block:b")
    }

    private func info(size: Int, version: String? = "v1") -> JSONObject {
        var o: JSONObject = ["ticket": "AAECAwQFBgcICQoLDA0ODw", "expires_in_ms": 60000, "path": "/tmp/a b.txt",
                             "name": "a b.txt", "size": size, "modified_at": "2026-11-17T17:55:17Z"]
        if let version { o["version"] = version }
        return o
    }

    func testADownloadWritesTheStreamInOrderUntilTheServerCloses() async throws {
        let link = FakeLink()
        link.replies[Self.download] = info(size: 6)
        let d = downloader(link)
        let got = Received()
        var shown: [Int64] = []
        let task = Task { @MainActor in
            try await d.download(path: "a b.txt", limit: 100, write: { got.append($0) }, progress: { n, _ in shown.append(n) })
        }
        _ = await eventually { link.sockets.first?.receives ?? 0 >= 2 }
        let s = link.sockets[0]
        s.push([1, 2, 3])
        s.push([4, 5, 6])
        _ = await eventually { link.sockets[0].receives >= 4 }
        s.drop(code: 1000)
        let outcome = try await task.value
        XCTAssertEqual(got.data, Data([1, 2, 3, 4, 5, 6]), "written in order, all of it, before the download ends")
        XCTAssertEqual(shown, [0, 3, 6])
        XCTAssertEqual(outcome, .downloaded(FileDownloader.Info(path: "/tmp/a b.txt", name: "a b.txt", size: 6,
                                                                 modifiedAt: "2026-11-17T17:55:17Z", version: "v1")))
        XCTAssertEqual(link.subprotocols, [BytesStream.subprotocol])
        let args = try XCTUnwrap(link.calls.first?.payload.obj("args"))
        XCTAssertEqual(args.str("path"), "a b.txt")
        XCTAssertTrue(args.str("ref")?.hasPrefix("download:") == true)
    }

    func testACurrentCopyOpensNoConnection() async throws {
        let link = FakeLink()
        var reply = info(size: 6)
        reply["ticket"] = nil
        reply["not_modified"] = true
        link.replies[Self.download] = reply
        let outcome = try await downloader(link).download(path: "a", ifNoneMatch: "v1", limit: 100, write: { _ in })
        guard case .notModified = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(link.calls.first?.payload.obj("args")?.str("if_none_match"), "v1")
        XCTAssertTrue(link.sockets.isEmpty)
    }

    func testAFileOverTheLimitIsRefusedBeforeItsBytes() async {
        let link = FakeLink()
        link.replies[Self.download] = info(size: 500)
        do {
            _ = try await downloader(link).download(path: "a", limit: 100, write: { _ in })
            XCTFail("expected a failure")
        } catch let f as FileDownloader.Failure {
            XCTAssertEqual(f, .tooBig(500))
        } catch { XCTFail("\(error)") }
        XCTAssertTrue(link.sockets.isEmpty)
    }

    func testADownloadCutShortIsLost() async {
        let link = FakeLink()
        link.replies[Self.download] = info(size: 6)
        let d = downloader(link)
        let task = Task { @MainActor in
            do { _ = try await d.download(path: "a", limit: 100, write: { _ in }); return FileDownloader.Failure?.none }
            catch { return error as? FileDownloader.Failure }
        }
        _ = await eventually { link.sockets.first?.receives ?? 0 >= 2 }
        link.sockets[0].drop(code: 1006)
        let r = await task.value
        XCTAssertEqual(r, .lost("closed with 1006"))
    }

    func testCancellingADownloadCloses() async {
        let link = FakeLink()
        link.replies[Self.download] = info(size: 6)
        let d = downloader(link)
        let task = Task { @MainActor in
            do { _ = try await d.download(path: "a", limit: 100, write: { _ in }); return FileDownloader.Failure?.none }
            catch { return error as? FileDownloader.Failure }
        }
        _ = await eventually { link.sockets.first?.receives ?? 0 >= 2 }
        d.cancel()
        let r = await task.value
        XCTAssertEqual(r, .cancelled)
        XCTAssertTrue(link.sockets[0].closed)
    }

    func testProgressIsReportedOncePerPercent() {
        XCTAssertEqual(FileDownloader.percent(0, of: 1000), 0)
        XCTAssertEqual(FileDownloader.percent(9, of: 1000), 0)
        XCTAssertEqual(FileDownloader.percent(10, of: 1000), 1)
        XCTAssertEqual(FileDownloader.percent(2000, of: 1000), 100)
        XCTAssertEqual(FileDownloader.percent(0, of: 0), 100)
    }

    func testDownloadRefusalsInPlainCategories() {
        func f(_ code: String, _ msg: String) -> FileDownloader.Failure {
            FileDownloader.failure(beginning: RexError(code: code, message: msg, status: 400))
        }
        // The server's own wording, from a probe.
        XCTAssertEqual(f("not_found", "not found: /tmp/zz-files/nope does not exist"), .notFound)
        XCTAssertEqual(f("bad_request", "not a regular file: /tmp/zz-files is a directory"), .folder)
        XCTAssertEqual(f("bad_request", "not a regular file: /dev/null is a Dc---------"), .notAFile)
        XCTAssertEqual(f("bad_request", "opening /etc/shadow: open /etc/shadow: permission denied"), .noPermission)
        XCTAssertEqual(f("method_not_found", "method not found"), .unsupported)
        XCTAssertEqual(f("bad_request", "something else"), .refused("something else"))
    }
}

/// A download's bytes, written from the downloader's own queue.
private final class Received: @unchecked Sendable {
    // Safe: every access holds the lock.
    private let lock = NSLock()
    private var bytes = Data()

    func append(_ d: Data) { lock.lock(); bytes.append(d); lock.unlock() }
    var data: Data { lock.lock(); defer { lock.unlock() }; return bytes }
}
