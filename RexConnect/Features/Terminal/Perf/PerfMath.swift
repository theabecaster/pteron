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
