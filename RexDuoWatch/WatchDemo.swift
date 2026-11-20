#if DEBUG
import Foundation
import GlanceModel

/// `-glanceDemo <scenario>` on the watch (Debug builds): puts that made-up snapshot in the
/// watch's file, as the phone's `-glanceDemo` does in its own. `none` removes the file and
/// `newer` writes one from a later, incompatible app.
enum WatchDemo {
    static func write(_ name: String, to store: GlanceStore, now: Date) {
        if let data = try? GlanceDemo.snapshot(name, now: now)?.encoded() {
            try? store.write(data)
        } else if name == "newer" {
            try? store.write(GlanceDemo.newerFile)
        } else {
            store.remove()
        }
    }
}
#endif
