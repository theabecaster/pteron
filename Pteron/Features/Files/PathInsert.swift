import Foundation
import RexKit

/// Insert Path: whether a path may be written into a pane, and the exact text that is.
///
/// A path is written as if pasted, so it must only go where the program takes text. The decision
/// reads two facts and nothing else: the name of the pane's foreground program and whether the
/// program asked for bracketed paste. A window title, an agent's status record and the reported
/// working directory are never read: each can name something that isn't in the foreground.
enum PathInsert {
    enum Quoting: Equatable {
        /// For a shell's prompt: `ShellEscape`.
        case shell
        /// As it is: an agent's prompt or an editor takes the text literally.
        case raw
    }

    enum Decision: Equatable {
        /// The pane's program runs somewhere else (ssh, tmux, a container): the listed folders
        /// are not the ones it sees, so Insert isn't offered. The program's name, for the notice.
        case elsewhere(String)
        /// A server whose paths this build doesn't write (Windows).
        case unavailable
        case direct(Quoting)
        /// The program didn't ask for text: the user is asked first. Its name, when known.
        case ask(program: String?)

        /// Whether Insert is offered at all.
        var offered: Bool {
            switch self {
            case .elsewhere, .unavailable: return false
            case .direct, .ask: return true
            }
        }

        var quoting: Quoting {
            if case .direct(let q) = self { return q }
            return .raw
        }
    }

    /// The rows are tried in this order; the first that applies decides.
    static func decide(foreground: String?, bracketedPaste: Bool, windows: Bool = false) -> Decision {
        if windows { return .unavailable }
        let program = foreground.flatMap { $0.isEmpty ? nil : $0 }
        if let program {
            if ProcessNames.isRemoteWrapper(program) { return .elsewhere(program) }
            // A shell in the foreground owns the terminal: it is at its prompt, a `read` or a builtin.
            if ProcessNames.isShell(program) { return .direct(.shell) }
            if AgentKind.fromProgram(program) != nil { return .direct(.raw) }
        }
        if bracketedPaste { return .direct(.raw) }
        return .ask(program: program)
    }

    /// The question before an insert into a program that didn't ask for text.
    static func question(program: String?) -> String {
        "\(program ?? "This program") isn't taking text. Insert anyway?"
    }

    enum Refusal: Error, Equatable {
        /// A control character (general category Cc: C0, DEL, C1) in the path.
        case control
        /// A character that reorders the text around it (U+202A–202E, U+2066–2069).
        case reordering

        var message: String {
            switch self {
            case .control: return "Can't insert a name with control characters."
            case .reordering: return "Can't insert a name with hidden direction marks."
            }
        }
    }

    /// The form a path is written in: relative to the program's working directory when under it
    /// (`.` for that directory itself), `~/…` when under the home folder, absolute otherwise.
    /// A relative path that starts with `-` gets `./` so no command reads it as an option;
    /// absolute and `~/` paths can't start with one. Compared and cut by bytes: nothing is
    /// normalized.
    static func form(_ path: String, cwd: String?, home: String) -> String {
        if let cwd, !cwd.isEmpty {
            if same(path, cwd) { return "." }
            if let rest = remainder(of: path, under: cwd) { return rest.utf8.first == UInt8(ascii: "-") ? "./" + rest : rest }
        }
        if !home.isEmpty, home != "/" {
            if same(path, home) { return "~" }
            if let rest = remainder(of: path, under: home) { return "~/" + rest }
        }
        return path
    }

    /// The text written for `path` (absolute, as listed): its form, quoted for the program, and a
    /// space after it. No line end is ever part of it.
    static func text(for path: String, cwd: String?, home: String, quoting: Quoting) -> Result<String, Refusal> {
        for s in path.unicodeScalars {
            if ShellEscape.isControl(s) { return .failure(.control) }
            if (0x202A...0x202E).contains(s.value) || (0x2066...0x2069).contains(s.value) { return .failure(.reordering) }
        }
        let shaped = form(path, cwd: cwd, home: home)
        switch quoting {
        case .raw:
            return .success(shaped + " ")
        case .shell:
            guard let escaped = ShellEscape.escape(shaped) else { return .failure(.control) }
            return .success(escaped + " ")
        }
    }

    private static func same(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }

    /// `path` without `folder/` in front, when it is inside `folder`.
    private static func remainder(of path: String, under folder: String) -> String? {
        var prefix = Array(folder.utf8)
        if prefix.last != UInt8(ascii: "/") { prefix.append(UInt8(ascii: "/")) }
        guard path.utf8.count > prefix.count, path.utf8.starts(with: prefix) else { return nil }
        return String(Substring(path.utf8.dropFirst(prefix.count)))
    }
}
