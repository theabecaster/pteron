import Foundation

/// The rules of a `rex.data.bytes.v1` data stream, which carries one file's bytes to or from a
/// terminal's machine (`com.superlogical.terminal.upload_begin` and `download_begin`).
///
/// The server's /llms.txt documents the methods and the handshake but not the upload's bytes.
/// These were found by probing a Rex server (API revision 13, Linux and macOS; docs/rex-protocol.md):
///
/// - Upload: after the WELCOME the client sends the file as binary messages of at most 64 KiB, then
///   one empty binary message to say the file is complete. The server then moves the file into place
///   and closes with 1000. The file lands at `<state>/rex/uploads/<server run>/<block>/<ref>/<name>`
///   and is removed when its pane closes.
/// - A file that ends short of its `size`, or runs past it, is refused: the server closes with 4006
///   (`data stream broke a rule`). So is a message over 64 KiB (the connection drops).
/// - Any other end before the empty message, a close with 1000 included, aborts the upload and its
///   whole batch; the batch's other files are deleted and its ID can't be used again (`conflict`).
///   An upload can't be resumed: a RESUME is refused (REJECT 0x03). A lost file is sent again
///   from the start, with its batch, under a new batch ID.
/// - Download: after the WELCOME the server sends the file as binary messages and closes with 1000
///   at its end. Closing with 1000 cancels it.
public enum BytesStream {
    public static let subprotocol = "rex.data.bytes.v1"
    /// The largest message the server takes in an upload.
    public static let maxMessage = 65_536
    /// The server's close status for a stream that broke a rule, such as a file of the wrong size.
    public static let brokeRule = 4006
    /// The normal end of a stream.
    public static let normal = 1000

    /// A data reference: the kind (`upload` or `download`), then a new UUID in lower case.
    public static func ref(_ kind: String, _ id: UUID = UUID()) -> String {
        "\(kind):\(id.uuidString.lowercased())"
    }

    /// `upload_begin`'s arguments. A batch has an ID, the file's index and the batch's size; a file
    /// sent on its own has none, and its path is typed as soon as it arrives.
    public static func uploadArgs(ref: String, name: String, size: Int64, batch: String?, index: Int, count: Int) -> JSONObject {
        var args: JSONObject = ["ref": ref, "name": name, "size": size]
        if let batch {
            args["batch"] = batch
            args["index"] = index
            args["count"] = count
        }
        return args
    }

    /// The sizes of the messages that carry `size` bytes, in order.
    public static func chunks(size: Int64, max: Int = maxMessage) -> [Int] {
        guard size > 0 else { return [] }
        let full = Int(size / Int64(max))
        let rest = Int(size % Int64(max))
        return Array(repeating: max, count: full) + (rest > 0 ? [rest] : [])
    }
}

/// Where an upload's bytes come from. Read in order, at most `max` bytes at a time, so a file is
/// never held in memory whole.
public protocol UploadSource: Sendable {
    /// The next bytes, at most `max`; empty at the end.
    func read(upTo max: Int) async throws -> Data
}

/// A file on disk as an upload's source. Reads off the main actor.
public final class FileSource: UploadSource, @unchecked Sendable {
    // Safe: an upload reads its source from one task, one read at a time, and closes it after.
    private let handle: FileHandle

    public init(url: URL) throws { handle = try FileHandle(forReadingFrom: url) }

    public func read(upTo max: Int) async throws -> Data {
        try handle.read(upToCount: max) ?? Data()
    }

    deinit { try? handle.close() }
}

/// Bytes in memory as an upload's source (tests, and small text).
public final class DataSource: UploadSource, @unchecked Sendable {
    // Safe: read from one task, one read at a time.
    private let data: Data
    private var offset = 0

    public init(_ data: Data) { self.data = data }

    public func read(upTo max: Int) async throws -> Data {
        let end = min(offset + max, data.count)
        defer { offset = end }
        return data.subdata(in: offset..<end)
    }
}

/// Sends files to a terminal's machine, which types their paths into the terminal as if pasted
/// once they have all arrived. One file at a time, each with its own ticket asked for just before
/// its connection opens. See `BytesStream` for the wire rules.
@MainActor
public final class FileUploader {
    public struct Item: Sendable {
        public var name: String
        public var size: Int64
        public var open: @Sendable () throws -> any UploadSource

        public init(name: String, size: Int64, open: @escaping @Sendable () throws -> any UploadSource) {
            self.name = name
            self.size = size
            self.open = open
        }
    }

    public enum Failure: Error, Equatable {
        /// The server has no `upload_begin`.
        case unsupported
        /// `cancel()` was called.
        case cancelled
        /// The server refused the upload; its message.
        case refused(String)
        /// The server refused the bytes (4006): the file changed size while it was read.
        case brokeRule
        /// The connection was lost, or the server didn't answer.
        case lost(String)
        /// Larger than the server takes (`too_large`).
        case tooLarge
        /// The batch's last file went out whole, then the connection was lost before the server
        /// confirmed it. The server may have typed the paths, so it isn't sent again.
        case unconfirmed

        /// Worth sending the batch again from the start.
        public var isRetryable: Bool { if case .lost = self { return true } else { return false } }
    }

    /// The largest file a terminal takes, from a probe of the server (its `too_large` error says
    /// 104857600). The server's answer decides; this lets a batch be refused before any of it goes.
    public nonisolated static let maxFileSize: Int64 = 104_857_600
    /// How often a lost batch is sent again from the start.
    public static let retryLimit = 2
    /// How long the server has to close after the end of a file.
    public static let closeWait: Duration = .seconds(30)
    /// How long a retry waits for the control connection.
    public static let controlWait: Duration = .seconds(15)

    private let link: any StreamLink
    public let sessionID: String
    public let blockID: String
    private var socket: (any StreamSocket)?
    private var cancelled = false
    /// The empty message after the batch's last file has gone out: the server may type at any moment.
    private var lastFileOut = false
    /// Every wait goes through here, so tests can skip them.
    var sleep: @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) }

    public convenience init(control: RexControl, sessionID: String, blockID: String) {
        self.init(link: control, sessionID: sessionID, blockID: blockID)
    }

    init(link: any StreamLink, sessionID: String, blockID: String) {
        self.link = link
        self.sessionID = sessionID
        self.blockID = blockID
    }

    /// Sends `items` as one batch, a single file included: their paths are typed together, in this
    /// order, once all arrived. `progress` gets the bytes sent and the total. A batch lost before
    /// its last file went out whole is sent again from the start under a new ID, up to
    /// `retryLimit` times; `onRetry` hears each time. Once that last file is out, nothing is sent
    /// again: the server may already have typed the paths. Throws a `Failure`.
    public func send(_ items: [Item], progress: @escaping @MainActor (Int64, Int64) -> Void,
                     onRetry: @escaping @MainActor (Int) -> Void = { _ in }) async throws {
        var attempt = 0
        while true {
            do {
                try await sendOnce(items, progress: progress)
                return
            } catch let f as Failure where f.isRetryable && attempt < Self.retryLimit && !cancelled {
                attempt += 1
                onRetry(attempt)
                await sleep(.seconds(1))
                if cancelled { throw Failure.cancelled }
                await waitForControl()
            }
        }
    }

    /// Stops the upload. The server deletes what arrived of the batch and types nothing: a file on
    /// its way is cut off, and between files the next one is reserved and cut off at once. Once the
    /// batch's last file has gone out whole it is too late, and the send ends as it would have.
    public func cancel() {
        guard !lastFileOut else { return }
        cancelled = true
        socket?.close()
    }

    private func waitForControl() async {
        guard !link.isConnected else { return }
        let back = Flag()
        link.observeConnected { back.set = true; return false }
        var waited: Duration = .zero
        while !back.set, !cancelled, waited < Self.controlWait {
            await sleep(.milliseconds(250))
            waited += .milliseconds(250)
        }
    }

    private func sendOnce(_ items: [Item], progress: @escaping @MainActor (Int64, Int64) -> Void) async throws {
        let total = items.reduce(Int64(0)) { $0 + $1.size }
        let batch = UUID().uuidString.lowercased()
        lastFileOut = false
        var base: Int64 = 0
        progress(0, total)
        for (index, item) in items.enumerated() {
            let before = base
            do {
                try await sendFile(item, batch: batch, index: index, count: items.count) { sent in
                    progress(before + sent, total)
                }
            } catch Failure.cancelled where index + 1 < items.count {
                // Cancelled while this file was finishing: the server may hold it and the ones
                // before it. Cutting off the next one makes it drop them all.
                await abort(batch: batch, index: index + 1, count: items.count)
                throw Failure.cancelled
            }
            base += item.size
        }
    }

    /// Reserves file `index` of the batch and cuts it off at once, so the server aborts the batch and
    /// deletes its files. A batch the server already aborted refuses the reservation; that is fine.
    private func abort(batch: String, index: Int, count: Int) async {
        let args = BytesStream.uploadArgs(ref: BytesStream.ref("upload"), name: "cancelled", size: 0,
                                          batch: batch, index: index, count: count)
        guard let reply = try? await link.call("com.superlogical.terminal.upload_begin",
                                               ["session_id": sessionID, "block_id": blockID, "args": args]),
              let ticket = reply.str("ticket"), let hello = DataFrame.ticketHello(ticket),
              let socket = try? openSocket() else { return }
        try? await handshake(socket, hello: hello)
        socket.close()
    }

    private func sendFile(_ item: Item, batch: String, index: Int, count: Int,
                          progress: @escaping @MainActor (Int64) -> Void) async throws {
        // Nothing of the batch is on the server yet. Past the first file, a cancel still reserves
        // this file and cuts it off, which makes the server drop the files before it.
        if cancelled, index == 0 { throw Failure.cancelled }
        let args = BytesStream.uploadArgs(ref: BytesStream.ref("upload"), name: item.name, size: item.size,
                                          batch: batch, index: index, count: count)
        let reply: JSONObject
        do {
            reply = try await link.call("com.superlogical.terminal.upload_begin",
                                        ["session_id": sessionID, "block_id": blockID, "args": args])
        } catch {
            throw Self.failure(beginning: error)
        }
        guard let ticket = reply.str("ticket"), let hello = DataFrame.ticketHello(ticket) else {
            throw Failure.lost("no ticket")
        }
        let source: any UploadSource
        do { source = try item.open() } catch { throw Failure.refused("Couldn't read \(item.name).") }
        let socket = try openSocket()
        self.socket = socket
        defer { if self.socket === socket { self.socket = nil } }
        let last = index == count - 1
        do {
            try await handshake(socket, hello: hello)
            var sent: Int64 = 0
            while sent < item.size {
                if cancelled { throw Failure.cancelled }
                let want = Int(min(Int64(BytesStream.maxMessage), item.size - sent))
                let chunk = try await source.read(upTo: want)
                // Shorter than its size: the server would refuse it at the end anyway.
                guard !chunk.isEmpty else { throw Failure.brokeRule }
                try await socket.send(chunk)
                sent += Int64(chunk.count)
                progress(sent)
            }
            if cancelled { throw Failure.cancelled }
            if last { lastFileOut = true }
            try await socket.send(Data())
        } catch let f as Failure {
            socket.close()
            throw cancelled ? .cancelled : f
        } catch {
            socket.close()
            if cancelled { throw Failure.cancelled }
            throw lastFileOut ? Failure.unconfirmed : Failure.lost(error.localizedDescription)
        }
        do {
            try await waitForClose(socket)
        } catch Failure.lost(_) where lastFileOut {
            throw Failure.unconfirmed
        }
    }

    /// The server closes once the file is in place: 1000 when it took it.
    private func waitForClose(_ socket: any StreamSocket) async throws {
        let timedOut = Flag()
        let sleep = self.sleep
        let timer = Task { @MainActor [weak socket] in
            await sleep(Self.closeWait)
            guard !Task.isCancelled else { return }
            timedOut.set = true
            socket?.close()
        }
        defer { timer.cancel() }
        while true {
            do {
                _ = try await socket.receive()  // the server sends nothing more; skip anything it does
            } catch {
                break
            }
        }
        if cancelled { throw Failure.cancelled }
        if timedOut.set { throw Failure.lost("the server didn't confirm the file") }
        switch socket.closeCode {
        case BytesStream.normal: return
        case BytesStream.brokeRule: throw Failure.brokeRule
        case let code: throw Failure.lost("closed with \(code)")
        }
    }

    private func openSocket() throws -> any StreamSocket {
        do { return try link.openDataSocket(subprotocol: BytesStream.subprotocol) } catch {
            throw Failure.lost(error.localizedDescription)
        }
    }

    private func handshake(_ socket: any StreamSocket, hello: [UInt8]) async throws {
        try await socket.send(Data(hello))
        guard let answer = try await socket.receive() else { throw Failure.lost("bad handshake") }
        do { _ = try DataFrame.welcome([UInt8](answer)) } catch { throw Failure.lost(error.localizedDescription) }
    }

    /// What a failed `upload_begin` means.
    static func failure(beginning error: Error) -> Failure {
        guard let e = error as? RexError else { return .lost(error.localizedDescription) }
        if e.code == "method_not_found" { return .unsupported }
        if e.code == "too_large" { return .tooLarge }
        if e.code == "client" { return .lost(e.message) }
        return .refused(e.message)
    }

    /// Whether the server takes uploads and downloads, or nil when it couldn't be told (no
    /// connection). Asks with a reference the server must refuse, so nothing is reserved: a server
    /// with the methods answers `bad_request`, one without `method_not_found`.
    public static func probeSupport(control: RexControl, sessionID: String, blockID: String) async -> Bool? {
        await probeSupport(link: control, sessionID: sessionID, blockID: blockID)
    }

    static func probeSupport(link: any StreamLink, sessionID: String, blockID: String) async -> Bool? {
        let asks: [(String, JSONObject)] = [
            ("com.superlogical.terminal.upload_begin", ["ref": "upload:probe", "name": "probe", "size": 0]),
            ("com.superlogical.terminal.download_begin", ["ref": "download:probe", "path": "/"]),
        ]
        for (method, args) in asks {
            do {
                _ = try await link.call(method, ["session_id": sessionID, "block_id": blockID, "args": args])
            } catch let e as RexError {
                if e.code == "method_not_found" { return false }
                if e.code == "client" { return nil }
            } catch {
                return nil
            }
        }
        return true
    }
}

/// Hands a download's bytes to its `write` on a serial queue, in order, and keeps the first error.
private final class Writer: @unchecked Sendable {
    // Safe: `failed` is only touched on `queue`, which runs one block at a time.
    private let queue = DispatchQueue(label: "dev.rexkit.download-writer", qos: .utility)
    private let write: @Sendable (Data) throws -> Void
    private var failed: Error?

    init(_ write: @escaping @Sendable (Data) throws -> Void) { self.write = write }

    func write(_ data: Data) {
        queue.async {
            guard self.failed == nil else { return }
            do { try self.write(data) } catch { self.failed = error }
        }
    }

    /// Waits for the writes so far, and gives the first error.
    @discardableResult
    func finish() async -> Error? {
        await withCheckedContinuation { c in queue.async { c.resume(returning: self.failed) } }
    }
}

/// A flag set from a callback and read by the code that waits for it.
@MainActor
private final class Flag {
    var set = false
}

/// Fetches a file from a terminal's machine. A relative path is relative to the working directory of
/// the terminal's foreground process, and a leading `~` is the home directory.
@MainActor
public final class FileDownloader {
    public struct Info: Sendable, Equatable {
        /// The absolute path, symlinks left as they are.
        public var path: String
        public var name: String
        public var size: Int64
        public var modifiedAt: String?
        /// Changes whenever the contents may have; nil when the copy must not be cached.
        public var version: String?

        public init(path: String, name: String, size: Int64, modifiedAt: String? = nil, version: String? = nil) {
            self.path = path
            self.name = name
            self.size = size
            self.modifiedAt = modifiedAt
            self.version = version
        }

        init(_ o: JSONObject, asked: String) {
            path = o.str("path") ?? asked
            name = o.str("name") ?? (path as NSString).lastPathComponent
            size = Int64(o.int("size") ?? 0)
            modifiedAt = o.str("modified_at")
            version = o.str("version")
        }
    }

    public enum Outcome: Sendable, Equatable {
        /// The copy with `ifNoneMatch` is current; nothing was written.
        case notModified(Info)
        case downloaded(Info)
    }

    public enum Failure: Error, Equatable {
        case unsupported
        case notFound
        case folder
        /// A device, socket or the like: only regular files can be downloaded.
        case notAFile
        case noPermission
        /// Larger than the limit; the file's size.
        case tooBig(Int64)
        case refused(String)
        case lost(String)
        case cancelled
    }

    private let link: any StreamLink
    public let sessionID: String
    public let blockID: String
    private var socket: (any StreamSocket)?
    private var cancelled = false

    public convenience init(control: RexControl, sessionID: String, blockID: String) {
        self.init(link: control, sessionID: sessionID, blockID: blockID)
    }

    init(link: any StreamLink, sessionID: String, blockID: String) {
        self.link = link
        self.sessionID = sessionID
        self.blockID = blockID
    }

    public func cancel() {
        cancelled = true
        socket?.close()
    }

    /// Downloads `path`, handing its bytes to `write` in order, on a queue of its own: the main
    /// actor only hands them on. `progress` gets the bytes received and the size the server gave, at
    /// most once per percent. Throws a `Failure`.
    public func download(path: String, ifNoneMatch: String? = nil, limit: Int64,
                         write: @escaping @Sendable (Data) throws -> Void,
                         progress: @escaping @MainActor (Int64, Int64) -> Void = { _, _ in }) async throws -> Outcome {
        var args: JSONObject = ["ref": BytesStream.ref("download"), "path": path]
        if let ifNoneMatch { args["if_none_match"] = ifNoneMatch }
        let reply: JSONObject
        do {
            reply = try await link.call("com.superlogical.terminal.download_begin",
                                        ["session_id": sessionID, "block_id": blockID, "args": args])
        } catch {
            throw Self.failure(beginning: error)
        }
        let info = Info(reply, asked: path)
        if reply.bool("not_modified") == true { return .notModified(info) }
        guard info.size <= limit else { throw Failure.tooBig(info.size) }
        guard let ticket = reply.str("ticket"), let hello = DataFrame.ticketHello(ticket) else {
            throw Failure.lost("no ticket")
        }
        if cancelled { throw Failure.cancelled }
        let socket: any StreamSocket
        do { socket = try link.openDataSocket(subprotocol: BytesStream.subprotocol) } catch {
            throw Failure.lost(error.localizedDescription)
        }
        self.socket = socket
        defer { if self.socket === socket { self.socket = nil } }
        var received: Int64 = 0
        let writer = Writer(write)
        var shown = -1
        do {
            try await socket.send(Data(hello))
            guard let answer = try await socket.receive() else { throw Failure.lost("bad handshake") }
            do { _ = try DataFrame.welcome([UInt8](answer)) } catch { throw Failure.lost(error.localizedDescription) }
            progress(0, info.size)
            while true {
                let message: Data?
                do { message = try await socket.receive() } catch { break }
                guard let message else { continue }
                received += Int64(message.count)
                // The file grew past the limit while it was read.
                if received > limit { socket.close(); throw Failure.tooBig(received) }
                writer.write(message)
                let percent = Self.percent(received, of: info.size)
                if percent != shown {
                    shown = percent
                    progress(received, info.size)
                }
            }
        } catch let f as Failure {
            socket.close()
            await writer.finish()
            throw cancelled ? .cancelled : f
        } catch {
            socket.close()
            await writer.finish()
            throw cancelled ? Failure.cancelled : Failure.lost(error.localizedDescription)
        }
        if let error = await writer.finish() { throw Failure.refused("Couldn't save it: \(error.localizedDescription)") }
        if cancelled { throw Failure.cancelled }
        guard socket.closeCode == BytesStream.normal else { throw Failure.lost("closed with \(socket.closeCode)") }
        return .downloaded(info)
    }

    /// Whole percent of `size` that `got` is; 100 for an empty or overrun file.
    static func percent(_ got: Int64, of size: Int64) -> Int {
        size > 0 ? Int(min(got * 100 / size, 100)) : 100
    }

    /// What a failed `download_begin` means. The server words a folder, a device and a file it
    /// can't open all as `bad_request`, so the message tells them apart.
    static func failure(beginning error: Error) -> Failure {
        guard let e = error as? RexError else { return .lost(error.localizedDescription) }
        switch e.code {
        case "method_not_found": return .unsupported
        case "not_found": return .notFound
        case "client": return .lost(e.message)
        default:
            let m = e.message.lowercased()
            if m.contains("is a directory") { return .folder }
            if m.contains("permission denied") { return .noPermission }
            if m.contains("not a regular file") { return .notAFile }
            if m.contains("does not exist") || m.contains("no such file") { return .notFound }
            return .refused(e.message)
        }
    }
}
