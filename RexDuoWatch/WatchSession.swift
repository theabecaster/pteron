import Foundation
import GlanceModel
import WatchConnectivity

/// The watch's end of the session with the phone. Each payload it receives goes to
/// `WatchInbox`, the one writer of the watch's snapshot file, and `changed` is called when the
/// file was replaced. It sends one thing, and only when the person confirmed it: an action for
/// a waiting agent (`send`), which wakes the phone's app to answer.
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

    /// Sends a confirmed action to the phone's app and waits for its answer. One message: it
    /// is not sent again, whatever comes of it.
    func send(_ action: WatchAction) async -> WatchActionOutcome {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated, WCSession.default.isReachable else { return .noPhone }
        return await withCheckedContinuation { done in
            let answer = Answer(done)
            // The session may neither answer nor fail for minutes: the watch stops waiting,
            // and claims nothing either way.
            Task {
                try? await Task.sleep(nanoseconds: UInt64(WatchActionOutcome.replyLimit * 1_000_000_000))
                answer.give(.unconfirmed)
            }
            WCSession.default.sendMessage(WatchActionWire.message(action), replyHandler: {
                answer.give(WatchActionOutcome(reply: $0))
            }, errorHandler: { error in
                // The message got there and the reply didn't: the phone may have typed.
                let code = (error as? WCError)?.code
                answer.give(WatchActionOutcome(reply: nil, arrived: code == .messageReplyTimedOut || code == .messageReplyFailed))
            })
        }
    }

    /// The first answer wins; the session calls one of its two handlers, on its own queue.
    /// `@unchecked Sendable`: the lock guards the one mutable field.
    private final class Answer: @unchecked Sendable {
        private let lock = NSLock()
        private var done: CheckedContinuation<WatchActionOutcome, Never>?

        init(_ done: CheckedContinuation<WatchActionOutcome, Never>) {
            self.done = done
        }

        func give(_ outcome: WatchActionOutcome) {
            lock.lock()
            let d = done
            done = nil
            lock.unlock()
            d?.resume(returning: outcome)
        }
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
