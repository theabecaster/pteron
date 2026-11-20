import GlanceModel
import SwiftUI

/// The widgets' colors, from a snapshot's palette: the theme's own, and the chrome derived from
/// them exactly as the app derives its chrome (`TermTheme.Chrome`), with the same SwiftUI mix,
/// which works in a perceptual space, so a widget and the app show the same canvas.
public struct GlanceColors: Sendable {
    public let palette: GlancePalette

    public init(_ palette: GlancePalette) {
        self.palette = palette
    }

    /// The palette for the system's mode: the theme chosen in the app for that mode.
    public static func pick(_ palette: GlanceSnapshot.Palette, system: ColorScheme) -> GlanceColors {
        GlanceColors(system == .light ? palette.light : palette.dark)
    }

    /// The theme's own appearance. The widget sets it on its content, so the system's secondary
    /// styles match the canvas even when a dark theme serves Light Mode.
    public var scheme: ColorScheme { palette.isDark ? .dark : .light }

    public var bg: Color { Color(glanceHex: palette.bg) }
    public var fg: Color { Color(glanceHex: palette.fg) }
    public var accent: Color { Color(glanceHex: palette.accent) }

    private var toward: Color { palette.isDark ? .black : .white }
    /// The widget's background.
    public var canvas: Color { bg.mix(with: toward, by: GlancePalette.Mix.canvas(dark: palette.isDark)) }
    /// The tiles.
    public var sidebar: Color { bg.mix(with: toward, by: GlancePalette.Mix.sidebar(dark: palette.isDark)) }
    public var secondary: Color { fg.opacity(GlancePalette.Mix.secondary) }
    public var tertiary: Color { fg.opacity(GlancePalette.Mix.tertiary) }

    public var blocked: Color { Color(glanceHex: palette.ansi(3)) }
    public var error: Color { Color(glanceHex: palette.ansi(1)) }
    public var working: Color { Color(glanceHex: palette.ansi(4)) }
    public var done: Color { Color(glanceHex: palette.ansi(2)) }

    /// The color of a state, as on the agent board.
    public func state(_ urgency: GlanceDigest.Urgency) -> Color {
        switch urgency {
        case .waiting: blocked
        case .error: error
        case .working: working
        case .done: done
        case .quiet, .offline: secondary
        }
    }
}

public extension Color {
    /// `#rgb` or `#rrggbb` in sRGB.
    init(glanceHex hex: String) {
        let c = GlancePalette.rgb(hex)
        self.init(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: 1)
    }
}
