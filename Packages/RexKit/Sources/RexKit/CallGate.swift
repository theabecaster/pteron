import Foundation

/// Lets at most `limit` of a connection's sync calls be under way at once, in the order they
/// were asked for. A sync sends one call for every session and three for every pane in one
/// turn: a hundred requests and their answers at once. On cellular that goes through the
/// phone's tunnel ahead of the pane on screen, so there the app sends them through this gate,
/// four at a time, the tab on screen first. On Wi-Fi the app does not use it.
///
/// Only the reads of a sync wait here. What the user does (typing, a tap, an action) never does.
///
/// A call that waits its turn starts when one ahead of it ends, and a control call always ends:
/// with its answer, or with the connection (`RexControl` fails every waiting call on a drop). So
/// the gate needs no timer.
@MainActor
public final class CallGate {
    public let limit: Int
    /// Calls under way now, and the most there have been at once.
    public private(set) var inFlight = 0
    public private(set) var peak = 0
    /// How many calls have gone through, ever.
    public private(set) var total = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(limit: Int = ReconnectPolicy.standard.syncCalls) {
        self.limit = max(1, limit)
    }

    /// Runs `body` when its turn comes: at once with fewer than `limit` under way, otherwise
    /// after those asked before it.
    public func run<R>(_ body: @MainActor () async throws -> R) async rethrows -> R {
        await enter()
        defer { leave() }
        return try await body()
    }

    /// Runs `body` for every item, starting them in the items' order with at most `limit` under
    /// way (counting every other call in the gate), and returns when all have ended. The first
    /// item is the first to start.
    public func each<T: Sendable>(_ items: [T], _ body: @escaping @MainActor (T) async -> Void) async {
        var tasks: [Task<Void, Never>] = []
        for item in items {
            await enter()
            tasks.append(Task { @MainActor in
                await body(item)
                self.leave()
            })
        }
        for t in tasks { await t.value }
    }

    private func enter() async {
        total += 1
        if inFlight < limit, waiters.isEmpty {
            inFlight += 1
            peak = max(peak, inFlight)
            return
        }
        // The one that leaves hands its place over: `inFlight` stays as it is.
        await withCheckedContinuation { waiters.append($0) }
    }

    private func leave() {
        if waiters.isEmpty {
            inFlight -= 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}
