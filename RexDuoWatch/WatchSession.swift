import Foundation
import GlanceModel
import WatchConnectivity

/// The watch's end of the session with the phone. It only receives: each payload goes to
/// `WatchInbox`, the one writer of the watch's snapshot file, and `changed` is called when the
/// file was replaced. Nothing is ever sent to the phone, so the watch can't wake it.
///
/// Sendable: it holds only constants, and the session's delegate queue calls it serially.
final class WatchSession: NSObject, WCSessionDelegate, Sendable {
    private let inbox: WatchInbox?
    private let changed: @Sendable () -> Void

    /// `inbox` is nil when there is no App Group to write to.
    init(inbox: WatchInbox?, changed: @escaping @Sendable () -> Void) {
        self.inbox = inbox
        self.changed = changed
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Stays until the session has handed over everything it holds (`WatchDrain`).
    func drain() async {
        await WatchDrain.wait(pending: { WCSession.default.hasContentPending },
                              sleep: { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) })
    }

    func take(_ payload: [String: Any]) {
        guard let inbox, inbox.receive(payload, now: Date()) else { return }
        changed()
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        // What the phone sent while the watch app wasn't there to be told.
        if activationState == .activated { take(session.receivedApplicationContext) }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        take(applicationContext)
    }

    /// A complication transfer: the same payload, delivered ahead of the queue.
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        take(userInfo)
    }
}
