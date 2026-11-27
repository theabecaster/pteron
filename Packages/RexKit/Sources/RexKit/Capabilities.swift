import Foundation

/// What the control API gained after the oldest revision the app still serves, by revision.
public enum RexAPI {
    /// Methods newer than revision 13, with the revision that added each. A call on a connection
    /// below a method's revision fails here with `revision_too_low` and is never sent. The exact
    /// numbers come from probes and from the server's page.
    public static let minimumRevision: [String: Int] = [
        "com.superlogical.tunnel.info": 14,
        "com.superlogical.terminal.ports": 15,
        // The phone's Navigate Back and Forward keep their own history and never call it
        // (docs/rex-protocol.md, Focus history); listed so that a call is never sent below 19.
        "focus_history.reverse": 19,
        "client.undo_close": 20,
        // Not used: the sidebar moves tabs only within their session (docs/rex-protocol.md).
        "session.transfer_window": 22,
    ]

    /// The revision that added the prompt events and `event_dropped`.
    public static let prompts = 17
    /// The revision that added `client.undo_close` and `undoable` on `block.close`,
    /// `session.close_window` and `session.destroy` (a server below it refuses the field).
    public static let undoClose = 20
    /// The revision that split a window's zoom in two (`tiled_zoomed_block_id`).
    public static let zoomsApart = 21

    public static func minimum(for method: String) -> Int { minimumRevision[method] ?? 0 }
}

/// Whether a server has something, as far as the app can tell.
public enum Presence: Equatable, Sendable {
    case present, absent
    /// Not asked yet, or the answer said nothing either way.
    case unknown

    /// `true`, `false`, or nil while unknown.
    public var answer: Bool? {
        switch self {
        case .present: return true
        case .absent: return false
        case .unknown: return nil
        }
    }
}

public extension RexError {
    /// Whether this answer to a call says the method doesn't exist on the server.
    ///
    /// - `method_not_found` and `revision_too_low` say so outright.
    /// - Servers older than `method_not_found` answer `not_found` for a missing method. That code
    ///   also means "no such block", so it counts only when the caller knows the target exists
    ///   (`targetExists`): a server method, or a block the creator list already vouched for.
    /// - Anything else says nothing: the method may be there and have failed for another reason.
    func presence(targetExists: Bool) -> Presence {
        switch code {
        case "method_not_found", "revision_too_low": return .absent
        case "not_found": return targetExists ? .absent : .unknown
        default: return .unknown
        }
    }
}

/// One creator from `block_creator.list`: its flavors and what its blocks can do.
public struct CreatorInfo: Equatable, Sendable {
    public var name: String
    /// The machine and account its blocks run as. Nil on a server that doesn't say.
    public var hostID: String?
    /// Full flavor names, such as `com.superlogical.terminal.shell`.
    public var flavors: Set<String>
    /// The block methods by short name. Nil when the server sent no `api.methods`: that is an
    /// older shape, not a creator without methods, so it answers nothing.
    public var methods: Set<String>?
    /// The block events by name. Nil when the server sent no `api.events`.
    public var events: Set<String>?

    public init(name: String, hostID: String? = nil, flavors: Set<String> = [], methods: Set<String>? = nil,
                events: Set<String>? = nil) {
        self.name = name
        self.hostID = hostID
        self.flavors = flavors
        self.methods = methods
        self.events = events
    }

    public init(_ o: JSONObject) {
        name = o.str("name") ?? ""
        hostID = o.str("host_id")
        flavors = Set(o.arr("flavors").compactMap { $0.str("flavor") })
        let api = o.obj("api")
        methods = api?.obj("methods").map { Set($0.keys) }
        events = api?.obj("events").map { Set($0.keys) }
    }
}

/// The result of `block_creator.list`, reduced to what answers "does this server, on this host,
/// have block method X, event Y or flavor Z" without a call. Unknown creators, flavors, methods and
/// events are kept as names and otherwise ignored.
public struct CreatorCatalog: Equatable, Sendable {
    public var creators: [CreatorInfo]

    public init(creators: [CreatorInfo] = []) { self.creators = creators }

    /// From a `block_creator.list` result.
    public init(_ result: JSONObject) {
        creators = result.arr("creators").map(CreatorInfo.init).filter { !$0.name.isEmpty }
    }

    /// The creator by name on one host. A creator for another host doesn't count.
    public func creator(_ name: String, host: String?) -> CreatorInfo? {
        creators.first { $0.name == name && $0.hostID == host }
    }

    /// Whether a host can make blocks of a flavor (full name).
    public func hasFlavor(_ flavor: String, host: String?) -> Bool {
        creators.contains { $0.hostID == host && $0.flavors.contains(flavor) }
    }

    /// A creator's block methods on one host; nil when the creator is missing or lists none.
    public func blockMethods(creator name: String, host: String?) -> Set<String>? {
        creator(name, host: host)?.methods
    }

    /// A creator's block events on one host; nil when the creator is missing or lists none.
    public func blockEvents(creator name: String, host: String?) -> Set<String>? {
        creator(name, host: host)?.events
    }

    /// A missing creator is absent. A creator that lists no methods at all is unknown.
    public func method(_ short: String, creator name: String, host: String?) -> Presence {
        guard let c = creator(name, host: host) else { return .absent }
        guard let m = c.methods else { return .unknown }
        return m.contains(short) ? .present : .absent
    }

    /// A missing creator is absent. A creator that lists no events at all is unknown.
    public func event(_ event: String, creator name: String, host: String?) -> Presence {
        guard let c = creator(name, host: host) else { return .absent }
        guard let e = c.events else { return .unknown }
        return e.contains(event) ? .present : .absent
    }
}
