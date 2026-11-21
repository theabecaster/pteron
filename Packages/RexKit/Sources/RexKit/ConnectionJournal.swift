import Foundation

/// The connection log's contents: a ring of the newest events for each server, and one for the
/// app and the phone. Pure values; `ConnectionLog` keeps one and writes it to a file.
///
/// A server is known here only by its tag, a hash of the key the app gives it, salted with a
/// number made at random on this device and kept in the file. The key itself is never stored.
struct ConnectionJournal: Equatable {
    /// Events kept per ring; the oldest goes when one more comes.
    static let eventsPerRing = 200
    /// Server rings kept. One more server pushes out the ring that has been quiet longest.
    static let maxServers = 12
    /// The file's first bytes: `CLOG`, the format's version, three zero bytes, then the salt.
    static let magic: [UInt8] = [0x43, 0x4C, 0x4F, 0x47, 1, 0, 0, 0]
    static let headerSize = 16
    /// The most events the rings hold together.
    static let maxEvents = (maxServers + 1) * eventsPerRing

    let salt: UInt64
    /// Events of the app and the phone: launches, scene phases, network changes.
    private(set) var app: [ConnectionEvent] = []
    private(set) var servers: [UInt64: [ConnectionEvent]] = [:]
    /// The network last recorded by this process, so a path update that changes none of the four
    /// facts adds no line.
    private var lastNetwork: UInt8?

    init(salt: UInt64) { self.salt = salt }

    var count: Int { app.count + servers.values.reduce(0) { $0 + $1.count } }

    /// The tag of a server: FNV-1a over the salt and the key. Never 0, which means the app.
    func tag(_ key: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        func mix(_ byte: UInt8) { h = (h ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 }
        for i in 0..<8 { mix(UInt8(truncatingIfNeeded: salt >> (8 * UInt64(i)))) }
        for byte in key.utf8 { mix(byte) }
        return h == 0 ? 1 : h
    }

    /// Adds an event to its ring. False when it was left out: a network event that repeats the
    /// last one.
    @discardableResult
    mutating func add(_ e: ConnectionEvent) -> Bool {
        if e.kind == .network {
            if lastNetwork == e.flags { return false }
            lastNetwork = e.flags
        }
        insert(e)
        return true
    }

    private mutating func insert(_ e: ConnectionEvent) {
        if e.server == 0 {
            app.append(e)
            if app.count > Self.eventsPerRing { app.removeFirst(app.count - Self.eventsPerRing) }
            return
        }
        if servers[e.server] == nil, servers.count >= Self.maxServers,
           let quiet = servers.min(by: { ($0.value.last?.time ?? 0) < ($1.value.last?.time ?? 0) })?.key {
            servers[quiet] = nil
        }
        servers[e.server, default: []].append(e)
        if let n = servers[e.server]?.count, n > Self.eventsPerRing {
            servers[e.server]?.removeFirst(n - Self.eventsPerRing)
        }
    }

    // MARK: File

    /// The whole file: the header, then every ring's events.
    func encoded() -> Data {
        var b = Self.magic
        b.reserveCapacity(Self.headerSize + count * ConnectionEvent.size)
        ConnectionEvent.put(salt, into: &b)
        for e in app { b += e.encoded() }
        for tag in servers.keys.sorted() { for e in servers[tag] ?? [] { b += e.encoded() } }
        return Data(b)
    }

    /// Reads a file. Nil when it is not this format or any event in it is damaged: the file is
    /// then dropped whole, since nothing in it can be trusted. `torn` is set when the file ends
    /// inside an event (the app died during a write): the whole events before it are kept.
    static func decode(_ data: Data) -> (journal: ConnectionJournal, torn: Bool)? {
        let b = [UInt8](data)
        guard b.count >= headerSize, Array(b[0..<8]) == magic else { return nil }
        var j = ConnectionJournal(salt: ConnectionEvent.take(b[...], 8))
        let body = b.count - headerSize
        for i in 0..<(body / ConnectionEvent.size) {
            let at = headerSize + i * ConnectionEvent.size
            guard let e = ConnectionEvent(bytes: b[at..<(at + ConnectionEvent.size)]) else { return nil }
            j.insert(e)
        }
        return (j, body % ConnectionEvent.size != 0)
    }

    // MARK: Export

    /// The log as text, oldest first, one event a line. `servers` are the app's keys in the order
    /// the app lists them: they are named "Server 1", "Server 2", … A ring whose server is not in
    /// the list (it was removed) is named "Former server 1", … No key appears in the text.
    func text(servers keys: [String], exported: Date) -> String {
        var names: [UInt64: String] = [0: "App"]
        for (i, key) in keys.enumerated() where names[tag(key)] == nil { names[tag(key)] = "Server \(i + 1)" }
        var former = 0
        for t in servers.keys.sorted(by: { (servers[$0]?.first?.time ?? 0) < (servers[$1]?.first?.time ?? 0) })
        where names[t] == nil {
            former += 1
            names[t] = "Former server \(former)"
        }
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        stamp.timeZone = TimeZone(secondsFromGMT: 0)
        // Rings in a fixed order, then by time: events of the same millisecond keep that order.
        var all = app
        for t in servers.keys.sorted(by: { (names[$0] ?? "") < (names[$1] ?? "") }) { all += servers[t] ?? [] }
        let sorted = all.enumerated().sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }
        let width = names.values.map(\.count).max() ?? 3
        var lines = ["Connection log", "exported \(stamp.string(from: exported))", "events \(all.count)", ""]
        for (_, e) in sorted {
            let name = names[e.server] ?? "?"
            let time = stamp.string(from: Date(timeIntervalSince1970: Double(e.time) / 1000))
            lines.append("\(time)  \(name.padding(toLength: width, withPad: " ", startingAt: 0))  \(e.summary)")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
