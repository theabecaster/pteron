import Foundation

/// Cuts typed text into `terminal.write` requests that each fit the server's message limit
/// (`limits.max_message_bytes`). A request over the limit closes the whole control connection
/// with 1009, so a long paste goes as consecutive writes, each sent after the one before it was
/// answered (`TerminalStream`'s one input queue).
///
/// A cut falls between grapheme clusters, so an emoji with its modifiers, a flag or a letter
/// with its accents arrives in one write. A cluster that alone costs more than a write may carry
/// (thousands of combining marks) is cut between Unicode scalars. A cut never falls inside a
/// scalar: every piece is valid UTF-8.
public enum WriteChunks {
    /// The bytes `scalar` takes inside a JSON string as `JSONCodec` writes it, or more: `"` and
    /// `\` take two, a control character six (`\u001b`), U+2028 and U+2029 six in case an
    /// encoder escapes them, `/` two although `JSONCodec` doesn't escape it, anything else its
    /// UTF-8 length. Never less than the real cost, so a piece never passes its budget.
    @inline(__always)
    public static func cost(_ scalar: Unicode.Scalar) -> Int {
        switch scalar.value {
        case 0x22, 0x2F, 0x5C: return 2
        case 0..<0x20, 0x7F: return 6
        case 0x2028, 0x2029: return 6
        case 0x20..<0x80: return 1
        case 0x80..<0x800: return 2
        case 0x800..<0x10000: return 3
        default: return 4
        }
    }

    /// What `text` costs inside a JSON string, at most (`cost`).
    public static func cost(of text: some StringProtocol) -> Int { cost(of: text.unicodeScalars) }

    private static func cost(of scalars: some Sequence<Unicode.Scalar>) -> Int {
        var n = 0
        for s in scalars { n += cost(s) }
        return n
    }

    /// Where the first write of `text` ends when one write may carry `budget` bytes of JSON
    /// string, or nil when all of `text` fits in one. The piece before the index is never empty:
    /// with a budget too small for even one scalar, the first scalar goes alone (the request
    /// then fails on its own, as any request over the limit does).
    public static func cut(_ text: String, budget: Int) -> String.Index? {
        // No scalar costs more than six bytes for each of its UTF-8 bytes: a keystroke ends here.
        if text.utf8.count * 6 <= budget { return nil }
        var used = 0
        var i = text.startIndex
        while i < text.endIndex {
            let next = text.index(after: i)
            let c = cost(of: text.unicodeScalars[i..<next])
            if used + c > budget {
                return i > text.startIndex ? i : scalarCut(text, from: i, budget: budget)
            }
            used += c
            i = next
        }
        return nil
    }

    /// A cluster at the start of `text` that costs more than `budget` alone: cut between its
    /// scalars, after at least one.
    private static func scalarCut(_ text: String, from start: String.Index, budget: Int) -> String.Index {
        let scalars = text.unicodeScalars
        var used = 0
        var i = start
        while i < scalars.endIndex {
            let c = cost(scalars[i])
            if used + c > budget, i > start { return i }
            used += c
            i = scalars.index(after: i)
        }
        return i
    }

    /// `text` as consecutive pieces of at most `budget` bytes of JSON string each (`cut`).
    public static func split(_ text: String, budget: Int) -> [String] {
        var out: [String] = []
        var rest = text
        while let i = cut(rest, budget: budget) {
            out.append(String(rest[..<i]))
            rest = String(rest[i...])
        }
        if !rest.isEmpty || out.isEmpty { out.append(rest) }
        return out
    }
}
