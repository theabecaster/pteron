import Foundation
import Testing
import RexKit
@testable import Pteron

/// Insert Path: when a path may be written into a pane, and the exact text.
struct PathInsertTests {
    // MARK: Which panes

    @Test func aShellInTheForegroundTakesAnEscapedPath() {
        for shell in ["sh", "bash", "zsh", "fish", "dash", "ksh", "mksh", "ZSH"] {
            #expect(PathInsert.decide(foreground: shell, bracketedPaste: false) == .direct(.shell), "\(shell)")
            #expect(PathInsert.decide(foreground: shell, bracketedPaste: true) == .direct(.shell), "\(shell)")
        }
        // A login shell reports `-zsh`; the label drops the dash.
        #expect(PathInsert.decide(foreground: ProcessNames.label(["argv0": "-zsh", "name": "zsh"]), bracketedPaste: true) == .direct(.shell))
    }

    @Test func anAgentByItsProgramNameTakesTheRawPath() {
        for agent in ["claude", "claude-code", "codex", "gemini-cli", "opencode", "amp", "aider", "cursor-agent", "codex.js"] {
            #expect(PathInsert.decide(foreground: agent, bracketedPaste: false) == .direct(.raw), "\(agent)")
        }
    }

    @Test func aProgramThatAskedForBracketedPasteTakesTheRawPath() {
        #expect(PathInsert.decide(foreground: "vim", bracketedPaste: true) == .direct(.raw))
        #expect(PathInsert.decide(foreground: nil, bracketedPaste: true) == .direct(.raw))
    }

    @Test func anythingElseIsAskedAboutFirst() {
        #expect(PathInsert.decide(foreground: "htop", bracketedPaste: false) == .ask(program: "htop"))
        #expect(PathInsert.decide(foreground: "less", bracketedPaste: false) == .ask(program: "less"))
        #expect(PathInsert.decide(foreground: nil, bracketedPaste: false) == .ask(program: nil))
        #expect(PathInsert.decide(foreground: "", bracketedPaste: false) == .ask(program: nil))
        // A script shows its own name, not its interpreter's.
        let script = ProcessNames.label(["script": "/home/dev/bin/deploy.sh", "name": "bash"])
        #expect(PathInsert.decide(foreground: script, bracketedPaste: false) == .ask(program: "deploy.sh"))
        // Nearly an agent's name is not an agent.
        #expect(PathInsert.decide(foreground: "claude-proxy", bracketedPaste: false) == .ask(program: "claude-proxy"))
        #expect(PathInsert.question(program: "htop") == "htop isn't taking text. Insert anyway?")
        #expect(PathInsert.question(program: nil) == "This program isn't taking text. Insert anyway?")
    }

    /// The decision takes the foreground's name and the paste mode only: a pane whose title or
    /// status record names an agent, or whose reported directory is anything at all, has no way in.
    @Test func aTitleOrStatusThatNamesAnAgentChangesNothing() {
        var m = BlockMeta()
        m.foreground = "less"
        m.title = "✳ Claude Code"
        m.pwd = "file://another-host/home/dev/claude-proxy"
        m.statuses = ["claude": ProgramStatus(["id": "claude", "app": "claude", "state": "working"])]
        #expect(m.agentKind == .claude)
        #expect(PathInsert.decide(foreground: m.foreground, bracketedPaste: false) == .ask(program: "less"))
    }

    @Test func aProgramThatWorksSomewhereElseHidesInsertBeforeAnythingElse() {
        for p in ["ssh", "autossh", "mosh", "mosh-client", "et", "tmux", "screen", "docker", "podman", "kubectl", "lxc",
                  "incus", "nsenter", "toolbox", "distrobox-enter", "distrobox", "SSH"] {
            #expect(PathInsert.decide(foreground: p, bracketedPaste: true) == .elsewhere(p), "\(p)")
            #expect(!PathInsert.decide(foreground: p, bracketedPaste: false).offered, "\(p)")
        }
        #expect(PathInsert.decide(foreground: "sshd-helper", bracketedPaste: false) == .ask(program: "sshd-helper"))
    }

    @Test func aWindowsServerHasNoInsert() {
        #expect(PathInsert.decide(foreground: "zsh", bracketedPaste: true, windows: true) == .unavailable)
        #expect(!PathInsert.Decision.unavailable.offered)
        #expect(PathInsert.Decision.direct(.shell).offered)
        #expect(PathInsert.Decision.ask(program: nil).offered)
    }

    // MARK: The path's form

    @Test func aPathIsRelativeUnderTheWorkingDirectoryThenHomeThenAbsolute() {
        let cwd = "/home/dev/project", home = "/home/dev"
        #expect(PathInsert.form("/home/dev/project/src/main.rs", cwd: cwd, home: home) == "src/main.rs")
        #expect(PathInsert.form("/home/dev/project", cwd: cwd, home: home) == ".")
        #expect(PathInsert.form("/home/dev/notes/todo.md", cwd: cwd, home: home) == "~/notes/todo.md")
        #expect(PathInsert.form("/home/dev", cwd: cwd, home: home) == "~")
        #expect(PathInsert.form("/etc/hosts", cwd: cwd, home: home) == "/etc/hosts")
        #expect(PathInsert.form("/home/dev/project2/a", cwd: cwd, home: home) == "~/project2/a", "a longer sibling name is not inside")
        #expect(PathInsert.form("/home/developer/a", cwd: cwd, home: home) == "/home/developer/a")
        #expect(PathInsert.form("/etc/hosts", cwd: "/", home: "") == "etc/hosts")
        #expect(PathInsert.form("/etc/hosts", cwd: nil, home: "") == "/etc/hosts")
        #expect(PathInsert.form("/etc/hosts", cwd: "", home: "/") == "/etc/hosts")
    }

    @Test func aRelativeNameThatStartsWithADashGetsDotSlash() throws {
        let cwd = "/home/dev/project", home = "/home/dev"
        #expect(PathInsert.form("/home/dev/project/-x", cwd: cwd, home: home) == "./-x")
        #expect(PathInsert.form("/home/dev/project/-rf", cwd: cwd, home: home) == "./-rf")
        #expect(PathInsert.form("/home/dev/project/--", cwd: cwd, home: home) == "./--")
        #expect(PathInsert.form("/home/dev/project/-d/file", cwd: cwd, home: home) == "./-d/file")
        #expect(PathInsert.form("/home/dev/project/a/-x", cwd: cwd, home: home) == "a/-x")
        #expect(PathInsert.form("/home/dev/-x", cwd: cwd, home: home) == "~/-x")
        #expect(PathInsert.form("/-x", cwd: cwd, home: home) == "/-x")
        // What lands after `rm ` in every mode.
        for q in [PathInsert.Quoting.shell, .raw] {
            #expect(try PathInsert.text(for: "/home/dev/project/-x", cwd: cwd, home: home, quoting: q).get() == "./-x ")
        }
    }

    // MARK: The text

    @Test func aShellGetsEveryListedCharacterEscapedAndASpaceAfter() throws {
        let cwd = "/home/dev/project", home = "/home/dev"
        func shell(_ name: String) throws -> String {
            try PathInsert.text(for: cwd + "/" + name, cwd: cwd, home: home, quoting: .shell).get()
        }
        for c in " `'\"\\$!&;|<>()*?[]{}#^~" {
            #expect(try shell("a\(c)b") == "a\\\(c)b ", "\(c)")
        }
        #expect(try shell("my file.txt") == "my\\ file.txt ")
        #expect(try shell("=eq") == "\\=eq ")
        #expect(try shell("~tilde") == "\\~tilde ")
        #expect(try shell("$(reboot)") == "\\$\\(reboot\\) ")
        #expect(try PathInsert.text(for: "/home/dev/a b/~c", cwd: cwd, home: home, quoting: .shell).get() == "~/a\\ b/\\~c ")
        #expect(try PathInsert.text(for: "/srv/a b", cwd: cwd, home: home, quoting: .shell).get() == "/srv/a\\ b ")
        #expect(try PathInsert.text(for: cwd, cwd: cwd, home: home, quoting: .shell).get() == ". ")
        #expect(try PathInsert.text(for: home, cwd: cwd, home: home, quoting: .shell).get() == "~ ")
    }

    @Test func otherProgramsGetThePathAsItIs() throws {
        let cwd = "/home/dev/project", home = "/home/dev"
        let name = "a b's $x ~y =z *.txt"
        #expect(try PathInsert.text(for: cwd + "/" + name, cwd: cwd, home: home, quoting: .raw).get() == name + " ")
        #expect(try PathInsert.text(for: "/home/dev/x y", cwd: cwd, home: home, quoting: .raw).get() == "~/x y ")
    }

    @Test func noLineEndIsEverWritten() throws {
        for q in [PathInsert.Quoting.shell, .raw] {
            let t = try PathInsert.text(for: "/srv/data/report final.txt", cwd: nil, home: "", quoting: q).get()
            #expect(t.hasSuffix(" "))
            #expect(!t.unicodeScalars.contains { ShellEscape.isControl($0) })
        }
    }

    @Test func aNameWithAControlCharacterIsRefusedInEveryMode() {
        for bad in ["a\tb", "a\nb", "a\rb", "a\u{1B}[201~b", "a\u{7F}b", "a\u{85}b", "a\u{0}b", "a\u{9B}b"] {
            for q in [PathInsert.Quoting.shell, .raw] {
                #expect(PathInsert.text(for: "/srv/" + bad, cwd: "/srv", home: "", quoting: q) == .failure(.control), "\(bad.debugDescription)")
            }
        }
        // In a folder's name too, not only the last part.
        #expect(PathInsert.text(for: "/srv/a\nb/file", cwd: nil, home: "", quoting: .raw) == .failure(.control))
        #expect(PathInsert.Refusal.control.message == "Can't insert a name with control characters.")
    }

    @Test func aNameThatReordersTextIsRefused() {
        for v in [0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069] {
            let bad = "/srv/a\(Character(Unicode.Scalar(UInt32(v))!))b"
            #expect(PathInsert.text(for: bad, cwd: nil, home: "", quoting: .shell) == .failure(.reordering), "\(String(v, radix: 16))")
            #expect(PathInsert.text(for: bad, cwd: nil, home: "", quoting: .raw) == .failure(.reordering))
        }
        // Joiners stay: emoji and some scripts need them.
        #expect(try! PathInsert.text(for: "/srv/\u{1F468}\u{200D}\u{1F4BB}", cwd: "/srv", home: "", quoting: .shell).get()
            == "\u{1F468}\u{200D}\u{1F4BB} ")
    }

    @Test func scalarsComeOutAsListed() throws {
        let nfc = "caf\u{E9}.txt", nfd = "cafe\u{301}.txt"
        for q in [PathInsert.Quoting.shell, .raw] {
            let a = try PathInsert.text(for: "/srv/" + nfc, cwd: "/srv", home: "", quoting: q).get()
            let b = try PathInsert.text(for: "/srv/" + nfd, cwd: "/srv", home: "", quoting: q).get()
            #expect(Array(a.unicodeScalars) == Array((nfc + " ").unicodeScalars))
            #expect(Array(b.unicodeScalars) == Array((nfd + " ").unicodeScalars))
            #expect(Array(a.utf8) != Array(b.utf8))
        }
        // A working directory spelled the other way is another folder: nothing is cut from the path.
        #expect(PathInsert.form("/srv/cafe\u{301}/x", cwd: "/srv/caf\u{E9}", home: "") == "/srv/cafe\u{301}/x")
    }

    @Test func aVeryLongPathIsWrittenWhole() throws {
        let long = "/srv/" + String(repeating: "deep dir/", count: 450) + "end.txt"
        let t = try PathInsert.text(for: long, cwd: "/srv", home: "", quoting: .shell).get()
        #expect(t.utf8.count == long.utf8.count - 5 + 450 + 1)
        #expect(t.hasSuffix("end.txt "))
    }

    // MARK: Names

    @Test func processNamesKeepTheirSets() {
        #expect(ProcessNames.shells == ["sh", "bash", "zsh", "fish", "dash", "ksh", "mksh"])
        #expect(ProcessNames.isShell("zsh") && !ProcessNames.isShell("nu") && !ProcessNames.isShell("zsh-helper"))
        #expect(ProcessNames.isRemoteWrapper("mosh-client") && ProcessNames.isRemoteWrapper("distrobox-enter"))
        #expect(!ProcessNames.isRemoteWrapper("sshfs") && !ProcessNames.isRemoteWrapper("zsh"))
        #expect(ProcessNames.label(["script": "/usr/local/bin/claude", "name": "node"]) == "claude")
        #expect(ProcessNames.label(["argv0": "-zsh", "name": "zsh"]) == "zsh")
        #expect(ProcessNames.label(["invoked_path": "/opt/bin/codex"]) == "codex")
        #expect(ProcessNames.label(["name": "vim"]) == "vim")
        #expect(ProcessNames.label([:]) == "")
    }
}
