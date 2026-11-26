import Foundation

/// One pane's compose: whether it is open and the draft. In memory only, for as long as the app
/// runs: `TerminalHostPool` keeps one per pane (`ComposeSlots`), so a draft outlives a parked or
/// evicted host and goes with the pane's session or computer.
@MainActor
final class ComposeSlot {
    var open = false
    var text = ""
}

/// The panes' compose slots, by pane. Owned by `TerminalHostPool`.
@MainActor
final class ComposeSlots {
    private var slots: [TerminalHostPool.Key: ComposeSlot] = [:]

    /// The pane's slot, made on first use.
    func slot(for key: TerminalHostPool.Key) -> ComposeSlot {
        if let s = slots[key] { return s }
        let s = ComposeSlot()
        slots[key] = s
        return s
    }

    /// Lets go of the slots of panes that are gone: `gone` says which.
    func drop(where gone: (TerminalHostPool.Key) -> Bool) {
        slots = slots.filter { !gone($0.key) }
    }

    var count: Int { slots.count }
}
