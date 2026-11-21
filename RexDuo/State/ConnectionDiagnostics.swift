import Foundation
import RexKit
import SwiftUI

/// Where the app keeps its connection log (`ConnectionLog` in RexKit) and what it calls things in
/// it. The log is evidence for a connection problem after the fact: it survives a relaunch, holds
/// numbers only, and leaves the phone only when the user shares its text.
enum ConnectionDiagnostics {
    /// `Application Support/Diagnostics/connections.clog`: not in Caches, which the system may
    /// empty when the evidence is wanted. The log leaves it out of backups.
    static var file: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Diagnostics", isDirectory: true).appendingPathComponent("connections.clog")
    }

    /// The log of this launch, with the launch as its first line.
    static func launchLog() -> ConnectionLog {
        let log = ConnectionLog(file: file)
        log.record(.launch(build: build))
        return log
    }

    /// The scene changed phase: one line, and in the background the file is written at once,
    /// since the app may not run again.
    static func phaseChanged(_ phase: ScenePhase, log: ConnectionLog?) {
        guard let log else { return }
        if let scene = scene(phase) { log.record(.scene(scene)) }
        if phase == .background { log.flush() }
    }

    /// The app's build number (`CFBundleVersion`), 0 when it isn't a number.
    static var build: Int64 { buildNumber(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion")) }

    static func buildNumber(_ value: Any?) -> Int64 { (value as? String).flatMap { Int64($0) } ?? 0 }

    /// A server's key in the log: its id, a random UUID. Never its name or its address. The log
    /// stores a salted hash of it.
    static func key(_ config: ServerConfig) -> String { config.id.uuidString }

    /// The log as text, with the servers numbered as Settings lists them.
    static func export(_ log: ConnectionLog, servers: [ServerConfig]) async -> String {
        await log.export(servers: servers.map(key))
    }

    static func scene(_ phase: ScenePhase) -> ConnectionEvent.Scene? {
        switch phase {
        case .inactive: .inactive
        case .active: .active
        case .background: .background
        @unknown default: nil
        }
    }
}
