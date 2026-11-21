import CoreGraphics
import Foundation
import Testing
@testable import RexKit

private func json(_ s: String) -> JSONObject { JSONCodec.decode(s)! }

/// Two panes side by side; the right one split top and bottom.
private var nestedLayout: JSONObject { json("""
{"rect": [0, 0, 1, 1], "split": {"split_id": "s1", "direction": "horizontal", "ratio": 0.6,
  "before": {"block_id": "A", "rect": [0, 0, 0.6, 1]},
  "after": {"rect": [0.6, 0, 0.4, 1], "split": {"split_id": "s2", "direction": "vertical", "ratio": 0.5,
    "before": {"block_id": "B", "rect": [0.6, 0, 0.4, 0.5]},
    "after": {"block_id": "C", "rect": [0.6, 0.5, 0.4, 0.5]}}}}}
""") }

struct LayoutTests {
    @Test func parsesNestedSplitsInReadingOrder() throws {
        let node = try #require(LayoutNode.parse(nestedLayout))
        #expect(node.leaves.map(\.id) == ["A", "B", "C"])
        #expect(node.leaves[2].rect == CGRect(x: 0.6, y: 0.5, width: 0.4, height: 0.5))
    }

    @Test func splitsNameTheBlocksBesideEachDivider() throws {
        let splits = try #require(LayoutNode.parse(nestedLayout)).splits
        #expect(splits.map(\.id) == ["s1", "s2"])
        #expect(splits[0].beforeFirst == "A" && splits[0].afterFirst == "B")
        #expect(splits[1].direction == "vertical")
        #expect(splits[1].beforeFirst == "B" && splits[1].afterFirst == "C")
        #expect(splits[0].ratio == 0.6)
    }

    @Test func badRectFallsBackToUnit() {
        #expect(LayoutNode.rect([1, 2]) == CGRect(x: 0, y: 0, width: 1, height: 1))
        #expect(LayoutNode.rect(nil) == CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    @Test func splitMissingASideIsNil() {
        #expect(LayoutNode.parse(json(#"{"split": {"before": {"block_id": "A"}}}"#)) == nil)
        #expect(LayoutNode.parse(nil) == nil)
    }
}

struct SessionTests {
    @Test func orderedBlockIDsAppendFloatingBlocks() {
        let w = WindowInfo(json("""
        {"window_id": "w1", "label": "api", "layers": [
          {"layer_id": "t", "kind": "tiled", "layout": {"block_id": "A"},
           "blocks": [{"block_id": "A", "creator_name": "com.superlogical.terminal"}]},
          {"layer_id": "f", "kind": "floating", "blocks": [{"block_id": "F"}]}]}
        """))
        #expect(w.orderedBlockIDs == ["A", "F"])
        #expect(w.block("A")?.isTerminal == true)
        #expect(w.block("F")?.isTerminal == false)
    }

    /// A tiled pane under three floats: the back one minimized, the middle one normal with two
    /// panes, the front one with no usable bounds.
    private var floatsWindow: WindowInfo { WindowInfo(json("""
    {"window_id": "w1", "layers": [
      {"layer_id": "t", "kind": "tiled", "bounds": [0, 0, 1, 1], "layout": {"block_id": "A", "rect": [0, 0, 1, 1]},
       "blocks": [{"block_id": "A"}]},
      {"layer_id": "m", "kind": "floating", "state": "minimized", "bounds": [0.1, 0.1, 0.3, 0.3],
       "layout": {"block_id": "M", "rect": [0.1, 0.1, 0.3, 0.3]}, "blocks": [{"block_id": "M"}]},
      {"layer_id": "f", "kind": "floating", "bounds": [0.3, 0.2, 0.5, 0.6],
       "layout": {"rect": [0.3, 0.2, 0.5, 0.6], "split": {"split_id": "s", "direction": "vertical", "ratio": 0.5,
         "before": {"block_id": "F1", "rect": [0.3, 0.2, 0.5, 0.3]}, "after": {"block_id": "F2", "rect": [0.3, 0.5, 0.5, 0.3]}}},
       "blocks": [{"block_id": "F1"}, {"block_id": "F2"}]},
      {"layer_id": "x", "kind": "floating", "bounds": [0.5, 0.5],
       "layout": {"block_id": "X", "rect": [0.5, 0.5, 0.2, 0.2]}, "blocks": [{"block_id": "X"}]}]}
    """)) }

    @Test func floatingLayersSplitIntoDrawnAndMinimized() {
        let w = floatsWindow
        #expect(w.tiled?.id == "t")
        #expect(w.floating.map(\.id) == ["m", "f", "x"])
        #expect(w.visibleFloating.map(\.id) == ["f"], "minimized and unplaced layers aren't drawn")
        #expect(w.minimizedFloating.map(\.id) == ["m"])
        #expect(w.layers[2].isFloating && !w.layers[0].isFloating)
        #expect(!w.layers[3].hasBounds)
        #expect(w.isMinimized("M") && !w.isMinimized("F1") && !w.isMinimized("A"))
        #expect(w.isHidden("M") && w.isHidden("X") && !w.isHidden("F2") && !w.isHidden("A"))
        #expect(w.floatingLayer(of: "F2")?.id == "f")
        #expect(w.floatingLayer(of: "A") == nil)
    }

    @Test func pageBlockIDsLeaveOutMinimizedAndPutTheFrontFloatFirst() {
        #expect(floatsWindow.pageBlockIDs == ["A", "F1", "F2"])
        #expect(floatsWindow.orderedBlockIDs == ["A", "M", "F1", "F2", "X"], "orderedBlockIDs doesn't change")
        // Two normal floats: front first.
        let w = WindowInfo(json("""
        {"window_id": "w", "layers": [
          {"layer_id": "t", "kind": "tiled", "layout": {"block_id": "A", "rect": [0, 0, 1, 1]}, "blocks": [{"block_id": "A"}]},
          {"layer_id": "back", "kind": "floating", "bounds": [0, 0, 0.5, 0.5], "layout": {"block_id": "B", "rect": [0, 0, 0.5, 0.5]}, "blocks": [{"block_id": "B"}]},
          {"layer_id": "front", "kind": "floating", "bounds": [0.5, 0.5, 0.5, 0.5], "layout": {"block_id": "C", "rect": [0.5, 0.5, 0.5, 0.5]}, "blocks": [{"block_id": "C"}]}]}
        """))
        #expect(w.pageBlockIDs == ["A", "C", "B"])
        // Split in two for a narrow window, where the floats aren't pages: the same order.
        #expect(w.tiledPageIDs == ["A"] && w.floatPageIDs == ["C", "B"])
        #expect(floatsWindow.tiledPageIDs + floatsWindow.floatPageIDs == floatsWindow.pageBlockIDs)
        // No floating layer: the same as orderedBlockIDs.
        let plain = WindowInfo(json(#"{"window_id": "p", "layers": [{"layer_id": "t", "kind": "tiled", "layout": {"rect": [0, 0, 1, 1], "split": {"direction": "horizontal", "ratio": 0.5, "before": {"block_id": "A", "rect": [0, 0, 0.5, 1]}, "after": {"block_id": "B", "rect": [0.5, 0, 0.5, 1]}}}, "blocks": [{"block_id": "A"}, {"block_id": "B"}]}]}"#))
        #expect(plain.pageBlockIDs == plain.orderedBlockIDs)
        #expect(plain.tiledPageIDs == ["A", "B"] && plain.floatPageIDs.isEmpty)
        #expect(plain.floating.isEmpty && plain.visibleFloating.isEmpty)
    }

    @Test func aLayerWithoutAnIDKeepsOneWhenTheOrderChanges() {
        let a = #"{"kind": "floating", "layer_id": null, "bounds": [0, 0, 0.5, 0.5], "layout": {"block_id": "B", "rect": [0, 0, 0.5, 0.5]}, "blocks": [{"block_id": "B"}]}"#
        let b = #"{"kind": "floating", "bounds": [0.5, 0.5, 0.5, 0.5], "layout": {"block_id": "C", "rect": [0.5, 0.5, 0.5, 0.5]}, "blocks": [{"block_id": "C"}]}"#
        let tiled = #"{"kind": "tiled", "layout": {"block_id": "A", "rect": [0, 0, 1, 1]}, "blocks": [{"block_id": "A"}]}"#
        let one = WindowInfo(json(#"{"window_id": "w", "layers": [\#(tiled), \#(a), \#(b)]}"#))
        let two = WindowInfo(json(#"{"window_id": "w", "layers": [\#(tiled), \#(b), \#(a)]}"#))
        #expect(one.floating.map(\.id) == ["layer:B", "layer:C"])
        #expect(two.floating.map(\.id) == ["layer:C", "layer:B"])
        #expect(LayerInfo(json(#"{"kind": "floating"}"#)).id == "layer:empty")
    }

    @Test func anUnknownKindFloatsAndAnUnknownStateIsNormal() {
        let w = WindowInfo(json("""
        {"window_id": "w", "layers": [
          {"layer_id": "t", "kind": "tiled", "layout": {"block_id": "A", "rect": [0, 0, 1, 1]}, "blocks": [{"block_id": "A"}]},
          {"layer_id": "p", "kind": "popover", "state": "shaded", "bounds": [0.2, 0.2, 0.4, 0.4],
           "layout": {"block_id": "P", "rect": [0.2, 0.2, 0.4, 0.4]}, "blocks": [{"block_id": "P"}], "future": 1}]}
        """))
        #expect(w.visibleFloating.map(\.id) == ["p"])
        #expect(w.pageBlockIDs == ["A", "P"])
    }

    @Test func noLayersMeansNoFloats() {
        let w = WindowInfo(json(#"{"window_id": "w"}"#))
        #expect(w.tiled == nil && w.floating.isEmpty && w.pageBlockIDs.isEmpty)
    }

    @Test func activeWindowFallsBackToFirst() {
        let v = SessionView(json(#"{"revision": 3, "session_id": "s", "active_window_id": "gone", "windows": [{"window_id": "w1"}, {"window_id": "w2", "layers": [{"blocks": [{"block_id": "B"}]}]}]}"#))
        #expect(v.revision == 3)
        #expect(v.activeWindow?.id == "w1")
        #expect(v.windowContaining(block: "B")?.id == "w2")
        #expect(v.window(nil) == nil)
    }
}

struct StatusTests {
    private func status(_ state: String, app: String? = nil) -> ProgramStatus {
        var o: JSONObject = ["state": state]
        if let app { o["app"] = app }
        return ProgramStatus(o)
    }

    @Test func topStatusIsTheMostUrgent() {
        var m = BlockMeta()
        m.statuses = ["a": status("done"), "b": status("blocked"), "c": status("working"), "d": status("error")]
        #expect(m.topStatus?.state == "blocked")
        m.statuses["b"] = nil
        #expect(m.topStatus?.state == "error")
        m.statuses["d"] = nil
        #expect(m.topStatus?.state == "working")
    }

    @Test func effectiveAppWins() {
        let s = ProgramStatus(["state": "working", "app": "node", "effective_app": "claude", "kind": "question"])
        #expect(s.app == "claude")
        #expect(s.waitingFor == "question")
    }

    @Test func agentKindFromStatusThenProcessThenTitle() {
        var m = BlockMeta()
        m.title = "Gemini - api"
        #expect(m.agentKind == .gemini)
        m.foreground = "codex"
        #expect(m.agentKind == .codex)
        m.statuses = ["x": status("working", app: "claude")]
        #expect(m.agentKind == .claude)
    }

    @Test(arguments: [
        ("claude", AgentKind.claude), ("claude-code", .claude), ("codex", .codex), ("gemini", .gemini),
        ("gemini.js", .gemini), ("gemini-cli", .gemini), ("opencode", .opencode), ("amp", .amp),
        ("aider", .aider), ("cursor-agent", .cursor),
    ])
    func programsByTheirWholeName(name: String, kind: AgentKind) {
        #expect(AgentKind.fromProgram(name) == kind)
    }

    @Test(arguments: [
        ("claude-code", AgentKind.claude), ("Claude Code", .claude), ("codex", .codex), ("gemini-cli", .gemini),
        ("opencode", .opencode), ("cursor-agent", .cursor),
    ])
    func appsAsAgentsNameThemselves(app: String, kind: AgentKind) {
        #expect(AgentKind.fromApp(app) == kind)
    }

    @Test(arguments: [
        ("Claude Code", AgentKind.claude), ("Claude Code — fix tests", .claude), ("✳ Claude Code", .claude),
        ("✶ Fix the tests", .claude), ("⠋ Claude Code", .claude), ("OpenCode", .opencode), ("Gemini - api", .gemini),
        ("Gemini CLI", .gemini),
    ])
    func titlesInTheAgentsOwnFormats(title: String, kind: AgentKind) {
        #expect(AgentKind.fromTitle(title) == kind)
    }

    /// A shell titles the pane with the command it runs; over ssh that title is all there is.
    @Test(arguments: [
        ("claude", AgentKind.claude), ("claude --resume", .claude), ("codex", .codex), ("codex resume --last", .codex),
        ("amp --resume", .amp), ("aider --model sonnet", .aider), ("aider", .aider), ("gemini", .gemini),
        ("opencode", .opencode), ("cursor-agent", .cursor),
    ])
    func commandLinesThatRunAnAgent(title: String, kind: AgentKind) {
        #expect(AgentKind.fromTitle(title) == kind)
    }

    @Test(arguments: ["sample", "campaign", "cursor", "zsh", "", "claude-notes", "codex-fork", "amp-config", "index.js"])
    func programsThatOnlyContainAnAgentsName(name: String) {
        #expect(AgentKind.fromProgram(name) == nil)
    }

    @Test(arguments: [
        "theabecaster@mac:~/claude-notes", "~/code/codex-fork", "/private/tmp/claude-501/scratchpad", "vim claude.md",
        "clear; cursor-agent", "Sleep command test", "⠙ theabecaster", "⠙ build tools", "notes about Claude Code",
        "vim CLAUDE.md", "vim claude.md", "cat codex.log", "Codex review notes", "Claude's plan", "claude-notes",
        "~/.local/bin/claude", "/usr/local/bin/codex --resume", "",
    ])
    func titlesThatAreNotAnAgentsOwn(title: String) {
        #expect(AgentKind.fromTitle(title) == nil)
    }
}

struct AddressTests {
    @Test(arguments: [
        ("https://mac.tail.ts.net", "wss://mac.tail.ts.net"),
        ("  https://mac.tail.ts.net/some/path?x=1 ", "wss://mac.tail.ts.net"),
        ("http://localhost:8080", "ws://localhost:8080"),
        ("wss://host", "wss://host"),
    ])
    func webSocketBase(address: String, expected: String) {
        #expect(RexControl.webSocketBase(for: address)?.absoluteString == expected)
    }

    @Test(arguments: ["", "mac.tail.ts.net", "ftp://host", "https://", "not a url"])
    func rejectsBadAddresses(address: String) {
        #expect(RexControl.webSocketBase(for: address) == nil)
    }
}
