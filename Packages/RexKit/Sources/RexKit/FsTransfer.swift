import Foundation

/// The fs block (`com.superlogical.fs`): a block that copies files and folders between its
/// computer and a client as one tar archive per transfer, over a `rex.data.bytes.v1` stream
/// (docs/rex-protocol.md, The fs block). Made with `session.new_block`, it starts detached: it is
/// in no window and no view, so no client shows it. Found by probing a revision-24 server
/// (preview.25, macOS):
///
/// - Upload: after the WELCOME the client sends the archive in messages of at most 64 KiB, then
///   one empty message. The server puts everything in place at once and closes with 1000.
///   Nothing shows at the destination before that: a stream that drops or closes early leaves
///   the destination as it was. An existing folder is merged into and an existing file is
///   replaced, without a word.
/// - A top-level entry count that differs from `roots`, a path with `..` or an absolute one, and
///   an entry whose folder came before it in no entry, close with 4006. `entries` and `size` are
///   not checked against the archive; `size` decides whether there is room (`too_large`, which
///   also wants 2 GiB left over).
/// - Download: the server sends a PAX archive and closes with 1000 at its end.
/// - Neither direction resumes (a RESUME is refused with 0x03), and a ticket left unused for
///   `expires_in_ms` (60 s) is refused with 0x01: a lost transfer starts over.
public enum FsBlock {
    public static let creator = "com.superlogical.fs"
    public static let flavor = "com.superlogical.fs.fs"
    public static let upload = "com.superlogical.fs.upload_begin"
    public static let download = "com.superlogical.fs.download_begin"
}

/// Opens a data connection for a ticket and returns it after its handshake. The app passes
/// `TunnelSession.open`, which asks the computer's gate first and runs off the main actor.
public typealias FsOpen = @MainActor (String) async throws -> any TunnelSocket

/// Sends a `TarPlan` to an fs block. The bytes are read, framed and sent off the main actor; the
/// main actor only paces (`UploadPacer`, one turn per up to `grant` bytes) and reports progress.
@MainActor
public final class FsUploader {
    public enum Failure: Error, Equatable {
        case cancelled
        /// The server refused the upload; its words, for logs.
        case refused(String)
        /// Too little room at the destination; the server's words, for logs.
        case noRoom(String)
        /// An item couldn't be read on this device; its name.
        case unreadable(String)
        /// A file changed while it was read; its name.
        case changed(String)
        /// The server refused the archive (4006).
        case brokeRule
        case lost(String)
        /// The archive went out whole, then the connection was lost before the server
        /// confirmed it: the files may be in place.
        case unconfirmed

        public var isRetryable: Bool { if case .lost = self { return true } else { return false } }
    }

    /// How often a lost upload is sent again from the start.
    public static let retryLimit = 2
    /// How long the server has to put everything in place after the end.
    public static let closeWait: Duration = .seconds(60)
    /// The most bytes one pacing turn covers: two messages.
    static let grant = 2 * BytesStream.maxMessage

    private let link: any StreamLink
    private let open: FsOpen
    public let sessionID: String
    public let blockID: String
    var rate = UploadRate()
    var sleep: @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    private var socket: (any TunnelSocket)?
    private var cancelled = false
    private var endSent = false

    public convenience init(control: RexControl, sessionID: String, blockID: String, open: @escaping FsOpen) {
        self.init(link: control, sessionID: sessionID, blockID: blockID, open: open)
    }

    init(link: any StreamLink, sessionID: String, blockID: String, open: @escaping FsOpen) {
        self.link = link
        self.sessionID = sessionID
        self.blockID = blockID
        self.open = open
    }

    /// Sends the plan to `path` (`upload_begin`'s rules) and returns the destination's absolute
    /// path as the server gives it. A connection lost before the end went out sends it all again
    /// from the start, up to `retryLimit` times. Throws a `Failure`.
    public func send(_ plan: TarPlan, to path: String, progress: @escaping @MainActor (Int64, Int64) -> Void,
                     onRetry: @escaping @MainActor (Int) -> Void = { _ in }) async throws -> String {
        var attempt = 0
        while true {
            do {
                return try await sendOnce(plan, to: path, progress: progress)
            } catch let f as Failure where f.isRetryable && attempt < Self.retryLimit && !cancelled {
                attempt += 1
                onRetry(attempt)
                await sleep(.seconds(1))
                if cancelled { throw Failure.cancelled }
            }
        }
    }

    /// Stops the upload: the server keeps nothing of it. Once the end has gone out it is too late.
    public func cancel() {
        guard !endSent else { return }
        cancelled = true
        socket?.close()
    }

    private func sendOnce(_ plan: TarPlan, to path: String, progress: @escaping @MainActor (Int64, Int64) -> Void) async throws -> String {
        if cancelled { throw Failure.cancelled }
        endSent = false
        let args: JSONObject = ["ref": BytesStream.ref("upload"), "path": path, "roots": plan.roots,
                                "entries": plan.entries, "size": plan.size]
        let reply: JSONObject
        do {
            reply = try await link.call(FsBlock.upload, ["session_id": sessionID, "block_id": blockID, "args": args])
        } catch {
            throw Self.failure(beginning: error)
        }
        guard let ticket = reply.str("ticket") else { throw Failure.lost("no ticket") }
        let dest = reply.str("path") ?? path
        if cancelled { throw Failure.cancelled }
        let socket: any TunnelSocket
        do { socket = try await open(ticket) } catch { throw Failure.lost(error.localizedDescription) }
        self.socket = socket
        defer { self.socket = nil }
        if cancelled { socket.close(); throw Failure.cancelled }
        let stream = TarStream(plan)
        let pacer = UploadPacer(link: link, rate: rate, sleep: sleep)
        defer { rate = pacer.rate }
        progress(0, plan.archiveSize)
        do {
            var sent: Int64 = 0
            while true {
                if cancelled { throw Failure.cancelled }
                let grant = await pacer.turn(upTo: Self.grant)
                if cancelled { throw Failure.cancelled }
                let n = try await Self.push(stream, to: socket, upTo: grant)
                if n == 0 { break }
                sent += Int64(n)
                progress(sent, plan.archiveSize)
            }
            if cancelled { throw Failure.cancelled }
            endSent = true
            try await socket.send(Data())
        } catch let f as Failure {
            socket.close()
            throw cancelled ? .cancelled : f
        } catch let f as TarStream.Failure {
            socket.close()
            switch f {
            case .changed(let name): throw Failure.changed(name)
            case .unreadable(let name): throw Failure.unreadable(name)
            }
        } catch {
            socket.close()
            if cancelled { throw Failure.cancelled }
            throw endSent ? Failure.unconfirmed : Failure.lost(error.localizedDescription)
        }
        try await waitForClose(socket)
        return dest
    }

    /// Up to `max` bytes of the archive as messages of at most 64 KiB, read and sent off the main
    /// actor. 0 once the archive is over.
    @concurrent
    nonisolated static func push(_ stream: TarStream, to socket: any TunnelSocket, upTo max: Int) async throws -> Int {
        var sent = 0
        while sent < max {
            let chunk = try stream.next(upTo: min(BytesStream.maxMessage, max - sent))
            if chunk.isEmpty { break }
            try await socket.send(chunk)
            sent += chunk.count
        }
        return sent
    }

    /// The server closes once everything is in place: 1000 when it took it.
    private func waitForClose(_ socket: any TunnelSocket) async throws {
        let timedOut = TimeoutFlag()
        let sleep = self.sleep
        let timer = Task { @MainActor in
            await sleep(Self.closeWait)
            guard !Task.isCancelled else { return }
            timedOut.set = true
            socket.abort()
        }
        defer { timer.cancel() }
        await Self.drain(socket)
        if timedOut.set { throw Failure.unconfirmed }
        switch socket.closeCode {
        case BytesStream.normal: return
        case BytesStream.brokeRule: throw Failure.brokeRule
        default: throw Failure.unconfirmed
        }
    }

    /// Reads until the socket closes; the server sends nothing on an upload.
    @concurrent
    nonisolated static func drain(_ socket: any TunnelSocket) async {
        while true {
            do { _ = try await socket.receive() } catch { return }
        }
    }

    /// What a failed `upload_begin` means.
    static func failure(beginning error: Error) -> Failure {
        guard let e = error as? RexError else { return .lost(error.localizedDescription) }
        switch e.code {
        case "too_large": return .noRoom(e.message)
        case "client": return .lost(e.message)
        default: return .refused(e.message)
        }
    }
}

/// Fetches files and folders from an fs block and writes them under a folder of this device as
/// the archive arrives: receiving, reading the archive and writing run off the main actor, and
/// only a whole percent of progress reaches it.
@MainActor
public final class FsDownloader {
    public struct Info: Equatable, Sendable {
        public var roots: Int
        public var entries: Int
        public var size: Int64
    }

    public struct Result: Equatable, Sendable {
        public var info: Info
        /// The top-level names written under the folder.
        public var tops: [String]
        /// Links and other entries left out.
        public var skipped: Int
    }

    public enum Failure: Error, Equatable {
        case cancelled
        case notFound
        case noPermission
        case refused(String)
        /// This device has too little room; the bytes needed.
        case noRoom(Int64)
        /// The archive named a path outside the folder.
        case unsafe(String)
        /// This device couldn't write; the system's words, for logs.
        case saveFailed(String)
        case lost(String)
    }

    private let link: any StreamLink
    private let open: FsOpen
    public let sessionID: String
    public let blockID: String
    private var socket: (any TunnelSocket)?
    private var cancelled = false

    public convenience init(control: RexControl, sessionID: String, blockID: String, open: @escaping FsOpen) {
        self.init(link: control, sessionID: sessionID, blockID: blockID, open: open)
    }

    init(link: any StreamLink, sessionID: String, blockID: String, open: @escaping FsOpen) {
        self.link = link
        self.sessionID = sessionID
        self.blockID = blockID
        self.open = open
    }

    public func cancel() {
        cancelled = true
        socket?.close()
    }

    /// Downloads `paths` (each taken literally: `TarPath.literal`), folders with everything in
    /// them, into `root`, a new empty folder. `hasRoom` is asked with the bytes of content before
    /// anything is sent. `progress` gets the bytes written and the total, at most once per
    /// percent. What arrived is left in `root` on a failure; the caller deletes it.
    public func download(_ paths: [String], into root: URL, hasRoom: @escaping @Sendable (Int64) -> Bool,
                         progress: @escaping @MainActor (Int64, Int64) -> Void) async throws -> Result {
        let args: JSONObject = ["ref": BytesStream.ref("download"), "paths": paths.map(TarPath.literal), "recursive": true]
        let reply: JSONObject
        do {
            reply = try await link.call(FsBlock.download, ["session_id": sessionID, "block_id": blockID, "args": args])
        } catch {
            throw Self.failure(beginning: error)
        }
        let info = Info(roots: reply.int("roots") ?? 0, entries: reply.int("entries") ?? 0, size: Int64(reply.int("size") ?? 0))
        guard let ticket = reply.str("ticket") else { throw Failure.lost("no ticket") }
        guard hasRoom(info.size) else { throw Failure.noRoom(info.size) }
        if cancelled { throw Failure.cancelled }
        let socket: any TunnelSocket
        do { socket = try await open(ticket) } catch { throw Failure.lost(error.localizedDescription) }
        self.socket = socket
        defer { self.socket = nil }
        if cancelled { socket.close(); throw Failure.cancelled }
        progress(0, info.size)
        let extractor = TarExtractor(root: root)
        let outcome = await Self.pull(socket, into: extractor, size: info.size, progress: progress)
        if cancelled { throw Failure.cancelled }
        switch outcome {
        case .failed(let f):
            socket.close()
            throw f
        case .closed:
            guard socket.closeCode == BytesStream.normal else { throw Failure.lost("closed with \(socket.closeCode)") }
            do { try extractor.finish() } catch { throw Failure.lost("the archive ended early") }
            return Result(info: info, tops: extractor.tops, skipped: extractor.skipped)
        }
    }

    enum PullEnd: Sendable {
        case closed
        case failed(Failure)
    }

    /// Receives until the socket closes, feeding the archive to `extractor`.
    @concurrent
    nonisolated static func pull(_ socket: any TunnelSocket, into extractor: TarExtractor, size: Int64,
                                 progress: @escaping @MainActor (Int64, Int64) -> Void) async -> PullEnd {
        var shown = -1
        while true {
            let message: Data?
            do { message = try await socket.receive() } catch { return .closed }
            guard let message else { continue }
            do { try extractor.feed(message) } catch let f as TarExtractor.Failure {
                switch f {
                case .unsafePath(let p): return .failed(.unsafe(p))
                case .writeFailed(let w): return .failed(.saveFailed(w))
                }
            } catch {
                return .failed(.lost("not an archive"))
            }
            let written = extractor.written
            let pct = size > 0 ? Int(min(written * 100 / size, 100)) : 100
            if pct != shown {
                shown = pct
                Task { @MainActor in progress(written, size) }
            }
        }
    }

    /// What a failed `download_begin` means.
    static func failure(beginning error: Error) -> Failure {
        guard let e = error as? RexError else { return .lost(error.localizedDescription) }
        switch e.code {
        case "not_found": return .notFound
        case "client": return .lost(e.message)
        default:
            let m = e.message.lowercased()
            if m.contains("permission denied") || m.contains("operation not permitted") { return .noPermission }
            if m.contains("no such file") || m.contains("does not exist") { return .notFound }
            return .refused(e.message)
        }
    }
}

/// A flag set by a timer and read by what waited.
@MainActor
private final class TimeoutFlag {
    var set = false
}
