import Foundation
import GlanceModel
import RexKit

/// Folders and several items in one stream, through a Rex fs block (`com.superlogical.fs`;
/// docs/terminal.md, Files, and docs/rex-protocol.md, The fs block).
extension ServerConnection {
    /// The pane's computer can send and take folders: the pane runs on the server's own host
    /// (an fs block is made on that host only), the server isn't Windows (uploads land under
    /// `/tmp`, and Go's patterns there read a backslash as a separator), and the creator list
    /// names the fs flavor on that host with the method. No revision is checked: a revision-24
    /// server lists the creator at every revision it serves.
    func takesTrees(_ method: String, block: BlockInfo?) -> Bool {
        guard let block, isLocal(block), let platform, !platform.hasPrefix("windows") else { return false }
        let host = capabilities.hostID
        return capabilities.hasFlavor(FsBlock.flavor, host: host)
            && capabilities.method(method, creator: FsBlock.creator, host: host) == .present
    }

    /// The folder every upload through an fs block goes into: a new one under `/tmp`, made by
    /// the upload itself, so nothing that is there already is ever replaced.
    nonisolated static let treeLanding = "/tmp"
}

/// The fs blocks this phone makes, one per transfer, in the pane's session. A block made with
/// `session.new_block` is detached: no window holds it, so no client shows it, and the Mac app
/// shows nothing new. Rex never removes one, so each is closed when its transfer ends, and every
/// block made is remembered (`TunnelLedger`, in its own key) until it is: on each sync of a server
/// with remembered blocks, the sweep closes every fs block with this phone's label that no
/// transfer uses, whoever owns it, as the ports' sweep does for tunnels.
@MainActor
final class TreeBlocks {
    private(set) lazy var tag: String = loadTag()
    private let loadTag: () -> String
    let ledger: TunnelLedger
    /// `<app> #<tag>`, the tunnels' label: the flavor tells the two apart.
    var label: String { "\(Brand.appName) #\(tag)" }
    /// The blocks transfers use now.
    private var live: Set<String> = []
    /// Blocks made lately, newest last: their events change no view.
    private var made: [String] = []
    /// "server session" where a `new_block` is under way.
    private var creating: Set<String> = []
    private let jobs = SerialJobs()

    init(tag: @escaping () -> String = { TunnelTag.load() },
         ledger: TunnelLedger = TunnelLedger(key: "fsBlocks")) {
        loadTag = tag
        self.ledger = ledger
    }

    /// The block is one of this phone's fs blocks, or one is being made in the session: its
    /// events change no view.
    func owns(_ bid: String?, server: UUID, session: String) -> Bool {
        if let bid, made.contains(bid) { return true }
        return creating.contains("\(server) \(session)")
    }

    /// Makes an fs block in `session`, runs `body` with it, and closes it, whatever `body` did.
    func with<T>(_ server: any TunnelServer, session sid: String,
                 _ body: @MainActor (String) async throws -> T) async throws -> T {
        let bid = try await make(server, session: sid)
        live.insert(bid)
        do {
            let value = try await body(bid)
            live.remove(bid)
            await close(bid, session: sid, on: server)
            return value
        } catch {
            live.remove(bid)
            await close(bid, session: sid, on: server)
            throw error
        }
    }

    private func make(_ server: any TunnelServer, session sid: String) async throws -> String {
        try await jobs.run { [self] () -> Result<String, Error> in
            ledger.mark(server: server.id, session: sid)
            let key = "\(server.id) \(sid)"
            creating.insert(key)
            defer {
                ledger.unmark(server: server.id, session: sid)
                creating.remove(key)
            }
            do {
                let r = try await server.tunnelCall("session.new_block", ["session_id": sid, "flavor": FsBlock.flavor, "label": label])
                guard let bid = r.str("block_id") else { return .failure(RexError.local("no block")) }
                ledger.remember(server: server.id, session: sid, block: bid)
                made.append(bid)
                if made.count > 64 { made.removeFirst(made.count - 64) }
                return .success(bid)
            } catch {
                return .failure(error)
            }
        }.get()
    }

    private func close(_ bid: String, session sid: String, on server: any TunnelServer) async {
        do {
            _ = try await server.tunnelCall("block.close", ["session_id": sid, "block_id": bid])
            ledger.forget(server: server.id, session: sid, block: bid)
        } catch {
            let code = (error as? RexError)?.code
            if code == "not_found" || code == "session_not_found" { ledger.forget(server: server.id, session: sid, block: bid) }
            // Otherwise it stays remembered, and the next sync's sweep closes it.
        }
    }

    /// A sync finished: blocks a killed app or a lost connection left are closed.
    func serverSynced(_ server: any TunnelServer) {
        let sessions = ledger.sessions(server: server.id)
        guard !sessions.isEmpty else { return }
        Task { await jobs.run { await self.sweep(server, sessions: sessions) } }
    }

    /// A server was removed in Settings: its blocks close when it is connected, else they are
    /// forgotten.
    func serverRemoved(_ server: any TunnelServer) {
        let sessions = ledger.sessions(server: server.id)
        guard !sessions.isEmpty else { return }
        guard server.tunnelConnected else { return ledger.forget(server: server.id) }
        Task {
            await jobs.run { await self.sweep(server, sessions: sessions) }
            ledger.forget(server: server.id)
        }
    }

    private func sweep(_ server: any TunnelServer, sessions: [String]) async {
        for sid in sessions {
            do {
                let r = try await server.tunnelCall("session.list_blocks", ["session_id": sid])
                let blocks = r.arr("blocks")
                let mine = blocks.filter {
                    $0.str("flavor") == FsBlock.flavor && $0.str("label") == label && !live.contains($0.str("block_id") ?? "")
                }.compactMap { $0.str("block_id") }
                let listed = Set(blocks.compactMap { $0.str("block_id") })
                for b in ledger.blocks(server: server.id, session: sid) where !listed.contains(b) && !live.contains(b) {
                    ledger.forget(server: server.id, session: sid, block: b)
                }
                for b in mine where !made.contains(b) { made.append(b) }
                let results = await server.tunnelCallsInOrder(mine.map { ("block.close", ["session_id": sid, "block_id": $0] as JSONObject) })
                for (b, res) in zip(mine, results) {
                    switch res {
                    case .success: ledger.forget(server: server.id, session: sid, block: b)
                    case .failure(let e):
                        let code = (e as? RexError)?.code
                        if code == "not_found" || code == "session_not_found" { ledger.forget(server: server.id, session: sid, block: b) }
                    }
                }
                if ledger.blocks(server: server.id, session: sid).allSatisfy({ live.contains($0) }) {
                    ledger.forget(server: server.id, session: sid, keeping: live)
                }
            } catch {
                let code = (error as? RexError)?.code
                if code == "session_not_found" || code == "not_found" { ledger.forget(server: server.id, session: sid) }
            }
        }
    }
}
