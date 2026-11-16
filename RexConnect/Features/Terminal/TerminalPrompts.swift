import UIKit

// Questions a pane asks before it does something a program, or a paste, could abuse: opening a
// link that isn't plainly a web page, and pasting text that would run in a shell. The rules are
// pure (`LinkOpenPolicy`, `PasteConfirmation`); `TerminalPrompt` shows the question.

/// Whether a tapped link opens at once.
///
/// A program writes both the link and its label (OSC 8), so neither can be trusted alone:
///
/// - `http`, `https` and `mailto` open at once: a browser or a mail draft, where the user sees
///   the address before anything happens.
/// - Any other scheme (`tel:`, `sms:`, `file:`, an app's own scheme) can start a call or make
///   another app act: the target is shown and the user is asked first.
/// - An OSC 8 link whose label reads like one site while the target is another
///   (`https://bank.com` on a link to `evil.example`) is asked about too, whatever its scheme.
/// - Text that isn't a URL with a scheme is not opened.
enum LinkOpenPolicy {
    enum Decision: Equatable {
        case open(URL)
        case ask(URL, LinkQuestion)
        case refuse
    }

    enum LinkQuestion: Equatable {
        /// Not a web or mail link.
        case scheme(String)
        /// The label names `shown`, the link goes to `target`.
        case mismatch(shown: String, target: String)
    }

    static let directSchemes: Set<String> = ["http", "https", "mailto"]

    /// `label` is the link's visible text, for an OSC 8 link; nil for an address found in the
    /// text (which is its own label).
    static func decide(target: String, label: String?) -> Decision {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), !scheme.isEmpty else { return .refuse }
        guard directSchemes.contains(scheme) else { return .ask(url, .scheme(scheme)) }
        if let label, let shown = host(inLabel: label), let goesTo = url.host?.lowercased(), !sameSite(shown: shown, target: goesTo) {
            return .ask(url, .mismatch(shown: shown, target: goesTo))
        }
        return .open(url)
    }

    /// Top-level domains common enough that `name.tld` in a label reads as a site, not as a
    /// file name (`README.md`, `main.rs`).
    private static let siteEndings: Set<String> = [
        "com", "org", "net", "io", "dev", "app", "ai", "co", "me", "sh", "edu", "gov", "info", "xyz", "cloud",
        "uk", "de", "fr", "es", "it", "nl", "eu", "us", "ca", "au", "ch", "se", "no", "jp", "cn", "in", "br", "ru",
    ]

    /// The site a label reads as, if it reads as one: the host of an address with a scheme, a
    /// name that starts with `www.`, or a bare name under a common top-level domain.
    static func host(inLabel label: String) -> String? {
        for word in label.lowercased().split(whereSeparator: { $0.isWhitespace }) {
            var s = Substring(word)
            var explicit = false
            if let r = s.range(of: "://") {
                s = s[r.upperBound...]
                explicit = true
            }
            // user@host, then the host ends at a path, a port or a query.
            if let at = s.firstIndex(of: "@"), explicit { s = s[s.index(after: at)...] }
            let host = s.prefix { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." }
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let parts = host.split(separator: ".")
            guard parts.count >= 2, let last = parts.last, last.count >= 2, last.allSatisfy(\.isLetter) else { continue }
            if explicit || host.hasPrefix("www.") || siteEndings.contains(String(last)) { return host }
        }
        return nil
    }

    /// `www.` aside, the same host, or the target is a subdomain of the one shown.
    static func sameSite(shown: String, target: String) -> Bool {
        func bare(_ h: String) -> String { h.hasPrefix("www.") ? String(h.dropFirst(4)) : h }
        let a = bare(shown.lowercased()), b = bare(target.lowercased())
        return a == b || b.hasSuffix("." + a)
    }
}

/// When a paste is asked about, and what the question says.
///
/// A paste into a program that asked for bracketed paste arrives as one block the program knows
/// is pasted; it goes straight in. Anywhere else each newline is the Return key, so a shell runs
/// every line as it arrives. The engine says whether the text has such characters
/// (`TerminalEngineView.pasteNeedsConfirmation`: libghostty-vt's unsafe-paste check).
enum PasteConfirmation {
    static let previewLines = 3
    static let previewWidth = 60

    /// The number of lines `text` is typed as.
    static func lineCount(_ text: String) -> Int {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
        // A newline at the end runs the last line; it doesn't start another.
        if lines.count > 1, lines.last?.isEmpty == true { lines.removeLast() }
        return max(1, lines.count)
    }

    static func title(_ text: String) -> String {
        let n = lineCount(text)
        return n == 1 ? "Paste and run this line?" : "Paste \(n) lines?"
    }

    /// The first lines, cut to fit an alert, control characters shown as spaces.
    static func message(_ text: String) -> String {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.allSatisfy(\.isWhitespace) }
        var shown = lines.prefix(previewLines).map { line -> String in
            let clean = String(String.UnicodeScalarView(line.unicodeScalars.map { $0.value < 0x20 || $0.value == 0x7f ? " " : $0 }))
            return clean.count > previewWidth ? String(clean.prefix(previewWidth - 1)) + "…" : clean
        }
        if lines.count > previewLines { shown.append("…") }
        let preview = shown.joined(separator: "\n")
        let why = "This program takes each line as typed, so a shell runs it at once."
        return preview.isEmpty ? why : preview + "\n\n" + why
    }
}

/// Shows a two-button question over a pane, in the system's alert style like the app's other
/// confirmations.
@MainActor
enum TerminalPrompt {
    /// Asks from the view controller on top of `view`'s window. `answer` gets true for the
    /// confirming button; false also when the question can't be shown.
    static func ask(over view: UIView, title: String, message: String, confirm: String, answer: @escaping @MainActor (Bool) -> Void) {
        guard var top = view.window?.rootViewController else { return answer(false) }
        while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in answer(false) })
        let yes = UIAlertAction(title: confirm, style: .default) { _ in answer(true) }
        alert.addAction(yes)
        alert.preferredAction = yes
        top.present(alert, animated: true)
    }

    static func ask(over view: UIView, link url: URL, question: LinkOpenPolicy.LinkQuestion, answer: @escaping @MainActor (Bool) -> Void) {
        let address = url.absoluteString
        let shownAddress = address.count > 300 ? String(address.prefix(299)) + "…" : address
        let title: String, message: String
        switch question {
        case .scheme(let scheme):
            title = "Open this link?"
            message = "\(shownAddress)\n\nA “\(scheme):” link opens in another app."
        case .mismatch(let shown, let target):
            title = "This link goes somewhere else"
            message = "It reads “\(shown)” but opens \(target):\n\n\(shownAddress)"
        }
        ask(over: view, title: title, message: message, confirm: "Open", answer: answer)
    }
}
