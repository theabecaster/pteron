import Foundation
import UserNotifications

/// Which delivered notifications no longer say anything true. A helper's push about an agent
/// stays in Notification Center after the agent was answered at the computer; once the app is
/// in front and knows the agents' states, the ones whose agent no longer waits are removed.
///
/// Only the two agent categories are ever removed. A desktop notification (`NOTICE`) is its
/// own and only copy, and the test notification is one of those, so both always stay.
enum NotificationTidy {
    /// A notification in Notification Center, as far as the rule reads it.
    struct Delivered: Equatable, Sendable {
        /// What removes it: the request's identifier (the push's collapse id, or one iOS made).
        var identifier: String
        var category: String
        var threadID: String
        /// `server` and `block_id` of the payload, which name the pane whatever the identifier is.
        var server: String?
        var blockID: String?
    }

    /// One of the app's servers, as far as the rule reads it.
    struct Server: Equatable {
        var url: String
        var hostName: String?
        /// The panes whose agent waits for the person now. Nil while that is not known: the
        /// server is not connected, or its agents' states have not all been read since.
        var waiting: Set<String>?
    }

    /// The categories of a push about an agent's state (docs/notifications.md).
    static let agentCategories: Set<String> = ["AGENT_BLOCKED", "AGENT_DONE"]

    /// The identifiers to remove, in the order given:
    ///
    /// - on a server whose agents' states are known, a question or a "finished" whose agent
    ///   does not wait now, which includes a pane that is gone;
    /// - for a server that is not in the app, both kinds, but only while every server of the
    ///   app is known, since a server that has not yet said its name can't be ruled out.
    ///
    /// Anything that can't be told stays: no server or pane in the payload, a server whose
    /// states are not known.
    static func stale(_ delivered: [Delivered], servers: [Server]) -> [String] {
        delivered.filter { isStale($0, servers: servers) }.map(\.identifier)
    }

    private static func isStale(_ n: Delivered, servers: [Server]) -> Bool {
        guard agentCategories.contains(n.category), !PushTest.isTest(threadID: n.threadID),
              let server = n.server, PushRoute.host(server) != nil else { return false }
        let route = PushRoute(server: server, sessionID: "")
        let from = servers.filter { route.matches(serverURL: $0.url, hostName: $0.hostName) }
        guard !from.isEmpty else { return servers.allSatisfy { $0.waiting != nil } }
        guard let block = n.blockID, !block.isEmpty else { return false }
        return from.allSatisfy { $0.waiting.map { !$0.contains(block) } ?? false }
    }

    /// At most one pass in this many seconds.
    static let pause: TimeInterval = 1

    /// How long a pass that is asked for at `now` waits, given when the last one ran.
    static func wait(at now: Date, last: Date?) -> TimeInterval {
        guard let last else { return 0 }
        let since = now.timeIntervalSince(last)
        // A clock that was set back does not hold a pass up for longer than one pause.
        return since < 0 ? pause : max(pause - since, 0)
    }
}

/// Runs `NotificationTidy` against Notification Center: a pass when the app comes to the front,
/// and one when a server's agents have been read or one of them changes state, never more
/// than one a second and only while the app is in front. It shows, plays and asks nothing.
@MainActor
final class NotificationTidier {
    /// What the tidier needs from iOS, so tests can stand in for it.
    @MainActor
    struct Center {
        var delivered: @MainActor () async -> [NotificationTidy.Delivered]
        var remove: @MainActor ([String]) -> Void

        static let live = Center(
            delivered: {
                await withCheckedContinuation { (c: CheckedContinuation<[NotificationTidy.Delivered], Never>) in
                    UNUserNotificationCenter.current().getDeliveredNotifications { list in
                        c.resume(returning: list.map { n in
                            let content = n.request.content
                            return NotificationTidy.Delivered(identifier: n.request.identifier, category: content.categoryIdentifier,
                                                              threadID: content.threadIdentifier,
                                                              server: content.userInfo["server"] as? String,
                                                              blockID: content.userInfo["block_id"] as? String)
                        })
                    }
                }
            },
            remove: { UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: $0) })
    }

    /// The app's servers now. AppModel sets it.
    var servers: @MainActor () -> [NotificationTidy.Server] = { [] }

    private let center: Center
    private let now: @MainActor () -> Date
    private let sleep: @MainActor (TimeInterval) async -> Void
    private var inFront = false
    private var last: Date?
    private var pass: Task<Void, Never>?
    /// A pass was asked for while one was under way.
    private var again = false

    init(center: Center = .live, now: @escaping @MainActor () -> Date = { Date() },
         sleep: @escaping @MainActor (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }) {
        self.center = center
        self.now = now
        self.sleep = sleep
    }

    /// The app is in front: a pass now.
    func becameActive() {
        inFront = true
        request()
    }

    func enteredBackground() {
        inFront = false
        again = false
    }

    /// Something the rule reads may have changed. Does nothing while the app is not in front.
    func request() {
        guard inFront else { return }
        guard pass == nil else {
            again = true
            return
        }
        // The pass holds on to the sleeper, not to this object.
        let sleep = sleep
        let wait = NotificationTidy.wait(at: now(), last: last)
        pass = Task { [weak self] in
            if wait > 0 { await sleep(wait) }
            await self?.run()
        }
    }

    private func run() async {
        last = now()
        again = false
        let delivered = inFront ? await center.delivered() : []
        // The servers as they are now, after the wait for iOS.
        let stale = inFront ? NotificationTidy.stale(delivered, servers: servers()) : []
        if !stale.isEmpty { center.remove(stale) }
        pass = nil
        if again { request() }
    }
}
