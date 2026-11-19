import Foundation

/// `event_dropped`: sent in place of an event that was too large to send. It names what was lost,
/// so the client reads back only that.
public struct DroppedEvent: Equatable, Sendable {
    /// The dropped event's type. For an event about one session, the type inside `session_event`.
    public var type: String
    public var sessionID: String?
    public var blockID: String?
    public var creator: String?
    /// For a dropped `block_event`, the event's name as its creator lists it.
    public var blockEventName: String?
    public var size: Int?

    public init(type: String, sessionID: String? = nil, blockID: String? = nil, creator: String? = nil,
                blockEventName: String? = nil, size: Int? = nil) {
        self.type = type
        self.sessionID = sessionID
        self.blockID = blockID
        self.creator = creator
        self.blockEventName = blockEventName
        self.size = size
    }

    /// From the event's payload. `session` is the enclosing `session_event`'s session, if any.
    public init(_ p: JSONObject, session: String? = nil) {
        type = p.str("event_type") ?? ""
        sessionID = p.str("session_id") ?? session
        blockID = p.str("block_id")
        creator = p.str("creator_name")
        blockEventName = p.str("block_event_name")
        size = p.int("size")
    }

    /// What to read again for a dropped event.
    public enum Recovery: Equatable, Sendable {
        /// One block's metadata (statuses, title, foreground), plus whatever a feature registered
        /// for the event's name. The session is nil when the server didn't name it.
        case block(session: String?, block: String, name: String)
        /// One session's view.
        case sessionView(String)
        /// The order and set of sessions.
        case sessionList
        case hosts
        case keymap
        /// `block_creator.list`.
        case creators
        /// Which clients are connected (the push helper among them).
        case clients
        /// Nothing can or need be read: a request addressed to this client whose `call_id` went
        /// with it, or state the app doesn't keep.
        case ignore
        /// A type this build doesn't know and no session to narrow it to: read everything.
        case everything
    }

    public var recovery: Recovery {
        switch type {
        case "block_event":
            guard let blockID else { return sessionID.map(Recovery.sessionView) ?? .ignore }
            return .block(session: sessionID, block: blockID, name: blockEventName ?? "")
        case "creator_changed":
            return .creators
        case "session_created", "session_destroyed", "session_moved":
            return .sessionList
        case "hosts_changed":
            return .hosts
        case "keymap_changed":
            return .keymap
        case "client_joined", "client_left", "client_changed":
            return .clients
        case "client_prompt_ended", "client_performed", "client_script_events_dropped",
             "tailscale_status_changed", "event_dropped":
            return .ignore
        default:
            // "Do this" requests to this client: the `call_id` to answer went with the event.
            if type.hasPrefix("client_"), type.hasSuffix("_requested") { return .ignore }
            if let sessionID { return .sessionView(sessionID) }
            return .everything
        }
    }
}
