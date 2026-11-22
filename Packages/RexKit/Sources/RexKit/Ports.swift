import Foundation

/// One TCP port a program in a terminal listens on (`com.superlogical.terminal.ports`, revision
/// 15, and the `ports_changed` block event, which carries the same reply).
public struct PortEntry: Equatable, Sendable {
    public var port: Int
    /// Where the computer dials to reach it: a loopback address when the program listens there,
    /// else the address it listens on (`PortRules.dialHost`).
    public var dialHost: String
    /// The program's name (`processLabel` of its process), or nil when the server couldn't tell
    /// which process holds the port.
    public var process: String?
    /// The id of the process that holds the port, when the server could tell.
    public var pid: Int?
    /// That process's executable name (`python3.12`), for naming an interpreter whose script
    /// says nothing (`PortNames`).
    public var program: String?
    /// That process's working directory, when the server could read it.
    public var folder: String?

    public init(port: Int, dialHost: String, process: String?, pid: Int? = nil, program: String? = nil, folder: String? = nil) {
        self.port = port
        self.dialHost = dialHost
        self.process = process
        self.pid = pid
        self.program = program
        self.folder = folder
    }

    /// How the port is named on screen: `localhost:5173`.
    public var name: String { "localhost:\(port)" }
}

/// A terminal's ports as one reply or event gave them: one entry per port number, sorted.
/// `first_seen_at` is left out, so a rescan that finds the same ports compares equal.
public struct PortList: Equatable, Sendable {
    public enum Status: String, Sendable {
        /// Every process in the terminal was looked at.
        case ok
        /// Some couldn't be: a port may be missing. Any status this build doesn't know counts too.
        case partial
        /// The server can't list ports for this terminal.
        case unsupported
    }

    public var status: Status
    public var entries: [PortEntry]
    /// The server left entries out to fit one message; these are the ones that came.
    public var truncated: Bool

    public init(status: Status = .ok, entries: [PortEntry] = [], truncated: Bool = false) {
        self.status = status
        self.entries = entries
        self.truncated = truncated
    }

    /// From a reply or a `ports_changed` payload. `label` names a process from its entry in
    /// `processes` (the app's `processLabel`).
    public init(_ o: JSONObject, label: (JSONObject) -> String) {
        status = Status(rawValue: o.str("status") ?? "") ?? .partial
        truncated = o.bool("truncated") ?? false
        var names: [Int: String] = [:]
        var holders: [Int: JSONObject] = [:]
        for p in o.arr("processes") {
            guard let pid = p.int("pid") else { continue }
            holders[pid] = p
            let l = label(p)
            if !l.isEmpty { names[pid] = l }
        }
        // One entry per port: a loopback address wins, then the first listed.
        var byPort: [Int: (entry: PortEntry, loopback: Bool)] = [:]
        for p in o.arr("ports") {
            guard p.str("protocol") == "tcp", let port = p.int("port"), (1...65535).contains(port),
                  let address = p.str("address"), let host = PortRules.dialHost(address) else { continue }
            let loopback = PortRules.isLoopback(host)
            if let had = byPort[port], had.loopback || !loopback { continue }
            let pid = p.int("pid"), holder = pid.flatMap { holders[$0] }
            byPort[port] = (PortEntry(port: port, dialHost: host, process: pid.flatMap { names[$0] }, pid: pid,
                                      program: holder?.str("name"), folder: holder?.str("cwd")), loopback)
        }
        entries = byPort.values.map(\.entry).sorted { $0.port < $1.port }
    }

    /// The ports a browser may open: every one except databases, mail, DNS, SSH, queues and
    /// debuggers (`PortRules.isWeb`). The app then asks each one what it answers (`PortProbe`)
    /// before it shows.
    public var webPorts: [PortEntry] { entries.filter { PortRules.isWeb($0) } }

    public func entry(_ port: Int) -> PortEntry? { entries.first { $0.port == port } }
}

/// Which ports open in a browser, and where the computer dials them.
public enum PortRules {
    /// Debuggers (Node, Chrome DevTools). Whoever reaches one runs code in the program, so they
    /// never open, from a link or anywhere else.
    public static let debuggerPorts: Set<Int> = [9229, 9222, 9230]
    /// SSH, mail, DNS, ZooKeeper, MySQL, Postgres, RabbitMQ, Redis, Kafka, memcached, MongoDB.
    public static let servicePorts: Set<Int> = [22, 25, 53, 2181, 3306, 5432, 5672, 6379, 9092, 11211, 27017]
    /// Programs that never serve a web page, by process name.
    public static let serviceProcesses: Set<String> = ["postgres", "mysqld", "redis-server", "mongod", "sshd"]

    /// The first filter, by number and program name only: a port that fails it is never shown
    /// and never probed. One that passes may still be no web page (an editor plugin's WebSocket
    /// server, say): the app asks it once, `GET /` through a dial tunnel, and hides it only on
    /// positive evidence (`PortProbe`, `PortProbeBook`; docs/terminal.md, Ports).
    public static func isWeb(_ e: PortEntry) -> Bool {
        if debuggerPorts.contains(e.port) || servicePorts.contains(e.port) { return false }
        if let p = e.process?.lowercased(), serviceProcesses.contains(p) { return false }
        return true
    }

    /// The address to dial for a socket bound to `address`: an unspecified address listens on
    /// loopback too, so it is dialed there. A link-local address with a zone names an interface
    /// of the computer that the dial can't use, so it is skipped (nil).
    public static func dialHost(_ address: String) -> String? {
        let a = address.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
        if a.isEmpty || a.contains("%") { return nil }
        if a == "0.0.0.0" { return "127.0.0.1" }
        if a == "::" { return "::1" }
        return a
    }

    public static func isLoopback(_ host: String) -> Bool {
        host == "::1" || host.hasPrefix("127.")
    }
}
