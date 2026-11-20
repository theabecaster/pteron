import GlanceModel
import SwiftUI

/// The watch app: who needs you, where, and for how long, as the iPhone app last saw it
/// (docs/glance.md, The watch). It has no connection of its own: what it knows is the snapshot
/// the phone's app sent, kept in the watch's own App Group container, where the complications
/// read it too. The one thing it sends is an action the person confirmed for a waiting agent
/// (Enter or Interrupt), which the phone's app checks and types.
@main
struct RexDuoWatchApp: App {
    @State private var model: WatchModel
    @State private var actions: WatchActions
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
        let session = WatchSession(inbox: store.map(WatchInbox.init(store:))) {
            WatchReload.all()
            Task { @MainActor in await model.reload() }
        }
        self.session = session
        session.activate()
        let actions = WatchActions { await session.send($0) }
        _actions = State(initialValue: actions)
        #if DEBUG
        WatchDemo.act(actions, store: store)
        #endif
        #if DEBUG
        // `-glanceDemoThen <scenario>`: 4 s after launch, that snapshot replaces the first, as
        // a delivery would, to see the open app take a change.
        if let store, let next = UserDefaults.standard.string(forKey: "glanceDemoThen"), !next.isEmpty {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                WatchDemo.write(next, to: store, now: Date())
                WatchReload.all()
                await model.reload()
            }
        }
        #endif
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

    /// `-glanceDetail later` (Debug builds): open the first waiting agent's screen 2 s after
    /// launch, as a tap on its row would, to see the way in. A simulator's watch can't be tapped
    /// from the command line.
    private var openLater: Bool {
        #if DEBUG
        return UserDefaults.standard.string(forKey: "glanceDetail") == "later"
        #else
        return false
        #endif
    }

    /// `-glanceDim YES` (Debug builds): draw as with the wrist down in Always On, where the
    /// screen dims and nothing moves. A simulator has no wrist to lower.
    private var dimmed: Bool {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: "glanceDim")
        #else
        return false
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                // Nothing until the file was read: the first screen is the one that holds.
                if model.loaded {
                    WatchRootView(screen: model.screen, path: startPath, dimmed: dimmed, openLater: openLater)
                        .environment(actions)
                }
            }
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
