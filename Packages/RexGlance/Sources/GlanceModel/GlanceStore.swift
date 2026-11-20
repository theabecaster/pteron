import Foundation

/// The snapshot's place on disk: `glance/snapshot.json` in a directory the caller passes, the
/// App Group's container in the app and the widgets, a temporary one in tests.
///
/// **One writer per file.** Only the app writes: `GlanceWriter`, through its
/// `SnapshotFileWriter`. The widgets only read. The write is atomic, so a reader sees the old
/// file or the new one, never half of one. The file is protected until the first unlock after
/// a restart; before that a read finds nothing and the widgets show their placeholder.
public struct GlanceStore: Sendable {
    /// The App Group the app and its extensions share.
    public static let appGroup = "group.dev.abrahamgonzalez.rexduo"

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// The store in the App Group's container. Nil when the target has no such group.
    public static func shared() -> GlanceStore? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup).map(GlanceStore.init(directory:))
    }

    var folder: URL { directory.appendingPathComponent("glance", isDirectory: true) }
    public var file: URL { folder.appendingPathComponent("snapshot.json") }
    var counter: URL { folder.appendingPathComponent("seq") }

    public func read() -> GlanceReading {
        GlanceReading(try? Data(contentsOf: file))
    }

    public func write(_ data: Data) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: file, options: Self.options)
    }

    public func remove() {
        try? FileManager.default.removeItem(at: file)
    }

    /// The highest `seq` handed out so far: the saved counter, or the snapshot's own when that
    /// is higher. The counter survives a snapshot that was lost, so a number never repeats.
    public func lastSeq() -> Int {
        let saved = (try? String(contentsOf: counter, encoding: .utf8)).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
        return max(saved, read().snapshot?.seq ?? 0)
    }

    public func saveSeq(_ seq: Int) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? Data(String(seq).utf8).write(to: counter, options: Self.options)
    }

    private static var options: Data.WritingOptions {
        #if os(macOS)
        [.atomic]
        #else
        [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        #endif
    }
}

/// The widget's kind: what the extension declares and what the app asks WidgetKit to reload.
public enum GlanceKind {
    public static let agents = "dev.abrahamgonzalez.rexduo.widget.agents"
}
