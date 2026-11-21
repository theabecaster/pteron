import Foundation

/// What reconnecting reads of the phone's network path. The app fills it from `NWPath` and the
/// interface list; nothing of it is logged or leaves the phone.
public struct PathFacts: Equatable, Sendable {
    /// The kind of interface the path uses. `none`: there is no path.
    public enum Interface: UInt8, Sendable {
        case none, wifi, cellular, wired, other
    }

    public var satisfied: Bool
    public var expensive: Bool
    public var interface: Interface
    /// The tunnel's addresses on the phone, as text that is only compared.
    public var tunnel: Set<String>

    public init(satisfied: Bool, expensive: Bool = false, interface: Interface = .other, tunnel: Set<String> = []) {
        self.satisfied = satisfied
        self.expensive = expensive
        self.interface = interface
        self.tunnel = tunnel
    }

    /// Whether the route is another one than `old`: there is a path where there was none, the
    /// kind of interface changed, or the tunnel has other addresses. Anything else the path
    /// reports (cost, constraints, the list of interfaces it could use) is no change of route,
    /// and no path is none either: nothing can be tried on it.
    public func isRouteChange(from old: PathFacts) -> Bool {
        guard satisfied else { return false }
        return !old.satisfied || interface != old.interface || tunnel != old.tunnel
    }
}

/// Tells a real change of route from the path monitor's other reports, and waits until the path
/// has been quiet for `ReconnectPolicy.routeSettle` before it says so: a change of network comes
/// as a burst of reports, and a host that is down is asked once for it, not once per report.
///
/// The first report is where the app started, not a change. A path that never stops changing
/// never settles and so reports nothing; the hosts' own schedules go on meanwhile.
@MainActor
public final class RouteWatch {
    /// Called when the route changed and has settled.
    public var onChange: (() -> Void)?
    /// The path as it last settled, and the newest report since.
    private var settled: PathFacts?
    private var newest: PathFacts?
    private var wait: Task<Void, Never>?
    private let clock: any ControlClock
    private let settle: Double

    public convenience init(policy: ReconnectPolicy = .standard) {
        self.init(policy: policy, clock: SystemControlClock())
    }

    init(policy: ReconnectPolicy, clock: any ControlClock) {
        self.clock = clock
        settle = policy.routeSettle
    }

    /// The path monitor reported `facts`.
    public func report(_ facts: PathFacts) {
        guard settled != nil else {
            settled = facts
            return
        }
        newest = facts
        wait?.cancel()
        wait = Task { @MainActor [weak self, clock, settle] in
            await clock.sleep(seconds: settle)
            guard let self, !Task.isCancelled, let now = self.newest, let was = self.settled else { return }
            self.wait = nil
            self.newest = nil
            self.settled = now
            if now.isRouteChange(from: was) { self.onChange?() }
        }
    }
}
