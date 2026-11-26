import Foundation
import RexKit
import Testing
import UIKit
@testable import Pteron

/// Which panes get the keyboard's autocorrection, spell checking and sentence capitals: only one
/// with an agent in front. The panes are the ones `AgentDetectTests` holds, as panes report them.
struct TypingAidsTests {
    typealias Pane = AgentDetectTests.Pane

    @Test func theAidsOfAnAgent() {
        #expect(TypingAids.prose.autocorrection == .yes)
        #expect(TypingAids.prose.spellChecking == .yes)
        #expect(TypingAids.raw.autocorrection == .no)
        #expect(TypingAids.raw.spellChecking == .no)
        #expect(TypingAids.for(nil) == .raw)
        #expect(TypingAids.for(BlockMeta()) == .raw)
    }

    /// The words the keyboard corrected in a simulator (iOS 27.2) in an agent's prompt, and
    /// whether the correction is made. `range` is the word the keyboard asked to replace.
    @Test(arguments: [
        ("Fix the bug in teh", "teh", false),
        ("i", "i", false),
        ("I think so. dont", "dont", false),
        ("@src/compnent.tsx", "tsx", true),       // the keyboard made it "tax"
        ("@src/compnent", "compnent", true),
        ("see src", "src", false),                 // "src" alone is a word to the keyboard
        ("!ls src", "src", true),                  // the keyboard made it "sec"
        ("  !git stauts", "stauts", true),
        ("ls -la", "la", true),
        ("use --verbsoe", "verbsoe", true),
        ("ask @clade", "clade", true),
        ("set $HOEM", "HOEM", true),
        ("run my_scirpt", "scirpt", true),
        ("open ~/Dekstop", "Dekstop", true),
        ("call `fucntion", "fucntion", true),
        ("v2beta", "v2beta", true),
        ("teh/", "teh", true),
    ])
    func correctionsLeaveCodeAsTyped(_ line: String, _ word: String, _ kept: Bool) {
        let range = (line as NSString).range(of: word, options: .backwards)
        #expect(TypingAids.keepsTyped(line, replacing: range) == kept, "\(line) [\(word)]")
    }

    /// A double space becomes ". " in prose, as the keyboard's shortcut does; not in a command.
    @Test func thePeriodShortcut() {
        #expect(!TypingAids.keepsTyped("ok ", replacing: NSRange(location: 2, length: 1)))
        #expect(TypingAids.keepsTyped("!ls ", replacing: NSRange(location: 3, length: 1)))
    }

    @Test func aRangeOutsideTheLineIsNeverReplaced() {
        #expect(TypingAids.keepsTyped("ok", replacing: NSRange(location: 0, length: 5)))
        #expect(TypingAids.keepsTyped("", replacing: NSRange(location: 4, length: 3)))
    }

    /// The watch tells a pane only when its aids change, never for a title or a status message.
    @MainActor @Test func theWatchTellsOnlyChanges() {
        let watch = TypingAidsWatch()
        var told: [TypingAids] = []
        watch.observe(block: "b") { told.append($0); return true }
        var shell = BlockMeta()
        shell.foreground = "zsh"
        var agent = shell
        agent.foreground = "claude"
        watch.metaChanged("b", from: nil, to: shell)
        #expect(told == [], "raw before and after")
        watch.metaChanged("b", from: shell, to: agent)
        #expect(told == [.prose])
        var working = agent
        working.title = "✳ Fix the tests"
        working.statuses["s"] = ProgramStatus(["state": "working", "app": "claude-code", "msg": "Reading"])
        watch.metaChanged("b", from: agent, to: working)
        #expect(told == [.prose], "a title or a status of the same agent is not a change")
        watch.metaChanged("b", from: working, to: shell)
        #expect(told == [.prose, .raw])
        watch.metaChanged("other", from: shell, to: agent)
        #expect(told == [.prose, .raw])
        watch.forget(block: "b")
        #expect(watch.count(block: "b") == 0)
        // An observer that answers false is let go.
        watch.observe(block: "c") { _ in false }
        watch.metaChanged("c", from: shell, to: agent)
        #expect(watch.count(block: "c") == 0)
    }

    /// An agent found by the program in front, or by its own OSC 7501 record while `ssh` or an
    /// unnamed program is in front.
    static var agents: [Pane] { [
        Pane(what: "Claude Code", source: "captured", foreground: AgentDetectTests.claudeNative, title: "Claude Code"),
        Pane(what: "Claude Code over npm", source: "layout", foreground: AgentDetectTests.claudeNpm, title: "zsh"),
        Pane(what: "Codex", source: "captured", foreground: AgentDetectTests.codexNative, title: "⠙ api"),
        Pane(what: "Codex over npm", source: "layout", foreground: AgentDetectTests.codexNpmScript, title: "api"),
        Pane(what: "Gemini CLI", source: "layout", foreground: AgentDetectTests.geminiNpm, title: "Gemini - api"),
        Pane(what: "OpenCode", source: "captured", foreground: AgentDetectTests.opencode, title: "OpenCode"),
        Pane(what: "cursor-agent", source: "captured", foreground: AgentDetectTests.cursorAgent, title: "cursor-agent"),
        Pane(what: "aider", source: "layout", foreground: AgentDetectTests.aiderPipx, title: "zsh"),
        Pane(what: "Amp", source: "layout", foreground: AgentDetectTests.ampNpm, title: "amp"),
        Pane(what: "Claude Code on Linux, its status in", source: "layout", foreground: AgentDetectTests.claudeLinuxBare,
             title: "Sleep command test", app: "claude-code"),
        Pane(what: "Claude Code over ssh, its status in", source: "ssh", foreground: AgentDetectTests.ssh,
             title: "✳ Fix the tests", app: "claude-code"),
        Pane(what: "an unknown program with an agent's status", source: "old server", foreground: nil, title: nil, app: "codex"),
    ] }

    @Test(arguments: agents.indices)
    func agentsGetTheAids(_ i: Int) {
        let pane = Self.agents[i]
        #expect(TypingAids.for(pane.meta) == .prose, "\(pane.testDescription)")
    }

    /// Everything else types as is, also where the sidebar sees an agent by its title.
    static var others: [Pane] { [
        Pane(what: "a shell", source: "captured", foreground: AgentDetectTests.zsh, title: "me@mac:~"),
        Pane(what: "a shell after Claude Code, its title left", source: "shell without titles",
             foreground: AgentDetectTests.zsh, title: "✳ Claude Code"),
        Pane(what: "a shell after Claude Code, its record left", source: "suspended agent",
             foreground: AgentDetectTests.zsh, title: "zsh", app: "claude-code"),
        Pane(what: "a login shell", source: "layout", foreground: ["name": "bash", "argv0": "-bash"], title: "bash", app: "codex"),
        Pane(what: "vim after Claude Code, its title left", source: "editor without titles",
             foreground: ["name": "vim"], title: "✳ Claude Code"),
        Pane(what: "Claude Code over ssh, no status yet", source: "ssh", foreground: AgentDetectTests.ssh, title: "claude --resume"),
        Pane(what: "Codex over ssh by its title", source: "ssh", foreground: AgentDetectTests.ssh, title: "codex"),
        Pane(what: "Claude Code on Linux before its status", source: "layout",
             foreground: AgentDetectTests.claudeLinuxBare, title: "Claude Code"),
        Pane(what: "an editor", source: "layout", foreground: ["name": "nvim"], title: "nvim claude.md"),
        Pane(what: "a program with another program's status", source: "layout", foreground: ["name": "cargo"],
             title: "cargo build", app: "cargo"),
    ] + AgentDetectTests.lookalikes }

    @Test(arguments: others.indices)
    func everythingElseTypesAsIs(_ i: Int) {
        let pane = Self.others[i]
        #expect(TypingAids.for(pane.meta) == .raw, "\(pane.testDescription)")
    }
}
