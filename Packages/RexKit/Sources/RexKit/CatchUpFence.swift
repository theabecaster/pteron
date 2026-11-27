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
///    resize came back in the stream, while the program redraws for its new size. When that
///    resize changed the size (`resizeEchoed(changedSize:)`, `expectRedraw`) over a screen the
///    user saw, the quiet before the redraw's first byte is `redrawStart` (700 ms): an agent lays
///    out its whole transcript before it reprints it, and a key must not land in that reprint;
/// 4. the sink has parsed everything it was given (`drained`), and nothing came meanwhile.
///
/// A program that never pauses would keep 3 from ever holding, and the pane could not be typed
/// into at all. So `cap` (300 ms) after 1 and 2 hold, the fence comes down once the sink has
/// parsed what it has: the screen then moves as the program writes, as it does on any busy
/// pane. While it waits for a redraw for our resize the cap is `redrawCap` (2.5 s), counted
/// from the resize.
///
/// **Keys and pastes while it is up** (`hold`) are kept, already encoded, in order.
/// - Down with nothing received since it went up, over a screen the user saw (`exact`): they
///   go out, in order, through the stream's one queue.
/// - Down after something came, over a screen the user saw: they go the same way only if the
///   screen as parsed is the one on show when the fence went up, with the same cursor and the
///   same modes (`sameScreen`): a program that only redrew, for our resize or for nothing,
///   shows what the user typed at. Otherwise they are dropped and the user is told once
///   (`onDropped`, with why: the screen changed, or the stream was not back in time). Bytes
///   encoded under the old screen's modes are never sent to a new one.
///   A pane that shows nothing yet never sends held keys.
/// - They live `heldLife` (1 s) at most, counted from the first one, or until the redraw's cap
///   while the fence waits for a redraw for our resize; then they are dropped the same way.
///   After a drop, every later key of the same fence is dropped too, silently: the rest of a
///   line whose start was dropped must not arrive alone.
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
        /// Our own resize changed the pane's size: how long the program may take to begin its
        /// redraw. An agent lays out its whole transcript first (400 ms seen for a long one).
        var redrawStart: Duration = .milliseconds(700)
        /// The cap once our own resize changed the size, from the moment it came back: a long
        /// transcript reprinted over a slow link.
        var redrawCap: Duration = .milliseconds(2500)
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
    /// Whether the screen as parsed is the one on show when the fence went up, with the same
    /// modes: the sink kept that screen on show, so keys typed meanwhile were typed at it.
    var sameScreen: (@MainActor () -> Bool)?

    private(set) var isUp = false
    /// A fit claim is on its way: its resize will change the screen.
    private(set) var claimPending = false
    /// The stream is live again and has delivered what it had to (see "Down", 1).
    private var hasArrived = false
    /// Nothing came since the fence went up, over a screen the user saw.
    private var exact = false
    /// The fence went up over a screen the user saw: keys are held even after output came, and
    /// go if the screen comes back the same (`sameScreen`).
    private var overScreen = false
    /// Our own resize came back in the stream since the fence went up.
    private var echoed = false
    /// That resize changed the pane's size: the program redraws for it.
    private var resized = false
    /// Output came since that resize: the redraw has begun.
    private var redrawing = false
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
    /// Counts quiet waits: one that was started over gives way to the newer one.
    private var quietSerial = 0
    /// Something came since the fence went up.
    private var changedSince = false
    /// Counts the caps armed: only the newest lowers the fence (conditions 1 and 2 began to
    /// hold again, or our resize changed the size).
    private var capSerial = 0
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
        overScreen = exact
        echoed = false
        resized = false
        redrawing = false
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

    /// A message came, or something the stream can't say more of: the screen may no longer be
    /// the one the user saw.
    func changed() {
        guard isUp else { return }
        exact = false
        changedSince = true
        // Keys held for a screen that changed go only if it comes back the same (`sameScreen`).
        if !held.isEmpty, !overScreen { drop() }
        noteActivity()
    }

    /// The pane is gone: held keys can never be sent, and the user is told.
    func paneGone() {
        guard isUp else { return }
        exact = false
        changedSince = true
        if !held.isEmpty { drop() }
    }

    /// The program wrote. After our resize changed the size, its redraw has begun: the long
    /// wait for it to begin gives way to the redraw's quiet at once.
    func output() {
        guard isUp else { return }
        let began = resized && !redrawing
        if began { redrawing = true }
        changed()
        if began, ready { armQuiet(restart: true) }
    }

    /// Our own resize came back in the stream.
    ///
    /// `changedSize`: the pane had another size before it, so the program redraws (an agent
    /// reprints its whole transcript, often after a pause to lay it out). The fence waits for
    /// that redraw to begin and settle, up to `redrawCap`, so no key lands in the middle of it.
    func resizeEchoed(changedSize: Bool = false) {
        guard isUp else { return }
        echoed = true
        changed()
        if changedSize { awaitRedraw() }
    }

    /// Our resize was applied while the fence is up and may have changed the size, though the
    /// stream can't show it: a fresh stream's snapshot already has the new size, and the
    /// program's redraw comes after it. Waits for that redraw as for one the echo showed. A
    /// resize to the size the pane had costs `redrawStart` once, with nothing lost.
    func expectRedraw() {
        guard isUp, !resized else { return }
        awaitRedraw()
    }

    /// Only over a screen the user saw: a pane that opens has nothing to keep still, and its
    /// keys are not held.
    private func awaitRedraw() {
        guard overScreen else { return }
        resized = true
        redrawing = false
        noteActivity()
        // The cap counts from here, at its own length: a pane that never goes quiet still
        // comes down.
        if ready { armCap() }
    }

    /// The fence waits for the program's redraw for our resize (`expectRedraw`).
    var awaitsRedraw: Bool { isUp && resized }

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
        guard exact || overScreen, !dropped else {
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
            // While the program redraws for our resize the redraw's cap bounds the wait: the
            // keys go when it is over, if the screen is the same.
            while let self, self.epoch == mine, self.isUp, self.resized, self.ready {
                await sleep(self.timing.redrawCap)
            }
            guard let self, self.epoch == mine, self.isUp, !self.held.isEmpty else { return }
            self.drop()
        }
    }

    // MARK: Coming down

    private var ready: Bool { hasArrived && !claimPending }

    private func noteActivity() {
        activity += 1
        let ready = ready
        if ready, !wasReady { armCap() }
        wasReady = ready
        if ready { armQuiet() }
    }

    /// One wait at a time: it starts over while bytes keep coming. `restart`: a new wait takes
    /// the place of the one asleep (the redraw began during the long wait for it).
    private func armQuiet(restart: Bool = false) {
        guard restart || quietEpoch != epoch else { return }
        quietEpoch = epoch
        quietSerial += 1
        let mine = epoch, serial = quietSerial, sleep = self.sleep
        Task { [weak self] in
            while true {
                guard let self, self.epoch == mine, self.isUp, self.ready, self.quietSerial == serial else { break }
                let seen = self.activity
                await sleep(self.quietWait)
                guard self.epoch == mine, self.isUp, self.ready, self.quietSerial == serial else { break }
                guard self.activity == seen else { continue }
                self.quietEpoch = -1
                self.lowerWhenDrained(epoch: mine, activity: seen)
                return
            }
            // Only this fence's own, newest wait gives the place back: a newer one has armed its own.
            if let self, self.quietEpoch == mine, self.quietSerial == serial { self.quietEpoch = -1 }
        }
    }

    /// The quiet that lowers the fence: longer once our resize came back, while the program
    /// redraws, and longest until that redraw has begun.
    private var quietWait: Duration {
        if resized, !redrawing { return timing.redrawStart }
        return echoed ? timing.resizeQuiet : timing.quiet
    }

    private func armCap() {
        capSerial += 1
        let mine = epoch, serial = capSerial, sleep = self.sleep, cap = resized ? timing.redrawCap : timing.cap
        Task { [weak self] in
            await sleep(cap)
            guard let self, self.epoch == mine, self.isUp, self.ready, self.capSerial == serial else { return }
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
        // Over a screen that changed, the keys go only if it came back the same: a program that
        // redrew for a new size, or for the size it had, shows what the user typed at.
        let same = !keys.isEmpty && !exact && overScreen && !dropped && (sameScreen?() ?? false)
        let send = (exact || same) && !dropped && !keys.isEmpty
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
