import Foundation
import RexKit

/// A pane on screen whose ports are followed.
struct PortWatch {
    var session: String
    /// The connection its ports were read on; nil until read.
    var readOn: Int?
}

/// Ports: which TCP ports programs in a pane listen on, for the pane menu's row and for tapped
/// `localhost` links, and the gates that say where any of it applies (docs/terminal.md, Ports).
///
/// Nothing runs for a pane that isn't on screen. A pane that comes on screen reads its ports once
/// per connection; after that `ports_changed` keeps them, and only for panes on screen: every
/// other pane's event is dropped after its `block_id` is read.
extension ServerConnection {
    static let portsMethod = "com.superlogical.terminal.ports"
    /// The probe slot for the dial flavor: a `not_found` from `session.new_block` fills it.
    static let dialProbe = "session.new_block:\(PortForward.flavor)"

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

    /// The pane menu's row and links show for this block: a local terminal on a server that
    /// lists ports and makes tunnels.
    func showsPorts(session sid: String, block bid: String) -> Bool {
        guard portsAvailable, tunnelsAvailable, let b = blockInfo(session: sid, block: bid) else { return false }
        return b.isTerminal && isLocal(b)
    }

    // MARK: Following panes on screen

    /// A pane came on screen: its ports are read, once per connection, and followed.
    func watchPorts(session sid: String, block bid: String) {
        if portWatch[bid] == nil { portWatch[bid] = PortWatch(session: sid, readOn: nil) }
        fillPorts(bid)
    }

    /// The pane left the screen: its ports are no longer kept.
    func unwatchPorts(_ bid: String) {
        guard portWatch.removeValue(forKey: bid) != nil else { return }
        pendingPorts[bid] = nil
        ports.remove(bid)
    }

    /// Reads a watched pane's ports, unless they were read on this connection already.
    func fillPorts(_ bid: String) {
        guard let w = portWatch[bid], w.readOn != connectionSerial, control.state == .connected,
              showsPorts(session: w.session, block: bid) else { return }
        portWatch[bid]?.readOn = connectionSerial
        readPorts(session: w.session, block: bid)
    }

    /// One `terminal.ports` call. A truncated reply keeps the entries that came.
    func readPorts(session sid: String, block bid: String) {
        let serial = connectionSerial
        Task {
            do {
                let r = try await control.blockCall(Self.portsMethod, session: sid, block: bid)
                guard serial == connectionSerial, portWatch[bid] != nil else { return }
                capabilities.record(method: Self.portsMethod, host: nil, .present, serial: serial)
                pendingPorts[bid] = nil
                ports.set(bid, PortList(r, label: Self.processLabel))
            } catch {
                capabilities.record(method: Self.portsMethod, host: nil, error: error, targetExists: true, serial: serial)
                if capabilities.probe(method: Self.portsMethod, host: nil) == false { ports.removeAll() }
            }
        }
    }

    /// `ports_changed`: the whole list, for a pane on screen. Anything else is dropped unread.
    func receivePorts(_ bid: String, _ payload: JSONObject) {
        guard portWatch[bid] != nil, portsAvailable else { return }
        pendingPorts[bid] = PortList(payload, label: Self.processLabel)
        scheduleFlush(after: Self.coalesce)
    }

    /// Applies buffered `ports_changed` lists, from the metadata flush. Equal lists write nothing.
    func flushPorts() {
        guard !pendingPorts.isEmpty else { return }
        for (bid, list) in pendingPorts where portWatch[bid] != nil { ports.set(bid, list) }
        pendingPorts = [:]
    }

    /// A `ports_changed` was too large to send: read the list again if the pane is on screen.
    func portsDropped(_ bid: String) {
        guard let w = portWatch[bid], showsPorts(session: w.session, block: bid) else { return }
        readPorts(session: w.session, block: bid)
    }

    /// A new connection: lists from before may be stale, and are read again after the sync.
    func resetPorts() {
        pendingPorts = [:]
        ports.removeAll()
    }

    /// A sync finished: panes no longer in a view lose their lists, and panes on screen read
    /// theirs if this connection hasn't yet.
    func portsSynced() {
        let present = Set(views.values.flatMap { $0.windows.flatMap(\.allBlocks).map(\.id) })
        ports.removeAll { !present.contains($0) || portWatch[$0] == nil }
        fillWatchedPorts()
    }

    /// Every pane on screen reads its ports, if this connection hasn't yet and the gates pass.
    func fillWatchedPorts() {
        for bid in portWatch.keys { fillPorts(bid) }
    }

    func forgetPorts(_ bid: String) {
        pendingPorts[bid] = nil
        ports.remove(bid)
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
    var tunnelConnected: Bool { control.state == .connected }

    func tunnelCall(_ method: String, _ payload: JSONObject) async throws -> JSONObject {
        try await control.call(method, payload)
    }

    func tunnelCallsInOrder(_ calls: [(method: String, payload: JSONObject)]) async -> [Result<JSONObject, Error>] {
        await control.callInOrder(calls)
    }

    func makeTunnelSession() -> TunnelSession? {
        control.wsBase.map { TunnelSession(base: $0) }
    }

    func openTunnel(ticket: String, in session: TunnelSession?) async throws -> any TunnelSocket {
        guard let session else { throw RexError.local("no tunnel session") }
        return try await session.open(ticket: ticket)
    }

    func tunnelsMissing() {
        capabilities.record(method: Self.dialProbe, host: nil, .absent, serial: connectionSerial)
    }
}
