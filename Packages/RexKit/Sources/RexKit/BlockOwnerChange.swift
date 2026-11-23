import Foundation

/// One `block_owner_changed` event: a pane passed from one client to another, and why.
public struct BlockOwnerChange: Equatable, Sendable {
    /// Why the owner changed, as the server says it. The raw values are the connection log's.
    public enum Reason: UInt8, Sendable, CaseIterable {
        /// A value this build doesn't know, or none: an older server names no reason.
        case unknown = 0
        /// The new owner created the block.
        case create
        /// The new owner called `session.own_block` with mode `take`.
        case take
        /// The new owner called `session.own_block` with mode `request`.
        case request
        /// The previous owner called `session.disown_block`.
        case disown
        /// The previous owner's connection dropped.
        case lost
        /// The previous owner detached from the session, or its client ended.
        case disconnect
        /// The owner reconnected and got the block back.
        case restore

        public init(name: String?) {
            switch name {
            case "create": self = .create
            case "take": self = .take
            case "request": self = .request
            case "disown": self = .disown
            case "lost": self = .lost
            case "disconnect": self = .disconnect
            case "restore": self = .restore
            default: self = .unknown
            }
        }

        /// A client asked for the pane: somebody is behind the change. Every other reason is
        /// the server passing the pane on because its owner dropped, left or gave it up, and
        /// an unknown one is not taken for a wish.
        public var isClaim: Bool { self == .take || self == .request }
    }

    /// Who a client is to this one. The raw values are the connection log's.
    public enum Party: UInt8, Sendable {
        case none = 0
        /// This client.
        case me
        /// Any other client.
        case other
    }

    public let blockID: String
    /// The client that owns the pane now; nil when it has no owner.
    public let owner: String?
    /// The client that owned it before; nil when it had none.
    public let previous: String?
    public let reason: Reason

    public init(blockID: String, owner: String?, previous: String?, reason: Reason) {
        self.blockID = blockID
        self.owner = owner
        self.previous = previous
        self.reason = reason
    }

    /// Nil when the payload names no block.
    public init?(_ payload: JSONObject) {
        guard let id = payload.str("block_id") else { return nil }
        self.init(blockID: id, owner: payload.str("owner"), previous: payload.str("previous"),
                  reason: Reason(name: payload.str("reason")))
    }

    /// `me`: this client's id; nil when it isn't known, and then nobody is this client.
    public static func party(_ client: String?, me: String?) -> Party {
        guard let client else { return .none }
        return me != nil && client == me ? .me : .other
    }

    /// Another client asked for the pane and has it: a take with somebody behind it.
    public func isTake(from me: String?) -> Bool {
        reason.isClaim && Self.party(owner, me: me) == .other
    }
}
