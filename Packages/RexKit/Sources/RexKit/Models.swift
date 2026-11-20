import Foundation
import CoreGraphics

/// A node of a window's layout tree. Every node carries its normalized rect [x, y, w, h].
public indirect enum LayoutNode: Equatable, Sendable {
    case block(id: String, rect: CGRect)
    case split(id: String, direction: String, ratio: Double, before: LayoutNode, after: LayoutNode, rect: CGRect)

    public static func parse(_ o: JSONObject?) -> LayoutNode? {
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

    public static func rect(_ any: Any?) -> CGRect {
        guard let a = any as? [Any], a.count == 4 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        let n = a.map { ($0 as? NSNumber)?.doubleValue ?? 0 }
        return CGRect(x: n[0], y: n[1], width: n[2], height: n[3])
    }

    /// Four finite numbers that make a rect with some area, else nil: no fallback.
    public static func strictRect(_ any: Any?) -> CGRect? {
        guard let a = any as? [Any], a.count == 4 else { return nil }
        let n = a.compactMap { ($0 as? NSNumber)?.doubleValue }
        guard n.count == 4, n.allSatisfy(\.isFinite), n[2] > 0, n[3] > 0 else { return nil }
        return CGRect(x: n[0], y: n[1], width: n[2], height: n[3])
    }

    public var rect: CGRect {
        switch self {
        case .block(_, let r): return r
        case .split(_, _, _, _, _, let r): return r
        }
    }

    /// Leaves in reading order.
    public var leaves: [(id: String, rect: CGRect)] {
        switch self {
        case .block(let id, let r): return [(id, r)]
        case .split(_, _, _, let b, let a, _): return b.leaves + a.leaves
        }
    }

    /// Splits with their divider geometry (for drawing and dragging).
    public var splits: [(id: String, direction: String, ratio: Double, rect: CGRect, beforeFirst: String, afterFirst: String)] {
        switch self {
        case .block: return []
        case .split(let id, let dir, let ratio, let b, let a, let r):
            let me = (id: id, direction: dir, ratio: ratio, rect: r,
                      beforeFirst: b.leaves.last?.id ?? "", afterFirst: a.leaves.first?.id ?? "")
            return [me] + b.splits + a.splits
        }
    }
}

public struct BlockInfo: Identifiable, Equatable, Sendable {
    public var id: String
    public var label: String
    public var creator: String
    public var flavor: String
    public var hostID: String?
    public var owner: String?

    public init(_ o: JSONObject) {
        id = o.str("block_id") ?? ""
        label = o.str("label") ?? ""
        creator = o.str("creator_name") ?? ""
        flavor = o.str("flavor") ?? ""
        hostID = o.str("host_id")
        owner = o.str("owner")
    }
    public var isTerminal: Bool { creator == "com.superlogical.terminal" }
}

public struct LayerInfo: Identifiable, Equatable, Sendable {
    public var id: String
    public var kind: String
    public var bounds: CGRect
    /// The server sent `bounds` as four numbers with some area. A floating layer without them
    /// can't be placed, so it isn't drawn.
    public var hasBounds: Bool
    public var layout: LayoutNode?
    public var blocks: [BlockInfo]
    public var minimized: Bool

    public init(_ o: JSONObject) {
        blocks = o.arr("blocks").map(BlockInfo.init)
        // An older server may send no ID. One made from the layer's first block stays the same
        // when the layers' order changes, so a raise never rebuilds a pane.
        id = o.str("layer_id") ?? "layer:" + (blocks.first?.id ?? "empty")
        kind = o.str("kind") ?? "tiled"
        let placed = LayoutNode.strictRect(o["bounds"])
        bounds = placed ?? LayoutNode.rect(o["bounds"])
        hasBounds = placed != nil
        layout = LayoutNode.parse(o.obj("layout"))
        // A state the app doesn't know is drawn as normal.
        minimized = (o.str("state") ?? "") == "minimized"
    }

    /// Every layer but a window's tiled one floats, a kind the app doesn't know too.
    public var isFloating: Bool { kind != "tiled" }
    public var isMinimized: Bool { minimized }
    /// A floating layer the app draws: normal, placed, and holding panes.
    public var isDrawnFloat: Bool { !minimized && hasBounds && !(layout?.leaves.isEmpty ?? true) }
}

public struct WindowInfo: Identifiable, Sendable {
    public var id: String
    public var label: String
    public var focusedBlockID: String?
    public var zoomedBlockID: String?
    public var layers: [LayerInfo]

    public init(_ o: JSONObject) {
        id = o.str("window_id") ?? ""
        label = o.str("label") ?? ""
        focusedBlockID = o.str("focused_block_id")
        zoomedBlockID = o.str("zoomed_block_id")
        layers = o.arr("layers").map(LayerInfo.init)
    }

    private var tiledIndex: Int? { layers.firstIndex { $0.kind == "tiled" } ?? (layers.isEmpty ? nil : 0) }
    public var tiled: LayerInfo? { tiledIndex.map { layers[$0] } }
    public var allBlocks: [BlockInfo] { layers.flatMap(\.blocks) }
    public var layout: LayoutNode? { tiled?.layout }
    /// Every block, the tiled panes first, then the floating layers' blocks, back to front,
    /// minimized ones included.
    public var orderedBlockIDs: [String] {
        var ids = layout?.leaves.map(\.id) ?? []
        for b in allBlocks where !ids.contains(b.id) { ids.append(b.id) }
        return ids
    }
    public func block(_ id: String) -> BlockInfo? { allBlocks.first { $0.id == id } }

    /// The floating layers, back to front: every layer but the tiled one.
    public var floating: [LayerInfo] {
        guard let t = tiledIndex else { return [] }
        return layers.enumerated().filter { $0.offset != t }.map(\.element)
    }

    /// The floating layers the app draws, back to front: normal, placed, with panes.
    public var visibleFloating: [LayerInfo] { floating.filter(\.isDrawnFloat) }

    /// The minimized floating layers that hold panes, back to front.
    public var minimizedFloating: [LayerInfo] { floating.filter { $0.minimized && !$0.blocks.isEmpty } }

    /// The panes in the order the phone pages through them: the tiled panes in reading order,
    /// then the drawn floating windows' panes, front first. A minimized float isn't in it. With no
    /// floating layer it is `orderedBlockIDs`.
    public var pageBlockIDs: [String] {
        var ids = layout?.leaves.map(\.id) ?? []
        for b in tiled?.blocks ?? [] where !ids.contains(b.id) { ids.append(b.id) }
        for layer in visibleFloating.reversed() {
            for id in (layer.layout?.leaves.map(\.id) ?? []) + layer.blocks.map(\.id) where !ids.contains(id) { ids.append(id) }
        }
        return ids
    }

    /// The floating layer that holds a block; nil for a tiled block.
    public func floatingLayer(of block: String) -> LayerInfo? {
        floating.first { $0.blocks.contains { $0.id == block } }
    }

    /// The block sits in a floating layer the app doesn't draw: minimized, or with no place.
    public func isHidden(_ block: String) -> Bool {
        guard let l = floatingLayer(of: block) else { return false }
        return !l.isDrawnFloat
    }

    /// The block sits in a minimized floating layer.
    public func isMinimized(_ block: String) -> Bool { floatingLayer(of: block)?.minimized ?? false }
}

public struct SessionView: Sendable {
    public var revision: Int
    public var sessionID: String
    public var label: String
    public var activeWindowID: String?
    public var windows: [WindowInfo]

    public init(_ o: JSONObject) {
        revision = o.int("revision") ?? 0
        sessionID = o.str("session_id") ?? ""
        label = o.str("label") ?? ""
        activeWindowID = o.str("active_window_id")
        windows = o.arr("windows").map(WindowInfo.init)
    }

    public func window(_ id: String?) -> WindowInfo? {
        guard let id else { return nil }
        return windows.first { $0.id == id }
    }
    public var activeWindow: WindowInfo? { window(activeWindowID) ?? windows.first }
    public func windowContaining(block: String) -> WindowInfo? {
        windows.first { $0.allBlocks.contains { $0.id == block } }
    }
}

/// A program status record reported with OSC 7501 (agents such as Claude Code report these).
public struct ProgramStatus: Equatable, Sendable {
    public var state: String      // idle | working | done | blocked | error
    public var app: String?
    public var text: String?
    public var label: String?
    public var waitingFor: String?
    public var progress: Int?

    public init(_ o: JSONObject) {
        state = o.str("state") ?? "idle"
        app = o.str("effective_app") ?? o.str("app")
        text = o.str("msg")
        label = o.str("title")
        waitingFor = o.str("kind")
        progress = o.int("progress")
    }
}

/// Live, per-block metadata gathered from events.
public struct BlockMeta: Equatable, Sendable {
    public var title: String?
    public var pwd: String?
    public var foreground: String?
    /// The foreground process's id: Stop for a port is offered only for this process (`PortStop`).
    public var foregroundPID: Int?
    public var statuses: [String: ProgramStatus] = [:]
    public var bellAt: Date?
    public var exited: Bool = false

    public init() {}

    /// The most important status among the records (blocked > error > working > done > idle).
    public var topStatus: ProgramStatus? {
        let rank = ["blocked": 5, "error": 4, "working": 3, "done": 2, "idle": 1]
        return statuses.values.max { (rank[$0.state] ?? 0) < (rank[$1.state] ?? 0) }
    }

    /// The agent in this pane: by the OSC 7501 app it reports, then by its foreground program,
    /// then by a title in an agent's own format. A word in a path or a shell's title
    /// ("~/claude-notes") is never an agent.
    public var agentKind: AgentKind? {
        if let app = topStatus?.app, let k = AgentKind.fromApp(app) { return k }
        if let fg = foreground, let k = AgentKind.fromProgram(fg) { return k }
        if let t = title, let k = AgentKind.fromTitle(t) { return k }
        return nil
    }
}

public enum AgentKind: String, Sendable {
    case claude, codex, gemini, opencode, amp, aider, cursor

    /// Programs by their whole name, as the foreground process or an OSC 7501 app gives it.
    static let programs: [String: AgentKind] = [
        "claude": .claude, "claude-code": .claude, "codex": .codex, "codex-cli": .codex,
        "gemini": .gemini, "gemini-cli": .gemini, "opencode": .opencode, "amp": .amp,
        "aider": .aider, "aider-chat": .aider, "cursor-agent": .cursor,
    ]

    /// The agent a program is, by its whole name, without a script extension: "claude" and
    /// "cli.js" of `claude-code` are Claude, "claude-notes" is not.
    public static func fromProgram(_ name: String) -> AgentKind? {
        var l = name.trimmingCharacters(in: .whitespaces).lowercased()
        for ext in [".js", ".mjs", ".cjs", ".py", ".exe"] where l.hasSuffix(ext) {
            l.removeLast(ext.count)
        }
        return programs[l]
    }

    /// The agent an OSC 7501 app names. Agents name themselves there, so their own longer names
    /// count too ("claude-code", "Claude Code", "gemini-cli").
    public static func fromApp(_ app: String) -> AgentKind? {
        if let k = fromProgram(app) { return k }
        let l = app.trimmingCharacters(in: .whitespaces).lowercased()
        for (id, kind) in [("claude", AgentKind.claude), ("codex", .codex), ("gemini", .gemini),
                           ("opencode", .opencode), ("aider", .aider), ("cursor-agent", .cursor), ("amp", .amp)]
        where l.hasPrefix(id + "-") || l.hasPrefix(id + " ") {
            return kind
        }
        return nil
    }

    /// Glyphs Claude Code puts before its title while it works ("✳ Claude Code", "✶ Fix tests").
    static let claudeTitleGlyphs: Set<Character> = ["✳", "✶", "✻", "✽", "✢"]

    /// The agent a title names: in a format the agent sets itself (checked in a pane with each
    /// one; docs/sidebar.md, Agents mode), or a command line that starts with the agent's own
    /// program, as a shell titles the pane while it runs one (`claude --resume`, `aider --model
    /// x`), which over ssh is all there is. A path, a shell's `user@host:path` title or a command
    /// that only mentions an agent (`vim CLAUDE.md`) never names one.
    public static func fromTitle(_ title: String) -> AgentKind? {
        let s = title.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, !isPathLike(s) else { return nil }
        if s == "Claude Code" || s.hasPrefix("Claude Code ") { return .claude }
        if let first = s.first, claudeTitleGlyphs.contains(first), s.dropFirst().first == " " { return .claude }
        // A braille spinner before "Claude Code" while it works.
        if let u = s.unicodeScalars.first, (0x2800...0x28FF).contains(u.value), s.contains("Claude Code") { return .claude }
        if s == "OpenCode" || s.hasPrefix("OpenCode ") || s.hasPrefix("OpenCode:") { return .opencode }
        if s == "Gemini CLI" || s.hasPrefix("Gemini CLI ") || s.hasPrefix("Gemini - ") { return .gemini }
        return fromCommandLine(s)
    }

    /// A command line whose first word is an agent's program, as typed: lowercase, no path.
    /// "Codex review notes" or "Claude's plan" are prose, not a command.
    static func fromCommandLine(_ s: String) -> AgentKind? {
        guard let first = s.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init),
              first == first.lowercased(), !first.contains("/") else { return nil }
        return fromProgram(first)
    }

    /// A path, or a shell's "user@host:path" title.
    static func isPathLike(_ s: String) -> Bool {
        if s.hasPrefix("/") || s.hasPrefix("~") || s.hasPrefix("./") { return true }
        guard let at = s.firstIndex(of: "@"), let colon = s[at...].firstIndex(of: ":") else { return false }
        return !s[..<at].contains(" ") && !s[at..<colon].contains(" ")
    }

    public var displayName: String {
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

    public var symbol: String {
        switch self {
        case .claude: return "asterisk"
        case .codex: return "hexagon"
        case .gemini: return "sparkle"
        default: return "cpu"
        }
    }
}
