import GlanceModel
import GlanceUI
import SwiftUI

/// The watch app's colors and type: the snapshot's dark theme over the watch's black
/// (`WatchScreen.palette`), with the state colors of the agent board, Glide's colors for the
/// brand, and the system's text styles, which follow the person's text size.
///
/// Every text color holds 4.5:1 or more against what it sits on: black, a row's platter, and
/// the top of the brand's ground (`WatchStyleTests`).
struct WatchStyle {
    let colors: GlanceColors

    init(_ palette: GlancePalette) {
        colors = GlanceColors(palette)
    }

    var fg: Color { colors.fg }
    /// The app's secondary text is the foreground at 55%; on the watch's small type that reads
    /// under 4.5:1, so the watch's is stronger.
    var secondary: Color { colors.fg.opacity(Self.secondaryOpacity) }
    static let secondaryOpacity = 0.72
    /// A row's platter.
    var platter: Color { colors.sidebar.opacity(0.9) }
    var waiting: Color { colors.blocked }

    func state(_ urgency: GlanceDigest.Urgency) -> Color { colors.state(urgency) }
    /// A ring's glyph: a mark in the foreground, never recolored (`AgentGlyph.ink`).
    func ink(kind: String?) -> Color { AgentGlyph.ink(kind: kind, colors) }

    /// The headline's color: the state's, as on the agent board ("2 need you" in the waiting
    /// color, "3 working" in the working color, "All done" in green). Plain when all is quiet,
    /// and quiet when the snapshot is old or a machine is down: dimmed, never a warning.
    func headline(_ screen: WatchScreen) -> Color {
        if screen.urgency == .offline { return secondary }
        if screen.dimmed || screen.urgency == .quiet { return fg }
        return state(screen.urgency)
    }

    /// A machine's counts, each in its state's color: "2 waiting · 3 working · 4 idle". A machine
    /// that is down, or an old snapshot, says them all in the secondary color.
    func counts(_ machine: WatchScreen.Machine) -> Text {
        guard !machine.dimmed, let first = machine.parts.first else { return Text(machine.words).foregroundStyle(secondary) }
        func part(_ p: GlanceDigest.Part) -> Text { Text(p.text).foregroundStyle(p.urgency == .quiet ? secondary : state(p.urgency)) }
        let dot = Text(" · ").foregroundStyle(secondary)
        return machine.parts.dropFirst().reduce(part(first)) { Text("\($0)\(dot)\(part($1))") }
    }

    /// The ground behind the app's screens: Glide's deep blue at the top, fading to the watch's
    /// black by the middle. Black with the wrist down, where the screen dims and should stay dark.
    func ground(wristDown: Bool) -> LinearGradient {
        let top = wristDown ? Color.black : GlanceGlide.deep
        return LinearGradient(stops: [.init(color: top, location: 0), .init(color: .black, location: 0.55)],
                              startPoint: .top, endPoint: .bottom)
    }

    static let headline = Font.title3.bold().monospacedDigit()
    static let name = Font.headline
    static let words = Font.footnote.weight(.semibold).monospacedDigit()
    static let place = Font.caption2
    /// What is last known rather than current.
    static let dim = GlanceDigest.dimOpacity
    static let mark = "mark.open"
}

/// The ring of a waiting agent: the widgets' ring (`GlanceRing`), still. `breathes` puts the
/// soft glow around it that breathes while the agent waits (`WatchBreath`).
struct WatchRing: View {
    let row: WatchScreen.Row
    let style: WatchStyle
    let diameter: CGFloat
    var breathes = false

    var body: some View {
        GlanceRing(state: "blocked", kind: row.kind, symbol: row.symbol, tint: style.ink(kind: row.kind), color: style.waiting,
                   ground: .black, diameter: diameter)
            .modifier(WatchBreath(on: breathes && !row.lastKnown, color: style.waiting, diameter: diameter))
    }
}

/// How long an agent has waited, at least: "12 minutes". A system text that counts by itself.
struct WatchWaited: View {
    let since: Date

    var body: some View {
        Text(.currentDate, format: .offset(to: since, allowedFields: [.day, .hour, .minute], maxFieldCount: 1, sign: .never))
    }
}
