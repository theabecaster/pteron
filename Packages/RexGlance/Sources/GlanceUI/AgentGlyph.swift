import GlanceModel
import SwiftUI

/// An agent's glyph color, from its kind: the same tints as the app's sidebar and board
/// (`TabRowLabel.tint`; a test in the app holds the two together).
public enum AgentGlyph {
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
