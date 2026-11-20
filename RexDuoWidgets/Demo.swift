import GlanceModel
import WidgetKit

/// What the widget gallery and a placeholder show: made-up agents (`GlanceDemo`), so neither
/// ever shows a real session.
enum GlanceGallery {
    static func entry(now: Date) -> GlanceEntry {
        GlanceEntry(GlanceTimeline.entries(.snapshot(GlanceDemo.gallery(now: now)), now: now)[0])
    }
}
