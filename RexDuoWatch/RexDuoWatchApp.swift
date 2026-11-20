import GlanceModel
import SwiftUI

/// The watch app: who needs you, where, and for how long, as the iPhone app last saw it
/// (docs/glance.md, The watch). It only shows. It has no connection of its own and sends
/// nothing to the phone: what it knows is the snapshot the phone's app sent, kept in the
/// watch's own App Group container, where the complications read it too.
@main
struct RexDuoWatchApp: App {
    @State private var model: WatchModel
    private let session: WatchSession
    @Environment(\.scenePhase) private var phase

    init() {
        let store = GlanceStore.shared()
        #if DEBUG
        // `-glanceDemo <scenario>`: a made-up snapshot in place of the phone's.
        if let store, let name = UserDefaults.standard.string(forKey: "glanceDemo"), !name.isEmpty {
            WatchDemo.write(name, to: store, now: Date())
            WatchReload.all()
        }
        #endif
        let model = WatchModel { store?.read() ?? .missing }
        _model = State(initialValue: model)
        session = WatchSession(inbox: store.map(WatchInbox.init(store:))) {
            WatchReload.all()
            Task { @MainActor in await model.reload() }
        }
        session.activate()
    }

    /// `-glanceDetail YES` (Debug builds): open on the first waiting agent's screen.
    private var startPath: [String] {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "glanceDetail"), let first = WatchScreen(GlanceStore.shared()?.read() ?? .missing, now: Date()).rows.first {
            return [first.id]
        }
        #endif
        return []
    }

    var body: some Scene {
        WindowGroup {
            WatchRootView(screen: model.screen, path: startPath)
                .task { await model.reload() }
                .onChange(of: phase) { _, now in
                    // Time passed while the app was away, and a delivery may have landed.
                    if now == .active { Task { await model.reload() } }
                }
        }
        // A delivery that arrives while the app isn't open: the system starts it for this, the
        // session's delegate writes the file and reloads the complications, and the task ends
        // when the session has nothing more to hand over.
        .backgroundTask(.watchConnectivity) {
            await session.drain()
        }
    }
}
