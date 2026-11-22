import Foundation

/// Lets at most `limit` of a connection's sync calls be under way at once, in the order they
/// were asked for. A sync sends one call for every session and three for every pane in one
/// turn: a hundred requests and their answers at once. On cellular that goes through the
/// phone's tunnel ahead of the pane on screen, so there the app sends them through this gate,
/// four at a time, the tab on screen first. On Wi-Fi the app does not use it.
///
/// Only the reads of a sync wait here. What the user does (typing, a tap, an action) never does.
/// A read made for what the user is typing (`Priority.user`) starts at once, however many sync
/// reads are under way or waiting; it takes one of the `limit` places while it is out, so the
/// sync yields to it instead of adding to it.
///
/// A call that waits its turn starts when one ahead of it ends, and a control call always ends:
/// with its answer, or with the connection (`RexControl` fails every waiting call on a drop). So
/// the gate needs no timer.
@MainActor
public final class CallGate {
    public let limit: Int
    /// Sync calls under way now, and the most there have been at once.
    public private(set) var inFlight = 0
    public private(set) var peak = 0
    /// How many sync calls have gone through, ever.
    public private(set) var total = 0
    /// Calls for the user under way now. They never wait.
    public private(set) var userInFlight = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public enum Priority: Sendable {
        /// A sync's read: at most `limit` at once, in the order asked.
        case sync
        /// A read for what the user is doing: at once, ahead of every sync read.
        case user
    }

    public init(limit: Int = ReconnectPolicy.standard.syncCalls) {
        self.limit = max(1, limit)
    }

    /// A sync read is under way or waits its turn.
    public var syncBusy: Bool { inFlight > 0 || !waiters.isEmpty }

    /// A point to ask `quiet(since:)` about; nil while a sync read is under way or waiting.
    public var mark: Int? { syncBusy ? nil : total }

    /// No sync read was under way at `mark` and none has started since. What was timed between
    /// the two then shared the connection with no sync.
    public func quiet(since mark: Int?) -> Bool { mark != nil && mark == total }

    /// Runs `body` when its turn comes: at once with fewer than `limit` under way, otherwise
    /// after those asked before it. With `.user` it runs at once.
    public func run<R>(priority: Priority = .sync, _ body: @MainActor () async throws -> R) async rethrows -> R {
        if priority == .user {
            userInFlight += 1
            defer { leaveUser() }
            return try await body()
        }
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
        if inFlight + userInFlight < limit, waiters.isEmpty {
            inFlight += 1
            peak = max(peak, inFlight)
            return
        }
        // The one that leaves hands its place over.
        await withCheckedContinuation { waiters.append($0) }
    }

    private func leave() {
        inFlight -= 1
        admit()
    }

    private func leaveUser() {
        userInFlight -= 1
        admit()
    }

    /// Starts the sync reads that waited, while there is a place for them. A call for the user
    /// may have taken a place a sync read had, so one that leaves does not always free one.
    private func admit() {
        while !waiters.isEmpty, inFlight + userInFlight < limit {
            inFlight += 1
            peak = max(peak, inFlight)
            waiters.removeFirst().resume()
        }
    }
}
