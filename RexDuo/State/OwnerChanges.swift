import Foundation
import RexKit

/// Who is told when a pane changes owner: the panes that show it. One per computer
/// (`ServerConnection.ownerChanges`); the events come from its control connection.
@MainActor
final class OwnerChanges {
    private var observers: [String: [@MainActor (BlockOwnerChange) -> Bool]] = [:]

    /// Calls `body` for each change of this block's owner, until it returns false.
    func observe(block: String, _ body: @escaping @MainActor (BlockOwnerChange) -> Bool) {
        observers[block, default: []].append(body)
    }

    func send(_ change: BlockOwnerChange) {
        guard let current = observers[change.blockID] else { return }
        // An observer added from inside a call is kept for the next time.
        observers[change.blockID] = []
        let kept = current.filter { $0(change) } + (observers[change.blockID] ?? [])
        observers[change.blockID] = kept.isEmpty ? nil : kept
    }

    /// The block closed: nobody hears of it again.
    func forget(block: String) { observers[block] = nil }

    /// How many observers the block has. For tests.
    func count(block: String) -> Int { observers[block]?.count ?? 0 }
}
