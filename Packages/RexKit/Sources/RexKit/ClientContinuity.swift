import Foundation

/// Whether the server still has this connection's client, by what its welcome said.
///
/// A control connection that drops without a close frame leaves its client on the server for a
/// while: the client keeps its ID, its attachments and the streams it opened, and the next
/// connection continues it by sending the last welcome's reconnect token. The welcome then says
/// `resumed: true`. A token the server no longer knows starts a new client instead, and
/// `resumed` is false: the old client has left the server, and the server stops the streams a
/// client opened when that client leaves. A RESUME for one of them is refused, with certainty.
///
/// Pure: `RexControl` asks at each welcome, and a stream asks before it spends a RESUME.
public enum ClientContinuity {
    /// Whether a welcome says the client that was to be continued is gone. Only when the token
    /// was sent, so that the server was asked to continue it, and the answer was no: `resumed`
    /// is false, or the client has another ID than before. A server that says nothing about it
    /// (one from before clients could be continued) leaves it unknown, which is not "gone".
    public static func ended(sentToken: Bool, resumed: Bool?, previousID: String?, id: String?) -> Bool {
        guard sentToken else { return false }
        if resumed == false { return true }
        if let previousID, let id, previousID != id { return true }
        return false
    }

    /// Whether a stream that was welcomed while the connection was its `welcomedUnder`-th client
    /// can still be on the server now that the connection is its `now`-th. Unknown counts as yes:
    /// a RESUME is only left out where its refusal is certain.
    public static func streamSurvives(welcomedUnder: Int?, now: Int) -> Bool {
        guard let welcomedUnder else { return true }
        return welcomedUnder == now
    }
}

/// The sessions this connection's client is attached to, as far as the connection's own calls
/// say, and who waits for one to be attached.
///
/// A ticket for a pane's stream is refused with `conflict` until the pane's session is attached
/// on the connection. Right after a reconnect that started a new client the app attaches its
/// sessions again, and a stream that asked too early waits here for that call's answer instead
/// of asking again on a timer. A wait never ends by itself: whoever waits sets a cap, and
/// cancels the wait when it stops caring (`cancel`). Nothing here opens or asks anything.
@MainActor
final class AttachWaits {
    private(set) var attached: Set<String> = []
    private var waiters: [Int: (session: String, done: @MainActor (Bool) -> Void)] = [:]
    private var nextID = 0

    var waiting: Int { waiters.count }

    /// The server answered an attach of these sessions: their waiters go on.
    func attach(_ sessions: [String]) {
        attached.formUnion(sessions)
        for (id, w) in waiters where attached.contains(w.session) {
            waiters[id] = nil
            w.done(true)
        }
    }

    /// A new client: it is attached to nothing yet. Those who wait keep waiting for its attach.
    func newClient() { attached = [] }

    /// Calls `done(true)` once `session` is attached, or `done(false)` when the wait is
    /// cancelled. Returns nil, having called nothing, when the session is attached already: the
    /// caller's refusal then has another reason, and there is nothing to wait for.
    func wait(for session: String, _ done: @escaping @MainActor (Bool) -> Void) -> Int? {
        guard !attached.contains(session) else { return nil }
        nextID += 1
        waiters[nextID] = (session, done)
        return nextID
    }

    /// Ends one wait with `done(false)`. A wait that has ended already is left alone.
    func cancel(_ id: Int) {
        guard let w = waiters.removeValue(forKey: id) else { return }
        w.done(false)
    }

    /// Ends every wait with `done(false)`: the connection is lost or stopped, or the app went to
    /// the background.
    func cancelAll() {
        let all = waiters
        waiters = [:]
        for (_, w) in all { w.done(false) }
    }

    /// The sessions a call's answer says are attached now, by the call's method and payload.
    nonisolated static func attaches(method: String, payload: JSONObject?) -> [String] {
        switch method {
        case "session.attach": return payload?.str("session_id").map { [$0] } ?? []
        case "session.bootstrap": return (payload?["attach_session_ids"] as? [Any])?.compactMap { $0 as? String } ?? []
        default: return []
        }
    }
}
