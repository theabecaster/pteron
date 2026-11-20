import Foundation

/// One entry of a folder on a terminal's computer.
public struct DirEntry: Equatable, Hashable, Sendable {
    public var name: String
    /// Not a folder, or a link to something that isn't one.
    public var isFile: Bool
    public var isSymlink: Bool

    public init(name: String, isFile: Bool = false, isSymlink: Bool = false) {
        self.name = name
        self.isFile = isFile
        self.isSymlink = isSymlink
    }
}

/// One answer of `list_dir`.
public struct DirPage: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case ok, missing, notDir, denied
        /// A value a newer server added.
        case other(String)

        init(_ s: String?) {
            switch s {
            case "ok": self = .ok
            case "missing": self = .missing
            case "not_dir": self = .notDir
            case "denied": self = .denied
            default: self = .other(s ?? "")
            }
        }
    }

    /// The folder that was listed, absolute. Set when it couldn't be read too.
    public var path: String
    /// The home folder of the terminal's program; empty when the server can't tell.
    public var home: String
    public var status: Status
    /// In the order the filesystem gave them, hidden ones included.
    public var entries: [DirEntry]
    /// Some entries were left out: the limit was reached or the reply grew too large.
    public var truncated: Bool

    public init(path: String, home: String = "", status: Status = .ok, entries: [DirEntry] = [], truncated: Bool = false) {
        self.path = path
        self.home = home
        self.status = status
        self.entries = entries
        self.truncated = truncated
    }

    /// From a `list_dir` result. `entries` may be null; fields this build doesn't know are ignored.
    public init(_ o: JSONObject, asked: String) {
        path = o.str("path") ?? asked
        home = o.str("home") ?? ""
        status = Status(o.str("status"))
        truncated = o.bool("truncated") ?? false
        entries = o.arr("entries").compactMap { e in
            guard let name = e.str("name"), !name.isEmpty else { return nil }
            return DirEntry(name: name, isFile: e.bool("file") ?? false, isSymlink: e.bool("symlink") ?? false)
        }
    }
}

/// Why a folder couldn't be asked for. A folder that is missing or unreadable is not a failure:
/// it is a `DirPage` with that status.
public enum DirFailure: Error, Equatable, Sendable {
    /// The server has no `list_dir`.
    case unsupported
    /// No connection, or it broke under the call.
    case lost(String)
    case refused(String)

    init(_ error: Error) {
        guard let e = error as? RexError else { self = .lost(error.localizedDescription); return }
        switch e.code {
        case "method_not_found", "revision_too_low": self = .unsupported
        case "client": self = .lost(e.message)
        default: self = .refused(e.message)
        }
    }
}

/// Lists folders on a terminal's computer (`com.superlogical.terminal.list_dir`). A relative path
/// is relative to the working directory of the terminal's foreground process, `~` is its home,
/// and an empty path is that working directory.
@MainActor
public final class DirLister {
    public static let method = "com.superlogical.terminal.list_dir"
    /// The most entries one call asks for; the server's own default.
    public static let limit = 2000

    private let link: any StreamLink
    public let sessionID: String
    public let blockID: String

    public convenience init(control: RexControl, sessionID: String, blockID: String) {
        self.init(link: control, sessionID: sessionID, blockID: blockID)
    }

    init(link: any StreamLink, sessionID: String, blockID: String) {
        self.link = link
        self.sessionID = sessionID
        self.blockID = blockID
    }

    /// Files are always asked for. The entries are read out of the reply off the main actor.
    /// Throws a `DirFailure`.
    public func list(path: String, prefix: String = "", limit: Int = DirLister.limit) async throws -> DirPage {
        var args: JSONObject = ["path": path, "limit": limit, "files": true]
        if !prefix.isEmpty { args["prefix"] = prefix }
        let reply: JSONObject
        do {
            reply = try await link.call(Self.method, ["session_id": sessionID, "block_id": blockID, "args": args])
        } catch {
            throw DirFailure(error)
        }
        let box = Reply(reply)
        return await Task.detached(priority: .userInitiated) { DirPage(box.object, asked: path) }.value
    }
}

/// A reply on its way to the task that reads it.
private struct Reply: @unchecked Sendable {
    // Safe: the reply is a value built for this call; the sender doesn't touch it again.
    let object: JSONObject
    init(_ o: JSONObject) { object = o }
}
