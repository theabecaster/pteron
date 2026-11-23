import Foundation

/// The words of a notice toast, built from what a program sent (OSC 9 / 777). A program chooses
/// the text, so it is cleaned and always shown with the place it came from: it can't pose as
/// the app.
enum AlertCopy {
    /// The most of a program's text a toast keeps; two lines show.
    static let maxText = 240

    /// Whether a `desktop_notification` is worth a toast: not empty, and not an OSC 9;4 progress
    /// report that an older server passed through as a notification.
    static func isNotice(title: String, body: String) -> Bool {
        if body.hasPrefix("4;") { return false }
        return !clean(title).isEmpty || !clean(body).isEmpty
    }

    /// The program's title, or the tab's name for OSC 9, which has none.
    static func noticeTitle(_ title: String, tab: String) -> String {
        let t = clean(title)
        return t.isEmpty ? tab : t
    }

    /// Where it came from ("session › tab"), then the program's text.
    static func noticeBody(_ body: String, place: String) -> String {
        [place, clean(body)].filter { !$0.isEmpty }.joined(separator: " — ")
    }

    /// The count under a notice toast for notices folded into it.
    static func moreNotices(_ n: Int) -> String {
        n == 1 ? "1 more notification" : "\(n) more notifications"
    }

    /// The same count where the sentence doesn't fit.
    static func moreNoticesShort(_ n: Int) -> String { "\(n) more" }

    /// One line of plain text: control characters and direction overrides out, runs of white
    /// space as one space, at most `maxText` characters.
    static func clean(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        var space = false
        for u in s.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(u) || u.properties.generalCategory == .control {
                space = !out.isEmpty
                continue
            }
            // Bidirectional embeddings, overrides and isolates can make text read as other text.
            if (0x202A...0x202E).contains(u.value) || (0x2066...0x2069).contains(u.value) { continue }
            if space { out.append(" "); space = false }
            out.append(u)
        }
        let text = String(out)
        return text.count > maxText ? String(text.prefix(maxText - 1)) + "…" : text
    }
}
