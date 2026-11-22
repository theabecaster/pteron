import Foundation
import GlanceModel
import RexKit

/// What a forward needs from a server. `ServerConnection` is the real one; tests use a fake.
@MainActor
protocol TunnelServer: AnyObject {
    var id: UUID { get }
    /// The server can make dial tunnels now (`ServerConnection.tunnelsAvailable`).
    var tunnelsAvailable: Bool { get }
    /// The first sync since the latest connect has finished.
    var synced: Bool { get }
    /// This app's client ID on the current connection; a tunnel block made on another is no
    /// longer owned by it after a long drop.
    var tunnelClientID: String? { get }
    var tunnelConnected: Bool { get }
    /// The computer's name, for what the user is told.
    var tunnelName: String { get }
    func tunnelCall(_ method: String, _ payload: JSONObject) async throws -> JSONObject
    func tunnelCallsInOrder(_ calls: [(method: String, payload: JSONObject)]) async -> [Result<JSONObject, Error>]
    /// A data connection to the block that has had its handshake.
    func openTunnel(ticket: String, in session: TunnelSession?) async throws -> any TunnelSocket
    /// A session for one browser's connections, or nil where tests need none.
    func makeTunnelSession() -> TunnelSession?
    /// The server said it can't make dial tunnels (`not_found` for the flavor).
    func tunnelsMissing()
}

/// Runs async jobs one at a time, in the order they were given.
@MainActor
final class SerialJobs {
    private var tail: Task<Void, Never>?

    func run<T: Sendable>(_ body: @escaping @MainActor () async -> T) async -> T {
        let before = tail
        let job = Task { @MainActor () -> T in
            await before?.value
            return await body()
        }
        tail = Task { _ = await job.value }
        return await job.value
    }
}

/// Opens a computer's dev server on the phone: one open browser at a time, through a Rex dial
/// tunnel (docs/terminal.md, Ports).
///
/// - The phone listens on 127.0.0.1 only, on the opened port when it is free and above 1024,
///   else on a free one, and only while the browser is up and the app is in front.
/// - The tunnel block (`com.superlogical.tunnel.dial`, detached, in the pane's session) is made
///   on the first connection, labeled `<app> #<tag>` with this phone's tag (`TunnelTag`). Each
///   browser connection is a data connection of its own (`TunnelRelay`), at most 16 at once.
/// - Rex never removes a tunnel block. So every block made is remembered (`TunnelLedger`), and
///   one about to be made is marked first; on each sync of a server with remembered blocks or a
///   mark, the sweep closes every block with this phone's tag that no browser uses.
/// - The blocks close before the app goes to the background, inside a background task, and when
///   the browser goes.
@MainActor
final class PortForward {
    /// Where a browser goes: a port of a terminal's computer, in that terminal's Rex session.
    struct Target: Equatable {
        var sessionID: String
        var port: Int
        /// Where the computer dials (`PortEntry.dialHost`).
        var dialHost: String
    }

    static let flavor = "com.superlogical.tunnel.dial"
    /// Connections that wait for the server to sync give up after this; WebKit waits 60 s.
    var syncedWait: Duration = .seconds(30)

    /// The open browser's forward.
    @MainActor
    final class Forward {
        let server: any TunnelServer
        let target: Target
        let listener: any PortListener
        /// The phone's port, kept for a return from the background.
        var localPort = 0
        var block: (id: String, clientID: String?)?
        var session: TunnelSession?
        var active = 0
        var waiting: [any TunnelLocal] = []
        var relays: [ObjectIdentifier: TunnelRelay] = [:]
        var syncWaiters: [Int: CheckedContinuation<Bool, Never>] = [:]
        var nextWaiter = 0
        /// One notice per browser for a refused block, and one for a lost server.
        var refusedShown = false
        var offlineShown = false
        var listening = false
        var closed = false

        init(server: any TunnelServer, target: Target, listener: any PortListener) {
            self.server = server
            self.target = target
            self.listener = listener
        }
    }

    /// Read from the Keychain on first use, so an app that never opens a page never reads it.
    private(set) lazy var tag: String = loadTag()
    private let loadTag: () -> String
    var label: String { "\(Brand.appName) #\(tag)" }
    let ledger: TunnelLedger
    private let makeListener: () -> any PortListener
    private let jobs = SerialJobs()
    private(set) var forward: Forward?
    /// The app is in the background: nothing listens.
    private var inBackground = false
    /// Shown when the browser can't go on (a refused block, a lost server). `Notice` by default.
    var notify: (String) -> Void = { Notice.shared.show($0, style: .neutral) }
    /// Begins a background task synchronously; returns its end. Tests count them.
    var beginBackground: (String) -> () -> Void = { name in
        let t = BackgroundTask(name: name) {}
        return { t.end() }
    }
    #if DEBUG
    /// Every step, for tests: `sweep <server>`, `close <ids>`, `new_block`, `listen <port>`, `stop`.
    var trace: [String] = []
    #endif

    init(tag: @escaping () -> String = { TunnelTag.load() }, ledger: TunnelLedger = TunnelLedger(),
         makeListener: @escaping () -> any PortListener = { LoopbackListener() }) {
        loadTag = tag
        self.ledger = ledger
        self.makeListener = makeListener
    }

    /// Tunnel blocks this app made lately, newest last: their events change no view.
    private var made: [String] = []
    /// The blocks of the probes running now (`probe`): no sweep closes them.
    private var probing: Set<String> = []
    /// How a probe waits for its reply; tests stand in for the clock. Must throw when cancelled.
    var probeSleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    /// Sessions where a `new_block` is under way, as "server session".
    private var creating: Set<String> = []

    /// The block is a tunnel this app made: its events change no view.
    func owns(_ blockID: String) -> Bool { made.contains(blockID) }

    /// A tunnel is being made in the session, so a `block_created` there may be it.
    func creating(in server: UUID, session: String) -> Bool { creating.contains("\(server) \(session)") }

    // MARK: Browser

    /// Starts listening for a browser on `target`, closing any other forward first. Returns the
    /// phone's port.
    func open(_ target: Target, on server: any TunnelServer) async throws -> Int {
        if forward != nil { close() }
        let f = Forward(server: server, target: target, listener: makeListener())
        forward = f
        f.session = server.makeTunnelSession()
        do {
            try await listen(f, preferring: target.port)
        } catch {
            if forward === f { close() }
            throw error
        }
        return f.localPort
    }

    /// The browser went: the block closes first, then the listener and the connections. With
    /// `only`, nothing happens unless that forward is still the open one.
    func close(_ only: Forward? = nil) {
        guard let f = forward, only == nil || only === f else { return }
        forward = nil
        let end = beginBackground("ports_close")
        f.closed = true
        Task { await self.teardown(f, forget: true); end() }
    }

    /// The app goes to the background (not merely inactive). The task begins before anything is
    /// queued, so the closes leave inside it.
    func enteredBackground() {
        inBackground = true
        guard let f = forward, f.listening else { return }
        let end = beginBackground("ports_background")
        Task { await self.teardown(f, forget: false); end() }
    }

    /// The app is in front again with the browser still up: listen on the same port again.
    func becameActive() {
        inBackground = false
        guard let f = forward, !f.closed, !f.listening, f.server.tunnelsAvailable else { return }
        Task { try? await self.listen(f, preferring: f.localPort) }
    }

    private func listen(_ f: Forward, preferring port: Int) async throws {
        // Set before the wait, so a sync meanwhile doesn't start a second one.
        f.listening = true
        let got: Int
        do {
            got = try await f.listener.start(preferring: port) { [weak self, weak f] local in
                guard let self, let f else { return local.reset() }
                self.accept(local, f)
            }
        } catch {
            f.listening = false
            throw error
        }
        guard !f.closed else { return f.listener.stop() }
        f.localPort = got
        #if DEBUG
        trace.append("listen \(got)")
        NSLog("PORTS_LISTEN %ld for %ld", got, f.target.port)
        #endif
    }

    /// Closes the forward's block, then stops the listener and resets the connections.
    /// `forget`: the browser is gone, so nothing restarts.
    private func teardown(_ f: Forward, forget: Bool) async {
        // No new connection from here on.
        f.listening = false
        // `block.close` goes first: it ends the open streams with 4000 in one round trip, before
        // the phone lets go of anything.
        if let b = f.block {
            f.block = nil
            await closeBlocks([b.id], session: f.target.sessionID, on: f.server)
        }
        f.listener.stop()
        for r in f.relays.values { r.cancel() }
        f.relays = [:]
        for l in f.waiting { l.reset() }
        f.waiting = []
        for w in f.syncWaiters.values { w.resume(returning: false) }
        f.syncWaiters = [:]
        #if DEBUG
        trace.append("stop")
        #endif
        if forget {
            f.session?.invalidate()
            f.session = nil
        }
    }

    // MARK: Connections

    private func accept(_ local: any TunnelLocal, _ f: Forward) {
        guard !f.closed, f.listening else { return local.reset() }
        if f.active < TunnelSession.slots {
            f.active += 1
            Task { await self.serve(local, f) }
        } else {
            f.waiting.append(local)
        }
    }

    private func serve(_ local: any TunnelLocal, _ f: Forward) async {
        defer {
            f.active -= 1
            if !f.waiting.isEmpty, !f.closed {
                let next = f.waiting.removeFirst()
                f.active += 1
                Task { await self.serve(next, f) }
            }
        }
        // The computer's one gate: while its control connection has no welcome, a page's request
        // dials nothing and asks nothing. The browser's connection is reset, as for any tunnel
        // that can't be made, and it tries again by itself.
        guard f.server.tunnelConnected else { return local.reset() }
        guard await waitSynced(f), !f.closed else { return local.reset() }
        var retried = false
        while true {
            guard let bid = await ensureBlock(f), !f.closed else { return local.reset() }
            let socket: any TunnelSocket
            do {
                let t = try await f.server.tunnelCall("data.connect", [
                    "session_id": f.target.sessionID, "block_id": bid,
                    "data_ref_id": BytesStream.ref("conn"), "subprotocol": BytesStream.subprotocol,
                ])
                guard let ticket = t.str("ticket"), f.server.tunnelConnected else { return local.reset() }
                socket = try await f.server.openTunnel(ticket: ticket, in: f.session)
            } catch {
                // A reconnect between the ticket and the HELLO: WebKit tries again on a new one.
                return local.reset()
            }
            guard !f.closed else {
                socket.abort()
                return local.reset()
            }
            let relay = TunnelRelay(socket: socket, local: local)
            let key = ObjectIdentifier(relay)
            f.relays[key] = relay
            let end = await relay.run()
            f.relays[key] = nil
            #if DEBUG
            // One line per browser connection, to check a page's loads on a simulator.
            NSLog("PORTS_CONN %@ block=%@", "\(end)", bid)
            #endif
            switch end {
            case .ownerLost(beforeAnyByte: true):
                // Another client owns the block now: make a new one, and send the request once more.
                if f.block?.id == bid { f.block = nil }
                guard !retried, local.rewind() else { return local.reset() }
                retried = true
                continue
            case .ownerLost, .blockClosed:
                if f.block?.id == bid { f.block = nil }
            default:
                break
            }
            return
        }
    }

    /// Waits up to `syncedWait` for the server's sync (after a return from the background, say).
    private func waitSynced(_ f: Forward) async -> Bool {
        if f.server.synced { return true }
        f.nextWaiter += 1
        let id = f.nextWaiter
        let wait = syncedWait
        let timeout = Task { [weak f] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled, let f, let w = f.syncWaiters.removeValue(forKey: id) else { return }
            w.resume(returning: false)
        }
        let ok = await withCheckedContinuation { f.syncWaiters[id] = $0 }
        timeout.cancel()
        return ok
    }

    /// The forward's block, made on its first connection: the sweep first, then the mark, then
    /// `session.new_block`. Nil when the server refused it.
    private func ensureBlock(_ f: Forward) async -> String? {
        if let b = f.block, b.clientID == f.server.tunnelClientID { return b.id }
        return await jobs.run { [self] in
            if let b = f.block, b.clientID == f.server.tunnelClientID { return b.id }
            guard !f.closed, f.server.tunnelsAvailable else { return nil }
            let sid = f.target.sessionID
            await sweep(f.server, sessions: [sid])
            ledger.mark(server: f.server.id, session: sid)
            let key = "\(f.server.id) \(sid)"
            creating.insert(key)
            defer {
                ledger.unmark(server: f.server.id, session: sid)
                creating.remove(key)
            }
            let client = f.server.tunnelClientID
            #if DEBUG
            trace.append("new_block \(f.target.dialHost):\(f.target.port)")
            NSLog("PORTS_NEW_BLOCK %@:%ld %@", f.target.dialHost, f.target.port, label)
            #endif
            do {
                let r = try await f.server.tunnelCall("session.new_block", [
                    "session_id": sid, "flavor": Self.flavor, "label": label,
                    "options": ["host": f.target.dialHost, "port": f.target.port,
                                "client_address": "127.0.0.1:\(f.localPort)"] as JSONObject,
                ])
                guard let bid = r.str("block_id") else { return nil }
                ledger.remember(server: f.server.id, session: sid, block: bid)
                made.append(bid)
                if made.count > 64 { made.removeFirst(made.count - 64) }
                // Made for a browser that went meanwhile: it closes at once.
                guard !f.closed else {
                    await closeBlocks([bid], session: sid, on: f.server)
                    return nil
                }
                f.block = (bid, client)
                return bid
            } catch {
                refused(error, f)
                return nil
            }
        }
    }

    /// `conflict` (the server is full), a changed shape (`bad_request`) or a request that never
    /// reached the server (the connection dropped): one notice per browser, so a page that
    /// doesn't load always says why. `not_found`: the server has no dial tunnels after all.
    private func refused(_ error: Error, _ f: Forward) {
        let e = error as? RexError
        if e?.code == "not_found" || e?.code == "method_not_found" { f.server.tunnelsMissing() }
        guard !f.refusedShown else { return }
        f.refusedShown = true
        if e?.neverSent == true || e?.code == "client" {
            notify("Couldn't open localhost:\(f.target.port). \(Messages.notSent(f.server.tunnelName))")
        } else {
            notify(e?.code == "conflict" ? "\(Messages.capitalized(f.server.tunnelName)) has too many panes open to show this page."
                                        : "Couldn't open the page. Try again.")
        }
    }

    // MARK: Probes

    /// Asks one port what it answers (`PortProbe`), for the Ports list and the pane menu's row:
    /// a dial block of its own made for this alone (labeled and remembered as the browser's are,
    /// so a sweep finds it after a kill), one data connection with `GET /` and at most 4 KB read,
    /// then the block closes. It reads only: nothing reaches a pane, nothing is kept, nothing is
    /// shown, whatever fails. Not through `CallGate`: the dial tunnel is separate from the sync's
    /// calls, and a probe is one small request per new port, on cellular too.
    func probe(_ target: Target, on server: any TunnelServer) async -> PortProbe.Verdict {
        guard server.tunnelConnected, server.synced, server.tunnelsAvailable,
              !PortRules.debuggerPorts.contains(target.port) else { return .unknown }
        guard let bid = await probeBlock(target, on: server) else { return .unknown }
        var bytes = Data()
        let session = server.makeTunnelSession()
        do {
            let t = try await server.tunnelCall("data.connect", [
                "session_id": target.sessionID, "block_id": bid,
                "data_ref_id": BytesStream.ref("conn"), "subprotocol": BytesStream.subprotocol,
            ])
            if let ticket = t.str("ticket"), server.tunnelConnected {
                let socket = try await server.openTunnel(ticket: ticket, in: session)
                bytes = await PortProbe.read(socket, port: target.port, sleep: probeSleep)
            }
        } catch {
            // No connection: nothing to go on.
        }
        session?.invalidate()
        await closeBlocks([bid], session: target.sessionID, on: server)
        probing.remove(bid)
        let verdict = PortProbe.classify(bytes)
        #if DEBUG
        // The verdict and the reply's size only: never the page's content.
        trace.append("probe \(target.dialHost):\(target.port) \(verdict)")
        NSLog("PORTS_PROBE %@:%ld %@ bytes=%ld", target.dialHost, target.port, "\(verdict)", bytes.count)
        #endif
        return verdict
    }

    /// The probe's block: marked, made and remembered as the browser's is, on the same job
    /// queue, so no sweep runs between its making and its entry in `probing`. No sweep first:
    /// the next sync's sweep finds leftovers. Nil when it couldn't be made; no notice.
    private func probeBlock(_ target: Target, on server: any TunnelServer) async -> String? {
        await jobs.run { [self] () -> String? in
            guard server.tunnelsAvailable, server.tunnelConnected else { return nil }
            let sid = target.sessionID
            ledger.mark(server: server.id, session: sid)
            let key = "\(server.id) \(sid)"
            creating.insert(key)
            defer {
                ledger.unmark(server: server.id, session: sid)
                creating.remove(key)
            }
            do {
                // No `client_address`: nothing on the phone listens for a probe.
                let r = try await server.tunnelCall("session.new_block", [
                    "session_id": sid, "flavor": Self.flavor, "label": label,
                    "options": ["host": target.dialHost, "port": target.port] as JSONObject,
                ])
                guard let bid = r.str("block_id") else { return nil }
                ledger.remember(server: server.id, session: sid, block: bid)
                made.append(bid)
                if made.count > 64 { made.removeFirst(made.count - 64) }
                probing.insert(bid)
                return bid
            } catch {
                let code = (error as? RexError)?.code
                if code == "not_found" || code == "method_not_found" { server.tunnelsMissing() }
                return nil
            }
        }
    }

    // MARK: Server state

    /// A sync finished on `server`: waiting connections go on, a block owned under an old client
    /// ID is dropped, and leftovers are swept. A server that can no longer make tunnels ends the
    /// browser's forward with one notice.
    func serverSynced(_ server: any TunnelServer) {
        if let f = forward, f.server === server {
            if !server.tunnelsAvailable {
                if f.listening { f.listener.stop() }
                f.listening = false
                if !f.offlineShown {
                    f.offlineShown = true
                    notify("This page can't be reached through Rex any more.")
                }
            } else {
                if let b = f.block, b.clientID != server.tunnelClientID {
                    // The connection was made again as another client: the block isn't ours to use.
                    f.block = nil
                }
                // The server can make tunnels again: the browser's next connection goes through.
                if !f.listening, !f.closed, !inBackground {
                    f.offlineShown = false
                    Task { try? await self.listen(f, preferring: f.localPort) }
                }
            }
            let waiters = f.syncWaiters
            f.syncWaiters = [:]
            for w in waiters.values { w.resume(returning: server.tunnelsAvailable) }
        }
        let sessions = ledger.sessions(server: server.id)
        guard !sessions.isEmpty else { return }
        Task { await jobs.run { await self.sweep(server, sessions: sessions) } }
    }

    /// A server was removed in Settings: its blocks close when it is connected, else they are
    /// forgotten.
    func serverRemoved(_ server: any TunnelServer) {
        if let f = forward, f.server === server { close() }
        let sessions = ledger.sessions(server: server.id)
        guard !sessions.isEmpty else { return }
        guard server.tunnelConnected else { return ledger.forget(server: server.id) }
        Task {
            await jobs.run { await self.sweep(server, sessions: sessions) }
            ledger.forget(server: server.id)
        }
    }

    /// Closes every dial block in the sessions that carries this phone's tag and no browser
    /// uses, whoever owns it, and forgets what is gone. Runs on the job queue.
    private func sweep(_ server: any TunnelServer, sessions: [String]) async {
        #if DEBUG
        trace.append("sweep \(sessions.sorted().joined(separator: ","))")
        NSLog("PORTS_SWEEP %@", sessions.sorted().joined(separator: ","))
        #endif
        // The browser's block and the probes' are in use.
        var live = probing
        if forward?.server === server, let b = forward?.block?.id { live.insert(b) }
        for sid in sessions {
            do {
                let r = try await server.tunnelCall("session.list_blocks", ["session_id": sid])
                let mine = r.arr("blocks").filter {
                    $0.str("flavor") == Self.flavor && $0.str("label") == label && !live.contains($0.str("block_id") ?? "")
                }.compactMap { $0.str("block_id") }
                let listed = Set(r.arr("blocks").compactMap { $0.str("block_id") })
                // Remembered blocks the server no longer has are gone.
                for b in ledger.blocks(server: server.id, session: sid) where !listed.contains(b) && !live.contains(b) {
                    ledger.forget(server: server.id, session: sid, block: b)
                }
                if !mine.isEmpty { await closeBlocks(mine, session: sid, on: server) }
                if ledger.blocks(server: server.id, session: sid).allSatisfy({ live.contains($0) }) {
                    ledger.forget(server: server.id, session: sid, keeping: live)
                }
            } catch {
                if (error as? RexError)?.code == "session_not_found" || (error as? RexError)?.code == "not_found" {
                    ledger.forget(server: server.id, session: sid)
                }
            }
        }
    }

    /// `block.close` for every block, sent in one turn. Closed and already-gone blocks are
    /// forgotten; one that couldn't be closed stays remembered for the next sweep.
    private func closeBlocks(_ ids: [String], session sid: String, on server: any TunnelServer) async {
        #if DEBUG
        trace.append("close \(ids.joined(separator: ","))")
        NSLog("PORTS_CLOSE %@", ids.joined(separator: ","))
        #endif
        // Their `block_closed` changes no view either.
        for id in ids where !made.contains(id) { made.append(id) }
        if made.count > 64 { made.removeFirst(made.count - 64) }
        let results = await server.tunnelCallsInOrder(ids.map { ("block.close", ["session_id": sid, "block_id": $0] as JSONObject) })
        for (id, r) in zip(ids, results) {
            switch r {
            case .success:
                ledger.forget(server: server.id, session: sid, block: id)
            case .failure(let e):
                let code = (e as? RexError)?.code
                if code == "not_found" || code == "session_not_found" { ledger.forget(server: server.id, session: sid, block: id) }
            }
        }
    }
}

/// This phone's tunnel tag: 8 hex characters in the Keychain, so it survives a reinstall and
/// the next launch can find blocks a killed app left. It never leaves the phone (this device
/// only, not synchronizable), so two phones never share one, and one phone never closes
/// another's tunnels.
enum TunnelTag {
    static let item = KeychainItem(service: "dev.abrahamgonzalez.rexduo.ports", account: "tunnel-tag")

    static func load(_ item: KeychainItem = item) -> String {
        do {
            if let data = try item.read(), let s = String(data: data, encoding: .utf8), valid(s) { return s }
            let fresh = make()
            try? item.write(Data(fresh.utf8))
            return fresh
        } catch {
            // The Keychain can't be read (before the first unlock): what it holds stays, and
            // this run uses a tag of its own.
            return make()
        }
    }

    static func make() -> String {
        (0..<4).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    static func valid(_ s: String) -> Bool {
        s.count == 8 && s.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
}

/// The tunnel blocks this phone made and may not have closed yet, and the sessions where one is
/// being made, per server, in UserDefaults: what the sweep looks for after a kill.
final class TunnelLedger {
    private struct Saved: Codable {
        /// server → session → blocks.
        var blocks: [String: [String: [String]]] = [:]
        /// server → sessions with a `new_block` under way.
        var marks: [String: [String]] = [:]
    }

    private let defaults: UserDefaults
    private let key: String
    private var saved: Saved

    init(defaults: UserDefaults = .standard, key: String = "portTunnels") {
        self.defaults = defaults
        self.key = key
        saved = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) } ?? Saved()
    }

    /// Sessions with remembered blocks or a mark.
    func sessions(server: UUID) -> [String] {
        let s = server.uuidString
        return Array(Set((saved.blocks[s] ?? [:]).keys).union(saved.marks[s] ?? [])).sorted()
    }

    func blocks(server: UUID, session: String) -> [String] {
        saved.blocks[server.uuidString]?[session] ?? []
    }

    func mark(server: UUID, session: String) {
        var m = saved.marks[server.uuidString] ?? []
        if !m.contains(session) { m.append(session) }
        saved.marks[server.uuidString] = m
        save()
    }

    func unmark(server: UUID, session: String) {
        saved.marks[server.uuidString]?.removeAll { $0 == session }
        if saved.marks[server.uuidString]?.isEmpty == true { saved.marks[server.uuidString] = nil }
        save()
    }

    func remember(server: UUID, session: String, block: String) {
        var s = saved.blocks[server.uuidString] ?? [:]
        var b = s[session] ?? []
        if !b.contains(block) { b.append(block) }
        s[session] = b
        saved.blocks[server.uuidString] = s
        save()
    }

    func forget(server: UUID, session: String, block: String) {
        saved.blocks[server.uuidString]?[session]?.removeAll { $0 == block }
        tidy(server)
        save()
    }

    /// Forgets the session, except the blocks a browser or a probe still uses.
    func forget(server: UUID, session: String, keeping live: Set<String> = []) {
        let kept = blocks(server: server, session: session).filter { live.contains($0) }
        if !kept.isEmpty {
            saved.blocks[server.uuidString]?[session] = kept
        } else {
            saved.blocks[server.uuidString]?[session] = nil
        }
        saved.marks[server.uuidString]?.removeAll { $0 == session }
        tidy(server)
        save()
    }

    func forget(server: UUID) {
        saved.blocks[server.uuidString] = nil
        saved.marks[server.uuidString] = nil
        save()
    }

    private func tidy(_ server: UUID) {
        let s = server.uuidString
        saved.blocks[s] = saved.blocks[s]?.filter { !$0.value.isEmpty }
        if saved.blocks[s]?.isEmpty == true { saved.blocks[s] = nil }
        if saved.marks[s]?.isEmpty == true { saved.marks[s] = nil }
    }

    private func save() {
        if saved.blocks.isEmpty, saved.marks.isEmpty {
            defaults.removeObject(forKey: key)
        } else if let d = try? JSONEncoder().encode(saved) {
            defaults.set(d, forKey: key)
        }
    }
}
