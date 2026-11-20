import Foundation

/// How predicted echo shows on a pane (docs/terminal.md, Predicted echo).
public enum EchoLevel: Int, Comparable, Sendable {
    /// No prediction at all: no predictor, no overlay, today's key path.
    case off
    /// Guesses show unmarked.
    case on
    /// Guesses carry a thin underline until the server confirms them.
    case slow

    public static func < (a: EchoLevel, b: EchoLevel) -> Bool { a.rawValue < b.rawValue }
}

/// The monotonic clock every echo time is read from, in seconds. The same clock on the main
/// thread and the feed queue, so a key's typed time and a check's time compare.
public enum EchoClock {
    @inline(__always) public static var now: Double { ProcessInfo.processInfo.systemUptime }
}

/// The smoothed round trip of a server's `terminal.write` calls, from the writes typing already
/// makes: no traffic of its own. mosh's estimator (α = 1/8), with two guards against the spikes
/// of a phone's radio: a sample counts at most `glitch` ms in the average, and the average turns
/// predictions on only when the median of the last five samples agrees (`EchoGate`).
public struct WriteRoundTrip: Sendable {
    /// A raw sample this slow (ms) is a glitch: it counts as `glitch` in the average.
    public static let glitch = 250.0
    /// Glitches count toward turning predictions on for this long (s).
    public static let glitchWindow = 10.0
    /// Samples that judge the cure are at least this far apart (s), so a burst of fast answers
    /// can't end predictions in a moment.
    public static let cureSpacing = 0.15
    /// How many spaced samples the cure looks at.
    public static let cureCount = 10

    /// The smoothed round trip in ms, nil before the first sample.
    public private(set) var srtt: Double?
    /// Samples since the last reset.
    public private(set) var samples = 0
    /// The newest raw sample (ms).
    public private(set) var last: Double?
    /// The last five raw samples, newest last.
    private var recent: [Double] = []
    /// When the glitches of the last `glitchWindow` happened.
    private var glitches: [Double] = []
    /// The last `cureCount` samples counted for the cure (glitches always count), newest last.
    private var cure: [Double] = []
    private var lastCured = -Double.infinity

    public init() {}

    public mutating func add(ms: Double, at now: Double) {
        samples += 1
        last = ms
        let clamped = min(ms, Self.glitch)
        srtt = srtt.map { $0 + (clamped - $0) / 8 } ?? clamped
        recent.append(ms)
        if recent.count > 5 { recent.removeFirst() }
        if ms >= Self.glitch { glitches.append(now) }
        glitches.removeAll { now - $0 > Self.glitchWindow }
        if ms >= Self.glitch || now - lastCured >= Self.cureSpacing {
            cure.append(ms)
            if cure.count > Self.cureCount { cure.removeFirst() }
            lastCured = now
        }
    }

    /// The cure proved the link fast: the glitches before it no longer count.
    public mutating func forgetGlitches() { glitches.removeAll() }

    /// Glitches in the last `glitchWindow` seconds.
    public func glitchCount(at now: Double) -> Int { glitches.filter { now - $0 <= Self.glitchWindow }.count }

    /// The median of the last five samples, nil before five.
    public var recentMedian: Double? {
        guard recent.count == 5 else { return nil }
        return recent.sorted()[2]
    }

    /// The last `cureCount` spaced samples exist and none is a glitch.
    public var cured: Bool { cure.count >= Self.cureCount && !cure.contains { $0 >= Self.glitch } }
}

/// Turns one server's write round trips into the level its panes want, with hysteresis
/// (docs/terminal.md, Predicted echo; mosh's underline thresholds, wider ones to start):
///
/// - off to on: at least 5 samples, and the smoothed round trip over 60 ms with the median of the
///   last five over 60 ms too, or 2 glitches within 10 s. A single spike never turns it on.
/// - on to slow: over 80 ms (the median agreeing), or a pane's drawn guess still unconfirmed
///   300 ms after it was typed (`noteOverdue`).
/// - slow to on: 50 ms or less with the last 10 spaced samples each under 250 ms.
/// - to off: 40 ms or less with the last 10 spaced samples each under 250 ms.
/// - reset (a reconnect, a network change): off, samples cleared, every pane told to clear.
///
/// Panes apply a change that shows more at once and one that shows less only once nothing is
/// pending (`EchoPaneLevel`). One gate per server: its panes share one control connection.
@MainActor
public final class EchoGate {
    public nonisolated static let onAbove = 60.0
    public nonisolated static let offAtOrBelow = 40.0
    public nonisolated static let slowAbove = 80.0
    public nonisolated static let slowEndsAtOrBelow = 50.0
    public nonisolated static let warmup = 5

    public private(set) var level = EchoLevel.off
    public private(set) var roundTrip = WriteRoundTrip()
    /// `-predict never|always` (tests and the benchmark): the level, whatever the samples say.
    public var forced: EchoLevel? {
        didSet { publish() }
    }
    /// The level the panes follow: `forced`, else what the samples give.
    public var effective: EchoLevel { forced ?? level }

    private var watchers: [UUID: Watcher] = [:]
    private struct Watcher {
        let changed: @MainActor (EchoLevel) -> Void
        let reset: @MainActor () -> Void
    }

    public init(forced: EchoLevel? = nil) { self.forced = forced }

    /// A write's round trip, from the moment it left to its answer.
    public func sample(ms: Double, at now: Double = EchoClock.now) {
        roundTrip.add(ms: ms, at: now)
        let next = Self.next(level, roundTrip, at: now)
        guard next != level else { return }
        if next == .off { roundTrip.forgetGlitches() }
        level = next
        publish()
    }

    /// A pane's drawn guess waited 300 ms: the link is slow enough to mark guesses.
    public func noteOverdue() {
        guard level == .on else { return }
        level = .slow
        publish()
    }

    /// The link changed under the samples: start again from today's behaviour.
    public func reset() {
        roundTrip = WriteRoundTrip()
        let was = effective
        level = .off
        for w in watchers.values { w.reset() }
        if effective != was { publish() }
    }

    /// Calls `changed` with each new level and `reset` on each reset, until the token is passed
    /// to `unwatch`.
    public func watch(changed: @escaping @MainActor (EchoLevel) -> Void, reset: @escaping @MainActor () -> Void) -> UUID {
        let id = UUID()
        watchers[id] = Watcher(changed: changed, reset: reset)
        return id
    }

    public func unwatch(_ id: UUID) { watchers[id] = nil }

    private func publish() {
        let l = effective
        for w in watchers.values { w.changed(l) }
    }

    /// The hysteresis, as a pure step.
    nonisolated static func next(_ level: EchoLevel, _ r: WriteRoundTrip, at now: Double) -> EchoLevel {
        guard let srtt = r.srtt, r.samples >= warmup else { return level }
        let median = r.recentMedian ?? 0
        switch level {
        case .off:
            let slowLink = srtt > onAbove && median > onAbove
            guard slowLink || r.glitchCount(at: now) >= 2 else { return .off }
            return srtt > slowAbove && median > slowAbove ? .slow : .on
        case .on:
            if srtt <= offAtOrBelow, r.cured { return .off }
            return srtt > slowAbove && median > slowAbove ? .slow : .on
        case .slow:
            if srtt <= offAtOrBelow, r.cured { return .off }
            if srtt <= slowEndsAtOrBelow, r.cured { return .on }
            return .slow
        }
    }
}

/// One pane's level: what its server's gate wants, applied at once when it shows more and only
/// once the pane has nothing pending when it shows less, so the look never changes mid-word.
public struct EchoPaneLevel: Equatable, Sendable {
    public private(set) var current = EchoLevel.off
    public private(set) var wanted = EchoLevel.off

    public init() {}

    /// Returns the new current level.
    @discardableResult
    public mutating func want(_ level: EchoLevel, pending: Bool) -> EchoLevel {
        wanted = level
        return settle(pending: pending)
    }

    /// The pane's pending state changed: a deferred lower level may apply now.
    @discardableResult
    public mutating func settle(pending: Bool) -> EchoLevel {
        if wanted > current || !pending { current = wanted }
        return current
    }
}
