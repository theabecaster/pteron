import Foundation
import Network
import RexKit

/// Watches the phone's network with `NWPathMonitor`, off the main thread, and reports a
/// `NetworkSnapshot` on the main actor when it changes. A change is the cue to retry servers that
/// are down, since a new path (Wi-Fi back, a VPN coming up) is when a retry can succeed.
@MainActor
@Observable
final class NetworkWatch {
    private(set) var snapshot = NetworkSnapshot.unknown
    /// Called on the main actor after `snapshot` changes.
    @ObservationIgnored var onChange: ((NetworkSnapshot) -> Void)?
    /// Called once on the main actor with the first report: the path the app started on.
    @ObservationIgnored var onStart: ((NetworkSnapshot) -> Void)?
    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private let override: NetworkSnapshot?
    @ObservationIgnored private var primed = false
    /// The path has been reported at least once: `snapshot` is the phone's, not the placeholder.
    var isKnown: Bool { primed }

    /// `log`: the connection log, which gets a line when the path's facts change.
    init(log: ConnectionLog? = nil) {
        override = Self.debugOverride
        if let override {
            snapshot = override
            #if DEBUG
            // `-simulateTailnetAfter <seconds>` (testing): an `offPrivate` iPhone joins the tailnet
            // that long after launch, as when Tailscale is turned on.
            let after = UserDefaults.standard.double(forKey: "simulateTailnetAfter")
            if after > 0, override.onPrivateNetwork == false {
                primed = true
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(after * 1_000_000_000))
                    self?.apply(NetworkSnapshot(reachable: true, onPrivateNetwork: true))
                }
            }
            #endif
            return
        }
        monitor.pathUpdateHandler = { [weak self] path in
            // On the monitor's queue: the interface scan stays off the main thread.
            let tunnel = PrivateNetwork.tunnelAddresses()
            let tailnet = !tunnel.isEmpty
            let kind: PathFacts.Interface = path.usesInterfaceType(.wifi) ? .wifi
                : path.usesInterfaceType(.cellular) ? .cellular
                : path.usesInterfaceType(.wiredEthernet) ? .wired : .other
            let snap = NetworkSnapshot(reachable: path.status == .satisfied, onPrivateNetwork: tailnet,
                                       route: path.availableInterfaces.map(\.name).joined(separator: ","),
                                       expensive: path.isExpensive, interface: kind, tunnel: tunnel)
            // Four yes-or-no facts and no interface name; the log leaves out a repeat.
            log?.record(.network(.init(satisfied: path.status == .satisfied, expensive: path.isExpensive,
                                       constrained: path.isConstrained, tailnet: tailnet)))
            Task { @MainActor in self?.apply(snap) }
        }
        monitor.start(queue: DispatchQueue(label: "dev.abrahamgonzalez.rexduo.network", qos: .utility))
    }

    deinit { monitor.cancel() }

    private func apply(_ snap: NetworkSnapshot) {
        // The first report is the starting state, not a change; the first connect is already on it.
        defer { primed = true }
        let changed = snap != snapshot
        if changed { snapshot = snap }
        if !primed {
            onStart?(snap)
        } else if changed {
            onChange?(snap)
        }
    }

    /// `-simulateNetwork offline|offPrivate|onPrivate` (Debug builds): pretend the phone's network is
    /// in that state, so the matching offline screens show with real connection errors.
    private static var debugOverride: NetworkSnapshot? {
        #if DEBUG
        switch UserDefaults.standard.string(forKey: "simulateNetwork") {
        case "offline": return NetworkSnapshot(reachable: false, onPrivateNetwork: false)
        case "offPrivate": return NetworkSnapshot(reachable: true, onPrivateNetwork: false)
        case "onPrivate": return NetworkSnapshot(reachable: true, onPrivateNetwork: true)
        default: return nil
        }
        #else
        return nil
        #endif
    }
}

/// Whether the phone looks like it's on a Tailscale network: an interface that's up with an address
/// in Tailscale's ranges. IPv6 fd7a:115c:a1e0::/48 is Tailscale's own and counts on any interface.
/// IPv4 100.64.0.0/10 counts only on a tunnel (`utun*`, where the Tailscale app puts it): it is also
/// the carrier-grade NAT range, which a cellular network can give the phone itself.
enum PrivateNetwork {
    nonisolated static func isConnected() -> Bool { !tunnelAddresses().isEmpty }

    /// The phone's Tailscale addresses, as text. They stay in memory and are only compared: a
    /// different set is a different tunnel.
    nonisolated static func tunnelAddresses() -> Set<String> {
        var found: Set<String> = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return found }
        defer { freeifaddrs(head) }
        var cur: UnsafeMutablePointer<ifaddrs>? = first
        while let p = cur {
            defer { cur = p.pointee.ifa_next }
            let flags = Int32(p.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, let sa = p.pointee.ifa_addr else { continue }
            switch Int32(sa.pointee.sa_family) {
            case AF_INET:
                let a = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
                if isTailnet(interface: String(cString: p.pointee.ifa_name), ipv4: a) { found.insert(String(a, radix: 16)) }
            case AF_INET6:
                let bytes = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { s in
                    withUnsafeBytes(of: s.pointee.sin6_addr) { Array($0) }
                }
                if isTailnet(ipv6: bytes) { found.insert(bytes.map { String($0, radix: 16) }.joined(separator: ":")) }
            default:
                break
            }
        }
        return found
    }

    /// An IPv4 address of the interface `name`: Tailscale's only on a tunnel.
    nonisolated static func isTailnet(interface name: String, ipv4 a: UInt32) -> Bool {
        name.hasPrefix("utun") && isTailnet(ipv4: a)
    }

    /// 100.64.0.0/10, the carrier-grade NAT range Tailscale assigns from.
    nonisolated static func isTailnet(ipv4 a: UInt32) -> Bool { a & 0xFFC0_0000 == 0x6440_0000 }

    /// fd7a:115c:a1e0::/48, Tailscale's IPv6 range.
    nonisolated static func isTailnet(ipv6 b: [UInt8]) -> Bool {
        b.count == 16 && Array(b.prefix(6)) == [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0]
    }
}
