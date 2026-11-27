import Foundation
import Network

/// A file ready to send: a copy in the app's temporary folder, under the name the server gets.
struct StagedFile: Equatable, Sendable {
    var url: URL
    var name: String
    var size: Int64
}

/// One item of a send that goes as one archive (`FileSender.sendTree`): a file or a folder,
/// either a copy the app owns in `Outgoing` (removed after) or an item the Files picker gave,
/// read where it is under its security scope (released after).
struct Outgoing: Equatable, Sendable {
    var url: URL
    /// The name it lands under.
    var name: String
    var isFolder: Bool
    /// A copy in the app's temporary folder.
    var owned: Bool
    /// The picker's security scope was started for it.
    var scoped: Bool

    init(url: URL, name: String, isFolder: Bool, owned: Bool, scoped: Bool) {
        self.url = url
        self.name = name
        self.isFolder = isFolder
        self.owned = owned
        self.scoped = scoped
    }

    init(_ f: StagedFile) {
        self.init(url: f.url, name: f.name, isFolder: false, owned: true, scoped: false)
    }

    /// Lets go of what the items hold: removes the copies, ends the scopes.
    static func release(_ items: [Outgoing]) {
        for i in items {
            if i.owned { try? FileManager.default.removeItem(at: i.url.deletingLastPathComponent()) }
            if i.scoped { i.url.stopAccessingSecurityScopedResource() }
        }
    }
}

/// The app's own copies of files on their way out (`Outgoing`), in (`Incoming`) or to the share
/// sheet (`Shared`), in its temporary folder. Each file has a folder of its own, so two files of
/// one name don't collide. A send or a share removes its copies when it ends; what a crash left
/// behind goes at the next launch.
enum FileStaging {
    static var outgoing: URL { FileManager.default.temporaryDirectory.appendingPathComponent("Outgoing", isDirectory: true) }
    static var incoming: URL { FileManager.default.temporaryDirectory.appendingPathComponent("Incoming", isDirectory: true) }
    static var shared: URL { FileManager.default.temporaryDirectory.appendingPathComponent("Shared", isDirectory: true) }

    /// A new, empty folder under `root`.
    static func folder(in root: URL) throws -> URL {
        let dir = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Copies `source` in, as `name` (sanitized).
    static func stage(copying source: URL, as name: String) throws -> StagedFile {
        let clean = UploadName.sanitize(name)
        let dest = try folder(in: outgoing).appendingPathComponent(clean)
        try FileManager.default.copyItem(at: source, to: dest)
        return try staged(dest, name: clean)
    }

    /// Moves `source`, a file the app already owns (a picker's copy), in as `name`.
    static func stage(moving source: URL, as name: String) throws -> StagedFile {
        let clean = UploadName.sanitize(name)
        let dest = try folder(in: outgoing).appendingPathComponent(clean)
        do { try FileManager.default.moveItem(at: source, to: dest) } catch {
            try FileManager.default.copyItem(at: source, to: dest)
        }
        return try staged(dest, name: clean)
    }

    /// Moves a folder the system copied for this app (a drop, a paste) in as `name`.
    static func stageFolder(moving source: URL, as name: String) throws -> Outgoing {
        let clean = UploadName.sanitize(name, fallback: "Folder")
        let dest = try folder(in: outgoing).appendingPathComponent(clean, isDirectory: true)
        do { try FileManager.default.moveItem(at: source, to: dest) } catch {
            try FileManager.default.copyItem(at: source, to: dest)
        }
        return Outgoing(url: dest, name: clean, isFolder: true, owned: true, scoped: false)
    }

    static func stage(data: Data, as name: String) throws -> StagedFile {
        let clean = UploadName.sanitize(name)
        let dest = try folder(in: outgoing).appendingPathComponent(clean)
        try data.write(to: dest)
        return StagedFile(url: dest, name: clean, size: Int64(data.count))
    }

    private static func staged(_ url: URL, name: String) throws -> StagedFile {
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
        return StagedFile(url: url, name: name, size: size?.int64Value ?? 0)
    }

    /// Removes the copies, with their folders.
    static func discard(_ files: [StagedFile]) {
        for f in files { try? FileManager.default.removeItem(at: f.url.deletingLastPathComponent()) }
    }

    /// Removes a folder made by `folder(in:)`, with what is in it.
    static func remove(_ folder: URL) {
        try? FileManager.default.removeItem(at: folder)
    }

    /// At launch: whatever an earlier run left.
    static func clearAll() {
        try? FileManager.default.removeItem(at: outgoing)
        try? FileManager.default.removeItem(at: incoming)
        try? FileManager.default.removeItem(at: shared)
    }

    /// Whether the phone's network costs money now (cellular, a hotspot). Asks the system once.
    static func networkIsExpensive() async -> Bool {
        await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            let monitor = NWPathMonitor()
            let once = Once()
            monitor.pathUpdateHandler = { path in
                guard once.first() else { return }
                monitor.cancel()
                c.resume(returning: path.isExpensive)
            }
            monitor.start(queue: DispatchQueue(label: "dev.abrahamgonzalez.rexduo.cost"))
        }
    }
}

/// True the first time only, from any thread.
private final class Once: @unchecked Sendable {
    // Safe: the flag is only read and written under the lock.
    private let lock = NSLock()
    private var done = false

    func first() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
