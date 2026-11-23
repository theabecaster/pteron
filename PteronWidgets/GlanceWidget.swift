import GlanceModel
import GlanceUI
import SwiftUI
import WidgetKit

/// The agents widget: how many agents need you, where, and for how long, in the Home Screen
/// sizes and the Lock Screen accessories. It only reads the snapshot the app wrote
/// (docs/glance.md); it connects to nothing.
struct GlanceWidget: Widget {
    static let kind = GlanceKind.agents

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: GlanceProvider()) { entry in
            GlanceWidgetView(entry: entry)
        }
        .configurationDisplayName(GlanceText.name)
        .description(GlanceText.description)
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

/// The words the widget gallery shows. Plain strings: the gallery doesn't fill in a
/// localized string's arguments, and would show the app's name as "%@".
enum GlanceText {
    static let name = "Agents"
    static var description: String { "Which agents need you, and for how long, as \(Brand.appName) last saw them." }
}

/// Picks the view for the family, and gives it the colors for the system's mode and the way
/// the system renders the widget.
struct GlanceWidgetView: View {
    let entry: GlanceEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var scheme
    @Environment(\.widgetRenderingMode) private var mode
    @Environment(\.redactionReasons) private var redaction

    var body: some View {
        let colors = GlanceColors.pick(entry.palette, system: scheme)
        let style = GlanceStyle(colors: colors, mode: mode)
        let digest = entry.digest
        // The phone is locked and asks for private content to be hidden.
        let accessory = digest.accessory(private: redaction.contains(.privacy))
        switch family {
        case .accessoryCircular:
            GlanceCircularView(accessory: accessory)
                .containerBackground(for: .widget) { Color.clear }
                .widgetURL(DeepLink.waiting.url)
        case .accessoryRectangular:
            GlanceRectangularView(accessory: accessory)
                .containerBackground(for: .widget) { Color.clear }
                .widgetURL(DeepLink.waiting.url)
        case .accessoryInline:
            GlanceInlineView(accessory: accessory)
                .widgetURL(DeepLink.open.url)
        default:
            GlanceHomeView(digest: digest, size: family == .systemSmall ? .small : family == .systemMedium ? .medium : .large,
                           style: style)
                // The theme's own appearance, so the system's styles match the canvas even
                // when a dark theme serves Light Mode.
                .environment(\.colorScheme, colors.scheme)
                .containerBackground(for: .widget) { GlanceCanvas(digest: digest, style: style) }
                .widgetURL(digest.tap.url)
        }
    }
}
