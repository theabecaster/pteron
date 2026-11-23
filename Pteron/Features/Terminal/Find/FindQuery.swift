import Foundation

/// The find field's text as a needle, when to search it, and the count the bar shows. Pure.
enum FindQuery {
    /// Needles longer than this many bytes (after NFC) are cut, at a character boundary.
    static let maxBytes = 1024
    /// Needles shorter than this many characters wait `shortDelay` before they are searched,
    /// as Ghostty's Mac overlay does: one or two letters match almost everything.
    static let shortLength = 3
    static let shortDelay: TimeInterval = 0.3

    /// The bytes to search for: the first line only, composed (NFC, as terminal output almost
    /// always is), at most `maxBytes`.
    static func sanitize(_ text: String) -> [UInt8] {
        let line = firstLine(text)
        let composed = line.precomposedStringWithCanonicalMapping
        var out: [UInt8] = []
        for ch in composed {
            let bytes = Array(String(ch).utf8)
            guard out.count + bytes.count <= maxBytes else { break }
            out += bytes
        }
        return out
    }

    /// Text up to its first line break. The field is one line: a paste keeps only its first line.
    static func firstLine(_ text: String) -> String {
        guard let i = text.firstIndex(where: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" }) else { return text }
        return String(text[..<i])
    }

    /// How long to wait before searching `text`.
    static func delay(for text: String) -> TimeInterval {
        let n = text.count
        return n > 0 && n < shortLength ? shortDelay : 0
    }

    /// What the bar shows inside the field's trailing edge, or nil for nothing (no needle, or
    /// nothing found yet while the search runs).
    static func count(_ r: FindResult) -> String? {
        guard r.open, !r.needle.isEmpty else { return nil }
        if r.total == 0 {
            guard r.complete else { return nil }
            return r.historyFull ? "No matches in recent history" : "No matches"
        }
        let more = r.complete ? "" : "+"
        if let i = r.selectedIndex { return "\(i + 1) of \(r.total)\(more)" }
        return r.complete ? "– of \(r.total)" : "\(r.total)+"
    }

    /// The same, as VoiceOver reads it.
    static func spokenCount(_ r: FindResult) -> String? {
        guard let text = count(r) else { return nil }
        return text.replacingOccurrences(of: "–", with: "none").replacingOccurrences(of: "+", with: " or more")
    }
}
