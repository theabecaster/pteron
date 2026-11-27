import Foundation

/// What goes into an upload's archive: every entry under the chosen items, in order, with where
/// each file's bytes are read from, and the counts `upload_begin` asks for. Built by walking the
/// items on disk once, before anything is sent, off the main actor.
///
/// Symbolic links are never followed. A link inside a chosen folder goes as a link when its
/// target is relative and stays inside that folder; any other link, and anything that is not a
/// file, a folder or a link (a socket, a FIFO), is left out and counted in `skipped`.
public struct TarPlan: Sendable {
    public struct Item: Sendable, Equatable {
        public var entry: TarEntry
        /// Where a file's bytes are read from; nil for the others.
        public var source: URL?
    }

    /// One thing the user chose: a file or a folder on this device, and the name it goes by.
    public struct Root: Sendable, Equatable {
        public var url: URL
        public var name: String

        public init(url: URL, name: String) {
            self.url = url
            self.name = name
        }
    }

    public enum Failure: Error, Equatable {
        /// An item couldn't be read; its name.
        case unreadable(String)
        /// Nothing to send: every item was left out.
        case empty
        case cancelled
    }

    public private(set) var items: [Item] = []
    /// The top-level entries.
    public private(set) var roots = 0
    /// The bytes of file content.
    public private(set) var size: Int64 = 0
    /// The archive's whole length.
    public private(set) var archiveSize = Int64(TarFormat.endBytes)
    /// Links and other entries left out.
    public private(set) var skipped = 0

    public var entries: Int { items.count }

    /// Walks `roots`. With `folder`, everything goes inside one top-level folder of that name
    /// (mode 0700), and `roots` counts that one. `cancelled` is asked between entries.
    public static func build(_ roots: [Root], inside folder: String? = nil,
                             cancelled: @Sendable () -> Bool = { false }) throws -> TarPlan {
        var plan = TarPlan()
        let base = folder.map { $0 + "/" } ?? ""
        if let folder {
            plan.add(TarEntry(path: folder, kind: .directory, mode: 0o700, mtime: Int64(Date().timeIntervalSince1970)), source: nil)
            plan.roots = 1
        }
        for root in roots {
            if cancelled() { throw Failure.cancelled }
            let before = plan.items.count
            try plan.walk(root.url, as: base + root.name, top: root.url.path, isRoot: true, cancelled: cancelled)
            if folder == nil, plan.items.count > before { plan.roots += 1 }
        }
        guard plan.roots > 0, plan.items.count > (folder == nil ? 0 : 1) else { throw Failure.empty }
        return plan
    }

    private mutating func add(_ e: TarEntry, source: URL?) {
        items.append(Item(entry: e, source: source))
        size += e.size
        archiveSize += Int64(TarFormat.header(e).count) + e.size + Int64(TarFormat.padding(e.size))
    }

    private mutating func walk(_ url: URL, as path: String, top: String, isRoot: Bool,
                               cancelled: @Sendable () -> Bool) throws {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { throw Failure.unreadable((path as NSString).lastPathComponent) }
        let mode = Int(st.st_mode) & 0o7777
        let mtime = Int64(st.st_mtimespec.tv_sec)
        switch st.st_mode & S_IFMT {
        case S_IFREG:
            add(TarEntry(path: path, kind: .file, size: Int64(st.st_size), mode: mode, mtime: mtime), source: url)
        case S_IFDIR:
            add(TarEntry(path: path, kind: .directory, mode: mode | 0o700, mtime: mtime), source: nil)
            let names: [String]
            do { names = try FileManager.default.contentsOfDirectory(atPath: url.path) } catch {
                throw Failure.unreadable((path as NSString).lastPathComponent)
            }
            for name in names.sorted() {
                if cancelled() { throw Failure.cancelled }
                try walk(url.appendingPathComponent(name), as: path + "/" + name, top: top, isRoot: false, cancelled: cancelled)
            }
        case S_IFLNK:
            guard !isRoot, let target = Self.readLink(url.path),
                  Self.staysInside(link: url.path, target: target, top: top) else {
                skipped += 1
                return
            }
            add(TarEntry(path: path, kind: .symlink(target), mode: 0o777, mtime: mtime), source: nil)
        default:
            skipped += 1
        }
    }

    static func readLink(_ path: String) -> String? {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let n = readlink(path, &buf, buf.count - 1)
        guard n > 0 else { return nil }
        return String(decoding: buf[0..<n].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Whether a link's target, relative and resolved by name alone, stays under `top`.
    static func staysInside(link: String, target: String, top: String) -> Bool {
        guard !target.isEmpty, !target.hasPrefix("/") else { return false }
        let topParts = top.split(separator: "/").map(String.init)
        var parts = link.split(separator: "/").map(String.init)
        parts.removeLast()
        for p in target.split(separator: "/", omittingEmptySubsequences: true) {
            if p == "." { continue }
            if p == ".." {
                guard parts.count > topParts.count else { return false }
                parts.removeLast()
            } else {
                parts.append(String(p))
            }
        }
        return parts.count >= topParts.count && Array(parts.prefix(topParts.count)) == topParts
    }
}

/// Writes a plan's archive, a piece at a time, reading each file only as its bytes are due. A
/// file that changed size since the walk fails the archive rather than send something else.
public final class TarStream: @unchecked Sendable {
    // Safe: one upload reads it from one task at a time (`next` is never called concurrently).
    public enum Failure: Error, Equatable {
        /// A file changed while it was read; its name.
        case changed(String)
        case unreadable(String)
    }

    private let items: [TarPlan.Item]
    private var index = 0
    private var pending = Data()
    private var handle: FileHandle?
    private var left: Int64 = 0
    private var pad = 0
    private var current = ""
    private var ended = false

    public init(_ plan: TarPlan) { items = plan.items }

    deinit { try? handle?.close() }

    /// The next bytes, at most `max`; empty once the archive is over.
    public func next(upTo max: Int) throws -> Data {
        var out = Data()
        out.reserveCapacity(max)
        while out.count < max {
            if !pending.isEmpty {
                let n = min(max - out.count, pending.count)
                out.append(pending.prefix(n))
                pending.removeFirst(n)
                continue
            }
            if left > 0 {
                let want = Int(min(Int64(max - out.count), left))
                let chunk: Data
                do { chunk = try handle?.read(upToCount: want) ?? Data() } catch { throw Failure.unreadable(current) }
                guard !chunk.isEmpty else { throw Failure.changed(current) }
                out.append(chunk)
                left -= Int64(chunk.count)
                if left == 0 { try finishFile() }
                continue
            }
            if pad > 0 {
                pending = Data(count: pad)
                pad = 0
                continue
            }
            guard index < items.count else {
                if !ended {
                    ended = true
                    pending = Data(count: TarFormat.endBytes)
                    continue
                }
                break
            }
            let item = items[index]
            index += 1
            pending = TarFormat.header(item.entry)
            current = (item.entry.path as NSString).lastPathComponent
            if item.entry.kind == .file, item.entry.size > 0, let url = item.source {
                do { handle = try FileHandle(forReadingFrom: url) } catch { throw Failure.unreadable(current) }
                left = item.entry.size
                pad = TarFormat.padding(item.entry.size)
            }
        }
        return out
    }

    /// The file's bytes all came: one more byte means it grew.
    private func finishFile() throws {
        let more = ((try? handle?.read(upToCount: 1)) ?? nil) ?? Data()
        try? handle?.close()
        handle = nil
        if !more.isEmpty { throw Failure.changed(current) }
    }
}

/// Writes an archive's entries under a folder of this device as they arrive, from a
/// `TarReader`. Only files and folders are made; links and everything else are counted in
/// `skipped` and left out, so nothing written can point outside the folder. A path with `..`, or
/// an absolute one, fails the whole archive.
public final class TarExtractor: @unchecked Sendable {
    // Safe: fed from one task, one piece at a time.
    public enum Failure: Error, Equatable {
        /// An entry's path would leave the folder.
        case unsafePath(String)
        /// This device couldn't write; the system's words, for logs.
        case writeFailed(String)
    }

    public let root: URL
    /// Top-level names, in the order they came.
    public private(set) var tops: [String] = []
    public private(set) var skipped = 0
    public private(set) var entries = 0
    /// File bytes written.
    public private(set) var written: Int64 = 0
    private var handle: FileHandle?
    private var currentURL: URL?
    private var currentMtime: Int64 = 0
    private var reader: TarReader!

    public init(root: URL) {
        self.root = root
        reader = TarReader { [unowned self] in try self.apply($0) }
    }

    deinit { try? handle?.close() }

    /// Bytes of the archive, in order.
    public func feed(_ data: Data) throws { try reader.feed(data) }

    /// The archive is over: it must end between entries.
    public func finish() throws {
        try reader.finish()
        try? handle?.close()
        handle = nil
    }

    public var finished: Bool { reader.finished }

    private func apply(_ event: TarReader.Event) throws {
        switch event {
        case .begin(let e):
            guard let parts = TarPath.components(e.path) else { throw Failure.unsafePath(e.path) }
            entries += 1
            if !tops.contains(parts[0]) { tops.append(parts[0]) }
            let url = parts.reduce(root) { $0.appendingPathComponent($1) }
            switch e.kind {
            case .directory:
                do { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) } catch {
                    throw Failure.writeFailed(error.localizedDescription)
                }
            case .file:
                do {
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                        throw Failure.writeFailed("couldn't create \(parts.last ?? "")")
                    }
                    handle = try FileHandle(forWritingTo: url)
                    currentURL = url
                    currentMtime = e.mtime
                } catch let f as Failure {
                    throw f
                } catch {
                    throw Failure.writeFailed(error.localizedDescription)
                }
            case .symlink, .other:
                skipped += 1
            }
        case .bytes(let d):
            guard let handle else { return }
            do { try handle.write(contentsOf: d) } catch { throw Failure.writeFailed(error.localizedDescription) }
            written += Int64(d.count)
        case .end:
            try? handle?.close()
            handle = nil
            if let url = currentURL, currentMtime > 0 {
                try? FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: TimeInterval(currentMtime))],
                                                       ofItemAtPath: url.path)
            }
            currentURL = nil
        }
    }
}
