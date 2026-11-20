import SwiftUI

/// The agent's glyph in a ring that shows its state, with a badge that says it without color:
/// the agent board's ring (`BoardRing`), with the same proportions and no motion. Waiting, done
/// and error are a full ring with a raised hand, a check or an x; working is an arc.
///
/// `strokes` is applied to the ring's lines only and `glyph` builds the agent's symbol, so a
/// widget can mark the lines as the part that takes the system's accent and say how the symbol
/// is drawn when tinted (WidgetKit modifiers, which this package doesn't import).
public struct GlanceRing<Strokes: ViewModifier, Glyph: View>: View {
    let state: String?
    let symbol: String
    let tint: Color
    let color: Color
    /// The color behind the ring, for the badge's rim.
    let ground: Color
    let diameter: CGFloat
    let strokes: Strokes
    let glyph: (Image) -> Glyph

    public init(state: String?, symbol: String, tint: Color, color: Color, ground: Color, diameter: CGFloat, strokes: Strokes,
                @ViewBuilder glyph: @escaping (Image) -> Glyph) {
        self.state = state
        self.symbol = symbol
        self.tint = tint
        self.color = color
        self.ground = ground
        self.diameter = diameter
        self.strokes = strokes
        self.glyph = glyph
    }

    private var line: CGFloat { max(3, diameter * 0.075) }

    public var body: some View {
        ZStack {
            Group {
                Circle().stroke(color.opacity(0.22), lineWidth: line)
                arc
            }
            .modifier(strokes)
            glyph(Image(systemName: symbol))
                .font(.system(size: diameter * 0.38, weight: .bold))
                .foregroundStyle(tint)
        }
        .padding(line / 2)
        .frame(width: diameter, height: diameter)
        .overlay(alignment: .bottomTrailing) { badge }
        .accessibilityHidden(true)
    }

    @ViewBuilder private var arc: some View {
        switch state {
        case "working":
            Circle().trim(from: 0, to: 0.28)
                .stroke(color, style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
        case "blocked", "done", "error":
            Circle().stroke(color, lineWidth: line)
        default:
            EmptyView()
        }
    }

    /// The badge's symbol for a state. Nil for working and idle.

    @ViewBuilder private var badge: some View {
        if let name = GlanceRingBadge.symbol(state) {
            let d = max(15, diameter * 0.36)
            Image(systemName: name)
                .font(.system(size: d * 0.52, weight: .heavy))
                .foregroundStyle(ground)
                .frame(width: d, height: d)
                .background(Circle().fill(color))
                .overlay(Circle().strokeBorder(ground, lineWidth: max(1.5, d * 0.1)))
                .offset(x: d * 0.18, y: d * 0.18)
        }
    }
}

public extension GlanceRing where Strokes == EmptyModifier, Glyph == Image {
    init(state: String?, symbol: String, tint: Color, color: Color, ground: Color, diameter: CGFloat) {
        self.init(state: state, symbol: symbol, tint: tint, color: color, ground: ground, diameter: diameter,
                  strokes: EmptyModifier()) { $0 }
    }
}

/// The badge that says a state without color.
public enum GlanceRingBadge {
    /// The badge's symbol for a state. Nil for working and idle.
    public static func symbol(_ state: String?) -> String? {
        switch state {
        case "blocked": "hand.raised.fill"
        case "done": "checkmark"
        case "error": "xmark"
        default: nil
        }
    }
}
