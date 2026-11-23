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

    /// The actions' own arguments, for the first waiting agent (a simulator's watch can't be
    /// tapped from the command line):
    /// - `-glanceOutcome sending|sent|changed|unreachable|unconfirmed|noPhone`: show how an
    ///   action ended, with nothing sent. `-glanceOutcomeKind interrupt` names the action.
    /// - `-glanceConfirm enter|interrupt`: 6 s after launch, send that action as a confirmed
    ///   tap would. The phone's app checks it like any other.
    @MainActor static func act(_ actions: WatchActions, store: GlanceStore?, defaults: UserDefaults = .standard) {
        func first() -> WatchScreen.Row? { WatchScreen(store?.read() ?? .missing, now: Date()).rows.first }
        if let name = defaults.string(forKey: "glanceOutcome"), let row = first() {
            let kind = defaults.string(forKey: "glanceOutcomeKind").flatMap(WatchAction.Kind.init(rawValue:)) ?? .enter
            actions.show(name, kind: kind, row: row)
        }
        if let kind = defaults.string(forKey: "glanceConfirm").flatMap(WatchAction.Kind.init(rawValue:)) {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                guard let row = first() else { return }
                await actions.confirmed(kind, row: row)
            }
        }
    }

    /// `-glanceAsk enter|interrupt`: an agent's screen opens with that action's question up.
    static var asked: WatchAction.Kind? {
        UserDefaults.standard.string(forKey: "glanceAsk").flatMap(WatchAction.Kind.init(rawValue:))
    }
}
#endif
