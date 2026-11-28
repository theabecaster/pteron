import Foundation

/// The fs block (`com.superlogical.fs`): a block that copies files and folders between its
/// computer and a client as one tar archive per transfer, over a `rex.data.bytes.v1` stream
/// (docs/rex-protocol.md, The fs block). Made with `session.new_block`, it starts detached: it is
/// in no window and no view, so no client shows it. Found by probing a revision-24 server
/// (preview.25, macOS):
///
/// - Upload: after the WELCOME the client sends the archive in messages of at most 64 KiB, then
///   one empty message. The server then puts everything in place (under `/tmp/.rex-fs-<id>`,
///   moved to the destination at the end: about 220 entries a second, 13 s for 3,000 small files)
///   and closes with 1000. Nothing shows at the destination before that: a stream that drops or
///   closes early leaves the destination as it was. Once the end is in, closing the data
///   connection doesn't stop it, but closing the fs block does (4000), and nothing is left. An
///   existing folder is merged into and an existing file is replaced, without a word.
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
    /// How long the server has at least to put everything in place after the end
    /// (`confirmWait` adds the time the plan's entries and content take).
    public static let closeWait: Duration = .seconds(60)
    /// How many entries a second the server puts in place: about 210 on an M-series Mac
    /// (30,032 small files in 143 s, probed), from the stream's start, as the archive arrives far
    /// faster. The progress counts on it.
    static let placeRate = 200.0
    /// The slowest server waited for: a tenth of that, and 8 MiB of content a second.
    static let slowestPlaceRate = 20.0
    static let slowestWriteRate = 8.0 * 1_048_576
    /// The most bytes one pacing turn covers: two messages.
    static let grant = 2 * BytesStream.maxMessage

    private let link: any StreamLink
    private let open: FsOpen
    public let sessionID: String
    public let blockID: String
    var rate = UploadRate()
    var sleep: @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    private var socket: (any TunnelSocket)?
    private let stop = CancelWait(Failure.cancelled)
    private var cancelled: Bool { stop.isSet }
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
                let sleep = self.sleep
                try await stop.unlessCancelled { await sleep(.seconds(1)) }
            }
        }
    }

    /// Stops the upload: `send` throws `Failure.cancelled` at once, wherever it waits (the
    /// start's answer, the data connection's handshake, the pause before a retry, the stream, the
    /// server's confirmation). The start's late answer is dropped and its ticket never used; a
    /// data connection that opens late is closed. Before the end the server keeps nothing. After
    /// it the server is still putting the archive in place, seconds for a large folder, and only
    /// the fs block's close stops that, which the caller does once `send` ends: the folder is
    /// left only if the server had finished.
    public func cancel() {
        stop.cancel()
        socket?.close()
    }

    private func sendOnce(_ plan: TarPlan, to path: String, progress: @escaping @MainActor (Int64, Int64) -> Void) async throws -> String {
        if cancelled { throw Failure.cancelled }
        endSent = false
        let args: JSONObject = ["ref": BytesStream.ref("upload"), "path": path, "roots": plan.roots,
                                "entries": plan.entries, "size": plan.size]
        let link = self.link, payload: JSONObject = ["session_id": sessionID, "block_id": blockID, "args": args]
        let reply = try await stop.unlessCancelled {
            do { return try await link.call(FsBlock.upload, payload) } catch { throw Self.failure(beginning: error) }
        }
        guard let ticket = reply.str("ticket") else { throw Failure.lost("no ticket") }
        let dest = reply.str("path") ?? path
        if cancelled { throw Failure.cancelled }
        let open = self.open
        let socket = try await stop.unlessCancelled({
            do { return try await open(ticket) } catch { throw Failure.lost(error.localizedDescription) }
        }, late: { $0.close() })
        self.socket = socket
        defer { self.socket = nil }
        if cancelled { socket.close(); throw Failure.cancelled }
        // A cancel ends the wait at once; the stream, which it closed, ends behind it.
        try await stop.unlessCancelled { try await self.stream(plan, over: socket, progress: progress) }
        return dest
    }

    /// How long the server has to confirm after the end: `closeWait`, and the time the slowest
    /// server takes to put `entries` and `size` bytes of content in place. The protocol shows no
    /// progress meanwhile: the server says nothing, and doesn't even answer a ping on the data
    /// connection (132 s for 30,032 entries, probed), so the wait is scaled, not reset. A Cancel
    /// ends it at any time.
    static func confirmWait(entries: Int, size: Int64) -> Duration {
        closeWait + .seconds(Double(entries) / slowestPlaceRate) + .seconds(Double(size) / slowestWriteRate)
    }

    /// The bytes the progress shows `elapsed` after the stream started: the bytes sent, or the
    /// share of the archive the entries the server has likely put in place stand for, whichever
    /// is less, and never the whole archive before the server confirms. A single large file
    /// shows its bytes; many small ones keep moving while the server puts them in place, and
    /// wait at 99% if it is slower than `placeRate`.
    static func shown(sent: Int64, archive: Int64, entries: Int, elapsed: Duration) -> Int64 {
        let placed = min(1, UploadRate.seconds(elapsed) * placeRate / Double(max(entries, 1)))
        return max(0, min(sent, Int64(Double(archive) * placed), archive - 1))
    }

    /// Sends the archive and its end over `socket`, then waits for the server's confirmation.
    private func stream(_ plan: TarPlan, over socket: any TunnelSocket,
                        progress: @escaping @MainActor (Int64, Int64) -> Void) async throws {
        let stream = TarStream(plan)
        let pacer = UploadPacer(link: link, rate: rate, sleep: sleep)
        defer { rate = pacer.rate }
        let start = ContinuousClock.now
        let shown: @MainActor (Int64) -> Void = { sent in
            progress(Self.shown(sent: sent, archive: plan.archiveSize, entries: plan.entries, elapsed: .now - start),
                     plan.archiveSize)
        }
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
                shown(sent)
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
        // The server is still putting entries in place: the estimate keeps the progress moving.
        let ticker = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, !self.cancelled else { return }
                shown(plan.archiveSize)
            }
        }
        defer { ticker.cancel() }
        try await waitForClose(socket, wait: Self.confirmWait(entries: plan.entries, size: plan.size))
        progress(plan.archiveSize, plan.archiveSize)
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

    /// The server closes once everything is in place: 1000 when it took it. Waits `wait` at most.
    private func waitForClose(_ socket: any TunnelSocket, wait: Duration) async throws {
        let timedOut = TimeoutFlag()
        let sleep = self.sleep
        let timer = Task { @MainActor in
            await sleep(wait)
            guard !Task.isCancelled else { return }
            timedOut.set = true
            socket.abort()
        }
        defer { timer.cancel() }
        await Self.drain(socket)
        // The close was this side's own.
        if cancelled { throw Failure.cancelled }
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
    private let stop = CancelWait(Failure.cancelled)
    private var cancelled: Bool { stop.isSet }

    public convenience init(control: RexControl, sessionID: String, blockID: String, open: @escaping FsOpen) {
        self.init(link: control, sessionID: sessionID, blockID: blockID, open: open)
    }

    init(link: any StreamLink, sessionID: String, blockID: String, open: @escaping FsOpen) {
        self.link = link
        self.sessionID = sessionID
        self.blockID = blockID
        self.open = open
    }

    /// Stops the download: `download` throws `Failure.cancelled` at once, wherever it waits. The
    /// server answers `download_begin` only once it has walked the whole tree, seconds for a large
    /// folder, so that answer is not waited for: it is dropped when it comes, and its ticket is
    /// never used. A data connection that opens after the cancel is closed.
    public func cancel() {
        stop.cancel()
        socket?.close()
    }

    /// Downloads `paths` (each taken literally: `TarPath.literal`), folders with everything in
    /// them, into `root`, a new empty folder. `hasRoom` is asked with the bytes of content before
    /// anything is sent. `progress` gets the bytes written and the total, at most once per
    /// percent. What arrived is left in `root` on a failure; the caller deletes it.
    public func download(_ paths: [String], into root: URL, hasRoom: @escaping @Sendable (Int64) -> Bool,
                         progress: @escaping @MainActor (Int64, Int64) -> Void) async throws -> Result {
        if cancelled { throw Failure.cancelled }
        let args: JSONObject = ["ref": BytesStream.ref("download"), "paths": paths.map(TarPath.literal), "recursive": true]
        let link = self.link, payload: JSONObject = ["session_id": sessionID, "block_id": blockID, "args": args]
        let reply = try await stop.unlessCancelled {
            do { return try await link.call(FsBlock.download, payload) } catch { throw Self.failure(beginning: error) }
        }
        let info = Info(roots: reply.int("roots") ?? 0, entries: reply.int("entries") ?? 0, size: Int64(reply.int("size") ?? 0))
        guard let ticket = reply.str("ticket") else { throw Failure.lost("no ticket") }
        guard hasRoom(info.size) else { throw Failure.noRoom(info.size) }
        if cancelled { throw Failure.cancelled }
        let open = self.open
        let socket = try await stop.unlessCancelled({
            do { return try await open(ticket) } catch { throw Failure.lost(error.localizedDescription) }
        }, late: { $0.close() })
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

/// A transfer's Cancel and the wait it ends: what is waited for through `unlessCancelled` ends
/// with the transfer's `cancelled` failure as soon as `cancel()` is called.
@MainActor
private final class CancelWait {
    private let failure: Error
    private(set) var isSet = false
    /// Ends the wait under way with `failure`.
    private var endWait: (@MainActor () -> Void)?

    init(_ failure: Error) { self.failure = failure }

    func cancel() {
        isSet = true
        let end = endWait
        endWait = nil
        end?()
    }

    /// What `op` gives, or the cancelled failure as soon as `cancel()` is called, whichever comes
    /// first. What `op` gives after that goes to `late`. One wait at a time.
    func unlessCancelled<T>(_ op: @escaping @MainActor () async throws -> T,
                            late: @escaping @MainActor (T) -> Void = { _ in }) async throws -> T {
        if isSet { throw failure }
        let race = FirstOf<T>(), failure = self.failure
        endWait = { race.finish(.failure(failure)) }
        defer { endWait = nil }
        Task { @MainActor in
            let r: Swift.Result<T, Error>
            do { r = .success(try await op()) } catch { r = .failure(error) }
            if !race.finish(r), case .success(let v) = r { late(v) }
        }
        return try await race.value()
    }
}

/// The first of two results: an operation's, or a cancel's. It stays on the main actor: the
/// wait is woken with nothing, and reads the result it holds.
@MainActor
private final class FirstOf<T> {
    private var result: Swift.Result<T, Error>?
    private var waiter: CheckedContinuation<Void, Never>?

    /// Keeps `r` if nothing came first. False when something did: `r` is not used.
    @discardableResult
    func finish(_ r: Swift.Result<T, Error>) -> Bool {
        guard result == nil else { return false }
        result = r
        waiter?.resume()
        waiter = nil
        return true
    }

    func value() async throws -> T {
        if result == nil { await withCheckedContinuation { waiter = $0 } }
        return try result!.get()  // set before the wake
    }
}

/// A flag set by a timer and read by what waited.
@MainActor
private final class TimeoutFlag {
    var set = false
}
