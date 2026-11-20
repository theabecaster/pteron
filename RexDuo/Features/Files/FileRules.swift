import Foundation
import RexKit
import UniformTypeIdentifiers

// The pure rules of sending files to a pane: the names files get, where the menu says they go,
// and what Paste does with what is on the clipboard. Tested in FileRulesTests.

/// File names as they reach the server, which types them into the pane inside a path.
enum UploadName {
    /// The longest name sent, in UTF-8 bytes. The server's own limit is 255; it cuts longer ones.
    static let maxBytes = 200
    /// An extension longer than this isn't kept whole when a name is cut.
    static let maxExtensionBytes = 16

    /// One path component: the last one of `raw`, NFC normalized, without control characters, with
    /// spaces at either end trimmed, at most `maxBytes` with its extension kept. A name that is
    /// left empty, or is `.` or `..`, becomes `fallback`.
    static func sanitize(_ raw: String, fallback: String = "File") -> String {
        let last = raw.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? ""
        let clean = String(String.UnicodeScalarView(last.unicodeScalars.filter { !isControl($0) }))
            .precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean != ".", clean != ".." else { return fallback }
        return cut(clean)
    }

    /// Control characters (C0, DEL, C1), the bidi embeddings, overrides and isolates that can make
    /// a name read in another order (U+202A–202E, U+2066–2069), and the zero-width space. The
    /// zero-width joiner and non-joiner stay: scripts such as Persian and Hindi and emoji need them.
    static func isControl(_ s: Unicode.Scalar) -> Bool {
        if s.properties.generalCategory == .control { return true }
        switch s.value {
        case 0x202A...0x202E, 0x2066...0x2069, 0x200B: return true
        default: return false
        }
    }

    /// `name` cut to `maxBytes`, keeping its extension, never inside a character.
    static func cut(_ name: String) -> String {
        guard name.utf8.count > maxBytes else { return name }
        let ext = (name as NSString).pathExtension
        let keep = !ext.isEmpty && ext.utf8.count <= maxExtensionBytes && ext.utf8.count < name.utf8.count - 1
        let suffix = keep ? "." + ext : ""
        let base = keep ? String(name.dropLast(suffix.count)) : name
        var out = ""
        var bytes = 0
        for ch in base {
            let n = String(ch).utf8.count
            if bytes + n + suffix.utf8.count > maxBytes { break }
            out.append(ch)
            bytes += n
        }
        return out + suffix
    }

    /// `name` with its extension replaced by `ext`, as when a HEIC photo goes as a JPEG.
    static func withExtension(_ name: String, _ ext: String) -> String {
        let base = (name as NSString).deletingPathExtension
        return (base.isEmpty ? name : base) + "." + ext
    }

    /// A readable name for something that has none: "Photo 2026-11-17 17.31.jpg". Colons are left
    /// out, as Finder does, so the name needs no quoting beyond its spaces.
    static func stamped(_ kind: String, at date: Date, ext: String, timeZone: TimeZone = .current) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let stamp = String(format: "%04d-%02d-%02d %02d.%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
        return "\(kind) \(stamp).\(ext)"
    }
}

/// Where a send goes, in words: the agent working in the pane, or else the pane's computer.
enum SendTarget {
    /// The agent's name when the pane runs one, else the machine's.
    static func name(agent: AgentKind?, machine: String?) -> String {
        if let agent { return agent.displayName }
        if let machine = machine?.trimmingCharacters(in: .whitespacesAndNewlines), !machine.isEmpty { return machine }
        return "this computer"
    }

    /// The attach menu's title.
    static func menuTitle(_ target: String) -> String { "Send to \(target)" }

    /// What is being sent: its name for one file, the count for more.
    static func what(_ names: [String]) -> String {
        names.count == 1 ? names[0] : "\(names.count) files"
    }

    static func progress(_ names: [String], to target: String, fraction: Double) -> String {
        let pct = Int((min(max(fraction, 0), 1) * 100).rounded(.down))
        return "Sending \(what(names)) to \(target) · \(pct)%"
    }

    static func done(_ names: [String], to target: String) -> String { "Sent \(what(names)) to \(target)" }

    static func tooLarge(_ what: String) -> String {
        "\(what) is too big. Rex takes files up to \(size(FileUploader.maxFileSize))."
    }

    /// A size in plain words, for the cellular question: "31 MB".
    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Above this, a send on an expensive network (cellular, a hotspot) asks first.
    static let expensiveLimit: Int64 = 25_000_000
}

/// What Paste (the paste key, ⌘V, the edit menu) does with the clipboard. Text always wins, so
/// pasting text never changes: an image or a file is sent only when the clipboard holds no text at
/// all. Otherwise only the attach menu's Paste Image or Paste File sends it. Everything here is read from the
/// pasteboard's types, which iOS lets an app check without asking the user.
enum ClipboardChoice: Equatable {
    case text
    case files
    case image
    case nothing

    static func paste(hasText: Bool, hasImage: Bool, hasFiles: Bool, canSend: Bool) -> ClipboardChoice {
        if hasText { return .text }
        guard canSend else { return .nothing }
        if hasFiles { return .files }
        if hasImage { return .image }
        return .nothing
    }

    /// The attach menu offers Paste Image or Paste File whenever there is one, even beside text (an
    /// image copied from Safari also carries its address).
    static func offersPasteImage(hasImage: Bool, canSend: Bool) -> Bool { hasImage && canSend }
}

/// Which of an item's types is read as the file to send: an image, else a movie, else, for an item
/// backed by a file, its data. Text and addresses on their own are never sent as files.
enum FileItemType {
    static func pick(_ types: [UTType], fileBacked: Bool) -> UTType? {
        if let t = types.first(where: { $0.conforms(to: .image) && !$0.conforms(to: .url) }) { return t }
        if let t = types.first(where: { $0.conforms(to: .movie) }) { return t }
        guard fileBacked else { return nil }
        return types.first { ($0.conforms(to: .data) || $0.conforms(to: .content)) && !$0.conforms(to: .url) && !$0.conforms(to: .text) }
    }
}

/// A file with no extension (`Makefile`, `LICENSE`, a dotfile) gives Quick Look nothing to choose
/// a viewer by. When it is small and reads as text, it is previewed as text.
enum TextHint {
    /// Larger files keep their name: Quick Look would lay out all of it as text.
    static let maxSize: Int64 = 1_000_000
    /// How much of the file is read to tell.
    static let headBytes = 4096

    /// Whether to preview as text: no extension, not empty, at most `maxSize`, and the head is
    /// UTF-8 with no NUL. A character cut in two by the end of the head still counts.
    static func applies(name: String, size: Int64, head: Data) -> Bool {
        guard (name as NSString).pathExtension.isEmpty, size > 0, size <= maxSize, !head.isEmpty, !head.contains(0) else { return false }
        if String(data: head, encoding: .utf8) != nil { return true }
        // Only a head that was cut may end inside a character: at most three bytes of one.
        guard head.count >= headBytes, Int64(head.count) < size else { return false }
        return (1...3).contains { String(data: head.dropLast($0), encoding: .utf8) != nil }
    }

    /// Renames the downloaded copy to `<name>.txt` when the hint applies, and gives the new place.
    /// Reads the head from disk: call it off the main actor.
    static func renamed(_ url: URL) -> URL? {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        let head = (try? handle.read(upToCount: headBytes)) ?? Data()
        try? handle.close()
        guard applies(name: url.lastPathComponent, size: Int64(size), head: head) else { return nil }
        let to = url.appendingPathExtension("txt")
        return (try? FileManager.default.moveItem(at: url, to: to)) == nil ? nil : to
    }
}
