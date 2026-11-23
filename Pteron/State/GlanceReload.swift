import GlanceModel
import WidgetKit

/// Asks WidgetKit to draw the app's widgets again from the snapshot.
enum GlanceReload {
    @MainActor static func all() {
        WidgetCenter.shared.reloadTimelines(ofKind: GlanceKind.agents)
    }
}
