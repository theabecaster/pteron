import Foundation

/// Names the relay looks up for a block, to make a push readable.
public struct BlockContext: Sendable {
    public var windowID: String?
    public var tabLabel: String?
    public var blockLabel: String?
    public var sessionLabel: String?
    public init(windowID: String? = nil, tabLabel: String? = nil, blockLabel: String? = nil, sessionLabel: String? = nil) {
        self.windowID = windowID
        self.tabLabel = tabLabel
        self.blockLabel = blockLabel
        self.sessionLabel = sessionLabel
    }
}

/// One push, ready for any device.
public struct PushMessage: Sendable {
    public var category: PushCategory
    public var title: String
    public var subtitle: String?
    public var body: String
    public var interruptionLevel: String   // passive | active | time-sensitive
    public var sound: Bool
    public var threadID: String
    public var collapseID: String?
    public var server: String
    public var sessionID: String
    public var windowID: String?
    public var blockID: String

    /// APNs priority: 10 delivers now, 5 lets the system batch passive pushes.
    public var priority: Int { interruptionLevel == "passive" ? 5 : 10 }

    /// The JSON body sent to APNs.
    public var payload: JSONObject {
        var alert: JSONObject = ["title": title, "body": body]
        if let subtitle { alert["subtitle"] = subtitle }
        var aps: JSONObject = [
            "alert": alert,
            "interruption-level": interruptionLevel,
            "thread-id": threadID,
            "category": category.rawValue,
        ]
        if sound { aps["sound"] = "default" }
        var p: JSONObject = ["aps": aps, "server": server, "session_id": sessionID, "block_id": blockID]
        if let windowID { p["window_id"] = windowID }
        return p
    }

    public var payloadData: Data { JSONCodec.data(payload) }

    public static func compose(_ i: PushIntent, context c: BlockContext) -> PushMessage {
        let tab = c.tabLabel ?? c.sessionLabel ?? "Rex"
        // Show the session too when the tab name alone doesn't say it.
        let subtitle = (c.sessionLabel != nil && c.sessionLabel != tab) ? c.sessionLabel : nil
        let agent = Self.displayName(i.agent ?? c.blockLabel ?? "Agent")
        let base = PushMessage(
            category: i.category, title: "", subtitle: subtitle, body: "", interruptionLevel: "active", sound: true,
            threadID: i.ref.blockID, collapseID: nil, server: i.ref.server, sessionID: i.ref.sessionID,
            windowID: c.windowID, blockID: i.ref.blockID)
        var m = base
        switch i.category {
        case .blocked:
            m.title = "\(agent) · \(tab)"
            m.body = i.text ?? i.headline ?? Self.blockedText(i.blockedKind)
            m.interruptionLevel = "time-sensitive"
            m.collapseID = Self.collapseID(i.ref, i.recordID)
        case .done:
            m.title = "\(agent) · \(tab)"
            let fallback = i.state == "error" ? "Failed" : "Finished"
            let text = i.text ?? i.headline ?? fallback
            m.body = (i.state == "error" && i.text != nil) ? "Error: \(text)" : text
            m.interruptionLevel = "passive"
            m.sound = false
            m.collapseID = Self.collapseID(i.ref, i.recordID)
        case .notice:
            m.title = i.headline ?? tab
            m.body = i.text ?? ""
        }
        m.title = Self.clip(m.title, 120)
        m.body = Self.clip(m.body, 1000)
        return m
    }

    static func blockedText(_ kind: String?) -> String {
        switch kind {
        case "permission": return "Needs your permission"
        case "question": return "Has a question for you"
        case "auth": return "Needs you to sign in"
        default: return "Waiting for you"
        }
    }

    /// "claude" → "Claude". Names that already have capitals are left alone.
    static func displayName(_ s: String) -> String {
        guard s == s.lowercased(), let f = s.first else { return s }
        return f.uppercased() + s.dropFirst()
    }

    /// Same block and record replace each other in Notification Center (max 64 bytes).
    static func collapseID(_ ref: BlockRef, _ record: String?) -> String {
        let short = String(ref.blockID.replacingOccurrences(of: "block:", with: "").prefix(40))
        if record?.isEmpty ?? true { return short }
        // Fold the record id into a short stable hash (FNV-1a).
        var h: UInt32 = 2166136261
        for b in (record ?? "").utf8 { h = (h ^ UInt32(b)) &* 16777619 }
        return "\(short)-\(String(h, radix: 16))"
    }

    static func clip(_ s: String, _ n: Int) -> String {
        s.count <= n ? s : String(s.prefix(n - 1)) + "…"
    }
}
