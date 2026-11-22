import Foundation
import GhosttyVt
import RexKit
import Synchronization

// Predicted echo on the feed queue (docs/terminal.md, Predicted echo).
//
// The predictor lives here, next to the grid it judges, and runs only on the feed queue with
// `termLock` held: after every slice it recomputes the overlay against the rows just parsed and
// publishes it (`echoPublished`) in the same lock section, so `lockFrame` always latches an
// overlay with the rows it was computed for. After every drain batch it judges. The main thread
// only enqueues what it learned (keys, answers, settles, clears, readings). Nothing here writes
// to the terminal or sends a byte.

/// What the feed queue tells the pane about predicted echo. Delivered on the feed queue; the
/// handler hops.
enum GhosttyEchoEvent: Equatable, Sendable {
    /// The predictor wants an `input_mode` reading for this generation.
    case inputMode(generation: Int)
    /// A drawn guess waited 300 ms: the link is slow enough to mark guesses.
    case slow
    /// No drawn guess is unconfirmed any more (a held prompt click may go now).
    case settled
    /// The predictor is gone: the pane's level is `.off` and nothing was pending.
    case retired
}

/// The feed queue's echo state. `@unchecked Sendable`: `predictor`, `level` and `tickAt` are only
/// touched on the feed queue with `termLock` held; `clock` is set once, before the pane's first
/// level; the rest are atomics or a mutex.
final class GhosttyEchoState: @unchecked Sendable {
    var predictor: EchoPredictor?
    var level = EchoPaneLevel()
    var tickAt: Double?
    /// A test's clock for every predictor call, set before the first level. With one, no timer
    /// is armed: the test moves time and calls `echoTick()` itself.
    var clock: (@Sendable () -> Double)?
    var now: Double { clock?() ?? EchoClock.now }
    /// A drawn guess is unconfirmed (`EchoOverlay.unsettled`). Any thread.
    let unsettled = Atomic<Bool>(false)
    let handler = Mutex<(@Sendable (GhosttyEchoEvent) -> Void)?>(nil)
    /// Counters for tests: predictors made, overlay changes published.
    let created = Atomic<Int>(0)
    let publishes = Atomic<Int>(0)
}

extension GhosttyCore {
    /// Hears echo events, on the feed queue.
    var onEcho: (@Sendable (GhosttyEchoEvent) -> Void)? {
        get { echo.handler.withLock { $0 } }
        set { echo.handler.withLock { $0 = newValue } }
    }

    /// A drawn guess is unconfirmed: the real cursor lags the one on screen. Any thread.
    var echoUnsettled: Bool { echo.unsettled.load(ordering: .relaxed) }

    // MARK: From the main thread, in order with the bytes

    /// The pane's wanted level. Leaving `.off` makes the predictor, with the stream's
    /// acknowledgement state; a lower level applies once nothing is pending.
    func setEchoLevel(_ level: EchoLevel, ack: (lastSeq: Int, answeredThrough: Int, settled: Bool)) {
        enqueue { [self] in
            termLock.lock()
            let current = echo.level.want(level, pending: echo.predictor?.hasPending ?? false)
            if current != .off, echo.predictor == nil {
                echo.predictor = EchoPredictor(level: current, lastSeq: ack.lastSeq, answeredThrough: ack.answeredThrough,
                                               settled: ack.settled)
                echo.created.add(1, ordering: .relaxed)
            }
            var events: [GhosttyEchoEvent] = []
            var changed = false
            if let t = terminal, let p = echo.predictor {
                if current != .off { p.level = current }
                p.tick(grid: GhosttyEchoGrid(t, marks: promptWatch.marks), now: echo.now)
                changed = echoPublish(&events)
            echoTrace(changed: changed)  // PERF
            }
            termLock.unlock()
            if changed { onDirty?() }
            deliverEcho(events)
        }
    }

    func echoTyped(_ kind: EchoInputKind, seq: Int, at time: Double) {
        echoOp(cost: .feedKey) { p, grid, _ in p.typed(kind, seq: seq, at: time, grid: grid) }
    }

    func echoAnswered(through seq: Int, at time: Double) {
        echoOp { p, grid, now in p.answered(through: seq, at: time, now: now, grid: grid) }
    }

    func echoSettled(after answer: Double) {
        echoOp { p, _, _ in p.settled(after: answer) }
    }

    func echoCleared(_ reason: EchoClearReason, through seq: Int) {
        echoOp { p, grid, _ in p.cleared(reason, through: seq, lastB: grid.marks.lastB) }
    }

    func echoInputMode(_ mode: EchoInputMode?, foreground: String?, generation: Int) {
        echoOp { p, grid, now in p.inputMode(mode, foreground: foreground, generation: generation, now: now, grid: grid) }
    }

    /// The program in front changed: OSC 133 markers seen so far no longer describe it.
    func echoForegroundChanged() {
        enqueue { [self] in
            termLock.lock()
            promptWatch.foregroundChanged()
            termLock.unlock()
        }
    }

    /// Runs `body` on the feed queue with the predictor and the grid, then publishes.
    private func echoOp(cost: EchoProbe.Cost? = nil, _ body: @escaping @Sendable (EchoPredictor, GhosttyEchoGrid, Double) -> Void) {
        enqueue { [self] in
            termLock.lock()
            guard let t = terminal, let p = echo.predictor else {
                termLock.unlock()
                return
            }
            // PERF: a timed op is split in three (the grid's facts, the predictor's call, the
            // publish), with the cells it read from the terminal.
            let probe = cost != nil ? EchoProbe.active : nil
            let began = probe != nil ? EchoProbe.clock() : 0
            let grid = GhosttyEchoGrid(t, marks: promptWatch.marks)
            let made = probe != nil ? EchoProbe.clock() : 0
            body(p, grid, echo.now)
            let called = probe != nil ? EchoProbe.clock() : 0
            var events: [GhosttyEchoEvent] = []
            let changed = echoPublish(&events)
            if let probe, let cost {
                let done = EchoProbe.clock()
                probe.cost(cost, seconds: done - began)
                probe.cost(.feedGrid, seconds: made - began)
                probe.cost(.feedCall, seconds: called - made)
                probe.cost(.feedPublish, seconds: done - called)
                probe.cellsRead(grid.cellReads)
            }
            echoTrace(changed: changed)  // PERF
            termLock.unlock()
            if changed { onDirty?() }
            deliverEcho(events)
        }
    }

    // MARK: On the feed queue, with `termLock` held

    /// After a slice was parsed into `t` (and judged, at the end of a drain batch). Only called
    /// while a predictor exists. Returns true when the overlay changed.
    func echoAfterSlice(_ t: GhosttyTerminal, batchEnd: Bool, events: inout [GhosttyEchoEvent]) -> Bool {
        guard let p = echo.predictor else { return false }
        let began = EchoProbe.active != nil ? EchoProbe.clock() : 0  // PERF
        let grid = GhosttyEchoGrid(t, marks: promptWatch.marks)
        if batchEnd { p.batchEnd(grid: grid, now: echo.now) } else { p.slice(grid: grid, now: echo.now) }
        let changed = echoPublish(&events)
        EchoProbe.active?.cost(.feedSlice, since: began)  // PERF
        echoTrace(changed: changed)  // PERF
        return changed
    }

    /// The grid changed under the guesses (a resize, a reset, a restore, a theme, dropped
    /// output): every guess goes, in the same lock section as the change. True when a drawn
    /// guess was unsettled (deliver `.settled`).
    func echoInvalidate(replaced: Bool = false) -> Bool {
        // A screen that was replaced was not watched being written: the prompt marks parsed
        // so far say nothing about it.
        echo.predictor?.reset(unproven: replaced, lastB: promptWatch.marks.lastB)
        echoPublished = nil
        return echo.unsettled.exchange(false, ordering: .relaxed)
    }

    /// Publishes the predictor's overlay, applies a deferred lower level, retires the predictor
    /// at `.off`, collects its requests and arms its next tick. True when the overlay changed.
    private func echoPublish(_ events: inout [GhosttyEchoEvent]) -> Bool {
        guard let p = echo.predictor else { return false }
        let level = echo.level.settle(pending: p.hasPending)
        if level == .off {
            EchoProbe.active?.retired(p.counters)  // PERF
            echo.predictor = nil
            echo.tickAt = nil
            let had = echoPublished != nil
            echoPublished = nil
            if echo.unsettled.exchange(false, ordering: .relaxed) { events.append(.settled) }
            events.append(.retired)
            return had
        }
        if p.level != level {
            p.level = level
        }
        if let generation = p.takeInputModeRequest() { events.append(.inputMode(generation: generation)) }
        if p.takeSlowSignal() { events.append(.slow) }
        let overlay = p.overlay
        let changed = overlay != echoPublished
        if changed {
            echoPublished = overlay
            echo.publishes.add(1, ordering: .relaxed)
        }
        let unsettled = overlay?.unsettled ?? false
        if echo.unsettled.exchange(unsettled, ordering: .relaxed), !unsettled { events.append(.settled) }
        if echo.clock == nil, let due = p.nextDeadline(), due < (echo.tickAt ?? .infinity) {
            echo.tickAt = due
            queue.asyncAfter(deadline: .now() + max(0, due - EchoClock.now) + 0.001) { [weak self] in self?.echoTick(due) }
        }
        return changed
    }

    /// PERF: after a predictor call, with `termLock` held and outside what the probe times:
    /// the overlay if the call changed it, and the screen at the moment the predictor counted
    /// a wrong guess, a cap or a reset.
    private func echoTrace(changed: Bool) {
        guard let probe = EchoProbe.active else { return }
        if changed { probe.published(echoPublished, core: self) }
        guard let t = terminal, let p = echo.predictor else { return }
        probe.counted(p.counters) {
            let grid = GhosttyEchoGrid(t, marks: promptWatch.marks)
            var row = String.UnicodeScalarView()
            for x in 0..<min(grid.cols, 60) { row.append(Unicode.Scalar(max(grid.cell(x, grid.cursorY).scalar, 0x20)) ?? " ") }
            return "cursor=\(grid.cursorX),\(grid.cursorY) row='\(String(row))'"
        }
    }

    private func echoTick(_ due: Double) {
        termLock.lock()
        if echo.tickAt == due { echo.tickAt = nil }
        var events: [GhosttyEchoEvent] = []
        var changed = false
        if let t = terminal, let p = echo.predictor {
            p.tick(grid: GhosttyEchoGrid(t, marks: promptWatch.marks), now: echo.now)
            changed = echoPublish(&events)
            echoTrace(changed: changed)  // PERF
        }
        termLock.unlock()
        if changed { onDirty?() }
        deliverEcho(events)
    }

    /// The predictor's deadlines (the safety cap, the slow-link signal) as of the clock now, in
    /// order with the bytes. For a test that moves its own clock.
    func echoTick() {
        enqueue { [self] in echoTick(.nan) }
    }

    /// Hands events to the pane. Call without `termLock`.
    func deliverEcho(_ events: [GhosttyEchoEvent]) {
        guard !events.isEmpty, let handler = onEcho else { return }
        for e in events { handler(e) }
    }

    // MARK: Reading (tests)

    /// The overlay last published, after `sync()`.
    var publishedEcho: EchoOverlay? {
        lockTerminal()
        defer { termLock.unlock() }
        return echoPublished
    }

    /// The predictor's counters, after `sync()`; nil without a predictor.
    var echoCounters: EchoPredictor.Counters? {
        lockTerminal()
        defer { termLock.unlock() }
        return echo.predictor?.counters
    }
}
