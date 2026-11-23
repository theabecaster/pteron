import GlanceModel
import WidgetKit

/// Asks WidgetKit to draw the watch's complications again from the snapshot: after a delivery
/// replaced the file, and at no other time.
enum WatchReload {
    static func all() {
        WidgetCenter.shared.reloadTimelines(ofKind: GlanceKind.agents)
    }
}
