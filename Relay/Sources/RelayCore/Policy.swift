import Foundation

/// Where an event came from: one block on one server.
public struct BlockRef: Hashable, Sendable {
    public var server: String
    public var sessionID: String
    public var blockID: String
    public init(server: String, sessionID: String, blockID: String) {
        self.server = server
        self.sessionID = sessionID
        self.blockID = blockID
    }
}

/// One OSC 7501 record, from a `program_status_changed` block event.
public struct StatusReport: Sendable {
    public var recordID: String
    public var state: String
    public var kind: String?
    public var app: String?
    public var title: String?
    public var msg: String?

    public init(recordID: String = "", state: String, kind: String? = nil, app: String? = nil,
                title: String? = nil, msg: String? = nil) {
        self.recordID = recordID
        self.state = state
        self.kind = kind
        self.app = app
        self.title = title
        self.msg = msg
    }

    /// Parses a `program_status_changed` payload: `{id, record: {state, kind, app, effective_app, title, msg}}`.
    public init?(event e: JSONObject) {
        guard let rec = e.obj("record"), let state = rec.text("state") else { return nil }
        self.init(recordID: e.str("id") ?? rec.str("id") ?? "", state: state, kind: rec.text("kind"),
                  app: rec.text("effective_app") ?? rec.text("app"), title: rec.text("title"), msg: rec.text("msg"))
    }
}

/// What the relay reacts to, already reduced from Rex events.
public enum RelayEvent: Sendable {
    case status(BlockRef, StatusReport)
    case statusRemoved(BlockRef, ids: [String])
    case notification(BlockRef, title: String?, body: String)
    case blockClosed(BlockRef)
}

public enum PushCategory: String, Sendable {
    case blocked = "AGENT_BLOCKED"
    case done = "AGENT_DONE"
    case notice = "NOTICE"
}

/// A push the policy decided to send, before it's dressed with tab and session names.
public struct PushIntent: Sendable, Equatable {
    public var category: PushCategory
    public var ref: BlockRef
    /// done / error / blocked for status pushes, nil for notices.
    public var state: String?
    public var recordID: String?
    public var blockedKind: String?
    public var agent: String?
    public var headline: String?
    public var text: String?

    public init(category: PushCategory, ref: BlockRef, state: String? = nil, recordID: String? = nil,
                blockedKind: String? = nil, agent: String? = nil, headline: String? = nil, text: String? = nil) {
        self.category = category
        self.ref = ref
        self.state = state
        self.recordID = recordID
        self.blockedKind = blockedKind
        self.agent = agent
        self.headline = headline
        self.text = text
    }
}

public enum Decision: Equatable {
    case push(PushIntent)
    /// Suppressed for now; call `due(now:)` at this time, which may release a trailing push.
    case deferred(until: Date)
    case drop(String)
}

/// Decides which events become pushes. Pure state machine, so it's unit-testable.
///
/// - blocked: pushed when a record enters `blocked` (or reports a new message while blocked).
///   At most once per block per `debounce` window; a block that blocks again inside the window
///   gets one trailing push at the window's end if it's still blocked then.
/// - done / error: pushed on entering the state, at most once per block and state per window.
/// - desktop notifications: identical ones from the same block within the window are dropped.
public struct PushPolicy {
    public var debounce: TimeInterval

    private struct Pending { var intent: PushIntent; var due: Date; var recordKey: String }

    private var lastState: [String: String] = [:]      // record key → state
    private var lastMsg: [String: String] = [:]        // record key → blocked text
    private var lastPush: [String: Date] = [:]         // block key + category/state → time
    private var pending: [String: Pending] = [:]       // block key → trailing blocked push

    public init(debounce: TimeInterval = 30) { self.debounce = debounce }

    private static func blockKey(_ r: BlockRef) -> String { "\(r.server)|\(r.blockID)" }
    private static func recordKey(_ r: BlockRef, _ id: String) -> String { "\(blockKey(r))|\(id)" }

    public var nextDue: Date? { pending.values.map(\.due).min() }

    public mutating func decide(_ event: RelayEvent, now: Date) -> Decision {
        switch event {
        case .status(let ref, let rep):
            return status(ref, rep, now: now)
        case .statusRemoved(let ref, let ids):
            for id in ids { forgetRecord(Self.recordKey(ref, id)) }
            return .drop("status cleared")
        case .notification(let ref, let title, let body):
            let key = "\(Self.blockKey(ref))|notice|\(title ?? "")|\(body)"
            if let t = lastPush[key], now.timeIntervalSince(t) < debounce { return .drop("duplicate notification") }
            lastPush[key] = now
            return .push(PushIntent(category: .notice, ref: ref, headline: title, text: body))
        case .blockClosed(let ref):
            let prefix = Self.blockKey(ref) + "|"
            lastState = lastState.filter { !$0.key.hasPrefix(prefix) }
            lastMsg = lastMsg.filter { !$0.key.hasPrefix(prefix) }
            lastPush = lastPush.filter { !$0.key.hasPrefix(prefix) }
            pending[Self.blockKey(ref)] = nil
            return .drop("block closed")
        }
    }

    private mutating func status(_ ref: BlockRef, _ rep: StatusReport, now: Date) -> Decision {
        let rkey = Self.recordKey(ref, rep.recordID)
        let bkey = Self.blockKey(ref)
        let prev = lastState[rkey]
        lastState[rkey] = rep.state

        switch rep.state {
        case "blocked":
            let text = rep.msg ?? rep.title ?? ""
            let prevText = lastMsg[rkey]
            lastMsg[rkey] = text
            if prev == "blocked" && prevText == text { return .drop("repeat report") }
            let intent = PushIntent(category: .blocked, ref: ref, state: "blocked", recordID: rep.recordID,
                                    blockedKind: rep.kind, agent: rep.app, headline: rep.title, text: rep.msg)
            let pkey = bkey + "|blocked"
            if let t = lastPush[pkey], now.timeIntervalSince(t) < debounce {
                let due = t.addingTimeInterval(debounce)
                pending[bkey] = Pending(intent: intent, due: due, recordKey: rkey)
                return .deferred(until: due)
            }
            lastPush[pkey] = now
            pending[bkey] = nil
            return .push(intent)

        case "done", "error":
            cancelPending(recordKey: rkey, block: bkey)
            lastMsg[rkey] = nil
            if prev == rep.state { return .drop("repeat report") }
            let pkey = bkey + "|" + rep.state
            if let t = lastPush[pkey], now.timeIntervalSince(t) < debounce { return .drop("debounced") }
            lastPush[pkey] = now
            return .push(PushIntent(category: .done, ref: ref, state: rep.state, recordID: rep.recordID,
                                    agent: rep.app, headline: rep.title, text: rep.msg))

        default: // idle, working, unknown
            cancelPending(recordKey: rkey, block: bkey)
            lastMsg[rkey] = nil
            return .drop("not notable")
        }
    }

    /// Trailing pushes whose window has ended and whose record is still blocked.
    public mutating func due(now: Date) -> [PushIntent] {
        var out: [PushIntent] = []
        for (bkey, p) in pending where p.due <= now {
            pending[bkey] = nil
            guard lastState[p.recordKey] == "blocked" else { continue }
            lastPush[bkey + "|blocked"] = now
            out.append(p.intent)
        }
        return out
    }

    private mutating func cancelPending(recordKey: String, block: String) {
        if pending[block]?.recordKey == recordKey { pending[block] = nil }
    }

    private mutating func forgetRecord(_ rkey: String) {
        lastState[rkey] = nil
        lastMsg[rkey] = nil
        for (b, p) in pending where p.recordKey == rkey { pending[b] = nil }
    }
}

/// Token bucket per device: `capacity` pushes at once, refilled at `perMinute`.
public struct RateLimiter {
    public var capacity: Double
    public var perMinute: Double
    private var buckets: [String: (tokens: Double, at: Date)] = [:]

    public init(capacity: Double = 10, perMinute: Double = 10) {
        self.capacity = capacity
        self.perMinute = perMinute
    }

    public mutating func allow(_ key: String, now: Date) -> Bool {
        var b = buckets[key] ?? (capacity, now)
        b.tokens = min(capacity, b.tokens + now.timeIntervalSince(b.at) * perMinute / 60)
        b.at = now
        guard b.tokens >= 1 else { buckets[key] = b; return false }
        b.tokens -= 1
        buckets[key] = b
        return true
    }
}
