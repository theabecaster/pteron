import Foundation
import RexKit

/// How the server answered one of fit mode's calls.
enum FitClaimAnswer: Equatable {
    case done
    /// The request never reached the server, or the connection broke before its answer: it is
    /// asked again once the control connection is back (`FitClaimTransport.whenConnected`).
    case offline
    /// The session isn't attached on this connection yet (`conflict` right after a reconnect,
    /// before the resync attaches it again): asked again shortly.
    case notYet
    /// The server has no such method: a server from before block ownership, where a resize
    /// applies at once and there is nothing to own.
    case unsupported
    /// The server said no.
    case refused
}

/// The three server calls of fit mode, one at a time.
@MainActor
protocol FitClaimTransport: AnyObject {
    /// `session.own_block` (take): this client decides the pane's size. Since block ownership a
    /// resize from a client that doesn't own the pane is kept for later and applies only once it
    /// becomes the owner, so a claim that skips this never changes the pane.
    func own() async -> FitClaimAnswer
    /// `terminal.resize`: the pane on the Mac changes size.
    func resize(cols: Int, rows: Int) async -> FitClaimAnswer
    /// `session.disown_block`: the Mac gets its size back.
    func disown() async
    /// Calls `body` once, the next time the control connection is connected.
    func whenConnected(_ body: @escaping @MainActor () -> Void)
}

/// Whether fit mode's resize has to be sent. Pure: `FitClaim` asks.
///
/// A resize to the size the pane already has is not sent: the program would be told of a
/// size it has, and the pane's fence would wait for the call. What counts is the size the
/// server last reported in the pane's stream, never the size this client last sent: another
/// client may have resized the pane since, and then the resize is needed.
enum FitResize {
    /// Whether a resize to `target` goes out. `reported`: the size the server last reported on
    /// a stream that is live; nil when none is known (no report yet, or the stream is down and
    /// the pane may have changed unseen), and then the resize always goes.
    static func sends(target: (Int, Int), reported: (Int, Int)?) -> Bool {
        guard let reported else { return true }
        return reported != target
    }

    /// The server's latest word on the pane's size, if there is one: the size its stream last
    /// reported, while the stream has reported since its last fresh start (`said`) and is up
    /// (`live`). A stream that is down or parked may have missed a resize.
    static func reported(_ size: (Int, Int), said: Bool, live: Bool) -> (cols: Int, rows: Int)? {
        said && live ? (size.0, size.1) : nil
    }

    /// Whether a size the server reports calls for the resize that was left out: the pane was
    /// taken to be at `target` on the server's word, and the server now says another size.
    static func sendsAfterAll(target: (Int, Int), reported: (Int, Int), leftOut: Bool) -> Bool {
        leftOut && reported != target
    }
}

/// Fit mode's claim on one pane: own it, resize it, give it back.
///
/// The calls are slow (a round trip each) and the reasons to make them change meanwhile: the
/// layout moves again, the app goes to the background, the pane is closed or swiped away, the
/// user switches to mirror. A resize that lands after any of those changes the Mac's pane for a
/// phone that isn't showing it. So nothing here is a task that can be cancelled too late. There
/// is one goal (a size, or nothing), and one worker that makes one call at a time and looks at
/// the goal again after every call:
///
/// - a size is wanted: `own`, then `resize` to the size wanted *now*;
/// - nothing is wanted: `disown`, if the pane is owned.
///
/// So a release during `own` skips the resize and disowns once `own` has returned (never before:
/// a disown that overtook the own would leave the pane claimed for good), a new size during a
/// resize is one more resize, and after `release()` no resize is ever sent.
///
/// `own` goes out with the first request and with every request that reasserts the claim (the
/// pane came on screen, the app came back, the user tapped to fit): another client may have
/// taken the pane meanwhile, and a resize from a client that isn't the owner only waits on the
/// server. A refit of a pane that stayed on screen (the keyboard, a fold) resizes under the
/// claim it has.
///
/// A resize to the size the server last reported is left out (`FitResize`): the take alone is
/// the claim. If the server then reports another size, the resize goes after all
/// (`serverReported`), so the pane always ends at the size wanted.
///
/// Nothing is answered with `onClaimed` that the server didn't answer: a call the connection
/// lost is asked again, `own` first, once it is back, and one the server refused ends the
/// claim (`onRefused`).
@MainActor
final class FitClaim {
    /// Layout settles (fold, rotation, keyboard animation) before a size is claimed.
    static let settleDelay: UInt64 = 120_000_000
    /// How often a call is asked again while the session isn't attached yet (`notYet`), each
    /// after `notYetPause`.
    static let notYetLimit = 8

    private enum Goal: Equatable {
        case nothing
        case size(Int, Int)
    }

    private let transport: any FitClaimTransport
    /// Waits out the settle delay. Tests return at once, or when they choose.
    private let settle: @MainActor () async -> Void
    /// Waits between `notYet` answers (250 ms). Tests return at once.
    private let notYetPause: @MainActor () async -> Void

    private var goal = Goal.nothing
    /// `own` went out and no `disown` after it.
    private var owned = false
    /// The size in place while owned: the last resize that was sent, or the size the server
    /// reported when a resize to it was left out (`leftOut`).
    private var applied: (Int, Int)? { didSet { if applied == nil { leftOut = false } } }
    /// `applied` is the server's word, not a resize of ours.
    private var leftOut = false
    private var working = false
    /// Counts requests and releases: a request that settled after a later one, or after a
    /// release, does nothing.
    private var generation = 0
    /// A request settled and has not been answered with `onClaimed` yet.
    private var unanswered = false
    /// The newest request still waiting out the settle delay.
    private var settling: (cols: Int, rows: Int)?
    /// The next size goes out after an `own`, even if this client owned the pane before.
    private var needsOwn = false
    /// A reasserting request is settling, maybe superseded by a newer one: `needsOwn` once it
    /// settles.
    private var reassertSettling = false
    /// The server has no `session.own_block` (from before block ownership): resizes only.
    private var ownMissing = false
    /// A call is to be asked again later (the connection is back, or after `notYetPause`).
    private var waiting = false
    /// Run once no call is out (`whenIdle`).
    private var idleWaiters: [@MainActor () -> Void] = []
    /// `notYet` answers in a row.
    private var notYetCount = 0

    /// The pane has the size asked for: owned, resized, and still wanted.
    var onClaimed: ((_ cols: Int, _ rows: Int) -> Void)?
    /// The server refused the claim: the pane isn't this client's to size.
    var onRefused: (() -> Void)?
    /// The size the server last reported for the pane on a stream that is live, nil when none
    /// is known (`FitResize.sends`). Without it every resize is sent.
    var reported: (() -> (cols: Int, rows: Int)?)?

    init(transport: any FitClaimTransport,
         settle: @escaping @MainActor () async -> Void = { try? await Task.sleep(nanoseconds: FitClaim.settleDelay) },
         notYetPause: @escaping @MainActor () async -> Void = { try? await Task.sleep(nanoseconds: 250_000_000) }) {
        self.transport = transport
        self.settle = settle
        self.notYetPause = notYetPause
    }

    /// True between the first call for a size and the release.
    var isClaiming: Bool { goal != .nothing }

    /// A request is waiting out the settle delay: a newer one would supersede it.
    var isSettling: Bool { settling != nil }

    /// The size in place was not sent: the server had it already (`FitResize`). No echo of a
    /// resize of ours will come for it.
    var resizeLeftOut: Bool { leftOut }

    /// The newest size asked for: the one settling, else the goal. Nil when nothing is wanted.
    /// Find's fit hold keeps the grid at this size while the keyboard rises.
    var wanted: (cols: Int, rows: Int)? {
        if let settling { return settling }
        if case .size(let c, let r) = goal { return (c, r) }
        return nil
    }

    /// Asks for the pane at this size, once the layout has settled. The newest request wins.
    /// `reassert`: take the pane again (`own`) and send the size even if it is the one in place,
    /// because another client may have taken the pane since.
    func request(cols: Int, rows: Int, reassert: Bool = false) {
        generation += 1
        let mine = generation
        settling = (cols, rows)
        // Kept when a newer request supersedes this one while it settles (the keyboard moves
        // right after the pane came on screen): the take still goes first.
        if reassert { reassertSettling = true }
        Task { [weak self, settle] in
            await settle()
            guard let self, self.generation == mine else { return }
            self.settling = nil
            self.goal = .size(cols, rows)
            self.unanswered = true
            if self.reassertSettling {
                self.reassertSettling = false
                self.needsOwn = true
            }
            self.work()
        }
    }

    /// Gives the pane back (`stop()`, the background, mirror mode). A request still settling is
    /// dropped; a call in flight finishes first, and no resize follows it.
    func release() {
        generation += 1
        settling = nil
        reassertSettling = false
        goal = .nothing
        work()
    }

    /// The pane left the screen but may be back in a moment (a fold moves it): nothing new is
    /// started. A size already in place stays; a claim not yet resized is given up.
    func pause() {
        generation += 1
        settling = nil
        reassertSettling = false
        goal = applied.map { .size($0.0, $0.1) } ?? .nothing
        work()
    }

    /// Another client took the pane and resized it: it is no longer ours to resize. This client
    /// still leaves the line of clients that claimed it (`disown`, which changes nothing for the
    /// owner), so the pane never passes back to a phone that isn't asking for it, as it would
    /// when the owner gives it up.
    func lost() {
        generation += 1
        settling = nil
        reassertSettling = false
        goal = .nothing
        work()
    }

    /// Runs `body` once no call is out and none waits to be asked again: now if the worker is
    /// idle. The app in the background holds a task of the system's until a release has left
    /// (`BackgroundGrace`).
    func whenIdle(_ body: @escaping @MainActor () -> Void) {
        guard working || waiting else { return body() }
        idleWaiters.append(body)
    }

    private func becameIdle() {
        guard !working, !waiting, !idleWaiters.isEmpty else { return }
        let waiters = idleWaiters
        idleWaiters = []
        for body in waiters { body() }
    }

    /// The server gave the pane back to this client at this size (an owner whose connection
    /// dropped gets its panes back when it reconnects): it is claimed again without a call.
    func adopt(cols: Int, rows: Int) {
        generation += 1
        settling = nil
        reassertSettling = false
        goal = .size(cols, rows)
        unanswered = false
        guard !working else { return }  // the worker looks at the goal again after its call
        owned = true
        needsOwn = false
        applied = (cols, rows)
    }

    /// The server reported this size for the pane, and it is not another client's doing (the
    /// host judges that first). If a resize was left out on the server's word and the server
    /// now says another size, the resize is sent after all. Returns whether it will be.
    @discardableResult
    func serverReported(cols: Int, rows: Int) -> Bool {
        guard case .size(let c, let r) = goal, let a = applied, a == (c, r),
              FitResize.sendsAfterAll(target: (c, r), reported: (cols, rows), leftOut: leftOut) else { return false }
        applied = nil
        unanswered = true
        work()
        return true
    }

    private func work() {
        guard !working, !waiting else { return }
        working = true
        // Strong from here until the worker is done: a pane that goes away still disowns,
        // whether a call was in flight or the worker had not begun. The pane is freed as soon
        // as it is stopped, which can be before this task first runs.
        Task { await self.run() }
    }

    private func run() async {
        defer {
            working = false
            becameIdle()
        }
        while true {
            switch goal {
            case .size(let cols, let rows):
                if !owned || needsOwn {
                    // Owned from here on, whatever the answer: a request the connection lost may
                    // still have made this client the owner, and then a release gives it back.
                    owned = true
                    needsOwn = false
                    applied = nil
                    if ownMissing { continue }
                    let answer = await transport.own()
                    guard proceeds(after: answer, own: true) else { return }
                    continue  // the goal may have changed during the call
                }
                if let a = applied, a == (cols, rows) {
                    // Already this size: nothing to send, but a request still gets its answer.
                    if unanswered {
                        unanswered = false
                        onClaimed?(cols, rows)
                    }
                    return
                }
                if !FitResize.sends(target: (cols, rows), reported: reported?().map { ($0.cols, $0.rows) }) {
                    // The pane has this size on the server: nothing to send. The request gets
                    // its answer on the next turn of the loop.
                    applied = (cols, rows)
                    leftOut = true
                    continue
                }
                applied = (cols, rows)
                leftOut = false
                let answer = await transport.resize(cols: cols, rows: rows)
                guard proceeds(after: answer, own: false) else { return }
                if answer == .done, goal == .size(cols, rows), owned, !needsOwn {
                    unanswered = false
                    onClaimed?(cols, rows)
                }
            case .nothing:
                guard owned else { return }
                owned = false
                applied = nil
                await transport.disown()
            }
        }
    }

    /// Acts on a call's answer. Returns whether the worker goes on now.
    private func proceeds(after answer: FitClaimAnswer, own: Bool) -> Bool {
        if answer != .notYet { notYetCount = 0 }
        switch answer {
        case .done:
            return true
        case .unsupported:
            // An older server: a resize applies at once there, so the claim is the resize alone.
            guard own else { return refuse() }
            ownMissing = true
            return true
        case .offline:
            // Asked again, `own` first, once the connection is back: the pane may have passed
            // to another client while this one was away. No size is known to be in place.
            needsOwn = true
            applied = nil
            guard goal != .nothing else { return true }
            waiting = true
            transport.whenConnected { [weak self] in self?.resume() }
            return false
        case .notYet:
            notYetCount += 1
            guard notYetCount <= Self.notYetLimit else { return refuse() }
            needsOwn = true
            applied = nil
            guard goal != .nothing else { return true }
            waiting = true
            Task { [weak self, notYetPause] in
                await notYetPause()
                self?.resume()
            }
            return false
        case .refused:
            return refuse()
        }
    }

    private func resume() {
        waiting = false
        work()
    }

    /// The pane isn't this client's to size: the claim ends, and the worker gives back what it
    /// may have taken.
    private func refuse() -> Bool {
        notYetCount = 0
        let wanted = goal != .nothing
        generation += 1
        settling = nil
        reassertSettling = false
        goal = .nothing
        unanswered = false
        if wanted { onRefused?() }
        return true
    }
}

/// What a fitted pane on screen, with nothing on its way, does when it looks at its grid
/// (`TerminalHost.checkFit`). The server's grid drawn 1:1 in a pane narrower than it is cut at the
/// right edge, mid-word, the input line too; that must never stay.
enum FitCheck: Equatable {
    /// The server has the size this pane fits, or claimed.
    case fine
    /// Another client has the pane: a claim was answered and the server kept another size (it
    /// keeps a non-owner's resize for later), or the session's view names another owner. The
    /// pane shows "Resized elsewhere" and the server's grid scaled, and doesn't fight over it.
    case elsewhere
    /// Nothing is claimed although the pane shows another grid: no path should leave it so.
    /// It claims once, with a take; if that doesn't hold either, `elsewhere`.
    case claim

    static func verdict(claimed: (Int, Int)?, server: (Int, Int), fits: (Int, Int), foreignOwner: Bool,
                        claimedOnce: Bool) -> FitCheck {
        if let c = claimed { return server == c && !foreignOwner ? .fine : .elsewhere }
        guard server != fits || foreignOwner else { return .fine }
        return claimedOnce ? .elsewhere : .claim
    }
}

/// Fit mode's calls, held back until the pane's session is attached on the control connection.
///
/// The server refuses them until then. Right after a reconnect that started a new client the
/// app attaches its sessions again, and a take that left in between was answered `conflict`
/// when it came before the app's `session.bootstrap`, and a plain `bad_request` when it came
/// between that and the attach. The second reads as a real no: the claim ended, and the pane
/// stayed at another client's size with the chip up, its last rows under the keyboard. So no
/// call leaves before the attach is answered (`RexControl.mayCall`).
///
/// A wait that ends without the attach (the connection dropped, the app went to the
/// background, or the cap passed) answers `notYet`: the claim asks again after its pause and
/// gives up at its limit, as for a `conflict`. A disown that can't leave is not sent: the
/// server has nothing of this client's to give back until it takes the pane again.
@MainActor
final class AttachGatedFitTransport: FitClaimTransport {
    private let inner: any FitClaimTransport
    /// Whether a call may leave now; waits for the session's attach when it may not yet.
    private let mayCall: @MainActor () async -> Bool

    init(_ inner: any FitClaimTransport, mayCall: @escaping @MainActor () async -> Bool) {
        self.inner = inner
        self.mayCall = mayCall
    }

    /// The gate of a pane's stream: its session on its control connection.
    convenience init(stream: TerminalStream) {
        self.init(StreamFitTransport(stream: stream)) { [weak stream] in
            guard let stream else { return false }
            return await stream.control.mayCall(attachedTo: stream.sessionID)
        }
    }

    func own() async -> FitClaimAnswer {
        guard await mayCall() else { return .notYet }
        return await inner.own()
    }

    func resize(cols: Int, rows: Int) async -> FitClaimAnswer {
        guard await mayCall() else { return .notYet }
        return await inner.resize(cols: cols, rows: rows)
    }

    func disown() async {
        guard await mayCall() else { return }
        await inner.disown()
    }

    func whenConnected(_ body: @escaping @MainActor () -> Void) { inner.whenConnected(body) }
}

/// The real calls, over the pane's stream.
@MainActor
final class StreamFitTransport: FitClaimTransport {
    private let stream: TerminalStream

    init(stream: TerminalStream) { self.stream = stream }

    func own() async -> FitClaimAnswer {
        #if DEBUG
        // One line per take, to count them (docs/debug-args.md).
        NSLog("FIT_OWN %@", stream.blockID)
        #endif
        return await Self.answer {
            try await self.stream.control.call("session.own_block",
                                               ["session_id": self.stream.sessionID, "block_ids": [self.stream.blockID], "mode": "take"])
        }
    }

    func resize(cols: Int, rows: Int) async -> FitClaimAnswer {
        #if DEBUG
        // One line per resize sent, to count them (docs/debug-args.md).
        NSLog("FIT_RESIZE %@ %dx%d", stream.blockID, cols, rows)
        #endif
        return await Self.answer {
            try await self.stream.control.blockCall("com.superlogical.terminal.resize", session: self.stream.sessionID,
                                                    block: self.stream.blockID, args: ["columns": cols, "rows": rows])
        }
    }

    func disown() async { await stream.release() }

    func whenConnected(_ body: @escaping @MainActor () -> Void) {
        stream.control.observeConnected { body(); return false }
    }

    private static func answer(_ call: @MainActor () async throws -> JSONObject) async -> FitClaimAnswer {
        do {
            _ = try await call()
            return .done
        } catch let e as RexError {
            return FitClaimAnswer(e)
        } catch {
            return .offline
        }
    }
}

extension FitClaimAnswer {
    /// What a call's error means for the claim.
    init(_ e: RexError) {
        switch e.code {
        // A server from before block ownership (`revision_too_low` is known without asking, so
        // it is never sent). Servers older than `method_not_found` say `not_found` for a
        // missing method; the pane's own block exists, it streams.
        case "method_not_found", "revision_too_low", "not_found": self = .unsupported
        // Never sent, or a local error: the connection broke after the request left.
        case _ where e.neverSent: self = .offline
        case "client": self = .offline
        case "conflict": self = .notYet
        default: self = .refused
        }
    }
}
