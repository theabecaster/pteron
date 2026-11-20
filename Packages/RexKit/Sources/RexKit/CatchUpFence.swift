import Foundation

/// Keeps input away from a program state the user has not seen.
///
/// A pane's screen is the user's picture of the program. Whenever that picture may be behind
/// (a pane that just opened, a stream that resumes after a drop or a wake, a pane that comes
/// back from the park, a fresh start), the fence is up, and it comes down only when the stream
/// has caught up. Input has no sequence number and is never sent twice, so a key typed at a
/// stale screen can't be taken back: it is held, and sent only if the screen turned out to be
/// exact.
///
/// **Up** (`raise`): the stream raises it; raising it again while it is up changes nothing but
/// the wait for the stream.
///
/// **Down**, when all of these hold:
/// 1. the stream has arrived (`arrived`): the WELCOME of a resume, the end of a fresh stream's
///    snapshot, or the pong of a wake;
/// 2. no fit claim is on its way (`claimPending`);
/// 3. no byte and no message came for `quiet` (40 ms), or for `resizeQuiet` (60 ms) once our own
///    resize came back in the stream, while the program redraws for its new size;
/// 4. the sink has parsed everything it was given (`drained`), and nothing came meanwhile.
///
/// A program that never pauses would keep 3 from ever holding, and the pane could not be typed
/// into at all. So `cap` (300 ms) after 1 and 2 hold, the fence comes down once the sink has
/// parsed what it has: the screen then moves as the program writes, as it does on any busy
/// pane.
///
/// **Keys and pastes while it is up** (`hold`) are kept, already encoded, in order.
/// - Down with nothing received since it went up, over a screen the user saw (`exact`): they
///   go out, in order, through the stream's one queue.
/// - Otherwise they are dropped, as soon as something comes, and the user is told once
///   (`onDropped`, with why: the screen changed, or the stream was not back in time). Bytes
///   encoded under the old screen's modes are never sent to a new one.
///   A pane that shows nothing yet, or a fresh snapshot, never sends held keys.
/// - They live `heldLife` (1 s) at most, counted from the first one; then they are dropped
///   the same way. After a drop, every later key of the same fence is dropped too, silently:
///   the rest of a line whose start was dropped must not arrive alone.
///
/// **Input queued before the fence went up** and not yet sent (typed without a connection, or
/// behind a request that is out) waits for it too, in the stream's queue: sent when the fence
/// comes down over an exact screen, dropped with the same notice otherwise (`onStale`).
///
/// **Everything else** (mouse reports, key-bound server actions, forwarded keys, typed paths)
/// is the caller's to drop while `isUp`; `noteDropped()` tells the user, once per fence.
///
/// Every wait goes through `sleep`, so tests skip them.
@MainActor
final class CatchUpFence {
    struct Timing: Sendable {
        var quiet: Duration = .milliseconds(40)
        var resizeQuiet: Duration = .milliseconds(60)
        var cap: Duration = .milliseconds(300)
        var heldLife: Duration = .seconds(1)
    }

    var timing = Timing()
    var sleep: @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    /// The fence went up or came down.
    var onChange: (@MainActor (Bool) -> Void)?
    /// Held keys to send now, in order.
    var onFlush: (@MainActor ([UInt8]) -> Void)?
    /// Why input was dropped.
    enum Drop: Sendable, Equatable {
        /// Output, a resize or a snapshot came: the screen is another one.
        case changed
        /// Nothing came, but the stream was not back in time, or the pane had no screen yet.
        case waiting
    }

    /// Input was dropped: at most once per fence.
    var onDropped: (@MainActor (Drop) -> Void)?
    /// The fence comes down over a screen that changed: input queued before it went up is the
    /// stream's to drop. True when it dropped any.
    var onStale: (@MainActor () -> Bool)?
    /// Asks the sink to call back once it has parsed everything it was given so far.
    var drained: (@MainActor (@escaping @MainActor () -> Void) -> Void)?

    private(set) var isUp = false
    /// A fit claim is on its way: its resize will change the screen.
    private(set) var claimPending = false
    /// The stream is live again and has delivered what it had to (see "Down", 1).
    private var hasArrived = false
    /// Nothing came since the fence went up, over a screen the user saw.
    private var exact = false
    /// Our own resize came back in the stream since the fence went up.
    private var echoed = false
    private var held: [UInt8] = []
    /// Something was dropped during this fence: nothing more is held, and the user was told.
    private var dropped = false
    private var waiters: [@MainActor () -> Void] = []

    /// Counts fences: a wait begun under an older one does nothing.
    private var epoch = 0
    /// Counts bytes, messages and changes of the conditions: a quiet wait that sees another
    /// value starts over.
    private var activity = 0
    /// The fence whose quiet wait is running. A wait left over from an older fence, still
    /// asleep, doesn't stand in for this one's.
    private var quietEpoch = -1
    /// Something came since the fence went up.
    private var changedSince = false
    /// Counts the times conditions 1 and 2 began to hold, for the cap.
    private var readySerial = 0
    private var wasReady = false
    /// The fence whose held keys have their expiry running.
    private var expiryEpoch = -1

    var heldCount: Int { held.count }

    // MARK: The stream's side

    /// The screen may be behind from now on. `exact`: the user saw a screen, and it may still
    /// be the program's (false for a pane that shows nothing yet).
    func raise(exact: Bool) {
        if isUp {
            // Still the same fence: the stream is on its way again.
            hasArrived = false
            noteActivity()
            return
        }
        epoch += 1
        isUp = true
        hasArrived = false
        self.exact = exact
        echoed = false
        dropped = false
        changedSince = false
        held.removeAll()
        wasReady = false
        activity += 1
        onChange?(true)
    }

    /// The stream has delivered its WELCOME (a resume), its snapshot (a fresh stream) or its
    /// pong (a wake): what comes now is what the program writes now.
    func arrived() {
        guard isUp, !hasArrived else { return }
        hasArrived = true
        noteActivity()
    }

    /// Output, a snapshot or a message came: the screen is no longer the one the user saw.
    func changed() {
        guard isUp else { return }
        exact = false
        changedSince = true
        // Keys held for the screen that just changed can never be sent.
        if !held.isEmpty { drop() }
        noteActivity()
    }

    /// Our own resize came back in the stream.
    func resizeEchoed() {
        guard isUp else { return }
        echoed = true
        changed()
    }

    /// The host asked for a fit claim (true), or the claim ended: resized, given up or lost.
    func setClaimPending(_ pending: Bool) {
        guard pending != claimPending else { return }
        claimPending = pending
        if isUp { noteActivity() }
    }

    /// The stream is over or parked: the fence is gone with everything it held, and nobody is
    /// told. Work that waited for it (`whenDown`) is dropped.
    func reset() {
        epoch += 1
        held.removeAll()
        waiters.removeAll()
        dropped = false
        guard isUp else { return }
        isUp = false
        onChange?(false)
    }

    // MARK: Input

    /// Takes typed bytes while the fence is up. False when it is down: the caller sends them.
    func hold(_ bytes: [UInt8]) -> Bool {
        guard isUp else { return false }
        // A pane that shows nothing has no screen to type at; after a drop the rest goes too.
        guard exact, !dropped else {
            drop()
            return true
        }
        held.append(contentsOf: bytes)
        armExpiry()
        return true
    }

    /// The caller dropped input because the fence is up (an action bound to a key, say).
    func noteDropped() {
        guard isUp else { return }
        drop()
    }

    /// Runs `body` now if the fence is down, else when it comes down. Never if the stream is
    /// stopped or parked first.
    func whenDown(_ body: @escaping @MainActor () -> Void) {
        guard isUp else { return body() }
        waiters.append(body)
    }

    private func drop() {
        held.removeAll()
        guard !dropped else { return }
        dropped = true
        onDropped?(changedSince ? .changed : .waiting)
    }

    private func armExpiry() {
        guard expiryEpoch != epoch else { return }
        expiryEpoch = epoch
        let mine = epoch, sleep = self.sleep, life = timing.heldLife
        Task { [weak self] in
            await sleep(life)
            guard let self, self.epoch == mine, self.isUp, !self.held.isEmpty else { return }
            self.drop()
        }
    }

    // MARK: Coming down

    private var ready: Bool { hasArrived && !claimPending }

    private func noteActivity() {
        activity += 1
        let ready = ready
        if ready, !wasReady {
            readySerial += 1
            armCap()
        }
        wasReady = ready
        if ready { armQuiet() }
    }

    /// One wait at a time: it starts over while bytes keep coming.
    private func armQuiet() {
        guard quietEpoch != epoch else { return }
        quietEpoch = epoch
        let mine = epoch, sleep = self.sleep
        Task { [weak self] in
            while true {
                guard let self, self.epoch == mine, self.isUp, self.ready else { break }
                let seen = self.activity
                await sleep(self.echoed ? self.timing.resizeQuiet : self.timing.quiet)
                guard self.epoch == mine, self.isUp, self.ready else { break }
                guard self.activity == seen else { continue }
                self.quietEpoch = -1
                self.lowerWhenDrained(epoch: mine, activity: seen)
                return
            }
            // Only this fence's own wait gives the place back: a newer fence has armed its own.
            if let self, self.quietEpoch == mine { self.quietEpoch = -1 }
        }
    }

    private func armCap() {
        let mine = epoch, serial = readySerial, sleep = self.sleep, cap = timing.cap
        Task { [weak self] in
            await sleep(cap)
            guard let self, self.epoch == mine, self.isUp, self.ready, self.readySerial == serial else { return }
            self.lowerWhenDrained(epoch: mine, activity: nil)
        }
    }

    /// Comes down once the sink has parsed what it was given. With `activity`, only if nothing
    /// came meanwhile (then the quiet wait starts over); without, whatever came (the cap).
    private func lowerWhenDrained(epoch mine: Int, activity seen: Int?) {
        let finish: @MainActor () -> Void = { [weak self] in
            guard let self, self.epoch == mine, self.isUp, self.ready else { return }
            if let seen, self.activity != seen {
                self.armQuiet()
                return
            }
            self.lower()
        }
        if let drained { drained(finish) } else { finish() }
    }

    private func lower() {
        let keys = held
        held.removeAll()
        let send = exact && !dropped && !keys.isEmpty
        if !keys.isEmpty, !send { drop() }
        // Keys typed at the old screen that had not left yet go the same way.
        if !exact, onStale?() == true, !dropped {
            dropped = true
            onDropped?(changedSince ? .changed : .waiting)
        }
        epoch += 1
        isUp = false
        onChange?(false)
        if send { onFlush?(keys) }
        let waiting = waiters
        waiters.removeAll()
        for body in waiting { body() }
    }
}
