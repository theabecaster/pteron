import Foundation

/// Which terminal streams on one control connection have typed input on its way: a write in
/// flight or queued (`TerminalStream.hasPendingInput`). A long read on the same connection (a
/// share of a pane's whole output) waits here before each request, so a keystroke's reply never
/// queues behind more than one of the read's requests.
///
/// Observed, never polled: `idle()` returns when the last stream's input has gone out, or when
/// the connection drops, since input waits for the next connection and the read can't go on.
@MainActor
public final class InputActivity {
    private struct Weak {
        weak var stream: AnyObject?
    }
    /// Weak, as a second guard: a stream says when it stops and when it goes (`remove`), and one
    /// that went without either holds no reader back, as `busy` skips it.
    private var pending: [ObjectIdentifier: Weak] = [:]
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    /// The connection is up. `RexControl` says so on every change of its state.
    public private(set) var connected = true

    public init() {}

    /// True while some stream has input on its way.
    public var busy: Bool { pending.values.contains { $0.stream != nil } }

    /// A stream's input went out, or some came in.
    func set(_ stream: AnyObject, pending isPending: Bool) {
        if isPending {
            pending[ObjectIdentifier(stream)] = Weak(stream: stream)
        } else {
            remove(ObjectIdentifier(stream))
        }
    }

    /// A stream stopped or went away: its input no longer counts.
    func remove(_ stream: ObjectIdentifier) {
        guard pending.removeValue(forKey: stream) != nil else { return }
        if !busy {
            pending = [:]
            wake()
        }
    }

    /// The connection came up or went down. Down, every waiter returns.
    func connection(_ up: Bool) {
        guard up != connected else { return }
        connected = up
        if !up { wake() }
    }

    private func wake() {
        let w = waiters
        waiters = [:]
        for (_, c) in w { c.resume() }
    }

    /// Returns once no stream has input on its way, at once if none has. It also returns when
    /// the connection is down and when the task is cancelled: the caller checks both itself.
    public func idle() async {
        // A stream's input can look gone for a moment inside one turn (an item that is sent
        // again goes back in the queue), so a woken waiter looks again.
        while busy, connected, !Task.isCancelled { await wait() }
    }

    private func wait() async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                if !busy || !connected || Task.isCancelled { c.resume() } else { waiters[id] = c }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.waiters.removeValue(forKey: id)?.resume() }
        }
    }
}
