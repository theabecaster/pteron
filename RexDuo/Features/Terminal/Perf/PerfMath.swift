import Foundation

/// The time span a run's numbers are taken over, in `CACurrentMediaTime` seconds.
struct PerfWindow: Equatable {
    var from: Double
    var to: Double
    var seconds: Double { max(0, to - from) }
}

/// Gaps between consecutive events (display link ticks, presented frames) inside a window.
///
/// A gap is the time from one event to the next, cut to the window. The last event at or before
/// the window's start and the first at or after its end count as the edges, so a stall that
/// spans an edge is counted for the part inside. With no event outside on a side, the gaps start
/// (or end) at the first (or last) event inside: what came before it isn't known.
struct PerfGapStats: Equatable {
    /// Events inside the window, edges included.
    var events = 0
    /// Gaps longer than the threshold.
    var over = 0
    /// The sum of those gaps, in seconds (each whole gap, not the part past the threshold).
    var overSeconds = 0.0
    /// The longest gap, in seconds.
    var worstSeconds = 0.0

    /// `times` must be ascending.
    static func measure(_ times: [Double], in window: PerfWindow, threshold: Double) -> PerfGapStats {
        var s = PerfGapStats()
        var previous: Double?
        for t in times {
            if t <= window.from {
                previous = window.from
                continue
            }
            let at = min(t, window.to)
            if t <= window.to { s.events += 1 }
            if let p = previous {
                let gap = at - p
                if gap > threshold {
                    s.over += 1
                    s.overSeconds += gap
                }
                s.worstSeconds = max(s.worstSeconds, gap)
            }
            previous = at
            if t >= window.to { break }
        }
        return s
    }
}

/// Time the main thread spent working inside a window: the run loop's slices between waking
/// (`afterWaiting`) and going back to sleep (`beforeWaiting`), cut to the window.
struct PerfBusyStats: Equatable {
    var totalSeconds = 0.0
    /// The longest single slice: the longest time the main thread could not react to anything.
    var worstSeconds = 0.0

    static func measure(_ slices: [PerfWindow], in window: PerfWindow) -> PerfBusyStats {
        var s = PerfBusyStats()
        for slice in slices {
            let d = min(slice.to, window.to) - max(slice.from, window.from)
            guard d > 0 else { continue }
            s.totalSeconds += d
            s.worstSeconds = max(s.worstSeconds, d)
        }
        return s
    }
}

/// Hitches against the display's own frame interval: a gap between consecutive events (display
/// link ticks, or frames presented while every interval should have one) longer than one and a
/// half intervals, so at least one refresh went by without a new frame. At 120 Hz that is a gap
/// over 12.5 ms. `hitchSeconds` is what those gaps took beyond one interval each (Apple's hitch
/// time; divided by the window it is the hitch time ratio, in ms per second).
struct PerfHitchStats: Equatable {
    /// Events inside the window.
    var events = 0
    var hitches = 0
    var hitchSeconds = 0.0
    var worstSeconds = 0.0

    /// `times` must be ascending. `period` is the display's frame interval in seconds. Only gaps
    /// between two events inside the window count.
    static func measure(_ times: [Double], in window: PerfWindow, period: Double) -> PerfHitchStats {
        var s = PerfHitchStats()
        var previous: Double?
        for t in times where t > window.from && t <= window.to {
            s.events += 1
            if let p = previous {
                let gap = t - p
                if gap > period * 1.5 {
                    s.hitches += 1
                    s.hitchSeconds += gap - period
                }
                s.worstSeconds = max(s.worstSeconds, gap)
            }
            previous = t
        }
        return s
    }
}

/// The median of a run's values: the middle one, or the mean of the two in the middle.
enum PerfMedian {
    static func of(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let v = values.sorted(), mid = v.count / 2
        return v.count % 2 == 1 ? v[mid] : (v[mid - 1] + v[mid]) / 2
    }
}
