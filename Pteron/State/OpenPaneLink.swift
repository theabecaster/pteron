import Foundation

/// What a pane link (`rexduo://pane?…`, a widget's row) does next, decided from plain values:
/// open the pane, wait for its session to load, or do nothing. `AppModel.openPane(link:)` feeds
/// it and carries out the step.
///
/// - **Accepted** only when the link's server id is one of the app's, and its pane is either in
///   a session the app has loaded or in the snapshot's waiting list (what the widget showed).
///   Anything else does nothing: the app is just open.
/// - **A pane the snapshot lists but the app hasn't loaded** (a cold launch from the widget):
///   it waits for the session, `cap` at most.
/// - **It gives up only on the person's own move**, as "Jump to Waiting" does: the tab on
///   screen is neither the one from when the link arrived nor one `autoSelect()` put there since.
struct OpenPaneLink {
    static let cap: TimeInterval = 10

    /// The link's target, as the app sees it now.
    struct World: Equatable {
        /// The link's server id is one of the app's servers.
        var serverKnown: Bool
        /// Its pane is in a session the app has loaded.
        var loaded: Bool
        /// Its pane is in the snapshot's waiting list, for that server.
        var inSnapshot: Bool
    }

    enum Step: Equatable {
        case wait
        case open
        case nothing(Why)
    }

    enum Why: Equatable {
        case unknownServer, unknownPane, timedOut, personMoved
        /// A newer link took over (set by the caller).
        case replaced
    }

    let began: TimeInterval
    let before: Selection?

    func step(_ world: World, now: TimeInterval, selection: Selection?, autoSelected: Selection?) -> Step {
        guard world.serverKnown else { return .nothing(.unknownServer) }
        if selection != before, selection != autoSelected { return .nothing(.personMoved) }
        if world.loaded { return .open }
        guard world.inSnapshot else { return .nothing(.unknownPane) }
        if now - began >= Self.cap { return .nothing(.timedOut) }
        return .wait
    }
}
