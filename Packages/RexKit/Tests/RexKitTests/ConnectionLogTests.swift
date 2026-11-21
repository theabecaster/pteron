import XCTest
@testable import RexKit

/// The connection log: what an event keeps of a failure, the rings, the file and what it
/// survives, the exported text, and that no name or address of a server gets into either.
final class ConnectionLogTests: XCTestCase {
    private var folder: URL!
    private var file: URL { folder.appendingPathComponent("log/connections.clog") }

    override func setUp() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("clog-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A log whose clock moves one millisecond per event from a fixed start, with a fixed salt, so
    /// a file's bytes are the same on every run.
    private func makeLog(flushDelay: TimeInterval = 60) -> ConnectionLog {
        let clock = Ticker()
        return ConnectionLog(file: file, flushDelay: flushDelay, now: { clock.next() }, salt: { 0x9E37_79B9_7F4A_7C15 })
    }

    private final class Ticker: @unchecked Sendable {
        // `@unchecked`: `ms` is read and written under `lock`.
        private let lock = NSLock()
        private var ms: Int64 = 1_795_000_000_000
        func next() -> Date {
            lock.withLock {
                ms += 1
                return Date(timeIntervalSince1970: Double(ms) / 1000)
            }
        }
    }

    private func failure(_ code: Int, posix: Int? = nil, http: Int? = nil, close: Int? = nil,
                         reason: String? = nil, message: String = "x") -> ConnectionFailure {
        ConnectionFailure(domain: NSURLErrorDomain, code: code, message: message,
                          underlyingDomain: posix == nil ? nil : NSPOSIXErrorDomain, underlyingCode: posix,
                          httpStatus: http, closeCode: close, closeReason: reason)
    }

    // MARK: Events

    func testAFailureIsReducedToAKindAndItsCodes() {
        typealias Cause = ConnectionEvent.Cause
        let cases: [(ConnectionFailure, Cause, Int32)] = [
            (.timedOut(), .timeout, Int32(NSURLErrorTimedOut)),
            (failure(NSURLErrorNetworkConnectionLost), .lost, Int32(NSURLErrorNetworkConnectionLost)),
            (failure(NSURLErrorNetworkConnectionLost, posix: Int(ECONNRESET)), .reset, Int32(NSURLErrorNetworkConnectionLost)),
            (failure(NSURLErrorCannotConnectToHost, posix: Int(ECONNREFUSED)), .refused, Int32(NSURLErrorCannotConnectToHost)),
            (failure(NSURLErrorCannotConnectToHost, posix: Int(EHOSTUNREACH)), .unreachable, Int32(NSURLErrorCannotConnectToHost)),
            (failure(NSURLErrorCannotConnectToHost, posix: Int(ETIMEDOUT)), .timeout, Int32(NSURLErrorCannotConnectToHost)),
            (failure(NSURLErrorCannotFindHost), .dns, Int32(NSURLErrorCannotFindHost)),
            (failure(NSURLErrorDNSLookupFailed), .dns, Int32(NSURLErrorDNSLookupFailed)),
            (failure(NSURLErrorSecureConnectionFailed), .tls, Int32(NSURLErrorSecureConnectionFailed)),
            (failure(NSURLErrorServerCertificateUntrusted), .tls, Int32(NSURLErrorServerCertificateUntrusted)),
            (failure(NSURLErrorBadServerResponse, http: 502), .http, 502),
            (failure(NSURLErrorBadServerResponse, http: 403), .auth, 403),
            (failure(NSURLErrorBadServerResponse, http: 401), .auth, 401),
            (failure(NSURLErrorClientCertificateRequired), .auth, Int32(NSURLErrorClientCertificateRequired)),
            (failure(NSURLErrorNetworkConnectionLost, close: 1001), .closed, 1001),
            (failure(NSURLErrorNetworkConnectionLost, close: 1008, reason: "event backlog exceeded"), .policy, 1008),
            (failure(NSURLErrorNetworkConnectionLost, close: 1008,
                     reason: "no common API revision: update the server"), .revision, 1008),
            (failure(NSURLErrorNotConnectedToInternet), .noInternet, Int32(NSURLErrorNotConnectedToInternet)),
            (failure(NSURLErrorDataNotAllowed), .noInternet, Int32(NSURLErrorDataNotAllowed)),
            (failure(NSURLErrorCancelled), .cancelled, Int32(NSURLErrorCancelled)),
            (.invalidAddress("desk.example.ts.net"), .badAddress, 0),
            (ConnectionFailure(RexError.local("disconnected")), .local, 0),
            (ConnectionFailure(domain: NSPOSIXErrorDomain, code: Int(ECONNRESET), message: "x"), .reset, ECONNRESET),
            (ConnectionFailure(domain: NSPOSIXErrorDomain, code: Int(ENETDOWN), message: "x"), .noInternet, ENETDOWN),
            (ConnectionFailure(domain: "kCFErrorDomainCFNetwork", code: 310, message: "x", streamCode: -9807), .tls, 310),
            (ConnectionFailure(domain: "SomethingElse", code: 42, message: "x"), .other, 42),
        ]
        for (f, cause, code) in cases {
            let e = ConnectionEvent.closed(f)
            XCTAssertEqual(e.kind, .closed)
            XCTAssertEqual(e.cause, cause, "\(f.detail)")
            if cause != .local { XCTAssertEqual(e.code, code, "\(f.detail)") }
        }
        // The POSIX code under a URL error is kept beside it.
        XCTAssertEqual(ConnectionEvent.closed(failure(NSURLErrorCannotConnectToHost, posix: Int(ECONNREFUSED))).value,
                       Int64(ECONNREFUSED))
    }

    func testAnEventIsThirtyTwoBytesAndReadsBackTheSame() {
        var events: [ConnectionEvent] = [
            .launch(build: 2_611_201_913), .scene(.background), .scene(.active),
            .network([.satisfied, .expensive, .tailnet]), .network([]), .connecting,
            .connected(afterMilliseconds: 1234), .closed(.timedOut()), .retry(after: 15), .retry(after: 0),
            .closed(failure(NSURLErrorCannotConnectToHost, posix: Int(ECONNREFUSED))),
            .dormant, .stopped, .breaker(open: true), .breaker(open: false), .connecting(by: .network),
        ]
        XCTAssertEqual(ConnectionEvent.breaker(open: true).summary, "breaker open")
        XCTAssertEqual(ConnectionEvent.breaker(open: false).summary, "breaker closed")
        XCTAssertEqual(ConnectionEvent.connecting(by: .peer).summary, "connecting by=peer")
        XCTAssertEqual(ConnectionEvent.dormant.summary, "dormant")
        for i in events.indices {
            events[i].time = 1_795_000_000_000 + Int64(i)
            events[i].server = i % 2 == 0 ? 0 : UInt64.max - UInt64(i)
        }
        for e in events {
            let bytes = e.encoded()
            XCTAssertEqual(bytes.count, ConnectionEvent.size)
            XCTAssertEqual(ConnectionEvent.size, 32)
            XCTAssertEqual(ConnectionEvent(bytes: bytes), e)
        }
        XCTAssertEqual(ConnectionEvent.retry(after: 15).value, 15000)
        XCTAssertEqual(ConnectionEvent.retry(after: 0.5).value, 500)
    }

    func testDamagedBytesAreNotAnEvent() {
        var e = ConnectionEvent.closed(.timedOut())
        e.time = 1_795_000_000_000
        let good = e.encoded()
        for i in 0..<good.count {
            var bad = good
            bad[i] ^= 0x10
            XCTAssertNil(ConnectionEvent(bytes: bad), "byte \(i) changed")
        }
        XCTAssertNil(ConnectionEvent(bytes: Array(good.dropLast())))
        XCTAssertNil(ConnectionEvent(bytes: good + [0]))
    }

    // MARK: Rings

    func testEachServerKeepsItsNewestTwoHundredEvents() {
        var j = ConnectionJournal(salt: 7)
        let a = j.tag("a"), b = j.tag("b")
        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(a, 0)
        for i in 0..<500 {
            var e = ConnectionEvent.retry(after: Double(i))
            e.time = Int64(i)
            e.server = a
            j.add(e)
        }
        var one = ConnectionEvent.connecting
        one.server = b
        j.add(one)
        var launch = ConnectionEvent.launch(build: 1)
        launch.time = 1
        j.add(launch)
        XCTAssertEqual(ConnectionJournal.eventsPerRing, 200)
        XCTAssertEqual(j.servers[a]?.count, 200)
        XCTAssertEqual(j.servers[a]?.first?.time, 300, "the oldest went")
        XCTAssertEqual(j.servers[a]?.last?.time, 499)
        XCTAssertEqual(j.servers[b]?.count, 1, "one server's storm leaves another's events alone")
        XCTAssertEqual(j.app.count, 1)
        XCTAssertEqual(j.count, 202)
    }

    func testOneServerTooManyPushesOutTheQuietestRing() {
        var j = ConnectionJournal(salt: 7)
        for i in 0...ConnectionJournal.maxServers {
            var e = ConnectionEvent.connecting
            e.server = j.tag("server-\(i)")
            // Server 3 was heard from longest ago.
            e.time = i == 3 ? 1 : 100 + Int64(i)
            j.add(e)
        }
        XCTAssertEqual(j.servers.count, ConnectionJournal.maxServers)
        XCTAssertNil(j.servers[j.tag("server-3")])
        XCTAssertNotNil(j.servers[j.tag("server-0")])
        XCTAssertLessThanOrEqual(j.count, ConnectionJournal.maxEvents)
    }

    func testANetworkUpdateThatChangesNothingAddsNoLine() {
        var j = ConnectionJournal(salt: 7)
        XCTAssertTrue(j.add(.network([.satisfied])))
        XCTAssertFalse(j.add(.network([.satisfied])))
        XCTAssertFalse(j.add(.network([.satisfied])))
        XCTAssertTrue(j.add(.network([.satisfied, .expensive])))
        XCTAssertTrue(j.add(.network([.satisfied])))
        XCTAssertEqual(j.app.count, 3)
        // Other kinds repeat freely.
        XCTAssertTrue(j.add(.scene(.active)))
        XCTAssertTrue(j.add(.scene(.active)))
    }

    func testTheSaltChangesEveryTag() {
        let a = ConnectionJournal(salt: 1), b = ConnectionJournal(salt: 2)
        XCTAssertNotEqual(a.tag("desk"), b.tag("desk"))
        XCTAssertEqual(a.tag("desk"), ConnectionJournal(salt: 1).tag("desk"))
    }

    // MARK: File format

    private func sampleJournal() -> ConnectionJournal {
        var j = ConnectionJournal(salt: 0x1122_3344_5566_7788)
        for i in 0..<5 {
            var e = ConnectionEvent.closed(.timedOut())
            e.time = 1_795_000_000_000 + Int64(i)
            e.server = j.tag(i % 2 == 0 ? "one" : "two")
            j.add(e)
        }
        var l = ConnectionEvent.launch(build: 42)
        l.time = 1_795_000_000_000
        j.add(l)
        return j
    }

    func testTheFileReadsBackTheSameRings() throws {
        let j = sampleJournal()
        let data = j.encoded()
        XCTAssertEqual(data.count, ConnectionJournal.headerSize + 6 * ConnectionEvent.size)
        let read = try XCTUnwrap(ConnectionJournal.decode(data))
        XCTAssertFalse(read.torn)
        XCTAssertEqual(read.journal.salt, j.salt)
        XCTAssertEqual(read.journal.app, j.app)
        XCTAssertEqual(read.journal.servers, j.servers)
    }

    func testAFileThatEndsInsideAnEventKeepsTheEventsBeforeIt() throws {
        let j = sampleJournal()
        let data = j.encoded().dropLast(7)
        let read = try XCTUnwrap(ConnectionJournal.decode(Data(data)))
        XCTAssertTrue(read.torn)
        XCTAssertEqual(read.journal.count, 5)
    }

    func testADamagedFileIsDroppedWhole() {
        let good = sampleJournal().encoded()
        XCTAssertNil(ConnectionJournal.decode(Data()))
        XCTAssertNil(ConnectionJournal.decode(Data("not a log at all, just text".utf8)))
        XCTAssertNil(ConnectionJournal.decode(good.prefix(10)))
        var wrongVersion = good
        wrongVersion[4] = 9
        XCTAssertNil(ConnectionJournal.decode(wrongVersion))
        var flipped = good
        flipped[ConnectionJournal.headerSize + 40] ^= 0xFF
        XCTAssertNil(ConnectionJournal.decode(flipped))
        XCTAssertNil(ConnectionJournal.decode(good + Data(repeating: 0, count: 64)), "zeroes are no events")
    }

    // MARK: The log and its file

    func testEventsAreStillThereAfterARelaunch() async throws {
        let first = makeLog()
        first.record(.launch(build: 2_611_201_913))
        first.record(.connecting, server: "A")
        first.record(.closed(.timedOut()), server: "A")
        first.record(.retry(after: 1), server: "A")
        _ = await first.written()

        // The next launches: each a new log on the same file.
        for launch in 2...13 {
            let log = makeLog()
            log.record(.launch(build: Int64(launch)))
            log.record(.connecting, server: "A")
            _ = await log.written()
        }
        let last = makeLog()
        let text = await last.export(servers: ["A"])
        XCTAssertEqual(text.components(separatedBy: "launch build=").count - 1, 13, "every launch is in it")
        XCTAssertTrue(text.contains("launch build=2611201913"))
        XCTAssertTrue(text.contains("Server 1  closed timeout code=-1001"))
        XCTAssertTrue(text.contains("Server 1  retry in=1000ms"))
        XCTAssertTrue(text.contains("events 28"))
    }

    func testAnEventNotYetWrittenIsWrittenAfterTheDelay() async throws {
        let log = makeLog(flushDelay: 0.05)
        log.record(.connecting, server: "A")
        var size = 0
        for _ in 0..<400 where size == 0 {
            try? await Task.sleep(for: .milliseconds(5))
            size = (try? Data(contentsOf: file))?.count ?? 0
        }
        XCTAssertEqual(size, ConnectionJournal.headerSize + ConnectionEvent.size)
    }

    func testAStormOfEventsIsOneWrite() async {
        let log = makeLog()
        log.record(.launch(build: 1))
        var counts = await log.written()
        XCTAssertEqual(counts.rewrites, 1, "the first write makes the file")
        XCTAssertEqual(counts.appends, 0)

        // Five servers that fail and retry forty times each before the next write is due.
        for round in 0..<40 {
            for s in 0..<5 {
                log.record(.connecting, server: "server-\(s)")
                log.record(.closed(.timedOut()), server: "server-\(s)")
                log.record(.retry(after: Double(min(1 << min(round, 4), 15))), server: "server-\(s)")
            }
        }
        // Nothing is written until a write is asked for (the delay here is a minute).
        XCTAssertEqual((try? Data(contentsOf: file))?.count, ConnectionJournal.headerSize + ConnectionEvent.size)
        counts = await log.written()
        XCTAssertEqual(counts.appends + counts.rewrites, 2, "600 events, one write")
        let again = await log.written()
        XCTAssertEqual(again.appends + again.rewrites, 2, "nothing new, no write")
    }

    func testTheFileStaysUnderItsLimitHoweverManyEventsCome() async throws {
        let log = makeLog()
        var largest = 0
        for batch in 0..<120 {
            for i in 0..<97 {
                log.record(.retry(after: Double(i)), server: "server-\((batch + i) % 20)")
                if i % 10 == 0 { log.record(.scene(.active)) }
            }
            _ = await log.written()
            largest = max(largest, try Data(contentsOf: file).count)
        }
        XCTAssertLessThanOrEqual(largest, ConnectionLog.maxFileBytes)
        XCTAssertEqual(ConnectionLog.maxFileBytes, 96_016)
        let counts = await log.written()
        XCTAssertGreaterThan(counts.appends, counts.rewrites, "most writes only append")

        // And it reads back: the newest events of each ring.
        let read = try XCTUnwrap(ConnectionJournal.decode(Data(contentsOf: file)))
        XCTAssertEqual(read.journal.app.count, ConnectionJournal.eventsPerRing)
        XCTAssertEqual(read.journal.servers.count, ConnectionJournal.maxServers)
        XCTAssertTrue(read.journal.servers.values.allSatisfy { $0.count <= ConnectionJournal.eventsPerRing })
    }

    func testADamagedFileIsReplacedAndNothingCrashes() async throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        for junk in [Data(), Data("garbage".utf8), Data(repeating: 0xFF, count: 5000),
                     sampleJournal().encoded().prefix(ConnectionJournal.headerSize + 40) + Data(repeating: 1, count: 64)] {
            try junk.write(to: file)
            let log = makeLog()
            let before = await log.export(servers: [])
            XCTAssertTrue(before.contains("events 0"), "a damaged file holds nothing")
            log.record(.connecting, server: "A")
            _ = await log.written()
            let read = try XCTUnwrap(ConnectionJournal.decode(Data(contentsOf: file)))
            XCTAssertEqual(read.journal.count, 1)
            XCTAssertFalse(read.torn)
        }
    }

    func testAFileTornByACrashIsMadeWholeAtTheNextWrite() async throws {
        let first = makeLog()
        for _ in 0..<10 { first.record(.connecting, server: "A") }
        _ = await first.written()
        let whole = try Data(contentsOf: file)
        try whole.dropLast(11).write(to: file)

        let log = makeLog()
        log.record(.connected(afterMilliseconds: 5), server: "A")
        _ = await log.written()
        let data = try Data(contentsOf: file)
        XCTAssertEqual(data.count, ConnectionJournal.headerSize + 10 * ConnectionEvent.size, "9 whole events and the new one")
        let read = try XCTUnwrap(ConnectionJournal.decode(data))
        XCTAssertFalse(read.torn)
        XCTAssertEqual(read.journal.servers.values.first?.last?.kind, .connected)
    }

    func testAFileThatCannotBeReadIsLeftAlone() async throws {
        let first = makeLog()
        for _ in 0..<5 { first.record(.connecting, server: "A") }
        _ = await first.written()
        let before = try Data(contentsOf: file)
        // As before the phone's first unlock: the file is there and closed to the app.
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        let log = makeLog()
        log.record(.closed(.timedOut()), server: "A")
        let counts = await log.written()
        XCTAssertEqual(counts.appends + counts.rewrites, 0, "nothing is written over a file that wasn't read")
        let text = await log.export(servers: ["A"])
        XCTAssertTrue(text.contains("events 1"), "this launch's events are still kept in memory")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        XCTAssertEqual(try Data(contentsOf: file), before)

        // The next launch reads it again and goes on.
        let next = makeLog()
        next.record(.connecting, server: "A")
        _ = await next.written()
        let read = try XCTUnwrap(ConnectionJournal.decode(Data(contentsOf: file)))
        XCTAssertEqual(read.journal.count, 6)
    }

    func testAFolderThatCannotBeWrittenLosesNothingInMemory() async {
        // The log's folder is a file: no write can work.
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? Data("x".utf8).write(to: folder.appendingPathComponent("log"))
        let log = makeLog()
        log.record(.connecting, server: "A")
        let counts = await log.written()
        XCTAssertEqual(counts.appends + counts.rewrites, 0)
        let text = await log.export(servers: ["A"])
        XCTAssertTrue(text.contains("Server 1  connecting"))
    }

    // MARK: Export

    func testServersAreNumberedInTheAppsOrderAndARemovedOneIsFormer() async {
        let log = makeLog()
        log.record(.launch(build: 7))
        log.record(.network([.satisfied, .expensive, .tailnet]))
        log.record(.connecting, server: "gone")
        log.record(.connecting, server: "second")
        log.record(.connecting, server: "first")
        log.record(.connected(afterMilliseconds: 840), server: "first")
        log.record(.scene(.background))
        let text = await log.export(servers: ["first", "second"])
        let lines = text.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines[0], "Connection log")
        XCTAssertTrue(lines[1].hasPrefix("exported 2026-"))
        XCTAssertEqual(lines[2], "events 7")
        let body = lines.dropFirst(3).map { $0.split(separator: " ", maxSplits: 1).last.map(String.init) ?? "" }
        XCTAssertEqual(body.map { $0.trimmingCharacters(in: .whitespaces) }, [
            "App              launch build=7",
            "App              network satisfied=yes expensive=yes constrained=no tailnet=yes",
            "Former server 1  connecting",
            "Server 2         connecting",
            "Server 1         connecting",
            "Server 1         connected after=840ms",
            "App              scene background",
        ])
        XCTAssertTrue(lines[3].hasPrefix("2026-11-18T"), "times are UTC with milliseconds: \(lines[3])")
        XCTAssertTrue(lines[3].contains(".001Z"))
    }

    // MARK: A connection's states

    /// A `RexControl` on fake sockets and a fake clock, reported into a log: an attempt that
    /// times out, the retry, the welcome, a drop, and the app stopping it.
    @MainActor
    func testAConnectionsLifeIsReportedLineByLine() async {
        let log = makeLog()
        let clock = FakeControlClock(), sockets = FakeControlSockets()
        let control = RexControl(address: "https://desk.example.ts.net",
                                 client: ClientInfo(name: "test", version: "0", label: "test"),
                                 clock: clock, sockets: sockets.factory, random: { 0.5 })
        var uptime = 100.0
        let reporter = ConnectionReporter(log: log, server: "https://desk.example.ts.net") { uptime }
        control.onStateChange = { reporter.changed($0) }
        control.onRetryScheduled = { reporter.retryScheduled(after: $0) }
        control.onAttempt = { reporter.attempt($0) }
        control.onDormant = { reporter.wentDormant() }

        reporter.changed(.idle)
        let first = Task { @MainActor in try? await control.connect() }
        await pump()
        await clock.advance(by: control.policy.connectDeadline(expensive: false))
        _ = await first.value
        await clock.advance(by: 10)
        uptime += 0.84
        sockets.last.welcome()
        await pump()
        sockets.last.failReceive(URLError(.networkConnectionLost))
        await pump()
        control.kick()
        await pump()
        control.kick()
        await pump()
        control.disconnect()
        control.disconnect()
        await pump()

        let text = await log.export(servers: ["https://desk.example.ts.net"])
        let lines = text.split(separator: "\n").dropFirst(3).map { line in
            line.split(separator: " ", omittingEmptySubsequences: true).dropFirst(3).joined(separator: " ")
        }
        XCTAssertEqual(lines, [
            "connecting by=first",
            "closed timeout code=-1001",
            // `connect()` was the first attempt: the second follows by the 10 s.
            "retry in=10000ms",
            "connecting by=backoff",
            "connected after=840ms",
            "closed lost code=-1005",
            "retry in=500ms",
            // Two taps: one attempt.
            "connecting by=user",
            "stopped",
        ])
        XCTAssertTrue(text.contains("  Server 1  connecting"))
    }

    // MARK: Privacy

    /// Everything the app could hand the log that names a server, a network or a person goes in;
    /// none of it may come out, in the file's bytes or in the exported text.
    func testNoNameOrAddressReachesTheFileOrTheExport() async throws {
        let host = "desk.example.ts.net"
        let secrets = [
            host, "example.ts.net", "ts.net", "desk", "192.0.2.7", "198.51.100.23", "2001:db8::17", "fd7a:115c",
            "Kitchen Mac", "Kitchen", "zz-secret-session", "pane-title", "tok_abc123", "https://", "wss://", "utun",
        ]
        let log = makeLog()
        log.record(.launch(build: 2_611_201_913))
        log.record(.network([.satisfied, .tailnet]))
        log.record(.scene(.active))
        // The server keys an app might use: its address, its label, its IP.
        let keys = ["https://\(host)", "Kitchen Mac", "192.0.2.7", "wss://\(host):8443/api/control?token=tok_abc123"]
        let failures: [ConnectionFailure] = [
            .invalidAddress("https://\(host)"),
            ConnectionFailure(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost,
                              message: "A server with the specified hostname “\(host)” could not be found."),
            ConnectionFailure(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost,
                              message: "Could not connect to 192.0.2.7 (Kitchen Mac) on utun4",
                              underlyingDomain: NSPOSIXErrorDomain, underlyingCode: Int(ECONNREFUSED)),
            ConnectionFailure(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost, message: "lost",
                              closeCode: 1008, closeReason: "no common API revision: update the server at \(host) [2001:db8::17]"),
            ConnectionFailure(domain: NSURLErrorDomain, code: NSURLErrorBadServerResponse, message: "bad",
                              httpStatus: 403, closeReason: "session zz-secret-session pane-title tok_abc123"),
            ConnectionFailure(domain: "https://\(host)/198.51.100.23", code: 5, message: "Kitchen Mac at fd7a:115c:a1e0::1"),
            ConnectionFailure(URLError(.cannotFindHost, userInfo: [
                NSLocalizedDescriptionKey: "no such host \(host)",
                NSURLErrorFailingURLStringErrorKey: "https://\(host)/api/control",
            ])),
            ConnectionFailure(RexError.local("superseded while opening wss://\(host)")),
        ]
        for key in keys {
            log.record(.connecting, server: key)
            for f in failures { log.record(.closed(f), server: key) }
            log.record(.retry(after: 2), server: key)
            log.record(.connected(afterMilliseconds: 12), server: key)
        }
        _ = await log.written()
        // Once more through a relaunch, so both the appended and the rewritten file are checked.
        let bytes = try Data(contentsOf: file)
        let second = makeLog()
        second.record(.connecting, server: keys[0])
        _ = await second.written()
        let text = await second.export(servers: keys)

        XCTAssertGreaterThan(bytes.count, 40 * ConnectionEvent.size, "the events are in the file")
        XCTAssertTrue(text.contains("Server 4"))
        XCTAssertTrue(text.contains("closed dns code=-1003"))
        for stored in [bytes, try Data(contentsOf: file)] {
            for secret in secrets {
                for encoding in [String.Encoding.utf8, .utf16LittleEndian, .utf16BigEndian] {
                    let needle = try XCTUnwrap(secret.data(using: encoding))
                    XCTAssertNil(stored.range(of: needle), "“\(secret)” is in the file")
                }
                let lowered = Data(String(decoding: stored, as: UTF8.self).lowercased().utf8)
                XCTAssertNil(lowered.range(of: Data(secret.lowercased().utf8)), "“\(secret)” is in the file")
            }
        }
        for secret in secrets {
            XCTAssertFalse(text.lowercased().contains(secret.lowercased()), "“\(secret)” is in the exported text")
        }
        // The text is made of the log's own words and numbers only.
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzACFS0123456789 =-:.TZ\n")
        XCTAssertNil(text.unicodeScalars.first { !allowed.contains($0) }, "an unexpected character in the export")
    }
}
