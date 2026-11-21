import Foundation
import RexKit

/// A pane on screen: its ports are read first on a new connection.
struct PortWatch {
    var session: String
}

/// One row of a machine's ports list: a web port a program in one of its panes listens on.
struct PortRow: Equatable, Identifiable {
    var sessionID: String
    var blockID: String
    var entry: PortEntry

    var id: String { "\(blockID):\(entry.port)" }
}

/// The ports list's rows from the panes' lists. Pure, so it is tested.
enum PortRows {
    /// `panes` in sidebar order; each pane's web ports follow by number. A port an agent holds
    /// itself (its sign-in or editor link) is no dev server: it gets no row. A server the agent
    /// started is another process and keeps its row.
    static func rows(panes: [(session: String, block: String)], list: (String) -> PortList?) -> [PortRow] {
        panes.flatMap { p in
            (list(p.block)?.webPorts ?? []).filter { !isAgent($0) }.map { PortRow(sessionID: p.session, blockID: p.block, entry: $0) }
        }
    }

    static func isAgent(_ e: PortEntry) -> Bool {
        [e.process, e.program].contains { $0.flatMap(AgentKind.fromProgram) != nil }
    }
}

/// Ports: which TCP ports programs in a pane listen on, for each machine's ports list, the pane
/// menu's row and tapped `localhost` links, and the gates that say where any of it applies
/// (docs/terminal.md, Ports).
///
/// Every local terminal's list is read once per connection, after the sync; then `ports_changed`
/// keeps it. Nothing here runs on a timer: a list changes only when the server says so.
extension ServerConnection {
    static let portsMethod = "com.superlogical.terminal.ports"
    /// The probe slot for the dial flavor: a `not_found` from `session.new_block` fills it.
    static let dialProbe = "session.new_block:\(PortForward.flavor)"
    /// How many `terminal.ports` reads are out at once after a sync.
    static let portReadWidth = 4

    /// The server lists a terminal's ports (revision 15), and no call on this connection found
    /// the method missing.
    var portsAvailable: Bool {
        capabilities.supports(15) && capabilities.probe(method: Self.portsMethod, host: nil) != false
    }

    /// The server makes dial tunnels: revision 14 (where tunnels were first documented) and the
    /// dial flavor in the creator list for its own host.
    var tunnelsAvailable: Bool {
        capabilities.supports(14) && capabilities.hasFlavor(PortForward.flavor, host: capabilities.hostID)
            && capabilities.probe(method: Self.dialProbe, host: nil) != false
    }

    /// The block runs on the server's own computer: its host is the server's, or it names none.
    /// A server that names no host has only blocks that name none as local.
    func isLocal(_ b: BlockInfo) -> Bool {
        guard let server = capabilities.hostID else { return b.hostID == nil }
        return b.hostID == nil || b.hostID == server
    }

    /// The block, from the views.
    func blockInfo(session sid: String, block bid: String) -> BlockInfo? {
        views[sid]?.windowContaining(block: bid)?.block(bid)
    }

    /// The pane menu's row, the ports list and links show for this block: a local terminal on
    /// a server that lists ports and makes tunnels.
    func showsPorts(session sid: String, block bid: String) -> Bool {
        guard portsAvailable, tunnelsAvailable, let b = blockInfo(session: sid, block: bid) else { return false }
        return b.isTerminal && isLocal(b)
    }

    // MARK: Following

    /// A pane came on screen: its ports are read now, if this connection hasn't yet.
    func watchPorts(session sid: String, block bid: String) {
        portWatch[bid] = PortWatch(session: sid)
        fillPorts(session: sid, block: bid)
    }

    /// The pane left the screen. Its list stays: the ports list shows it.
    func unwatchPorts(_ bid: String) {
        portWatch[bid] = nil
    }

    /// Reads one pane's ports, unless this connection read them or an event gave them already.
    func fillPorts(session sid: String, block bid: String) {
        guard portsRead[bid] != connectionSerial, control.state == .connected, showsPorts(session: sid, block: bid) else { return }
        portsRead[bid] = connectionSerial
        Task { await readPorts(session: sid, block: bid) }
    }

    /// Reads every local terminal's ports that this connection hasn't read: panes on screen
    /// first, then the rest, `portReadWidth` calls at a time. Once per connection for each pane.
    func fillAllPorts() {
        guard portsAvailable, tunnelsAvailable, control.state == .connected else { return }
        for (bid, w) in portWatch { fillPorts(session: w.session, block: bid) }
        let serial = connectionSerial
        let hidden = hiddenSessions()
        var due: [(session: String, block: String)] = []
        for (sid, v) in views where !hidden.contains(sid) {
            for b in v.windows.flatMap(\.allBlocks) where b.isTerminal && isLocal(b) && portsRead[b.id] != serial {
                portsRead[b.id] = serial
                due.append((sid, b.id))
            }
        }
        guard !due.isEmpty else { return }
        Task {
            var next = due.makeIterator()
            await withTaskGroup(of: Void.self) { g in
                for _ in 0..<Self.portReadWidth {
                    guard let d = next.next() else { break }
                    g.addTask { await self.readPorts(session: d.session, block: d.block) }
                }
                for await _ in g {
                    guard serial == connectionSerial, let d = next.next() else { continue }
                    g.addTask { await self.readPorts(session: d.session, block: d.block) }
                }
            }
        }
    }

    /// One `terminal.ports` call. A truncated reply keeps the entries that came. A read that
    /// fails leaves no list from before, and the next sync asks again.
    func readPorts(session sid: String, block bid: String) async {
        let serial = connectionSerial
        do {
            // On cellular the ports' reads share the sync's four (`syncCalls`); on Wi-Fi they
            // keep their own width.
            let r = gatesSync
                ? try await syncCalls.run { try await self.control.blockCall(Self.portsMethod, session: sid, block: bid) }
                : try await control.blockCall(Self.portsMethod, session: sid, block: bid)
            guard serial == connectionSerial, blockInfo(session: sid, block: bid) != nil else { return }
            capabilities.record(method: Self.portsMethod, host: nil, .present, serial: serial)
            pendingPorts[bid] = nil
            ports.set(bid, PortList(r, label: ProcessNames.label))
        } catch {
            guard serial == connectionSerial else { return }
            capabilities.record(method: Self.portsMethod, host: nil, error: error, targetExists: true, serial: serial)
            if capabilities.probe(method: Self.portsMethod, host: nil) == false { ports.removeAll() } else { ports.remove(bid) }
            portsRead[bid] = nil
        }
        refreshPortRows()
    }

    /// `ports_changed`: the whole list, for a local terminal. It counts as this connection's
    /// read of the pane.
    func receivePorts(session sid: String, _ bid: String, _ payload: JSONObject) {
        guard portsAvailable else { return }
        if let b = blockInfo(session: sid, block: bid), !(b.isTerminal && isLocal(b)) { return }
        portsRead[bid] = connectionSerial
        pendingPorts[bid] = PortList(payload, label: ProcessNames.label)
        scheduleFlush(after: Self.coalesce)
    }

    /// Applies buffered `ports_changed` lists, from the metadata flush. Equal lists write
    /// nothing. A list for a block no view holds is dropped, unless the block is new.
    func flushPorts() {
        guard !pendingPorts.isEmpty else { return }
        let present = Set(views.values.flatMap { $0.windows.flatMap(\.allBlocks).map(\.id) })
        var waiting: [String: PortList] = [:]
        for (bid, list) in pendingPorts {
            if present.contains(bid) {
                ports.set(bid, list)
            } else if createdAt[bid] != nil {
                // A new block whose view is on its way: applied when it lands (`createdBlocksShown`).
                waiting[bid] = list
            } else {
                portsRead[bid] = nil
            }
        }
        pendingPorts = waiting
        refreshPortRows()
    }

    /// A `ports_changed` was too large to send: the list is read again.
    func portsDropped(session sid: String?, _ bid: String) {
        guard let sid = sid ?? views.first(where: { $0.value.windowContaining(block: bid) != nil })?.key,
              showsPorts(session: sid, block: bid) else { return }
        portsRead[bid] = connectionSerial
        Task { await readPorts(session: sid, block: bid) }
    }

    /// A new connection: every list is read again after the sync. Until then the lists from
    /// before stay, so the ports list doesn't leave and come back on every reconnect.
    func resetPorts() {
        pendingPorts = [:]
        portsRead = [:]
    }

    /// A sync finished: panes no longer in a view lose their lists, a server that stopped
    /// listing ports loses them all, and every pane this connection hasn't read is read.
    func portsSynced() {
        if portsAvailable {
            let present = Set(views.values.flatMap { $0.windows.flatMap(\.allBlocks).map(\.id) })
            ports.removeAll { !present.contains($0) }
            portsRead = portsRead.filter { present.contains($0.key) }
        } else {
            ports.removeAll()
        }
        refreshPortRows()
        fillAllPorts()
    }

    func forgetPorts(_ bid: String) {
        pendingPorts[bid] = nil
        portsRead[bid] = nil
        ports.remove(bid)
        refreshPortRows()
    }

    /// Works out the ports list's rows again, and writes them only when they changed. Called
    /// where a list or the gates change; nothing reads the lists per frame.
    func refreshPortRows() {
        var rows: [PortRow] = []
        if portsAvailable, tunnelsAvailable, !ports.isEmpty {
            let hidden = hiddenSessions()
            var panes: [(session: String, block: String)] = []
            for e in orderedSessions where !hidden.contains(e.id) {
                guard let v = views[e.id] else { continue }
                for wid in orderedWindowIDs(e.id) {
                    for b in v.window(wid)?.allBlocks ?? [] where b.isTerminal && isLocal(b) { panes.append((e.id, b.id)) }
                }
            }
            rows = PortRows.rows(panes: panes) { ports.value($0) }
        }
        guard rows != portRows else { return }
        portRows = rows
        portRowPlaces = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let ids = rows.map(\.id)
        if ids != portRowIDs { portRowIDs = ids }
        if hasPortRows == ids.isEmpty { hasPortRows = !ids.isEmpty }
    }

    /// One row, read from its own pane's list: a view that calls this observes that pane's
    /// ports and nothing else.
    func portRow(_ id: String) -> PortRow? {
        guard let place = portRowPlaces[id], let entry = ports.value(place.blockID)?.entry(place.entry.port),
              PortRules.isWeb(entry), !PortRows.isAgent(entry) else { return nil }
        return PortRow(sessionID: place.sessionID, blockID: place.blockID, entry: entry)
    }

    // MARK: New blocks' metadata

    /// Marks older than this are dropped: their block never reached a view.
    static let createdMarkLife: TimeInterval = 30
    /// How long after `block_created` a new pane's metadata is read, as before.
    static let createdMetaDelay: TimeInterval = 0.3

    /// `block_created`: the block's metadata is read once it is in a view (`createdBlocksShown`),
    /// no sooner than `createdMetaDelay` after the event. A tunnel never enters a view, so it
    /// costs no terminal calls.
    func noteCreated(_ bid: String, now: Date = Date()) {
        createdAt = createdAt.filter { now.timeIntervalSince($0.value) < Self.createdMarkLife }
        createdAt[bid] = now
    }

    /// A view arrived: its terminal blocks that are new to it, marked by `block_created` and
    /// without metadata, get their read now or when the delay is up.
    func createdBlocksShown(_ view: SessionView, old: SessionView?, now: Date = Date()) {
        // A new block's ports may have come before its view.
        if !pendingPorts.isEmpty { scheduleFlush(after: Self.coalesce) }
        guard !createdAt.isEmpty else { return }
        let before = Set(old?.windows.flatMap(\.allBlocks).map(\.id) ?? [])
        var due: [(String, TimeInterval)] = []
        for w in view.windows {
            for b in w.allBlocks where b.isTerminal && !before.contains(b.id) {
                guard let at = createdAt.removeValue(forKey: b.id) else { continue }
                guard currentMeta(b.id) == nil else { continue }
                due.append((b.id, max(0, Self.createdMetaDelay - now.timeIntervalSince(at))))
            }
        }
        let sid = view.sessionID
        for (bid, wait) in due {
            Task {
                if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
                await loadMeta([(sid, bid)])
            }
        }
    }

    /// The block is a tunnel of the open browser, or one is being made in the session: its
    /// events change no view.
    func ownTunnel(_ bid: String?, session sid: String) -> Bool {
        guard let forward else { return false }
        if let bid, forward.owns(bid) { return true }
        return forward.creating(in: id, session: sid)
    }
}

extension ServerConnection: TunnelServer {
    var tunnelClientID: String? { control.clientID }
    /// Not in the background, and not after it before the control connection has answered
    /// (`RexControl.holdsData`): a page's request dials nothing until then.
    var tunnelConnected: Bool { control.state == .connected && !control.holdsData }
    var tunnelName: String { config.name }

    func tunnelCall(_ method: String, _ payload: JSONObject) async throws -> JSONObject {
        try await control.call(method, payload)
    }

    func tunnelCallsInOrder(_ calls: [(method: String, payload: JSONObject)]) async -> [Result<JSONObject, Error>] {
        await control.callInOrder(calls)
    }

    /// The control connection's own: every connection it opens asks the computer's gate first,
    /// and all of them are dropped when the control socket stops answering.
    func makeTunnelSession() -> TunnelSession? {
        control.makeTunnelSession()
    }

    func openTunnel(ticket: String, in session: TunnelSession?) async throws -> any TunnelSocket {
        guard let session else { throw RexError.local("no tunnel session") }
        return try await session.open(ticket: ticket)
    }

    func tunnelsMissing() {
        capabilities.record(method: Self.dialProbe, host: nil, .absent, serial: connectionSerial)
    }
}
