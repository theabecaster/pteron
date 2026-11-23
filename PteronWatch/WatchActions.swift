import Foundation
import GlanceModel
import Observation

/// The actions from the wrist, for the views: Enter and Interrupt for a waiting agent
/// (docs/glance.md, Actions from the wrist). It keeps one `WatchActionState` per agent, which
/// decides what may start and what is said, and sends a confirmed action to the phone, once. It
/// never sends by itself and never sends again: a line says how it ended, and that is all.
@MainActor
@Observable
final class WatchActions {
    private var states: [String: WatchActionState] = [:]
    @ObservationIgnored private let send: @Sendable (WatchAction) async -> WatchActionOutcome
    @ObservationIgnored private let makeID: @MainActor () -> String

    init(id: @escaping @MainActor () -> String = { UUID().uuidString }, send: @escaping @Sendable (WatchAction) async -> WatchActionOutcome) {
        self.send = send
        makeID = id
    }

    func state(_ row: String) -> WatchActionState {
        states[row] ?? WatchActionState()
    }

    /// The person confirmed `kind` for this agent. Nothing happens when no action may start
    /// (`WatchActionState.canAct`), so a second tap can't send a second one.
    func confirmed(_ kind: WatchAction.Kind, row: WatchScreen.Row) async {
        guard let target = row.target else { return }
        var state = state(row.id)
        guard let action = state.begin(kind, on: target, id: makeID()) else { return }
        states[row.id] = state
        let outcome = await send(action)
        states[row.id]?.finish(id: action.id, outcome)
    }

    #if DEBUG
    /// `-glanceOutcome <outcome>`: this agent shows how an action ended, with nothing sent.
    /// `sending` shows one on its way.
    func show(_ name: String, kind: WatchAction.Kind, row: WatchScreen.Row) {
        guard let target = row.target else { return }
        let outcomes: [String: WatchActionOutcome] = ["sent": .sent, "changed": .changed, "unreachable": .unreachable,
                                                     "unconfirmed": .unconfirmed, "noPhone": .noPhone]
        var state = WatchActionState()
        _ = state.begin(kind, on: target, id: "demo")
        if let outcome = outcomes[name] { state.finish(id: "demo", outcome) }
        states[row.id] = state
    }
    #endif
}
