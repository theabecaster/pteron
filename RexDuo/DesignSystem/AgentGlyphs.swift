import GlanceUI
import RexKit
import SwiftUI

/// The app's way to an agent's glyph: its maker's mark where the catalog has one, else
/// `AgentKind.symbol`, else `fallback` for a pane with no agent (`AgentGlyph` in GlanceUI, which
/// the widgets and the watch draw with too). The marks are in the app's own bundle.
extension AgentGlyph {
    static func name(agent: AgentKind?, fallback: String = "terminal") -> String {
        name(kind: agent?.rawValue, symbol: agent?.symbol ?? fallback)
    }

    static func image(agent: AgentKind?, fallback: String = "terminal") -> Image {
        image(name(agent: agent, fallback: fallback))
    }
}

extension Label where Title == Text, Icon == Image {
    /// A row's label whose icon is a glyph name: an agent's mark or an SF Symbol.
    init(_ title: String, glyph: String) {
        self.init { Text(title) } icon: { AgentGlyph.image(glyph) }
    }
}
