import Foundation

/// A terminal theme's colors, as far as the widgets need them, in hex. `appearance` is the
/// theme's own, `dark` or `light`: a dark theme can be the one chosen for Light Mode, and it is
/// then drawn as the dark theme it is.
///
/// The chrome colors come from these the same way the app's do (`TermTheme.Chrome`): `Mix`
/// holds the fractions, and GlanceUI applies them with the same SwiftUI call as the app.
public struct GlancePalette: Codable, Equatable, Sendable {
    public var appearance: String
    public var bg: String
    public var fg: String
    public var accent: String
    /// ANSI colors 0 to 5 at least: 1 error, 2 done, 3 waiting, 4 working, 5 other agents.
    public var ansi: [String]

    public init(appearance: String, bg: String, fg: String, accent: String, ansi: [String]) {
        self.appearance = appearance
        self.bg = bg
        self.fg = fg
        self.accent = accent
        self.ansi = Array(ansi.prefix(Self.ansiCount))
    }

    /// How many ANSI colors a snapshot carries.
    public static let ansiCount = 6

    public var isDark: Bool { appearance != "light" }

    /// An ANSI color, or the foreground where the theme has none at that index.
    public func ansi(_ i: Int) -> String { ansi.indices.contains(i) ? ansi[i] : fg }

    /// The app's default themes: GitHub Dark Dimmed and GitHub Light Default.
    public static let standardDark = GlancePalette(
        appearance: "dark", bg: "#22272e", fg: "#adbac7", accent: "#539bf5",
        ansi: ["#545d68", "#f47067", "#57ab5a", "#c69026", "#539bf5", "#b083f0"])
    public static let standardLight = GlancePalette(
        appearance: "light", bg: "#ffffff", fg: "#1f2328", accent: "#0969da",
        ansi: ["#24292f", "#cf222e", "#116329", "#4d2d00", "#0969da", "#8250df"])

    /// The fractions of `TermTheme.Chrome`, keyed on the theme's own appearance.
    public enum Mix {
        /// The canvas: the background mixed toward black (dark) or white (light) by this much.
        public static func canvas(dark: Bool) -> Double { dark ? 0.28 : 0.08 }
        /// The sidebar color, which the tiles use.
        public static func sidebar(dark: Bool) -> Double { dark ? 0.18 : 0.04 }
        /// The foreground's opacity for secondary and tertiary text.
        public static let secondary = 0.55
        public static let tertiary = 0.35
    }

    /// Red, green and blue from `#rgb` or `#rrggbb`, each 0...1. Black for anything else.
    public static func rgb(_ hex: String) -> (r: Double, g: Double, b: Double) {
        var s = Substring(hex.trimmingCharacters(in: .whitespaces))
        if s.hasPrefix("#") { s = s.dropFirst() }
        guard let v = UInt32(s, radix: 16) else { return (0, 0, 0) }
        if s.count == 3 {
            return (Double((v >> 8) & 0xf) * 17 / 255, Double((v >> 4) & 0xf) * 17 / 255, Double(v & 0xf) * 17 / 255)
        }
        return (Double((v >> 16) & 0xff) / 255, Double((v >> 8) & 0xff) / 255, Double(v & 0xff) / 255)
    }
}
