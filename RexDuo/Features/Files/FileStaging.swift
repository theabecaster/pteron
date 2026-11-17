import Foundation
import Network

/// A file ready to send: a copy in the app's temporary folder, under the name the server gets.
struct StagedFile: Equatable, Sendable {
    var url: URL
    var name: String
    var size: Int64
}

/// The app's own copies of files on their way out (`Outgoing`) or in (`Incoming`), in its
/// temporary folder. Each file has a folder of its own, so two files of one name don't collide.
/// A send removes its copies when it ends; what a crash left behind goes at the next launch.
enum FileStaging {
    static var outgoing: URL { FileManager.default.temporaryDirectory.appendingPathComponent("Outgoing", isDirectory: true) }
    static var incoming: URL { FileManager.default.temporaryDirectory.appendingPathComponent("Incoming", isDirectory: true) }

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

    /// At launch: whatever an earlier run left.
    static func clearAll() {
        try? FileManager.default.removeItem(at: outgoing)
        try? FileManager.default.removeItem(at: incoming)
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
