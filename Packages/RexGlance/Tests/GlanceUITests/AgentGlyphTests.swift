import Testing
@testable import GlanceUI

/// Which glyph an agent gets: its mark by kind, else the snapshot's SF Symbol. Whether each
/// target's bundle has the marks is checked by the app's and the watch's tests, which run in
/// those bundles.
@Suite struct AgentGlyphTests {
    @Test func aKindWithAMarkDrawsItsMark() {
        for kind in AgentGlyph.marked {
            #expect(AgentGlyph.mark(kind: kind) == "agent.\(kind)")
            #expect(AgentGlyph.name(kind: kind, symbol: "cpu") == "agent.\(kind)")
            #expect(AgentGlyph.isMark("agent.\(kind)"))
        }
    }

    @Test func anythingElseDrawsTheSymbol() {
        // Another program, a kind from a newer app, or no kind: the symbol the writer chose.
        #expect(AgentGlyph.mark(kind: nil) == nil)
        #expect(AgentGlyph.name(kind: nil, symbol: "terminal") == "terminal")
        #expect(AgentGlyph.name(kind: "a-future-agent", symbol: "cpu") == "cpu")
        #expect(AgentGlyph.name(kind: "", symbol: "cpu") == "cpu")
        // SF Symbols are never taken for marks, nor is a mark of a kind the catalog lacks.
        for symbol in ["asterisk", "hexagon", "sparkle", "cpu", "terminal", "checkmark", "agent.a-future-agent", "agent."] {
            #expect(!AgentGlyph.isMark(symbol), "\(symbol)")
        }
    }
}
