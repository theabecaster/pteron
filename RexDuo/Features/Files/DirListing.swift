import Foundation
import RexKit

/// One folder's entries, ordered for the browser: folders first, then names as Finder orders them
/// (`file2` before `file10`). Building it sorts, so it is built off the main actor; filtering
/// reads names folded once, here.
struct DirListing: Equatable, Sendable {
    struct Item: Equatable, Sendable {
        let entry: DirEntry
        /// The name in lower case, for the filter.
        let folded: String
        var hidden: Bool { entry.name.utf8.first == UInt8(ascii: ".") }
    }

    let path: String
    let home: String
    let status: DirPage.Status
    let truncated: Bool
    let items: [Item]

    init(_ page: DirPage) {
        path = page.path
        home = page.home
        status = page.status
        truncated = page.truncated
        items = page.entries.sorted(by: Self.inOrder).map { Item(entry: $0, folded: $0.name.lowercased()) }
    }

    static func inOrder(_ a: DirEntry, _ b: DirEntry) -> Bool {
        if a.isFile != b.isFile { return !a.isFile }
        switch a.name.localizedStandardCompare(b.name) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        // Two names the comparison holds equal (`é` in two spellings) still need one order.
        case .orderedSame: return a.name.unicodeScalars.lexicographicallyPrecedes(b.name.unicodeScalars)
        }
    }

    /// The entries to show. Hidden ones (a leading dot) show when asked for, or when the filter
    /// itself starts with a dot. The filter matches anywhere in a name, whatever the case. A
    /// filter that is a path (`DirPath.isPath`) filters nothing.
    func visible(showHidden: Bool, query: String) -> [DirEntry] {
        let q = DirPath.isPath(query) ? "" : query.lowercased()
        let hiddenToo = showHidden || q.hasPrefix(".")
        var out: [DirEntry] = []
        out.reserveCapacity(q.isEmpty ? items.count : 64)
        for i in items where (hiddenToo || !i.hidden) && (q.isEmpty || i.folded.contains(q)) { out.append(i.entry) }
        return out
    }
}

/// Paths on the pane's computer, as text: joined, walked up and shown. They are never resolved
/// here; the server does that.
enum DirPath {
    /// Whether what was typed in the filter is a path to go to: it starts with `/` or `~`.
    static func isPath(_ query: String) -> Bool { query.hasPrefix("/") || query.hasPrefix("~") }

    static func join(_ folder: String, _ name: String) -> String {
        folder.utf8.last == UInt8(ascii: "/") ? folder + name : folder + "/" + name
    }

    /// The folder's own name; `/` for the root.
    static func name(_ path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        return parts.last.map(String.init) ?? "/"
    }

    /// The folder above, or nil for the root.
    static func parent(_ path: String) -> String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !parts.isEmpty else { return nil }
        return "/" + parts.dropLast().joined(separator: "/")
    }

    /// Every folder above `path`, nearest first, ending at `/`.
    static func parents(_ path: String) -> [String] {
        var out: [String] = []
        var p = parent(path)
        while let next = p {
            out.append(next)
            p = parent(next)
        }
        return out
    }

    /// The path as shown: `~` for the home folder and `~/…` under it, when the home is known.
    static func display(_ path: String, home: String) -> String {
        guard !home.isEmpty, home != "/" else { return path }
        if path.utf8.elementsEqual(home.utf8) { return "~" }
        let prefix = home.utf8.last == UInt8(ascii: "/") ? home : home + "/"
        guard path.utf8.count > prefix.utf8.count, path.utf8.starts(with: prefix.utf8) else { return path }
        return "~/" + String(Substring(path.utf8.dropFirst(prefix.utf8.count)))
    }
}

/// What kind of file a name looks like, for its row's symbol. By extension only: the server
/// lists names, not types.
enum FileGlyph {
    static let byExtension: [String: String] = {
        var t: [String: String] = [:]
        for e in ["png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tiff", "tif", "bmp", "svg", "ico"] { t[e] = "photo" }
        for e in ["mov", "mp4", "m4v", "mkv", "avi", "webm"] { t[e] = "film" }
        for e in ["pdf", "rtf", "doc", "docx", "pages", "key", "ppt", "pptx", "xls", "xlsx", "numbers"] { t[e] = "doc.richtext" }
        for e in ["zip", "tar", "gz", "tgz", "bz2", "xz", "zst", "7z", "rar", "dmg", "jar"] { t[e] = "archivebox" }
        for e in ["txt", "md", "log", "json", "yml", "yaml", "toml", "xml", "html", "css", "csv", "swift", "rs", "go", "py",
                  "js", "ts", "tsx", "jsx", "c", "h", "cpp", "hpp", "m", "java", "kt", "rb", "sh", "zsh", "lua", "sql",
                  "conf", "ini", "env", "lock"] { t[e] = "doc.text" }
        return t
    }()

    static func symbol(for entry: DirEntry) -> String {
        guard entry.isFile else { return "folder.fill" }
        let ext = (entry.name as NSString).pathExtension.lowercased()
        return byExtension[ext] ?? "doc"
    }
}
