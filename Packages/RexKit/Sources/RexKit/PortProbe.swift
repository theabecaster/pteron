import Foundation

/// What a listening port answers, asked once: is it a web page? A port Rex lists may be anything
/// that listens on TCP, and `PortRules` only knows ports and programs by name. An editor
/// plugin's WebSocket server (Claude Code's IDE link in nvim, say) is neither, and opening it
/// only shows "Bad WebSocket upgrade request". So each port that would get a row is asked one
/// small question through a dial tunnel, `GET /`, and hidden only on positive evidence that it is
/// no web page (docs/terminal.md, Ports, "Which ports show").
public enum PortProbe {
    public enum Verdict: Equatable, Sendable {
        /// An HTTP reply of any status but the WebSocket refusals below: a 404 at `/` is still a
        /// web server.
        case web
        /// Positive evidence that no page is there: 426, a 400 that asks for a WebSocket
        /// upgrade, or a reply that isn't HTTP at all (Redis's `-ERR`, an SSH banner).
        case notWeb
        /// Nothing to go on: no reply, a TLS reply, a cut-short status line, a tunnel that
        /// couldn't be made. Shown, as before the probe, and asked again at the port's next listing.
        case unknown
    }

    /// The most of a reply that is read.
    public static let replyLimit = 4096
    /// How long the reply may take once the request has gone.
    public static let replyWait: Duration = .seconds(2)

    /// The one request: no cookies, nothing the page could keep.
    public static func request(port: Int) -> Data {
        Data("GET / HTTP/1.1\r\nHost: localhost:\(port)\r\nAccept: */*\r\nConnection: close\r\n\r\n".utf8)
    }

    /// The verdict for the bytes read so far (at most `replyLimit` of them).
    public static func classify(_ bytes: Data) -> Verdict { judge(bytes).verdict }

    /// Whether more bytes could change the verdict: false once it is decided.
    static func settled(_ bytes: Data) -> Bool { judge(bytes).final }

    private static let http = Array("HTTP/".utf8)

    private static func judge(_ data: Data) -> (verdict: Verdict, final: Bool) {
        let bytes = [UInt8](data.prefix(replyLimit))
        guard let first = bytes.first else { return (.unknown, false) }
        // A TLS record: an alert (0x15) or a handshake (0x16). An HTTPS-only server; the
        // browser opens `http://`, so nothing changes for it here.
        if first == 0x15 || first == 0x16 { return (.unknown, true) }
        if bytes.count < http.count, http.starts(with: bytes) { return (.unknown, false) }
        guard bytes.starts(with: http) else {
            // HTTP/0.9 answers with the page alone.
            let text = String(decoding: bytes.prefix(64), as: UTF8.self).lowercased()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if text.hasPrefix("<!doctype html") || text.hasPrefix("<html") { return (.web, true) }
            if "<!doctype html".hasPrefix(text) || "<html".hasPrefix(text) { return (.unknown, false) }
            return (.notWeb, true)
        }
        // `HTTP/1.1 426 Upgrade Required`: the status is the three digits after the first space.
        guard let space = bytes.firstIndex(of: 0x20), bytes.count >= space + 4 else { return (.unknown, false) }
        let digits = bytes[(space + 1)...(space + 3)]
        guard digits.allSatisfy({ (0x30...0x39).contains($0) }),
              let status = Int(String(decoding: digits, as: UTF8.self)) else { return (.unknown, true) }
        switch status {
        case 426:
            return (.notWeb, true)
        case 400:
            // `ws` and Bun say why in the body: "Bad WebSocket upgrade request: Missing or
            // invalid Upgrade header". Read on to the end, or to the limit, for it.
            let text = String(decoding: bytes, as: UTF8.self).lowercased()
            if text.contains("websocket") && text.contains("upgrade") { return (.notWeb, true) }
            return (.web, false)
        default:
            return (.web, true)
        }
    }

    /// Sends the request on a tunnel's data connection that has had its handshake, and reads the
    /// reply until the server ends it, `limit` bytes came, the verdict is settled, or `wait`
    /// passed. The connection is dropped afterwards, whatever happened. `sleep` stands in for the
    /// clock in tests; it must throw when its task is cancelled.
    public static func read(_ socket: any TunnelSocket, port: Int, limit: Int = replyLimit, wait: Duration = replyWait,
                            sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) async -> Data {
        let timer = Task {
            do { try await sleep(wait) } catch { return }
            socket.abort()
        }
        defer {
            timer.cancel()
            socket.abort()
        }
        var got = Data()
        do {
            try await socket.send(request(port: port))
            while got.count < limit, !settled(got) {
                guard let d = try await socket.receive() else { continue }
                // One empty message: the server's end of its data.
                if d.isEmpty { break }
                got.append(d)
            }
        } catch {
            // Closed, refused (1001 with no bytes) or out of time: what came is the answer.
        }
        return got.count > limit ? got.prefix(limit) : got
    }
}

/// Which ports have been asked and what they answered, for one computer. Pure, so it is tested;
/// `ServerConnection` holds one and runs the probes it hands out (docs/terminal.md, Ports).
///
/// - A verdict belongs to a process's port (`Key`: pid, port, dial address), so a dev server
///   that restarts under a new pid is asked again, and one port in two panes is asked once.
///   A key no list holds any more is dropped, and a probe that answers for a dropped key or an
///   older attempt changes nothing.
/// - A new key is held, hidden, until its probe answers or `hold` passes; then it shows unless
///   it answered `notWeb`. A key that replaces a shown one on the same port (a restart) isn't
///   held, so a row that was there doesn't blink.
/// - `web` and `notWeb` are final for the key. `unknown` shows, and is asked again once at the
///   next new listing of a pane that holds it; nothing is asked on a timer.
/// - At most `width` probes run at once; the rest wait their turn in order.
public struct PortProbeBook: Sendable {
    public struct Key: Hashable, Sendable {
        public var pid: Int?
        public var port: Int
        public var host: String

        public init(pid: Int?, port: Int, host: String) {
            self.pid = pid
            self.port = port
            self.host = host
        }

        public init(_ e: PortEntry) { self.init(pid: e.pid, port: e.port, host: e.dialHost) }
    }

    /// One probe to run: dial `key.host`:`key.port` from a tunnel in `session`.
    public struct Job: Equatable, Sendable {
        public var key: Key
        public var session: String
        public var attempt: Int
    }

    /// Where a key was seen: the first pane that lists it.
    public struct Place: Equatable, Sendable {
        public var session: String
        public var block: String

        public init(session: String, block: String) {
            self.session = session
            self.block = block
        }
    }

    enum Phase: Equatable {
        case queued
        case running(attempt: Int)
        case known(PortProbe.Verdict)
    }

    struct Item: Equatable {
        var phase: Phase
        var place: Place
        var firstSeen: Double
        /// Shown at once, held or not: it answered, or it took over a shown row's port.
        var released: Bool
    }

    /// How long a new port waits for its answer before it shows anyway, in seconds.
    public static let hold: Double = 1.5
    /// Probes at once, per computer.
    public static let width = 2
    /// Ports remembered as shown after they went, for a restart to take over.
    static let goneLimit = 64
    /// How long a shown port that went is remembered, in seconds: longer than a Restart waits
    /// for its port to come back (30 s).
    static let goneLife: Double = 60

    private(set) var items: [Key: Item] = [:]
    private var queue: [Key] = []
    private var nextAttempt = 0
    /// Ports (port, host, no pid) whose row was shown when their key went, and when, newest last.
    private var gone: [(key: Key, at: Double)] = []

    public init() {}

    /// The candidates as the lists hold them now, each key's first place. `relisted`: keys found
    /// in a list that is new since the last update; an `unknown` one is asked again. `canProbe`:
    /// probes can run on this computer now; while they can't, a new key shows at once (`unknown`),
    /// and is asked at its pane's next listing.
    public mutating func update(_ seen: [Key: Place], relisted: Set<Key>, now: Double, canProbe: Bool) {
        for (key, item) in items where seen[key] == nil {
            items[key] = nil
            if !hidden(item, now: now) { remember(key, now: now) }
        }
        queue.removeAll { items[$0] == nil }
        for (key, place) in seen.sorted(by: { ($0.key.port, $0.key.host) < ($1.key.port, $1.key.host) }) {
            if var item = items[key] {
                item.place = place
                if item.phase == .known(.unknown), relisted.contains(key), canProbe {
                    item.phase = .queued
                    queue.append(key)
                }
                items[key] = item
                continue
            }
            let tookOver = takeOver(key, now: now)
            if canProbe {
                items[key] = Item(phase: .queued, place: place, firstSeen: now, released: tookOver)
                queue.append(key)
            } else {
                items[key] = Item(phase: .known(.unknown), place: place, firstSeen: now, released: true)
            }
        }
    }

    /// The probes to start now: up to `width` running at once, in the order their keys came.
    public mutating func start() -> [Job] {
        var running = items.values.filter { if case .running = $0.phase { true } else { false } }.count
        var jobs: [Job] = []
        while running < Self.width, !queue.isEmpty {
            let key = queue.removeFirst()
            guard var item = items[key], item.phase == .queued else { continue }
            nextAttempt += 1
            item.phase = .running(attempt: nextAttempt)
            items[key] = item
            jobs.append(Job(key: key, session: item.place.session, attempt: nextAttempt))
            running += 1
        }
        return jobs
    }

    /// A probe's answer. False when it is stale (its key went, or a newer attempt replaced it):
    /// then nothing changed.
    @discardableResult
    public mutating func finish(_ job: Job, _ verdict: PortProbe.Verdict) -> Bool {
        guard var item = items[job.key], item.phase == .running(attempt: job.attempt) else { return false }
        item.phase = .known(verdict)
        item.released = true
        items[job.key] = item
        return true
    }

    /// Whether the key's row is hidden now: it answered `notWeb`, or it is new and still held.
    public func hidden(_ key: Key, now: Double) -> Bool {
        guard let item = items[key] else { return false }
        return hidden(item, now: now)
    }

    /// When the next held key shows by itself, if one is held.
    public func nextRelease(now: Double) -> Double? {
        items.values.filter { !$0.released && $0.phase != .known(.notWeb) && $0.firstSeen + Self.hold > now }
            .map { $0.firstSeen + Self.hold }.min()
    }

    /// The key's verdict so far: nil while it is asked for the first time.
    public func verdict(_ key: Key) -> PortProbe.Verdict? {
        guard case .known(let v) = items[key]?.phase else { return nil }
        return v
    }

    /// Probes running now.
    public var running: Int { items.values.filter { if case .running = $0.phase { true } else { false } }.count }

    private func hidden(_ item: Item, now: Double) -> Bool {
        if item.phase == .known(.notWeb) { return true }
        return !item.released && now < item.firstSeen + Self.hold
    }

    private mutating func remember(_ key: Key, now: Double) {
        let k = Key(pid: nil, port: key.port, host: key.host)
        gone.removeAll { $0.key == k || now - $0.at > Self.goneLife }
        gone.append((k, now))
        if gone.count > Self.goneLimit { gone.removeFirst(gone.count - Self.goneLimit) }
    }

    private mutating func takeOver(_ key: Key, now: Double) -> Bool {
        let k = Key(pid: nil, port: key.port, host: key.host)
        guard let i = gone.firstIndex(where: { $0.key == k }) else { return false }
        let fresh = now - gone[i].at <= Self.goneLife
        gone.remove(at: i)
        return fresh
    }
}
