import Foundation
import Observation
import RexKit

/// What one server can do, so each feature shows only where it works. One per `ServerConnection`:
/// with two servers saved, one's support never shows an entry point for the other's pane.
///
/// Three sources, cheapest first:
/// - the API revision the connection negotiated (`supports`);
/// - the creator list (`block_creator.list`), which names every block method, block event and
///   flavor a host has, with no further call;
/// - a probe: the answer a feature's own first call gave, kept per host.
///
/// It is observable for entry points only: a menu row that reads it appears or goes when a
/// reconnect changes the answer. Nothing here is read on the terminal's path.
@MainActor
@Observable
final class ServerCapabilities {
    /// The creator list has three states. Unknown and failed both mean "no answer": a feature
    /// then falls back to its probe, or stays hidden.
    enum Creators: Equatable {
        case unknown
        case known(CreatorCatalog)
        /// The read failed. A server too old for `block_creator.list` ends here.
        case failed
    }

    private struct ProbeKey: Hashable {
        var method: String
        var host: String?
    }

    /// The API revision of the current connection; 0 before the first one and on a server from
    /// before revisions.
    private(set) var revision = 0
    /// The newest revision the server speaks.
    private(set) var serverRevision = 0
    private(set) var features: Set<String> = []
    private(set) var creators: Creators = .unknown
    /// The machine and account the server runs as (`server_status.host_id`). A block or creator
    /// with another `host_id` is on a remote host. Nil on a server that doesn't say.
    private(set) var hostID: String?
    private var probes: [ProbeKey: Bool] = [:]

    /// The probes that came back without an answer on this connection: how often, and when last.
    @ObservationIgnored private var asks: [ProbeKey: (count: Int, last: Date)] = [:]
    @ObservationIgnored private var instance: String?
    /// Which server a creator list belongs to. The list is about 70 KB, so it is read once per
    /// server process and API revision, not on every sync. A server that names no process
    /// (`instance_id`) may be another one after any reconnect, so there the connection counts too.
    private struct ListKey: Equatable {
        var instance: String?
        var revision: Int
        var serial: Int?
    }
    /// The server as of the latest sync; nil before the first.
    @ObservationIgnored private var currentKey: ListKey?
    /// The server the list (or its failure) was read from.
    @ObservationIgnored private var loadedKey: ListKey?
    /// The connection these answers are for (`ServerConnection.connectionSerial`).
    @ObservationIgnored private(set) var serial = 0

    /// How long a probe that gave no answer waits before it is asked again on one connection.
    static let probeRetry: TimeInterval = 60
    /// How often a probe is asked on one connection: once, and once more after `probeRetry`.
    static let probeAsks = 2

    /// The connection speaks at least this revision.
    func supports(_ revision: Int) -> Bool { self.revision >= revision }

    // MARK: Updates, from the connection

    /// A connection was made. Probe answers belong to the old one and go. The creator list is
    /// kept while the revision is the same, so entry points don't blink on every wake; `status`
    /// drops it if the server is another process.
    func connected(serial: Int, revision: Int, serverRevision: Int, features: Set<String>) {
        self.serial = serial
        if !probes.isEmpty { probes = [:] }
        asks = [:]
        let sameRevision = revision == self.revision
        if self.revision != revision { self.revision = revision }
        if self.serverRevision != serverRevision { self.serverRevision = serverRevision }
        if self.features != features { self.features = features }
        if case .known = creators, sameRevision { return }
        if creators != .unknown { creators = .unknown }
    }

    /// The server's status from a sync. Another process (`instance_id`) is another server as far
    /// as a kept creator list goes: it may be a different version.
    func status(instance: String?, hostID: String?) {
        if self.hostID != hostID { self.hostID = hostID }
        if let old = self.instance, old != instance, creators != .unknown { creators = .unknown }
        self.instance = instance
        currentKey = ListKey(instance: instance, revision: revision, serial: instance == nil ? serial : nil)
    }

    /// Whether a sync should read `block_creator.list`: nothing was read from this server process
    /// at this revision yet. `creator_changed` and `hosts_changed` read it whatever this says.
    var needsCreatorRead: Bool { currentKey == nil || loadedKey != currentKey }

    /// The result of `block_creator.list` read on connection `serial`, or nil when the server
    /// answered with an error. A failed read never takes away a list that is known: the list
    /// stays, and the next sync asks again.
    func creatorsLoaded(_ result: JSONObject?, serial: Int) {
        guard serial == self.serial else { return }
        guard let result else {
            if creators == .unknown {
                creators = .failed
                loadedKey = currentKey
            } else {
                loadedKey = nil
            }
            return
        }
        let next = Creators.known(CreatorCatalog(result))
        if creators != next { creators = next }
        loadedKey = currentKey
    }

    /// A creator read got no answer because the connection dropped under it. Nothing known
    /// changes; the next sync reads again.
    func creatorReadLost() { loadedKey = nil }

    // MARK: Creator list

    var catalog: CreatorCatalog? {
        if case .known(let c) = creators { return c }
        return nil
    }

    /// Whether `host` can make blocks of a flavor (full name). False while the list is unknown.
    func hasFlavor(_ flavor: String, host: String?) -> Bool {
        catalog?.hasFlavor(flavor, host: host) ?? false
    }

    func blockMethods(creator: String, host: String?) -> Set<String>? {
        catalog?.blockMethods(creator: creator, host: host)
    }

    func blockEvents(creator: String, host: String?) -> Set<String>? {
        catalog?.blockEvents(creator: creator, host: host)
    }

    /// Whether blocks of `creator` on `host` have a method (short name). Unknown while the list
    /// is, and for a creator that lists no methods at all (an older shape).
    func method(_ short: String, creator: String, host: String?) -> Presence {
        catalog?.method(short, creator: creator, host: host) ?? .unknown
    }

    /// Whether blocks of `creator` on `host` send an event.
    func event(_ name: String, creator: String, host: String?) -> Presence {
        catalog?.event(name, creator: creator, host: host) ?? .unknown
    }

    // MARK: Probes

    /// What a feature's own call said about a method on a host: true, false, or nil while nobody
    /// has an answer on this connection.
    func probe(method: String, host: String?) -> Bool? {
        probes[ProbeKey(method: method, host: host)]
    }

    /// Whether to ask now. A probe with no answer is asked once more on the same connection,
    /// `probeRetry` after the first try, and then not again until the next connection.
    func shouldProbe(method: String, host: String?, now: Date = Date()) -> Bool {
        let key = ProbeKey(method: method, host: host)
        guard probes[key] == nil else { return false }
        guard let asked = asks[key] else { return true }
        return asked.count < Self.probeAsks && now.timeIntervalSince(asked.last) >= Self.probeRetry
    }

    /// Records what a call on connection `serial` showed. Unknown leaves the slot empty.
    func record(method: String, host: String?, _ presence: Presence, serial: Int, now: Date = Date()) {
        guard serial == self.serial else { return }
        let key = ProbeKey(method: method, host: host)
        guard let answer = presence.answer else {
            asks[key] = ((asks[key]?.count ?? 0) + 1, now)
            return
        }
        asks[key] = nil
        if probes[key] != answer { probes[key] = answer }
    }

    /// Records a probe call's outcome: no error means the method is there. `targetExists`: the
    /// block or server the call named is known to exist, so a bare `not_found` means the method.
    func record(method: String, host: String?, error: Error?, targetExists: Bool, serial: Int, now: Date = Date()) {
        let presence: Presence
        if let error {
            presence = (error as? RexError)?.presence(targetExists: targetExists) ?? .unknown
        } else {
            presence = .present
        }
        record(method: method, host: host, presence, serial: serial, now: now)
    }
}

/// What the app reads again when the server says an event was too large to send
/// (`event_dropped`). Features register here for the block events whose state only they keep.
@MainActor
final class EventRouter {
    /// `session` is nil when the server didn't name it and no view holds the block.
    typealias BlockHandler = @MainActor (_ session: String?, _ block: String) -> Void

    private var blockHandlers: [String: [BlockHandler]] = [:]

    /// Calls `handler` when a block event of this name was dropped, after the block's metadata
    /// read is started. A handler that writes state checks `connectionSerial` first.
    func on(blockEvent name: String, _ handler: @escaping BlockHandler) {
        blockHandlers[name, default: []].append(handler)
    }

    func handlers(forBlockEvent name: String) -> [BlockHandler] { blockHandlers[name] ?? [] }
}

/// Questions from the server (`client_prompt_requested`, an action that called `rex.ui`). Until
/// a feature takes them, every prompt is declined at once, which takes only this app out of it:
/// the question stays open on the Mac.
@MainActor
final class PromptHook {
    /// Returns true to take the prompt: the handler then owes it a `client.reply`. False, or no
    /// handler, declines it. A prompt of a kind this build can't show never gets here.
    var onPrompt: ((PromptRequest) -> Bool)?
    /// A prompt ended without this app's answer. Close it whatever the reason.
    var onPromptEnded: ((_ callID: String, _ reason: String) -> Void)?
    /// A new connection was made: every `call_id` from the old one means nothing now. Close
    /// those prompts without replying.
    var onConnected: ((_ serial: Int) -> Void)?
}
