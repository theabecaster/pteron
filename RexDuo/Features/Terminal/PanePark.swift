import Foundation

/// How many panes that left the screen are kept ready to come back, and for how long.
struct ParkLimits: Equatable {
    /// Parked panes at most; the panes on screen don't count.
    var count = 4
    /// Their terminals' memory together, by the engine's own figure (`GhosttyCore.memoryBytes`).
    var bytes = 96 << 20
    /// Parked panes are let go when the app comes back after this long in the background.
    var backgroundLife: TimeInterval = 600
}

/// Which parked panes go. Pure: the pool (`TerminalHostPool`) asks and acts.
enum ParkPolicy {
    /// The panes to let go so that the rest fit `limits`: the oldest first. `parked` is in the
    /// order the panes were parked, oldest first, each with its terminal's memory.
    static func evictions<Key>(_ parked: [(key: Key, bytes: Int)], limits: ParkLimits) -> [Key] {
        var keep = parked.count
        var total = parked.reduce(0) { $0 + $1.bytes }
        var out: [Key] = []
        for p in parked {
            guard keep > max(limits.count, 0) || total > limits.bytes else { break }
            out.append(p.key)
            keep -= 1
            total -= p.bytes
        }
        return out
    }

    /// Whether a parked pane has nowhere to come back to: its server is not the one on screen
    /// (the user left it) or is gone, or its session closed. `sessions` holds the session ids of
    /// each server that is online; a server that is not online says nothing about its sessions.
    static func isStale(server: UUID, session: String, selected: UUID?, servers: Set<UUID>,
                        sessions: [UUID: Set<String>]) -> Bool {
        if !servers.contains(server) { return true }
        if let selected, selected != server { return true }
        if let open = sessions[server], !open.contains(session) { return true }
        return false
    }

    /// Whether the time away ends the park.
    static func expired(awayFor seconds: TimeInterval, limits: ParkLimits) -> Bool {
        seconds >= limits.backgroundLife
    }
}

/// How many panes that left the screen keep streaming, unseen, so that coming back to one is
/// not even a resume: they parse and never draw. Built for a phone: few, quiet ones only, and
/// none when the phone has reasons to save.
enum WarmPolicy {
    /// What the limit depends on.
    struct Facts: Equatable {
        var foreground = true
        var lowPower = false
        /// `ProcessInfo.ThermalState` serious or critical.
        var hot = false
        /// A cellular network or a hotspot.
        var expensive = false
    }

    /// Warm panes at most.
    static let most = 2
    /// A warm pane that writes more than this, on average over `rateWindow`, parks.
    static let rateLimit = 64 * 1024
    static let rateWindow: CFTimeInterval = 2

    static func limit(_ facts: Facts) -> Int {
        guard facts.foreground, !facts.lowPower, !facts.hot else { return 0 }
        return facts.expensive ? 1 : most
    }
}

/// The output of a warm pane, in windows of `WarmPolicy.rateWindow`: says when one passed the
/// limit. No timer: it looks at the clock when bytes arrive.
struct WarmRate {
    private var start: CFTimeInterval = 0
    private var bytes = 0

    mutating func reset(at now: CFTimeInterval) {
        start = now
        bytes = 0
    }

    /// Counts `count` bytes that arrived at `now`. True when the window that just ended held
    /// more than the limit allows.
    mutating func add(_ count: Int, at now: CFTimeInterval) -> Bool {
        if now - start >= WarmPolicy.rateWindow {
            // The window ended before these bytes: judge it, and start the next one with them.
            let over = Double(bytes) > Double(WarmPolicy.rateLimit) * (now - start)
            start = now
            bytes = count
            return over
        }
        bytes += count
        return false
    }
}

/// Whether a warm pane that comes back on screen needs the catch-up fence.
enum WarmReturn {
    /// A mirror pane never: its screen is the stream's, and nothing about it changes. A
    /// fitted pane that still holds its claim, at the size that fits and that the server has,
    /// neither: it was streamed at that size the whole time. Only a claim that is about to be
    /// made (the grace ran out, another client took the pane, the pane fits another grid now)
    /// will change the screen.
    static func fences(fit: Bool, claimed: (Int, Int)?, server: (Int, Int), fits: (Int, Int)) -> Bool {
        guard fit else { return false }
        guard let claimed else { return true }
        return claimed != fits || server != fits
    }
}
