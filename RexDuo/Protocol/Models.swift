import Foundation
import CoreGraphics

/// A node of a window's layout tree. Every node carries its normalized rect [x, y, w, h].
indirect enum LayoutNode {
    case block(id: String, rect: CGRect)
    case split(id: String, direction: String, ratio: Double, before: LayoutNode, after: LayoutNode, rect: CGRect)

    static func parse(_ o: JSONObject?) -> LayoutNode? {
        guard let o else { return nil }
        let rect = Self.rect(o["rect"])
        if let b = o.str("block_id") { return .block(id: b, rect: rect) }
        if let s = o.obj("split"),
           let before = parse(s.obj("before")),
           let after = parse(s.obj("after")) {
            return .split(id: s.str("split_id") ?? "", direction: s.str("direction") ?? "horizontal",
                          ratio: s.dbl("ratio") ?? 0.5, before: before, after: after, rect: rect)
        }
        return nil
    }

    static func rect(_ any: Any?) -> CGRect {
        guard let a = any as? [Any], a.count == 4 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        let n = a.map { ($0 as? NSNumber)?.doubleValue ?? 0 }
        return CGRect(x: n[0], y: n[1], width: n[2], height: n[3])
    }

    var rect: CGRect {
        switch self {
        case .block(_, let r): return r
        case .split(_, _, _, _, _, let r): return r
        }
    }

    /// Leaves in reading order.
    var leaves: [(id: String, rect: CGRect)] {
        switch self {
        case .block(let id, let r): return [(id, r)]
        case .split(_, _, _, let b, let a, _): return b.leaves + a.leaves
        }
    }

    /// Splits with their divider geometry (for drawing and dragging).
    var splits: [(id: String, direction: String, ratio: Double, rect: CGRect, beforeFirst: String, afterFirst: String)] {
        switch self {
        case .block: return []
        case .split(let id, let dir, let ratio, let b, let a, let r):
            let me = (id: id, direction: dir, ratio: ratio, rect: r,
                      beforeFirst: b.leaves.last?.id ?? "", afterFirst: a.leaves.first?.id ?? "")
            return [me] + b.splits + a.splits
        }
    }
}

struct BlockInfo: Identifiable, Equatable {
    var id: String
    var label: String
    var creator: String
    var flavor: String
    var hostID: String?
    var owner: String?

    init(_ o: JSONObject) {
        id = o.str("block_id") ?? ""
        label = o.str("label") ?? ""
        creator = o.str("creator_name") ?? ""
        flavor = o.str("flavor") ?? ""
        hostID = o.str("host_id")
        owner = o.str("owner")
    }
    var isTerminal: Bool { creator == "com.superlogical.terminal" }
}

struct LayerInfo: Identifiable {
    var id: String
    var kind: String
    var bounds: CGRect
    var layout: LayoutNode?
    var blocks: [BlockInfo]
    var minimized: Bool

    init(_ o: JSONObject) {
        id = o.str("layer_id") ?? UUID().uuidString
        kind = o.str("kind") ?? "tiled"
        bounds = LayoutNode.rect(o["bounds"])
        layout = LayoutNode.parse(o.obj("layout"))
        blocks = o.arr("blocks").map(BlockInfo.init)
        minimized = (o.str("state") ?? "") == "minimized"
    }
}

struct WindowInfo: Identifiable {
    var id: String
    var label: String
    var focusedBlockID: String?
    var zoomedBlockID: String?
    var layers: [LayerInfo]

    init(_ o: JSONObject) {
        id = o.str("window_id") ?? ""
        label = o.str("label") ?? ""
        focusedBlockID = o.str("focused_block_id")
        zoomedBlockID = o.str("zoomed_block_id")
        layers = o.arr("layers").map(LayerInfo.init)
    }

    var tiled: LayerInfo? { layers.first { $0.kind == "tiled" } ?? layers.first }
    var allBlocks: [BlockInfo] { layers.flatMap(\.blocks) }
    var layout: LayoutNode? { tiled?.layout }
    var orderedBlockIDs: [String] {
        var ids = layout?.leaves.map(\.id) ?? []
        for b in allBlocks where !ids.contains(b.id) { ids.append(b.id) }
        return ids
    }
    func block(_ id: String) -> BlockInfo? { allBlocks.first { $0.id == id } }
}

struct SessionView {
    var revision: Int
    var sessionID: String
    var label: String
    var activeWindowID: String?
    var windows: [WindowInfo]

    init(_ o: JSONObject) {
        revision = o.int("revision") ?? 0
        sessionID = o.str("session_id") ?? ""
        label = o.str("label") ?? ""
        activeWindowID = o.str("active_window_id")
        windows = o.arr("windows").map(WindowInfo.init)
    }

    func window(_ id: String?) -> WindowInfo? {
        guard let id else { return nil }
        return windows.first { $0.id == id }
    }
    var activeWindow: WindowInfo? { window(activeWindowID) ?? windows.first }
    func windowContaining(block: String) -> WindowInfo? {
        windows.first { $0.allBlocks.contains { $0.id == block } }
    }
}

/// A program status record reported with OSC 7501 (agents such as Claude Code report these).
struct ProgramStatus: Equatable {
    var state: String      // idle | working | done | blocked | error
    var app: String?
    var text: String?
    var label: String?
    var waitingFor: String?
    var progress: Int?

    init(_ o: JSONObject) {
        state = o.str("state") ?? "idle"
        app = o.str("effective_app") ?? o.str("app")
        text = o.str("msg")
        label = o.str("title")
        waitingFor = o.str("kind")
        progress = o.int("progress")
    }
}

/// Live, per-block metadata gathered from events.
struct BlockMeta: Equatable {
    var title: String?
    var pwd: String?
    var foreground: String?
    var statuses: [String: ProgramStatus] = [:]
    var bellAt: Date?
    var exited: Bool = false

    /// The most important status among the records (blocked > error > working > done > idle).
    var topStatus: ProgramStatus? {
        let rank = ["blocked": 5, "error": 4, "working": 3, "done": 2, "idle": 1]
        return statuses.values.max { (rank[$0.state] ?? 0) < (rank[$1.state] ?? 0) }
    }

    var agentKind: AgentKind? {
        if let app = topStatus?.app, let k = AgentKind.detect(app) { return k }
        if let fg = foreground, let k = AgentKind.detect(fg) { return k }
        if let t = title, let k = AgentKind.detect(t) { return k }
        return nil
    }
}

enum AgentKind: String {
    case claude, codex, gemini, opencode, amp, aider, cursor

    static func detect(_ s: String) -> AgentKind? {
        let l = s.lowercased()
        if l.contains("claude") { return .claude }
        if l.contains("codex") { return .codex }
        if l.contains("gemini") { return .gemini }
        if l.contains("opencode") { return .opencode }
        if l == "amp" || l.hasPrefix("amp ") { return .amp }
        if l.contains("aider") { return .aider }
        if l.contains("cursor-agent") { return .cursor }
        return nil
    }

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .gemini: return "Gemini"
        case .opencode: return "opencode"
        case .amp: return "Amp"
        case .aider: return "Aider"
        case .cursor: return "Cursor"
        }
    }

    var symbol: String {
        switch self {
        case .claude: return "asterisk"
        case .codex: return "hexagon"
        case .gemini: return "sparkle"
        default: return "cpu"
        }
    }
}
