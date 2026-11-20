import XCTest
@testable import RexKit

/// The spelling of a path for a shell, and a round trip through the real shells: each must read
/// the escaped word back as the path, as one argument.
final class ShellEscapeTests: XCTestCase {
    func testEverySpecialCharacterGetsABackslash() {
        for c in " `'\"\\$!&;|<>()*?[]{}#^~" {
            XCTAssertEqual(ShellEscape.escape("a\(c)b"), "a\\\(c)b", "\(c)")
        }
        XCTAssertEqual(ShellEscape.escape("plain-name_1.txt"), "plain-name_1.txt")
        XCTAssertEqual(ShellEscape.escape("src/a b/c.swift"), "src/a\\ b/c.swift")
        XCTAssertEqual(ShellEscape.escape("it's"), "it\\'s")
        XCTAssertEqual(ShellEscape.escape("$(id)"), "\\$\\(id\\)")
        XCTAssertEqual(ShellEscape.escape("a  b "), "a\\ \\ b\\ ")
    }

    func testOnlyTheHomePrefixKeepsItsTilde() {
        XCTAssertEqual(ShellEscape.escape("~"), "~")
        XCTAssertEqual(ShellEscape.escape("~/notes"), "~/notes")
        XCTAssertEqual(ShellEscape.escape("~/a b/~x"), "~/a\\ b/\\~x")
        XCTAssertEqual(ShellEscape.escape("~foo"), "\\~foo")
        XCTAssertEqual(ShellEscape.escape("a~b"), "a\\~b")
        XCTAssertEqual(ShellEscape.escape("a=~x"), "a=\\~x")
        XCTAssertEqual(ShellEscape.escape("x=a:~"), "x=a:\\~")
        XCTAssertEqual(ShellEscape.escape("dir/~x"), "dir/\\~x")
    }

    func testALeadingEqualsIsEscaped() {
        XCTAssertEqual(ShellEscape.escape("=foo"), "\\=foo")
        XCTAssertEqual(ShellEscape.escape("a=b"), "a=b")
        XCTAssertEqual(ShellEscape.escape("~/=foo"), "~/=foo")
    }

    func testControlCharactersHaveNoSpelling() {
        for s in ["a\nb", "a\tb", "a\u{1B}[201~b", "a\u{7F}", "a\u{85}b", "\r", "a\u{0}b", "a\u{9B}b", ""] {
            XCTAssertNil(ShellEscape.escape(s), s.debugDescription)
        }
    }

    func testScalarsGoOutAsTheyCameIn() {
        let nfc = "caf\u{E9}", nfd = "cafe\u{301}"
        XCTAssertEqual(ShellEscape.escape(nfc).map { Array($0.unicodeScalars) }, Array(nfc.unicodeScalars))
        XCTAssertEqual(ShellEscape.escape(nfd).map { Array($0.unicodeScalars) }, Array(nfd.unicodeScalars))
        XCTAssertNotEqual(ShellEscape.escape(nfc).map { Array($0.utf8) }, ShellEscape.escape(nfd).map { Array($0.utf8) })
    }

    func testAVeryLongPathIsEscapedWhole() throws {
        let long = String(repeating: "dir with space/", count: 300) + "end"
        let out = try XCTUnwrap(ShellEscape.escape(long))
        XCTAssertEqual(out.utf8.count, long.utf8.count + 600)
        XCTAssertEqual(out.replacingOccurrences(of: "\\ ", with: " "), long)
    }

    #if os(macOS)
    /// Names that shells are known to read differently, and ordinary ones.
    static let names: [String] = [
        "a~b", "a=~x", "x=a:~", "=foo", "=", "~foo", "dir/~x", "a b", "it's", "$HOME", "a{b,c}", "*", "x^y", "a#b", "x!y",
        "caf\u{E9}", "cafe\u{301}", "\"q\"", "back`tick", "a\\b", "\\", "a&b", "a;b", "a|b", "a<b", "a>b", "(x)", "a?b",
        "[ab]", "#start", "^start", "!start", "!!", "$(id)", "`id`", "${x}", "$1", "a  b", " lead", "trail ", "-x", "--",
        "a,b", "%1", "@x", "+x", ":x", "a=b", "a\u{A0}b", "a\u{2028}b", "a\u{3000}b", "\u{1F468}\u{200D}\u{1F4BB}.txt",
        "'", "''", "a'b\"c", "*.txt", "?", "~~", "a\\ b", "x y/z w/q.txt", "né/ü ber", "100%", "{", "}", "[", "]", "!",
        String(repeating: "long name ", count: 400),
    ]

    /// The shells and option sets the escape is promised for. A shell that isn't installed is skipped.
    static let shells: [(name: String, path: String, args: [String])] = [
        ("zsh", "/bin/zsh", ["-f"]),
        ("zsh extendedglob", "/bin/zsh", ["-f", "-o", "extendedglob"]),
        ("zsh equals", "/bin/zsh", ["-f", "-o", "equals"]),
        ("zsh magicequalsubst", "/bin/zsh", ["-f", "-o", "magicequalsubst"]),
        ("bash", "/bin/bash", ["--norc", "--noprofile"]),
        ("bash posix", "/bin/bash", ["--norc", "--noprofile", "--posix"]),
        ("dash", "/bin/dash", []),
        ("ksh", "/bin/ksh", []),
        ("sh", "/bin/sh", []),
        ("fish", "/opt/homebrew/bin/fish", ["--no-config"]),
        ("fish", "/usr/local/bin/fish", ["--no-config"]),
        ("fish", "/usr/bin/fish", ["--no-config"]),
    ]

    private func run(_ shell: String, _ args: [String], _ command: String) throws -> Data {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = args + ["-c", command]
        p.environment = ["HOME": "/tmp/rexkit-home", "PATH": "/usr/bin:/bin", "LC_ALL": "en_US.UTF-8"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        p.standardInput = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return data
    }

    func testEveryShellReadsTheEscapedPathBackAsOneWord() throws {
        var ran = 0
        // One script per shell, a line per name. Two more words around each show it stayed one word.
        let escaped = try Self.names.map { try XCTUnwrap(ShellEscape.escape($0), $0) }
        let script = escaped.map { "printf '%s\\n' first \($0) last" }.joined(separator: "\n")
        let expected = Self.names.map { "first\n\($0)\nlast\n" }
        for shell in Self.shells where FileManager.default.isExecutableFile(atPath: shell.path) {
            ran += 1
            let out = String(decoding: try run(shell.path, shell.args, script), as: UTF8.self)
            guard out != expected.joined() else { continue }
            // Which name: each one again, alone.
            for (name, word) in zip(Self.names, escaped) {
                let one = try run(shell.path, shell.args, "printf '%s\\n' first \(word) last")
                XCTAssertEqual(String(decoding: one, as: UTF8.self), "first\n\(name)\nlast\n",
                               "\(shell.name): \(name.debugDescription) as \(word.debugDescription)")
            }
            XCTFail("\(shell.name) read the names differently")
        }
        XCTAssertGreaterThanOrEqual(ran, 2, "no shell to test with")
    }

    func testTheHomePrefixStillExpands() throws {
        for shell in Self.shells where FileManager.default.isExecutableFile(atPath: shell.path) {
            let escaped = try XCTUnwrap(ShellEscape.escape("~/a b/~c"))
            let out = try run(shell.path, shell.args, "printf '%s\\n' \(escaped)")
            XCTAssertEqual(String(decoding: out, as: UTF8.self), "/tmp/rexkit-home/a b/~c\n", shell.name)
        }
    }

    /// With `./` before it, a name that starts with a dash is an operand, not an option.
    func testADashNameBehindDotSlashIsNotAnOption() throws {
        let escaped = try XCTUnwrap(ShellEscape.escape("./-n"))
        let out = try run("/bin/sh", [], "echo \(escaped)")
        XCTAssertEqual(String(decoding: out, as: UTF8.self), "./-n\n")
    }
    #endif
}
