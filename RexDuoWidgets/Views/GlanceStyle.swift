import GlanceModel
import GlanceUI
import SwiftUI
import WidgetKit

/// The colors a widget draws with, for the way the system renders it.
///
/// - **Full color**: the theme's palette (`GlanceColors`).
/// - **Accented** (tinted or clear Home Screen) and **vibrant** (Lock Screen, StandBy at
///   night): the system supplies the color, so text is primary or secondary, the count and the
///   ring's lines take the accent, and a state reads from its shape and its word, never from
///   its color. Nothing is drawn under 60% opacity.
struct GlanceStyle {
    let colors: GlanceColors
    let mode: WidgetRenderingMode
    /// Where the custom symbols are: the extension's own asset catalog.
    var symbols: Bundle = .main

    var fullColor: Bool { mode == .fullColor }

    var fg: Color { fullColor ? colors.fg : .primary }
    var secondary: Color { fullColor ? colors.secondary : .primary.opacity(0.7) }
    var tertiary: Color { fullColor ? colors.tertiary : .primary.opacity(0.6) }
    var tile: Color { fullColor ? colors.sidebar : .primary.opacity(0.12) }
    /// Behind a ring's badge.
    var ground: Color { fullColor ? colors.sidebar : .black }

    func state(_ urgency: GlanceDigest.Urgency) -> Color {
        fullColor ? colors.state(urgency) : (urgency == .quiet || urgency == .offline ? secondary : .primary)
    }

    func tint(kind: String?) -> Color { fullColor ? AgentGlyph.tint(kind: kind, colors) : .primary }

    /// The headline's color: its state's, as on the agent board and the watch ("2 need you" in
    /// the waiting color, "All done" in green). Plain when all is quiet or the snapshot is old,
    /// and secondary for "Last seen": a stale widget never shows a warning color.
    func headline(_ digest: GlanceDigest) -> Color {
        if digest.urgency == .offline { return secondary }
        if !fullColor || digest.dimmed || digest.urgency == .quiet { return fg }
        return colors.state(digest.urgency)
    }

    /// The opacity of what is last known rather than current: dimmed enough to read as older,
    /// not so much that it reads as broken.
    var dim: Double { 0.6 }

    /// The faint wash at the top of the canvas: the most urgent state's color while someone
    /// waits, fails or works, else the theme's accent. Still, and only in full color.
    func wash(_ digest: GlanceDigest) -> Color {
        (digest.glow.map(colors.state) ?? colors.accent).opacity(colors.palette.isDark ? 0.16 : 0.1)
    }

    static let markOpen = "mark.open"
}

/// Marks a ring's lines as the part that takes the system's accent.
struct Accented: ViewModifier {
    func body(content: Content) -> some View { content.widgetAccentable() }
}

/// Colors a view only when there is a color to give it: without one the view is left exactly
/// as it was, with the style it inherits.
struct GlanceAccent: ViewModifier {
    let color: Color?

    @ViewBuilder func body(content: Content) -> some View {
        if let color { content.foregroundStyle(color) } else { content }
    }
}

/// The headline: "2 need you", or "Last seen 12:04".
struct GlanceHeadline: View {
    let headline: GlanceDigest.Headline
    /// Two lines for "Last seen", where one doesn't fit (the small size).
    var stacked = false

    var body: some View {
        switch headline {
        case .text(let t):
            Text(t)
        case .lastSeen(let date):
            if stacked {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Last seen").font(GlanceType.state)
                    Text(date, style: .time)
                }
            } else {
                Text("Last seen \(Text(date, style: .time))")
            }
        }
    }
}

/// The line that dates the snapshot. Nothing while it is current.
struct GlanceAgeLine: View {
    let age: GlanceDigest.Age

    var body: some View {
        switch age {
        case .current: EmptyView()
        case .asOf(let date): Text("as of \(Text(date, style: .time))")
        case .refresh: Text(GlanceDigest.refreshText)
        }
    }
}

/// How long an agent has waited, at least: "12 minutes". It counts by itself, with no reload.
///
/// A text that updates itself asks for all the width there is, so it must sit in a frame of a
/// set width, never in `fixedSize()`: on the Home Screen that pushes the whole widget's content
/// out of sight (seen on the iOS 27.2 simulator; a view drawn outside a widget doesn't show it).
struct GlanceWaited: View {
    let since: Date

    var body: some View {
        Text(.currentDate, format: .offset(to: since, allowedFields: [.day, .hour, .minute], maxFieldCount: 1, sign: .never))
    }
}
