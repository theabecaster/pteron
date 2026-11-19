import Foundation
import Testing
import RexKit
@testable import RexDuo

/// Which panes run an agent, on what panes really report. "captured" rows were read from a pane
/// with the agent running (Rex 0.1.0-preview.21, macOS, 2026-11-19: `terminal.title`,
/// `terminal.process`, `terminal.program_status`); "layout" rows follow the program's published
/// install layout, for agents not installed where this was checked; "ssh" rows are a local `ssh`
/// whose remote shell titles the pane with the command it runs.
struct AgentDetectTests {
    struct Pane: CustomTestStringConvertible {
        var what: String
        var source: String
        var foreground: JSONObject?
        var title: String?
        var app: String?
        /// A pane that only mentions an agent: the old rule's false find, dropped on purpose.
        var lookalike = false
        var testDescription: String { "\(what) (\(source))" }

        var meta: BlockMeta {
            var m = BlockMeta()
            m.foreground = foreground.map(ServerConnection.processLabel)
            m.title = title
            if let app { m.statuses["s"] = ProgramStatus(["state": "working", "app": app]) }
            return m
        }
    }

    // MARK: Fixtures

    static var claudeNative: JSONObject { [
        "name": "2.1.329", "path": "/Users/me/.local/share/claude/versions/2.1.329",
        "invoked_path": "/Users/me/.local/bin/claude", "argv0": "/Users/me/.local/bin/claude",
    ] }
    /// The same binary as Rex on Linux may report it: no invoked path, no argv0.
    static var claudeLinuxBare: JSONObject { ["name": "2.1.329", "path": "/home/me/.local/share/claude/versions/2.1.329"] }
    static var codexNative: JSONObject { [
        "name": "codex",
        "path": "/Users/me/.nvm/versions/node/v24.1.0/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex",
        "invoked_path": "/Users/me/.nvm/versions/node/v24.1.0/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex",
    ] }
    static var codexNpmScript: JSONObject { ["name": "node", "script": "/opt/homebrew/lib/node_modules/@openai/codex/bin/codex.js"] }
    static var opencode: JSONObject { [
        "name": "opencode", "path": "/Users/me/.opencode/bin/opencode",
        "invoked_path": "/Users/me/.opencode/bin/opencode", "argv0": "opencode",
    ] }
    static var cursorAgent: JSONObject { [
        "name": "node", "script": "/Users/me/.local/share/cursor-agent/versions/2025.10.21-224d294/index.js",
        "invoked_path": "/Users/me/.local/share/cursor-agent/versions/2025.10.21-224d294/node",
    ] }
    static var claudeNpm: JSONObject { ["name": "node", "script": "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js"] }
    static let npx = "/Users/me/.npm/_npx/6a9f3c1b2d4e5f60/node_modules"
    static var claudeNpx: JSONObject { ["name": "node", "script": "\(npx)/@anthropic-ai/claude-code/cli.js"] }
    static var geminiNpx: JSONObject { ["name": "node", "script": "\(npx)/@google/gemini-cli/dist/index.js"] }
    static var codexNpx: JSONObject { ["name": "node", "script": "\(npx)/@openai/codex/bin/codex.js"] }
    static var geminiNpm: JSONObject { ["name": "node", "script": "/opt/homebrew/lib/node_modules/@google/gemini-cli/dist/index.js"] }
    static var geminiBundle: JSONObject { ["name": "node", "script": "/opt/homebrew/lib/node_modules/@google/gemini-cli/bundle/gemini.js"] }
    static var aiderPip: JSONObject { ["name": "python3.12", "script": "/Users/me/.local/bin/aider"] }
    static var aiderPipx: JSONObject { ["name": "python3.12", "script": "/Users/me/.local/pipx/venvs/aider-chat/bin/aider"] }
    static var aiderModule: JSONObject { [
        "name": "python3.12", "script": "/Users/me/.venv/lib/python3.12/site-packages/aider/__main__.py",
    ] }
    static var aiderChat: JSONObject { ["name": "aider-chat", "path": "/Users/me/.local/bin/aider-chat"] }
    static var ampNpm: JSONObject { ["name": "node", "script": "/opt/homebrew/lib/node_modules/@sourcegraph/amp/dist/main.js"] }
    static var zsh: JSONObject { ["name": "zsh", "path": "/bin/zsh", "invoked_path": "/bin/zsh", "argv0": "-zsh"] }
    static var ssh: JSONObject { ["name": "ssh", "path": "/usr/bin/ssh", "invoked_path": "/usr/bin/ssh", "argv0": "ssh"] }

    /// Every real agent pane, and what it is.
    static var agents: [(Pane, AgentKind)] { [
        (Pane(what: "Claude Code starting", source: "captured", foreground: claudeNative, title: "Claude Code"), .claude),
        (Pane(what: "Claude Code on a task", source: "captured", foreground: claudeNative, title: "Sleep command test",
              app: "claude-code"), .claude),
        // Sampled every 0.3 s through a working turn: "Claude Code", then the task's name, no spinner.
        (Pane(what: "Claude Code working", source: "captured", foreground: claudeNative, title: "Sleep 10 command"), .claude),
        (Pane(what: "Claude Code before its status", source: "captured", foreground: claudeNative,
              title: "cd ~ && ~/.local/bin/claude "), .claude),
        (Pane(what: "Claude Code over npm, working", source: "layout", foreground: claudeNpm, title: "✳ Claude Code"), .claude),
        (Pane(what: "Claude Code over npx", source: "layout", foreground: claudeNpx, title: "zsh"), .claude),
        (Pane(what: "Claude Code with a braille spinner", source: "layout", foreground: ssh, title: "⠋ Claude Code"), .claude),
        (Pane(what: "Claude Code on Linux, its status in", source: "layout", foreground: claudeLinuxBare,
              title: "Sleep command test", app: "claude-code"), .claude),
        (Pane(what: "Claude Code over ssh, working", source: "ssh", foreground: ssh, title: "✳ Fix the tests"), .claude),
        (Pane(what: "Claude Code over ssh, starting", source: "ssh", foreground: ssh, title: "claude"), .claude),
        (Pane(what: "Claude Code over ssh, resumed", source: "ssh", foreground: ssh, title: "claude --resume"), .claude),
        (Pane(what: "Codex working", source: "captured", foreground: codexNative, title: "⠙ theabecaster"), .codex),
        (Pane(what: "Codex on a task", source: "captured", foreground: codexNative, title: "Reply with zz | theabecaster",
              app: "codex"), .codex),
        (Pane(what: "Codex over npm", source: "layout", foreground: codexNpmScript, title: "⠙ api"), .codex),
        (Pane(what: "Codex over npx", source: "layout", foreground: codexNpx, title: "api"), .codex),
        (Pane(what: "Codex over ssh, before its status", source: "ssh", foreground: ssh, title: "codex"), .codex),
        (Pane(what: "OpenCode", source: "captured", foreground: opencode, title: "OpenCode"), .opencode),
        (Pane(what: "OpenCode over ssh", source: "ssh", foreground: ssh, title: "OpenCode"), .opencode),
        (Pane(what: "cursor-agent", source: "captured", foreground: cursorAgent, title: "clear; cursor-agent"), .cursor),
        (Pane(what: "Gemini CLI", source: "layout", foreground: geminiNpm, title: "Gemini - api"), .gemini),
        (Pane(what: "Gemini CLI bundle", source: "layout", foreground: geminiBundle, title: "zsh"), .gemini),
        (Pane(what: "Gemini CLI over npx", source: "layout", foreground: geminiNpx, title: "zsh"), .gemini),
        (Pane(what: "Gemini CLI over ssh", source: "ssh", foreground: ssh, title: "gemini"), .gemini),
        (Pane(what: "aider", source: "layout", foreground: aiderPip, title: "aider"), .aider),
        (Pane(what: "aider from pipx (aider-chat)", source: "layout", foreground: aiderPipx, title: "zsh"), .aider),
        (Pane(what: "aider-chat", source: "layout", foreground: aiderChat, title: "zsh"), .aider),
        (Pane(what: "python -m aider", source: "layout", foreground: aiderModule, title: "python -m aider"), .aider),
        (Pane(what: "aider over ssh", source: "ssh", foreground: ssh, title: "aider --model sonnet"), .aider),
        (Pane(what: "Amp", source: "layout", foreground: ampNpm, title: "amp"), .amp),
        (Pane(what: "Amp over ssh", source: "ssh", foreground: ssh, title: "amp --resume"), .amp),
    ] }

    /// Agents neither rule finds, kept so a change that starts finding them is noticed.
    static var missed: [Pane] { [
        // Linux may report Claude's binary by its version alone: found once its OSC 7501 record
        // arrives (above), and by its "Claude Code" title while starting.
        Pane(what: "Claude Code on Linux before its status", source: "layout", foreground: claudeLinuxBare,
             title: "Sleep command test"),
    ] }

    /// Shells and programs that only mention an agent: the old rule took every one for an agent.
    static var lookalikes: [Pane] { [
        Pane(what: "shell in ~/claude-notes", source: "shell title", foreground: zsh, title: "me@mac:~/claude-notes"),
        Pane(what: "shell in a codex fork", source: "shell title", foreground: zsh, title: "~/code/codex-fork"),
        Pane(what: "shell under a claude temp dir", source: "captured", foreground: zsh,
             title: "theabecaster@Abrahams-MacBook-Pro:/private/tmp/claude-501/-Users-theabecaster-rexduo/x/lane-c"),
        Pane(what: "editing a note", source: "command title", foreground: ["name": "nvim"], title: "nvim claude.md"),
        Pane(what: "editing CLAUDE.md over ssh", source: "ssh", foreground: ssh, title: "vim CLAUDE.md"),
        Pane(what: "a project named after an agent", source: "layout",
             foreground: ["name": "node", "script": "/Users/me/code/claude-notes/index.js"], title: "node ~/code/claude-notes/index.js"),
        Pane(what: "gemini notes", source: "shell title", foreground: zsh, title: "me@mac:~/gemini-notes"),
        Pane(what: "aider config", source: "command title", foreground: ["name": "vim"], title: "vim .aider.conf.yml"),
        Pane(what: "a remote shell in ~/claude-notes", source: "ssh", foreground: ssh, title: "me@box:~/claude-notes"),
    ].map { var p = $0; p.lookalike = true; return p } }

    static var everyPane: [Pane] { agents.map(\.0) + missed + lookalikes }

    /// The rule before this change, to show no agent it found is lost.
    static func oldKind(_ m: BlockMeta) -> AgentKind? {
        func detect(_ s: String) -> AgentKind? {
            let l = s.lowercased()
            if l.contains("claude") { return .claude }
            if l.contains("codex") { return .codex }
            if l.contains("gemini") { return .gemini }
            if l.contains("opencode") { return .opencode }
            if l == "amp" || l.hasPrefix("amp ") { return .amp }
            if l.contains("aider") { return .aider }
            if l.contains("cursor-agent") { return .cursor }
            return nil
        }
        if let app = m.topStatus?.app, let k = detect(app) { return k }
        if let fg = m.foreground, let k = detect(fg) { return k }
        if let t = m.title, let k = detect(t) { return k }
        return nil
    }

    // MARK: Tests

    @Test(arguments: agents.indices)
    func everyRealAgentIsFound(_ i: Int) {
        let (pane, kind) = Self.agents[i]
        #expect(pane.meta.agentKind == kind, "\(pane.testDescription)")
    }

    /// Every fixture the old rule took for an agent finds the same agent now, except the
    /// lookalikes, which are dropped on purpose.
    @Test(arguments: everyPane.indices)
    func nothingTheOldRuleFoundIsMissed(_ i: Int) {
        let pane = Self.everyPane[i]
        guard !pane.lookalike, let old = Self.oldKind(pane.meta) else { return }
        #expect(pane.meta.agentKind == old, "\(pane.testDescription)")
    }

    @Test(arguments: missed.indices)
    func knownMissesStayDocumented(_ i: Int) {
        let pane = Self.missed[i]
        #expect(Self.oldKind(pane.meta) == nil && pane.meta.agentKind == nil,
                "\(pane.testDescription) is found now: move it to `agents`")
    }

    @Test(arguments: lookalikes.indices)
    func shellsAndFilesThatMentionAnAgentAreNot(_ i: Int) {
        let pane = Self.lookalikes[i]
        #expect(Self.oldKind(pane.meta) != nil, "the old rule took \(pane.what) for an agent")
        #expect(pane.meta.agentKind == nil, "\(pane.testDescription)")
    }

    @Test func genericEntryScriptsAreNamedByTheirPackage() {
        #expect(ServerConnection.processLabel(Self.cursorAgent) == "cursor-agent")
        #expect(ServerConnection.processLabel(Self.claudeNpm) == "claude-code")
        #expect(ServerConnection.processLabel(Self.claudeNpx) == "claude-code")
        #expect(ServerConnection.processLabel(Self.geminiNpm) == "gemini-cli")
        #expect(ServerConnection.processLabel(Self.geminiNpx) == "gemini-cli")
        #expect(ServerConnection.processLabel(Self.codexNpx) == "codex.js")
        #expect(ServerConnection.processLabel(Self.ampNpm) == "amp")
        #expect(ServerConnection.processLabel(Self.aiderModule) == "aider")
        #expect(ServerConnection.processLabel(Self.claudeNative) == "claude")
        #expect(ServerConnection.processLabel(Self.claudeLinuxBare) == "2.1.329")
        #expect(ServerConnection.processLabel(["name": "node", "script": "/srv/app/server.js"]) == "server.js")
        #expect(ServerConnection.processLabel(["name": "node", "script": "index.js"]) == "index.js")
        #expect(ServerConnection.processLabel(["name": "python3", "script": "/srv/tool/__main__.py"]) == "tool")
    }
}
