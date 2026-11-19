import Foundation
import RexKit

/// The three server calls of fit mode, one at a time.
@MainActor
protocol FitClaimTransport: AnyObject {
    /// `session.own_block` (take): this client decides the pane's size.
    func own() async
    /// `terminal.resize`: the pane on the Mac changes size.
    func resize(cols: Int, rows: Int) async
    /// `session.disown_block`: the Mac gets its size back.
    func disown() async
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
/// - a size is wanted: `own` (once), then `resize` to the size wanted *now*;
/// - nothing is wanted: `disown`, if the pane is owned.
///
/// So a release during `own` skips the resize and disowns once `own` has returned (never before:
/// a disown that overtook the own would leave the pane claimed for good), a new size during a
/// resize is one more resize, and after `release()` no resize is ever sent.
@MainActor
final class FitClaim {
    /// Layout settles (fold, rotation, keyboard animation) before a size is claimed.
    static let settleDelay: UInt64 = 120_000_000

    private enum Goal: Equatable {
        case nothing
        case size(Int, Int)
    }

    private let transport: any FitClaimTransport
    /// Waits out the settle delay. Tests return at once, or when they choose.
    private let settle: @MainActor () async -> Void

    private var goal = Goal.nothing
    /// `own` went out and no `disown` after it.
    private var owned = false
    /// The size of the last resize that was sent while owned.
    private var applied: (Int, Int)?
    private var working = false
    /// Counts requests and releases: a request that settled after a later one, or after a
    /// release, does nothing.
    private var generation = 0
    /// A request settled and has not been answered with `onClaimed` yet.
    private var unanswered = false
    /// The newest request still waiting out the settle delay.
    private var settling: (cols: Int, rows: Int)?

    /// The pane has the size asked for: owned, resized, and still wanted.
    var onClaimed: ((_ cols: Int, _ rows: Int) -> Void)?

    init(transport: any FitClaimTransport,
         settle: @escaping @MainActor () async -> Void = { try? await Task.sleep(nanoseconds: FitClaim.settleDelay) }) {
        self.transport = transport
        self.settle = settle
    }

    /// True between the first call for a size and the release.
    var isClaiming: Bool { goal != .nothing }

    /// A request is waiting out the settle delay: a newer one would supersede it.
    var isSettling: Bool { settling != nil }

    /// The newest size asked for: the one settling, else the goal. Nil when nothing is wanted.
    /// Find's fit hold keeps the grid at this size while the keyboard rises.
    var wanted: (cols: Int, rows: Int)? {
        if let settling { return settling }
        if case .size(let c, let r) = goal { return (c, r) }
        return nil
    }

    /// Asks for the pane at this size, once the layout has settled. The newest request wins.
    func request(cols: Int, rows: Int) {
        generation += 1
        let mine = generation
        settling = (cols, rows)
        Task { [weak self, settle] in
            await settle()
            guard let self, self.generation == mine else { return }
            self.settling = nil
            self.goal = .size(cols, rows)
            self.unanswered = true
            self.work()
        }
    }

    /// Gives the pane back (`stop()`, the background, mirror mode). A request still settling is
    /// dropped; a call in flight finishes first, and no resize follows it.
    func release() {
        generation += 1
        settling = nil
        goal = .nothing
        work()
    }

    /// The pane left the screen but may be back in a moment (a fold moves it): nothing new is
    /// started. A size already in place stays; a claim not yet resized is given up.
    func pause() {
        generation += 1
        settling = nil
        goal = applied.map { .size($0.0, $0.1) } ?? .nothing
        work()
    }

    /// Another client took the pane and resized it: it is no longer ours to resize or to give
    /// back.
    func lost() {
        generation += 1
        settling = nil
        goal = .nothing
        // With a call in flight the worker gives back whatever that call claimed.
        guard !working else { return }
        owned = false
        applied = nil
    }

    private func work() {
        guard !working else { return }
        working = true
        Task { [weak self] in
            // Strong while it runs: a pane that goes away mid-call still disowns.
            guard let self else { return }
            await self.run()
        }
    }

    private func run() async {
        defer { working = false }
        while true {
            switch goal {
            case .size(let cols, let rows):
                if !owned {
                    owned = true
                    await transport.own()
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
                applied = (cols, rows)
                await transport.resize(cols: cols, rows: rows)
                if goal == .size(cols, rows), owned {
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
}

/// The real calls, over the pane's stream.
@MainActor
final class StreamFitTransport: FitClaimTransport {
    private let stream: TerminalStream

    init(stream: TerminalStream) { self.stream = stream }

    func own() async {
        _ = try? await stream.control.call("session.own_block",
                                           ["session_id": stream.sessionID, "block_ids": [stream.blockID], "mode": "take"])
    }

    func resize(cols: Int, rows: Int) async {
        #if DEBUG
        // One line per resize sent, to count them (docs/debug-args.md).
        NSLog("FIT_RESIZE %@ %dx%d", stream.blockID, cols, rows)
        #endif
        _ = try? await stream.control.blockCall("com.superlogical.terminal.resize", session: stream.sessionID,
                                                block: stream.blockID, args: ["columns": cols, "rows": rows])
    }

    func disown() async { await stream.release() }
}
