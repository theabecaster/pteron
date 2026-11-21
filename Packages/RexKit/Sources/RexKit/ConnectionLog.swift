import Foundation

/// The connection log: what happened to each server's control connection, to the phone's network
/// and to the app, kept in a file so it is still there after the app was closed or crashed.
/// Nothing reads it but `export`, and nothing leaves the phone unless the user shares that text.
///
/// - **What it holds:** `ConnectionEvent`s, numbers only (see there for the privacy rule), the
///   newest `ConnectionJournal.eventsPerRing` per server and as many for the app.
/// - **Cost:** `record` reads the time and hands the event to a serial queue; the caller does no
///   more. The file is written on that queue, at most once per `flushDelay`, however many events
///   came. Only a change of connection state, of the network or of the scene's phase is recorded:
///   nothing per frame or per key.
/// - **File:** a 16-byte header and 32-byte events. A write appends the new events; every
///   `rewriteAfter` appended events the file is written again from the rings, atomically, so it
///   never passes `maxFileBytes`. A file that is damaged is dropped and a new one started; one
///   that ends inside an event keeps the events before it; one that can't be read at all is
///   left as it is.
public final class ConnectionLog: @unchecked Sendable {
    // `@unchecked`: the constants below are immutable, and every `var` is read and written on
    // `queue` only.

    /// How long after an event the file is written, so a burst of events is one write.
    public static let flushDelay: TimeInterval = 0.5
    /// Appended events after which the file is written again from the rings.
    static let rewriteAfter = 400
    /// The file never grows past this: the rings when full, plus the appended events.
    public static let maxFileBytes = ConnectionJournal.headerSize
        + (ConnectionJournal.maxEvents + rewriteAfter) * ConnectionEvent.size

    private let file: URL
    private let flushDelay: TimeInterval
    private let now: @Sendable () -> Date
    private let makeSalt: @Sendable () -> UInt64
    private let queue = DispatchQueue(label: "dev.abrahamgonzalez.rexduo.connection-log", qos: .utility)

    private var journal: ConnectionJournal?
    /// Events not yet in the file.
    private var pending: [ConnectionEvent] = []
    private var flushScheduled = false
    /// Events appended to the file since it was last written whole.
    private var appended = 0
    /// The file is missing, damaged or of unknown length: the next write replaces it.
    private var mustRewrite = false
    /// The file is there and could not be read (the phone has not been unlocked since it
    /// started): it is left alone, and this process keeps its events in memory only.
    private var unreadable = false
    private var appends = 0
    private var rewrites = 0

    /// `file`: where the log is kept; its folder is made at the first write. `now`: the time
    /// stamped on each event.
    public convenience init(file: URL, flushDelay: TimeInterval = ConnectionLog.flushDelay,
                            now: @escaping @Sendable () -> Date = { Date() }) {
        self.init(file: file, flushDelay: flushDelay, now: now) { UInt64.random(in: 1...UInt64.max) }
    }

    /// `salt`: the number a new file's server tags are salted with. Random, except in tests.
    init(file: URL, flushDelay: TimeInterval, now: @escaping @Sendable () -> Date, salt: @escaping @Sendable () -> UInt64) {
        self.file = file
        self.flushDelay = flushDelay
        self.now = now
        self.makeSalt = salt
    }

    /// Records an event, stamped with the time of the call. `server`: the app's key for the
    /// server the event is about (it is hashed, never stored), nil for an event of the app or the
    /// phone. Safe from any thread; returns at once.
    public func record(_ event: ConnectionEvent, server: String? = nil) {
        var stamped = event
        stamped.time = Int64((now().timeIntervalSince1970 * 1000).rounded())
        queue.async { [self, stamped] in
            load()
            var e = stamped
            e.server = server.map { journal!.tag($0) } ?? 0
            guard journal!.add(e) else { return }
            pending.append(e)
            guard !flushScheduled else { return }
            flushScheduled = true
            queue.asyncAfter(deadline: .now() + flushDelay) { [self] in write() }
        }
    }

    /// Writes what is pending now instead of after `flushDelay`: the app is going to the
    /// background and may not run again.
    public func flush() {
        queue.async { [self] in write() }
    }

    /// The log as text (`ConnectionJournal.text`): `servers` are the app's keys in the order it
    /// lists them, and come out as "Computer 1", "Computer 2", …
    public func export(servers: [String]) async -> String {
        let exported = now()
        return await withCheckedContinuation { done in
            queue.async { [self] in
                load()
                done.resume(returning: journal!.text(servers: servers, exported: exported))
            }
        }
    }

    /// Returns once everything recorded so far is in the file, with the number of writes made:
    /// appends, and writes of the whole file.
    func written() async -> (appends: Int, rewrites: Int) {
        await withCheckedContinuation { done in
            queue.async { [self] in
                write()
                done.resume(returning: (appends, rewrites))
            }
        }
    }

    // MARK: On the queue

    private func load() {
        guard journal == nil else { return }
        let data = try? Data(contentsOf: file)
        if let data, let read = ConnectionJournal.decode(data) {
            journal = read.journal
            // A torn end, or more events than the rings keep: the next write tidies the file.
            mustRewrite = read.torn || data.count > ConnectionJournal.headerSize + read.journal.count * ConnectionEvent.size
            appended = 0
        } else {
            // No file, or a damaged one: start over. The next write replaces it.
            journal = ConnectionJournal(salt: makeSalt())
            mustRewrite = true
            unreadable = data == nil && FileManager.default.fileExists(atPath: file.path)
        }
    }

    private func write() {
        flushScheduled = false
        guard !pending.isEmpty, let journal else { return }
        let new = pending
        pending = []
        guard !unreadable else { return }
        if !mustRewrite, appended + new.count <= Self.rewriteAfter, append(new) {
            appended += new.count
            appends += 1
            return
        }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try journal.encoded().write(to: file, options: .atomic)
            // A log of this device's connections: not for a backup or another device.
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var f = file
            try? f.setResourceValues(values)
            mustRewrite = false
            appended = 0
            rewrites += 1
        } catch {
            // The rings still hold the events; the next write tries the whole file again.
            mustRewrite = true
        }
    }

    private func append(_ events: [ConnectionEvent]) -> Bool {
        guard let handle = try? FileHandle(forWritingTo: file) else { return false }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(events.flatMap { $0.encoded() }))
            return true
        } catch {
            return false
        }
    }
}
