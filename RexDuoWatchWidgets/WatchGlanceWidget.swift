import GlanceModel
import GlanceUI
import SwiftUI
import WidgetKit

/// The agents complication: how many agents need you, in the four accessory families. It reads
/// the snapshot the watch app wrote from the phone's deliveries and connects to nothing. The
/// circular, rectangular and inline families are the iPhone Lock Screen's views
/// (`RexDuoWidgets/Views`), compiled into this extension as they are; the corner is the watch's own.
///
/// The timeline is the widgets' (`GlanceProvider`): it ages by itself and never reloads. In
/// the Smart Stack, an entry in which an agent waits counts for more (`GlanceDigest.relevance`),
/// which only orders the stack.
struct WatchGlanceWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: GlanceKind.agents, provider: GlanceProvider()) { entry in
            WatchGlanceWidgetView(entry: entry)
        }
        .configurationDisplayName(WatchWidgetText.name)
        .description(WatchWidgetText.description)
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryRectangular, .accessoryInline])
    }
}

/// The words the complication gallery shows.
enum WatchWidgetText {
    static let name = "Agents"
    static var description: String { "Which agents need you, as \(Brand.appName) on iPhone last saw them." }
}

struct WatchGlanceWidgetView: View {
    let entry: GlanceEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var mode
    @Environment(\.redactionReasons) private var redaction

    var body: some View {
        // The system asks for private content to be hidden: counts only, no name or place.
        let accessory = entry.digest.accessory(private: redaction.contains(.privacy))
        // On a face in full color the count takes the waiting color; a tinted face colors it itself.
        let accent = WatchAccent.color(accessory, palette: entry.palette, fullColor: mode == .fullColor)
        Group {
            switch family {
            case .accessoryCorner: WatchCornerView(accessory: accessory, accent: accent)
            case .accessoryRectangular: GlanceRectangularView(accessory: accessory, accent: accent)
            case .accessoryInline: GlanceInlineView(accessory: accessory)
            default: GlanceCircularView(accessory: accessory, accent: accent)
            }
        }
        .containerBackground(for: .widget) { Color.clear }
    }
}

enum WatchAccent {
    /// The waiting color of the watch's theme, while someone waits in a snapshot that isn't dimmed.
    static func color(_ accessory: GlanceDigest.Accessory, palette: GlanceSnapshot.Palette, fullColor: Bool) -> Color? {
        guard fullColor, accessory.hand, !accessory.dimmed else { return nil }
        return GlanceColors(WatchScreen.palette(palette)).blocked
    }
}

/// The corner of a watch face: the count, or the mark when nobody waits or works, with the
/// words curved along the bezel ("2" and "need you").
struct WatchCornerView: View {
    let accessory: GlanceDigest.Accessory
    var accent: Color?
    var symbols: Bundle = .main

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            if let count = accessory.count {
                Text("\(count)")
                    .font(GlanceType.count)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .modifier(GlanceAccent(color: accent))
                    .widgetAccentable()
                    .opacity(accessory.dimmed ? 0.6 : 1)
            } else {
                Image(GlanceStyle.markOpen, bundle: symbols).font(.system(size: 20, weight: .medium))
            }
        }
        .widgetLabel {
            if let label = accessory.cornerLabel { Text(label) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessory.count.map { "\($0) \(accessory.hand ? "waiting" : "working")" } ?? GlanceDigest.openText)
    }
}
