import SwiftUI

/// Glide's colors, from the app icon (`Brand/AppIcon.icon`): the body's cool gradient of mint,
/// cyan, sky, indigo and violet, on the icon's deep blue. The widgets and the watch draw the
/// mascot (the `mark.open` symbol) with them.
public enum GlanceGlide {
    public static let mintHex = "#8AF7DA", cyanHex = "#3DD6F8", skyHex = "#3F93FF", indigoHex = "#5A6AF8", violetHex = "#8A5CF8"
    /// The icon's ground, display P3 (0.07, 0.11, 0.29), in sRGB.
    public static let deepHex = "#0F1C4D"

    public static let deep = Color(glanceHex: deepHex)
    public static let indigo = Color(glanceHex: indigoHex)

    /// Glide's body, lit from the upper right as on the icon.
    public static let gradient = LinearGradient(colors: [mintHex, cyanHex, skyHex, indigoHex, violetHex].map(Color.init(glanceHex:)),
                                                startPoint: .topTrailing, endPoint: .bottomLeading)

    /// The soft indigo halo behind Glide where there is nothing to list: twice the mark's size.
    public static func halo(_ size: CGFloat, strength: Double = 0.4) -> some View {
        Circle()
            .fill(RadialGradient(colors: [indigo.opacity(strength), .clear], center: .center, startRadius: 0, endRadius: size))
            .frame(width: size * 2, height: size * 2)
    }
}

/// Glide, in the icon's gradient over its halo. `accent` is applied to the mark only, so a
/// widget can say the mark takes the system's accent when it is tinted (a WidgetKit modifier,
/// which this package doesn't import). Without `fullColor` the mark is drawn in the inherited
/// style with no halo: the system then gives it its color.
public struct GlanceGlideMark<Accent: ViewModifier>: View {
    let mark: Image
    let size: CGFloat
    let fullColor: Bool
    let halo: Bool
    let accent: Accent

    public init(_ mark: Image, size: CGFloat, fullColor: Bool, halo: Bool = true, accent: Accent) {
        self.mark = mark
        self.size = size
        self.fullColor = fullColor
        self.halo = halo
        self.accent = accent
    }

    public var body: some View {
        ZStack {
            if fullColor, halo { GlanceGlide.halo(size) }
            if fullColor {
                mark.font(.system(size: size, weight: .medium)).foregroundStyle(GlanceGlide.gradient).modifier(accent)
            } else {
                mark.font(.system(size: size, weight: .medium)).modifier(accent)
            }
        }
        // The halo spills past the mark without taking room from the text around it.
        .frame(width: size * 1.25, height: size * 1.1)
        .accessibilityHidden(true)
    }
}
