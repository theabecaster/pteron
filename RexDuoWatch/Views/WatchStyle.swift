import GlanceModel
import GlanceUI
import SwiftUI

/// The watch app's colors and type: the snapshot's dark theme over the watch's black
/// (`WatchScreen.palette`), with the state colors of the agent board, and the system's text
/// styles, which follow the person's text size.
struct WatchStyle {
    let colors: GlanceColors

    init(_ palette: GlancePalette) {
        colors = GlanceColors(palette)
    }

    var fg: Color { colors.fg }
    var secondary: Color { colors.secondary }
    /// A row's platter.
    var platter: Color { colors.sidebar.opacity(0.9) }
    var waiting: Color { colors.blocked }

    func state(_ urgency: GlanceDigest.Urgency) -> Color { colors.state(urgency) }
    func tint(kind: String?) -> Color { AgentGlyph.tint(kind: kind, colors) }

    static let headline = Font.title3.bold().monospacedDigit()
    static let name = Font.headline
    static let words = Font.footnote.weight(.semibold).monospacedDigit()
    static let place = Font.caption2
    /// What is last known rather than current.
    static let dim = GlanceDigest.dimOpacity
    static let mark = "mark.open"
}

/// The ring of a waiting agent, still: the widgets' ring (`GlanceRing`).
struct WatchRing: View {
    let row: WatchScreen.Row
    let style: WatchStyle
    let diameter: CGFloat

    var body: some View {
        GlanceRing(state: "blocked", symbol: row.symbol, tint: style.tint(kind: row.kind), color: style.waiting,
                   ground: .black, diameter: diameter)
    }
}

/// How long an agent has waited, at least: "12 minutes". A system text that counts by itself.
struct WatchWaited: View {
    let since: Date

    var body: some View {
        Text(.currentDate, format: .offset(to: since, allowedFields: [.day, .hour, .minute], maxFieldCount: 1, sign: .never))
    }
}
