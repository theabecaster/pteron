import Foundation
import GlanceModel
import SwiftUI

/// An agent's glyph: its maker's mark where it has one, else an SF Symbol, and its color.
///
/// The marks are custom symbols (`agent.<kind>`) in `Brand/agents/AgentMarks.xcassets`, which
/// every target that draws an agent compiles into its own bundle (project.yml): the app, the
/// widgets, the watch app and its complications. A custom symbol is an `Image` that sizes with
/// the font and `imageScale`, sits on the text's baseline and takes `foregroundStyle` and the
/// widgets' accented and vibrant modes like an SF Symbol, so a caller draws a mark where it drew
/// a symbol and nothing moves. The app's and the watch's tests check that each target's bundle
/// has every mark in `marked`. Each mark identifies its own agent only (Brand/agents/README.md).
public enum AgentGlyph {
    /// The kinds (`AgentKind`'s raw values) that have a mark in the catalog. Amp has none: its
    /// maker publishes only a wordmark, so it keeps its SF Symbol.
    public static let marked: Set<String> = ["claude", "codex", "gemini", "opencode", "aider", "cursor"]

    private static let prefix = "agent."

    /// The mark's asset name for a kind, or nil when the kind has none.
    public static func mark(kind: String?) -> String? {
        guard let kind, marked.contains(kind) else { return nil }
        return prefix + kind
    }

    /// Whether a glyph name is one of the marks rather than an SF Symbol.
    public static func isMark(_ name: String) -> Bool {
        name.hasPrefix(prefix) && marked.contains(String(name.dropFirst(prefix.count)))
    }

    /// The name to draw for a kind: its mark, else `symbol` (the SF Symbol a snapshot carries, so
    /// a kind this build doesn't know still draws what the writer chose).
    public static func name(kind: String?, symbol: String) -> String {
        mark(kind: kind) ?? symbol
    }

    /// A glyph by name: a mark from `bundle`, or an SF Symbol.
    public static func image(_ name: String, bundle: Bundle = .main) -> Image {
        isMark(name) ? Image(name, bundle: bundle) : Image(systemName: name)
    }

    /// A kind's glyph: its mark, else `symbol`.
    public static func image(kind: String?, symbol: String, bundle: Bundle = .main) -> Image {
        image(name(kind: kind, symbol: symbol), bundle: bundle)
    }

    public static func tint(kind: String?, _ colors: GlanceColors) -> Color {
        switch kind {
        case "claude": Color(glanceHex: "#d97757")
        case "codex": colors.fg
        case "gemini": Color(glanceHex: colors.palette.ansi(4))
        case .some: Color(glanceHex: colors.palette.ansi(5))
        case nil: colors.secondary
        }
    }
}

/// An agent's glyph as a view: `AgentGlyph.image(kind:symbol:bundle:)`. It takes `.font`,
/// `.imageScale`, `.foregroundStyle` and the widgets' modifiers as an SF Symbol does.
public struct AgentGlyphMark: View {
    let kind: String?
    let symbol: String
    let bundle: Bundle

    public init(kind: String?, symbol: String, bundle: Bundle = .main) {
        self.kind = kind
        self.symbol = symbol
        self.bundle = bundle
    }

    public var body: some View { AgentGlyph.image(kind: kind, symbol: symbol, bundle: bundle) }
}
