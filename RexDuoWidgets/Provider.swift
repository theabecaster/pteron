import GlanceModel
import WidgetKit

struct GlanceEntry: TimelineEntry {
    let date: Date
    let digest: GlanceDigest
    let palette: GlanceSnapshot.Palette

    init(_ entry: GlanceTimeline.Entry) {
        date = entry.date
        digest = entry.digest
        palette = entry.palette
    }
}

/// Reads the snapshot from the App Group and turns it into a timeline that ages by itself:
/// an entry now, one when the snapshot turns two minutes old and one when it turns an hour
/// old, and no reload after that. The app reloads the timeline when it writes something new.
struct GlanceProvider: TimelineProvider {
    private func entries(now: Date) -> [GlanceEntry] {
        GlanceTimeline.entries(GlanceStore.shared()?.read() ?? .missing, now: now).map(GlanceEntry.init)
    }

    func placeholder(in context: Context) -> GlanceEntry { GlanceGallery.entry(now: Date()) }

    func getSnapshot(in context: Context, completion: @escaping (GlanceEntry) -> Void) {
        // The gallery shows made-up agents, never the person's sessions.
        let now = Date()
        completion(context.isPreview ? GlanceGallery.entry(now: now) : entries(now: now)[0])
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<GlanceEntry>) -> Void) {
        completion(Timeline(entries: entries(now: Date()), policy: .never))
    }
}
