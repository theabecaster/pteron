import Foundation
import RexKit

/// Which file methods a pane's host has: true, false, or nil while nobody knows. Each reader
/// asks for the one it needs, so a host with only some of them shows only what works there.
struct FileSupport: Equatable {
    var upload: Bool?
    var download: Bool?
    var listDir: Bool?

    subscript(_ method: FileMethod) -> Bool? {
        switch method {
        case .upload: return upload
        case .download: return download
        case .listDir: return listDir
        }
    }
}

extension ServerConnection {
    /// Whether terminals on `host` have a file method. A call's own answer on this connection
    /// comes first; else the creator list answers without a call, when it lists the terminal
    /// creator for that host with its methods. Nil: nobody knows yet (`PaneFiles.checkSupport` asks).
    func has(_ method: FileMethod, host: String?) -> Bool? {
        if let probed = capabilities.probe(method: method.full, host: host) { return probed }
        return capabilities.catalog?.creator(Self.terminalCreator, host: host)?.methods?.contains(method.rawValue)
    }

    /// Whether a files command applies to a pane now: its host has the method, and for Insert
    /// Path the pane's program is one a path can be written to. One rule for the attach menu,
    /// the bound keys and the palette.
    func offers(_ command: FilesCommand, host: String?, block: String) -> Bool {
        guard has(command.needs, host: host) == true else { return false }
        guard command == .insertPath else { return true }
        // Bracketed paste decides how a path is written, never whether Insert is offered.
        return PathInsert.decide(foreground: meta[block]?.foreground, bracketedPaste: false,
                                 windows: platform?.hasPrefix("windows") == true).offered
    }

    func fileSupport(host: String?) -> FileSupport {
        FileSupport(upload: has(.upload, host: host), download: has(.download, host: host), listDir: has(.listDir, host: host))
    }
}
