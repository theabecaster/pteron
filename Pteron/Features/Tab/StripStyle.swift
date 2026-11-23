import SwiftUI

/// How the tab strip's chips and the session popover look: sizes, type and the colors they take
/// from the theme's chrome. The strip says where each part sits (`StripLayout`); this says how a
/// part fills its frame. The Mac app's horizontal tabs in small: the active tab a quiet filled
/// capsule, the others plain text, no shadows, and no motion of their own but the pane icons'
/// stack when the active pane changes.
enum StripStyle {
    // MARK: Chips

    /// The selected capsule's height, at most: the chip's frame less `capsuleInset` above and
    /// below in a short (34 pt) bar.
    static let capsuleHeight: CGFloat = 30
    /// The least room the capsule keeps above and below in the bar.
    static let capsuleInset: CGFloat = 4
    /// Inside a chip, before its first icon and after its status.
    static let chipPadding: CGFloat = 10
    /// Between a chip's icons, title and status.
    static let chipSpacing: CGFloat = 5
    /// A pane icon: the sidebar's tile (`TabRowLabel.tile`) in small.
    static let iconSize: CGFloat = 15
    static let iconGlyph: CGFloat = 8
    /// A chip's pane icons stack as a deck (`PaneStack`). Each icon behind reaches this much
    /// further right than the one before it, its top this much higher: a stack of three is
    /// 27 pt wide, where a row of three was 51 pt.
    static let stackStep: CGFloat = 6
    static let stackRise: CGFloat = 2
    /// The icons' scale and opacity, front first: the ones behind are smaller and dimmer.
    static let stackScales: [CGFloat] = [1, 0.82, 0.68]
    static let stackOpacities: [Double] = [1, 0.8, 0.6]
    /// The cutout around an icon that lies over another, so the two read apart on any fill.
    static let stackRing: CGFloat = 1.5

    /// The width of a stack of `count` icons.
    static func stackWidth(_ count: Int) -> CGFloat {
        count > 0 ? iconSize + stackStep * CGFloat(count - 1) : 0
    }

    /// A new front icon comes forward and the old one goes back in a short spring; with Reduce
    /// Motion the stack crossfades instead.
    static var stackMotion: Animation { .snappy(duration: 0.25) }
    static var stackFade: Animation { .easeInOut(duration: 0.2) }
    /// The close button's glyph. Its hit target is `StripLayout.hit` wide.
    static let closeGlyph: CGFloat = 10
    /// The session chip's and the popover rows' waiting dot.
    static let waitingDot: CGFloat = 6
    /// The hairline that ends the session chip, so it reads apart from the first tab.
    static let separatorHeight: CGFloat = 16

    /// The chips' text stops growing here: the strip keeps its height at every text size, so a
    /// larger title would clip. Past it the title truncates. Sidebar mode's title line stops here
    /// too (`TitleLine.typeLimit`).
    static let chipTypeLimit: DynamicTypeSize = .xxxLarge

    /// A chip's title: the active one at the title bar's weight, any other quieter.
    static func titleFont(active: Bool) -> Font {
        .subheadline.weight(active ? .semibold : .regular)
    }

    static func titleColor(active: Bool, _ theme: TermTheme) -> Color {
        active ? theme.fg : theme.chrome.secondary
    }

    /// The selected chip's fill: the sidebar's selected row.
    static func selectedFill(_ theme: TermTheme) -> Color { theme.chrome.rowSelected }

    /// A chip held down: half the selected fill, so the press shows without a capsule
    /// that looks like a second selection.
    static func pressedFill(_ theme: TermTheme) -> Color { theme.chrome.rowSelected.opacity(0.5) }

    /// A chip the strip's scroll view shows only part of fades out over this much before the
    /// scroll view's edge, so it never ends in a hard cut through a letter.
    static let edgeFade: CGFloat = 20

    /// Inactive chips' icons sit back with their titles.
    static let inactiveIconOpacity: Double = 0.7

    // MARK: Popover

    /// The popover's width at the default text size; it grows with Dynamic Type up to
    /// `popoverMaxWidth`, which a 382 pt folded Duo still holds with the system's margins.
    static let popoverWidth: CGFloat = 300
    static let popoverMaxWidth: CGFloat = 350
    /// The tallest the popover asks to be; the system makes it shorter where the window is.
    static let popoverMaxHeight: CGFloat = 520
    /// A row's leading edge: the machine's status dot, then the name.
    static let rowInset: CGFloat = 16
    /// Where a session's name starts: under its machine's name.
    static let sessionInset: CGFloat = 32
    /// The selected session row's highlight sits this far in from the popover's edges.
    static let highlightInset: CGFloat = 8
    static let highlightRadius: CGFloat = 8
    /// A machine's status dot.
    static let statusDot: CGFloat = 7
    /// Rows: as tall as a finger needs, no taller.
    static let rowHeight: CGFloat = 44
    static let headingHeight: CGFloat = 36
}

/// A chip's press: a faint fill while held, the system's touch feedback in the strip's shape.
/// No animation of its own beyond the system's.
struct ChipPressStyle: ButtonStyle {
    let theme: TermTheme
    /// The chip is the selected one: it already has its fill.
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                if configuration.isPressed && !selected {
                    ChipCapsule().fill(StripStyle.pressedFill(theme))
                }
            }
    }
}

/// The selected capsule, as tall as `StripStyle.capsuleHeight` and never closer than
/// `capsuleInset` to the bar's edges, centered in whatever frame it is given.
struct ChipCapsule: Shape {
    func path(in rect: CGRect) -> Path {
        let h = min(StripStyle.capsuleHeight, max(rect.height - StripStyle.capsuleInset * 2, 0))
        let r = CGRect(x: rect.minX, y: rect.midY - h / 2, width: rect.width, height: h)
        return Capsule().path(in: r)
    }
}

/// Fades a chip out toward the edge of the scroll view that holds it, where the edge crosses the
/// chip: the strip's row ends softly instead of cutting a title through a letter. A chip in full
/// view, or one outside any scroll view, is drawn as it is.
///
/// Cheap while the row scrolls: the geometry is read every frame, but the state changes only for
/// the chips the edges cross, as what is hidden of every other chip stays all or nothing.
struct ScrollEdgeFade: ViewModifier {
    /// How much of the chip lies past the scroll view's leading and trailing edges, in points.
    struct Hidden: Equatable {
        var leading: CGFloat = 0
        var trailing: CGFloat = 0
        var width: CGFloat = 0

        /// Some of the chip shows and some doesn't.
        var crossed: Bool {
            (leading > 0 || trailing > 0) && leading + trailing < width
        }
    }

    @State private var hidden = Hidden()

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: Hidden.self) { proxy in
                let w = proxy.size.width
                guard let visible = proxy.bounds(of: .scrollView), w > 0 else { return Hidden() }
                func clamp(_ v: CGFloat) -> CGFloat { min(max(v, 0), w).rounded() }
                return Hidden(leading: clamp(visible.minX), trailing: clamp(w - visible.maxX), width: w.rounded())
            } action: { hidden = $0 }
            .mask {
                if hidden.crossed {
                    LinearGradient(stops: Self.stops(hidden), startPoint: .leading, endPoint: .trailing)
                } else {
                    Rectangle()
                }
            }
    }

    /// Opaque across what shows, clear past the edges, with `StripStyle.edgeFade` between.
    static func stops(_ h: Hidden) -> [Gradient.Stop] {
        let w = max(h.width, 1), fade = StripStyle.edgeFade / w
        let start = h.leading / w, end = 1 - h.trailing / w
        var stops: [Gradient.Stop] = []
        if h.leading > 0 {
            stops += [.init(color: .clear, location: start), .init(color: .black, location: min(start + fade, end))]
        } else {
            stops.append(.init(color: .black, location: 0))
        }
        if h.trailing > 0 {
            stops += [.init(color: .black, location: max(end - fade, start)), .init(color: .clear, location: end)]
        } else {
            stops.append(.init(color: .black, location: 1))
        }
        return stops
    }
}
