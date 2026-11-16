import Foundation
import RexKit

/// Finds the Rex server on this Mac without any configuration.
///
/// 1. `REX_SERVER`, which Rex sets in its own terminals (useful when run from a Rex shell).
/// 2. The default local socket, `~/Library/Application Support/rex/server.sock`.
/// 3. `rex server status --json` (with autostart off, so it never starts a server): its
///    `endpoint`, else its Tailscale HTTPS URL.
public enum Discovery {
    public static var defaultSocket: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/rex/server.sock").path
    }

    /// Where the rex CLI usually lives. Apps launched at login get no shell PATH.
    static var cliCandidates: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var paths = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map { "\($0)/rex" }
        paths += [
            "\(home)/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex",
            "/opt/homebrew/bin/rex", "/usr/local/bin/rex", "\(home)/.local/bin/rex", "\(home)/bin/rex",
        ]
        return paths
    }

    @MainActor
    public static func find() async -> RexEndpoint? {
        if let env = ProcessInfo.processInfo.environment["REX_SERVER"], let ep = RexEndpoint(string: env) {
            return ep
        }
        if FileManager.default.fileExists(atPath: defaultSocket) { return .unix(defaultSocket) }
        return await fromCLI()
    }

    static func fromCLI() async -> RexEndpoint? {
        guard let rex = cliCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }),
              let out = await run(rex, ["--autostart=false", "--timeout", "3s", "server", "status", "--json"]),
              let status = JSONCodec.decode(out) else { return nil }
        if let e = status.str("endpoint"), let ep = RexEndpoint(string: e) {
            if case .unix(let path) = ep, !FileManager.default.fileExists(atPath: path) {
                // fall through to Tailscale
            } else {
                return ep
            }
        }
        if let u = status.obj("tailscale")?.obj("https")?.text("url") { return RexEndpoint(string: u) }
        return nil
    }

    /// Runs a command off the main thread; its stdout, or nil if it failed or took over 5 s.
    static func run(_ path: String, _ args: [String]) async -> Data? {
        await withCheckedContinuation { c in
            DispatchQueue.global(qos: .utility).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: path)
                p.arguments = args
                let out = Pipe()
                p.standardOutput = out
                p.standardError = FileHandle.nullDevice
                p.standardInput = FileHandle.nullDevice
                do { try p.run() } catch { c.resume(returning: nil); return }
                let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: killer)
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                killer.cancel()
                c.resume(returning: p.terminationStatus == 0 ? data : nil)
            }
        }
    }
}
