import Foundation

/// The file methods of a terminal. A server, and each host behind it, may have any of them.
public enum FileMethod: String, CaseIterable, Sendable {
    case upload = "upload_begin"
    case download = "download_begin"
    case listDir = "list_dir"

    /// The name a call uses.
    public var full: String { "com.superlogical.terminal." + rawValue }

    /// Arguments that reserve nothing: uploads and downloads get a reference the server must
    /// refuse (`bad_request`), and a listing reads one entry of the root.
    var probeArgs: JSONObject {
        switch self {
        case .upload: return ["ref": "upload:probe", "name": "probe", "size": 0]
        case .download: return ["ref": "download:probe", "path": "/"]
        case .listDir: return ["path": "/", "limit": 1]
        }
    }
}

/// Asks a terminal's server whether it has a file method, one method per call, so one missing
/// method says nothing about the others.
public enum FileProbe {
    /// `remote`: the terminal runs on another host than the server's own.
    @MainActor
    public static func ask(_ method: FileMethod, control: RexControl, sessionID: String, blockID: String,
                           remote: Bool) async -> Presence {
        await ask(method, link: control, sessionID: sessionID, blockID: blockID, remote: remote)
    }

    @MainActor
    static func ask(_ method: FileMethod, link: any StreamLink, sessionID: String, blockID: String,
                    remote: Bool) async -> Presence {
        do {
            _ = try await link.call(method.full, ["session_id": sessionID, "block_id": blockID, "args": method.probeArgs])
            return .present
        } catch {
            return presence(after: error, remote: remote)
        }
    }

    /// What a refused probe says.
    ///
    /// - `method_not_found` (and `revision_too_low`): the method isn't there.
    /// - `bad_request`: the server read the arguments, so the method is there.
    /// - `not_found`: a server older than `method_not_found` says this for a missing method, and
    ///   every server says it for a block that has gone. No answer.
    /// - No connection: no answer.
    /// - Any other code: on the server's own host the method answered, so it is there; on a
    ///   remote host the error may be the route's, so no answer.
    static func presence(after error: Error, remote: Bool) -> Presence {
        guard let e = error as? RexError else { return .unknown }
        switch e.code {
        case "method_not_found", "revision_too_low": return .absent
        case "bad_request": return .present
        case "not_found", "client": return .unknown
        default: return remote ? .unknown : .present
        }
    }
}
