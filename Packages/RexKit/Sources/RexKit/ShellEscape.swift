import Foundation

/// Writes a path so a shell at its prompt reads it back as one word, that same path.
///
/// One rule for sh, bash, zsh, dash, ksh and fish: a backslash before every character one of
/// them reads as syntax, the way the server types the paths of sent files. The path's scalars go
/// out exactly as they came in; nothing is normalized, because names on Linux are byte-exact.
///
/// - Every `~` is escaped except a leading `~/` (or a lone `~`), which stays the home folder:
///   bash and zsh also expand a `~` after `=` or `:` in a word.
/// - A leading `=` is escaped (zsh reads `=name` as a command's path).
/// - A path with a control character has no spelling here and gives nil: a backslash before a
///   line end is a line continuation, not a line end, and an escape sequence must never reach a
///   prompt. Callers refuse such a path.
///
/// It does not stop a word that starts with `-` from reading as an option: that is the caller's
/// (`./-name`), since no quoting can.
public enum ShellEscape {
    /// What a shell reads as syntax somewhere in a word.
    static let special: Set<Unicode.Scalar> = [
        " ", "`", "'", "\"", "\\", "$", "!", "&", ";", "|", "<", ">", "(", ")", "*", "?", "[", "]", "{", "}",
        "#", "^", "~",
    ]

    /// Whether a scalar is a control character (general category Cc: C0, DEL and C1).
    public static func isControl(_ s: Unicode.Scalar) -> Bool { s.properties.generalCategory == .control }

    /// The path as a shell word, or nil when it is empty or holds a control character.
    public static func escape(_ path: String) -> String? {
        let scalars = path.unicodeScalars
        guard !scalars.isEmpty, !scalars.contains(where: isControl) else { return nil }
        var out = String.UnicodeScalarView()
        var rest = Substring.UnicodeScalarView(scalars)
        // The home prefix stays as it is.
        if path == "~" { return "~" }
        if rest.starts(with: "~/".unicodeScalars) {
            out.append(contentsOf: "~/".unicodeScalars)
            rest = rest.dropFirst(2)
        } else if rest.first == "=" {
            out.append(contentsOf: "\\=".unicodeScalars)
            rest = rest.dropFirst()
        }
        for s in rest {
            if special.contains(s) { out.append("\\") }
            out.append(s)
        }
        return String(out)
    }
}
