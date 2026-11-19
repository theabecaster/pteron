import Foundation
import Observation
import RexKit

/// Modifier keys, in Rex's spelling order (shift, ctrl, alt, cmd).
struct KeyMods: OptionSet, Hashable {
    let rawValue: UInt8
    static let shift = KeyMods(rawValue: 1)
    static let ctrl = KeyMods(rawValue: 2)
    static let alt = KeyMods(rawValue: 4)
    static let cmd = KeyMods(rawValue: 8)
}

/// One key with modifiers, spelled the way Rex writes bindings: `shift+cmd+d`, `ctrl+tab`,
/// `cmd+[Digit1]` (a physical key, by its W3C code).
struct KeyChord: Hashable {
    var mods: KeyMods
    /// A logical key (`d`, `=`, `enter`, `left`) or a physical one in brackets (`[Digit1]`).
    var key: String

    var isPhysical: Bool { key.hasPrefix("[") }

    init(mods: KeyMods, key: String) {
        self.mods = mods
        self.key = key
    }

    init?(spelling: String) {
        let s = spelling.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        var parts = s.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        // A trailing "+" is the plus key itself (rare; Rex spells it shift+=).
        if s.hasSuffix("++") { parts.removeLast(2); parts.append("+") }
        guard let last = parts.popLast(), !last.isEmpty else { return nil }
        var mods: KeyMods = []
        for p in parts {
            switch p.lowercased() {
            case "shift": mods.insert(.shift)
            case "ctrl", "control": mods.insert(.ctrl)
            case "alt", "opt", "option": mods.insert(.alt)
            case "cmd", "command", "super", "meta", "win": mods.insert(.cmd)
            default: return nil
            }
        }
        self.mods = mods
        self.key = last.hasPrefix("[") ? last : Self.normalizedKey(last.lowercased())
    }

    private static func normalizedKey(_ k: String) -> String {
        switch k {
        case "return": "enter"
        case "esc": "escape"
        case "page_up", "pgup": "pageup"
        case "page_down", "pgdn": "pagedown"
        case "arrowleft": "left"
        case "arrowright": "right"
        case "arrowup": "up"
        case "arrowdown": "down"
        case "del", "forwarddelete": "delete"
        default: k
        }
    }

    var spelling: String {
        var p: [String] = []
        if mods.contains(.shift) { p.append("shift") }
        if mods.contains(.ctrl) { p.append("ctrl") }
        if mods.contains(.alt) { p.append("alt") }
        if mods.contains(.cmd) { p.append("cmd") }
        p.append(key)
        return p.joined(separator: "+")
    }
}

/// One resolved single-key binding.
struct KeyBinding {
    let chord: KeyChord
    let action: String
    let args: JSONObject?
}

/// What the app does for a Rex action name.
enum AppAction {
    /// App-level: the visible window screen performs it.
    case command(RexCommand)
    /// Split along the pane's longer side.
    case splitAuto
    /// Type a key into the pane (`pane.send_key`), e.g. `ctrl+u`.
    case sendKey(KeyChord)
    case copy, paste, selectAll
    case pageUp, pageDown
    case promptPrevious, promptNext
    /// A configuration-file or block action, run by the server (`client.action`).
    case server(String, JSONObject?)
    /// A key bound to a Lua function: send the key itself with `client.key`.
    case forwardKey

    /// Nil when the app can't perform the action; the next binding on the key, or the terminal, gets it.
    static func resolve(_ name: String, _ args: JSONObject?) -> AppAction? {
        let a = args ?? [:]
        switch name {
        case "client.tab.new": return .command(.newTab)
        case "client.tab.close": return .command(.closeTab)
        case "client.tab.rename": return .command(.renameTab)
        case "client.tab.next": return .command(.nextTab)
        case "client.tab.previous": return .command(.previousTab)
        case "client.tab.goto":
            guard let i = a.int("index") else { return nil }
            return .command(.goToTab(i))
        case "client.tab.overview", "session.switch", "pane.go_to": return .command(.tabOverview)
        case "client.close", "pane.close": return .command(.closePane)
        case "session.new": return .command(.newSession)
        case "pane.split.right": return .command(.splitRight)
        case "pane.split.down": return .command(.splitDown)
        case "pane.split.auto": return .splitAuto
        case "pane.split":
            switch a.str("direction") {
            case "right": return .command(.splitRight)
            case "down": return .command(.splitDown)
            case "auto": return .splitAuto
            default: return nil  // left/up: no RexCommand yet
            }
        case "pane.focus_next", "pane.focus.right", "pane.focus.down": return .command(.nextPane)
        case "pane.focus_previous", "pane.focus.left", "pane.focus.up": return .command(.previousPane)
        case "pane.focus":
            switch a.str("direction") {
            case "right", "down": return .command(.nextPane)
            case "left", "up": return .command(.previousPane)
            default: return nil
            }
        case "pane.zoom": return .command(.toggleZoom)
        case "client.font.increase": return .command(.fontBigger)
        case "client.font.decrease": return .command(.fontSmaller)
        case "client.font.reset": return .command(.fontReset)
        case "client.sidebar.toggle": return .command(.toggleSidebar)
        case "client.sidebar.activity.toggle": return .command(.toggleAgents)
        case "client.agents.jump_to_waiting": return .command(.jumpToWaiting)
        case "client.settings": return .command(.settings)
        case "pane.send_key":
            guard let k = a.str("key"), let c = KeyChord(spelling: k) else { return nil }
            return .sendKey(c)
        case "pane.copy": return .copy
        case "pane.paste": return .paste
        case "pane.select_all": return .selectAll
        case "client.scroll.page_up": return .pageUp
        case "client.scroll.page_down": return .pageDown
        case "client.prompt.previous": return .promptPrevious
        case "client.prompt.next": return .promptNext
        case "client.key.forward": return .forwardKey
        default:
            // Rex's own client actions that the app doesn't have (find, palette, resize, …).
            if name.hasPrefix("client.") || name.hasPrefix("pane.") || name.hasPrefix("session.") { return nil }
            // Dotted: a block action (com.superlogical.terminal.clear). No dot: a config-file action.
            return .server(name, args)
        }
    }
}

/// The actions the app declares to the server, with the Rex Mac app's titles.
enum KeyActions {
    struct Info {
        let name: String
        let title: String
        let category: String
        let repeats: Bool
    }

    static let all: [Info] = [
        Info(name: "client.close", title: "Close", category: "Window", repeats: false),
        Info(name: "client.settings", title: "Settings…", category: "App", repeats: false),
        Info(name: "client.sidebar.toggle", title: "Toggle Sidebar", category: "View", repeats: false),
        Info(name: "client.sidebar.activity.toggle", title: "Toggle Agents", category: "View", repeats: false),
        Info(name: "client.agents.jump_to_waiting", title: "Jump to Waiting Agent", category: "View", repeats: false),
        Info(name: "session.new", title: "New Session", category: "Session", repeats: false),
        Info(name: "session.switch", title: "Change Session…", category: "Session", repeats: false),
        Info(name: "client.tab.new", title: "New Tab", category: "Tab", repeats: false),
        Info(name: "client.tab.close", title: "Close Tab", category: "Tab", repeats: false),
        Info(name: "client.tab.rename", title: "Rename Tab", category: "Tab", repeats: false),
        Info(name: "client.tab.next", title: "Show Next Tab", category: "Tab", repeats: true),
        Info(name: "client.tab.previous", title: "Show Previous Tab", category: "Tab", repeats: true),
        Info(name: "client.tab.goto", title: "Go to Tab", category: "Tab", repeats: false),
        Info(name: "client.tab.overview", title: "Show All Tabs", category: "Tab", repeats: false),
        Info(name: "pane.split", title: "Split Pane", category: "Pane", repeats: false),
        Info(name: "pane.split.right", title: "Split Pane Right", category: "Pane", repeats: false),
        Info(name: "pane.split.down", title: "Split Pane Down", category: "Pane", repeats: false),
        Info(name: "pane.split.auto", title: "Split Pane Best Fit", category: "Pane", repeats: false),
        Info(name: "pane.focus", title: "Focus Pane", category: "Pane", repeats: true),
        Info(name: "pane.focus.left", title: "Focus Pane Left", category: "Pane", repeats: true),
        Info(name: "pane.focus.right", title: "Focus Pane Right", category: "Pane", repeats: true),
        Info(name: "pane.focus.up", title: "Focus Pane Up", category: "Pane", repeats: true),
        Info(name: "pane.focus.down", title: "Focus Pane Down", category: "Pane", repeats: true),
        Info(name: "pane.focus_next", title: "Focus Next Pane", category: "Pane", repeats: true),
        Info(name: "pane.focus_previous", title: "Focus Previous Pane", category: "Pane", repeats: true),
        Info(name: "pane.zoom", title: "Zoom Pane", category: "Pane", repeats: false),
        Info(name: "pane.close", title: "Close Pane", category: "Pane", repeats: false),
        Info(name: "pane.go_to", title: "Go to Anything…", category: "Pane", repeats: false),
        Info(name: "pane.send_key", title: "Send Key", category: "Pane", repeats: true),
        Info(name: "pane.copy", title: "Copy", category: "Pane", repeats: false),
        Info(name: "pane.paste", title: "Paste", category: "Pane", repeats: false),
        Info(name: "pane.select_all", title: "Select All", category: "Pane", repeats: false),
        Info(name: "client.key.forward", title: "Send Key to Server", category: "Pane", repeats: true),
        Info(name: "client.prompt.previous", title: "Jump to Previous Prompt", category: "Pane", repeats: true),
        Info(name: "client.prompt.next", title: "Jump to Next Prompt", category: "Pane", repeats: true),
        Info(name: "client.scroll.page_up", title: "Scroll Page Up", category: "Pane", repeats: true),
        Info(name: "client.scroll.page_down", title: "Scroll Page Down", category: "Pane", repeats: true),
        Info(name: "client.font.increase", title: "Increase Font Size", category: "View", repeats: true),
        Info(name: "client.font.decrease", title: "Decrease Font Size", category: "View", repeats: true),
        Info(name: "client.font.reset", title: "Reset Font Size", category: "View", repeats: false),
    ]

    static let byName: [String: Info] = Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0) })

    static let blockTitles: [String: String] = [
        "com.superlogical.terminal.clear": "Clear Terminal",
        "com.superlogical.terminal.reset": "Reset Terminal",
    ]

    static func repeats(_ action: String) -> Bool { byName[action]?.repeats ?? false }

    /// The title shown in the ⌘ shortcut overlay.
    static func title(_ b: KeyBinding) -> String {
        let a = b.args ?? [:]
        switch b.action {
        case "client.tab.goto":
            let i = a.int("index") ?? 0
            return i < 0 ? "Go to Last Tab" : "Go to Tab \(i)"
        case "pane.split":
            return "Split Pane \((a.str("direction") ?? "").capitalized)"
        case "pane.focus":
            return "Focus Pane \((a.str("direction") ?? "").capitalized)"
        case "pane.send_key":
            switch a.str("key") {
            case "ctrl+u": return "Delete to Line Start"
            case "ctrl+a": return "Move to Line Start"
            case "ctrl+e": return "Move to Line End"
            case "alt+b": return "Move Back One Word"
            case "alt+f": return "Move Forward One Word"
            case "ctrl+j": return "New Line"
            case "alt+backspace": return "Delete Word"
            case let k?: return "Send \(k)"
            default: return "Send Key"
            }
        default:
            if let t = byName[b.action]?.title { return t }
            if let t = blockTitles[b.action] { return t }
            let last = b.action.split(separator: ".").last.map(String.init) ?? b.action
            return last.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

/// The Rex Mac app's default shortcuts (for the actions the app performs), plus the app's own.
/// Sent to the server as the lowest layer; also the fallback when the server can't be asked.
@MainActor
enum KeyDefaults {
    static let layer: [(String, String, JSONObject?)] = {
        var b: [(String, String, JSONObject?)] = []
        func bind(_ keys: [String], _ action: String, _ args: JSONObject? = nil) {
            for k in keys { b.append((k, action, args)) }
        }
        bind(["cmd+w"], "client.close")
        bind(["cmd+,"], "client.settings")
        bind(["shift+cmd+n"], "session.new")
        bind(["cmd+k"], "session.switch")
        bind(["cmd+t"], "client.tab.new")
        bind(["alt+cmd+w"], "client.tab.close")
        bind(["ctrl+tab", "shift+cmd+]"], "client.tab.next")
        bind(["ctrl+shift+tab", "shift+cmd+["], "client.tab.previous")
        for i in 1...8 { bind(["cmd+[Digit\(i)]"], "client.tab.goto", ["index": i]) }
        bind(["cmd+[Digit9]"], "client.tab.goto", ["index": -1])
        bind(["cmd+d", "shift+cmd+right"], "pane.split.right")
        bind(["shift+cmd+d", "shift+cmd+down"], "pane.split.down")
        bind(["cmd+enter"], "pane.split.auto")
        bind(["alt+cmd+left"], "pane.focus.left")
        bind(["alt+cmd+right"], "pane.focus.right")
        bind(["alt+cmd+up"], "pane.focus.up")
        bind(["alt+cmd+down"], "pane.focus.down")
        bind(["cmd+]"], "pane.focus_next")
        bind(["cmd+["], "pane.focus_previous")
        bind(["shift+cmd+enter"], "pane.zoom")
        bind(["cmd+w"], "pane.close")
        bind(["cmd+p"], "pane.go_to")
        bind(["cmd+backspace"], "pane.send_key", ["key": "ctrl+u"])
        bind(["cmd+left"], "pane.send_key", ["key": "ctrl+a"])
        bind(["cmd+right"], "pane.send_key", ["key": "ctrl+e"])
        bind(["alt+left"], "pane.send_key", ["key": "alt+b"])
        bind(["alt+right"], "pane.send_key", ["key": "alt+f"])
        bind(["cmd+up"], "client.prompt.previous")
        bind(["cmd+down"], "client.prompt.next")
        bind(["shift+cmd+=", "cmd+="], "client.font.increase")
        bind(["cmd+-"], "client.font.decrease")
        bind(["cmd+[Digit0]"], "client.font.reset")
        bind(["cmd+/"], "client.sidebar.toggle")
        bind(["cmd+."], "client.sidebar.activity.toggle")
        // The app's own: the oldest agent waiting for you (the waiting pill's tap).
        bind(["alt+cmd+."], "client.agents.jump_to_waiting")
        // The app's own (Safari's Show All Tabs).
        bind(["shift+cmd+\\"], "client.tab.overview")
        return b
    }()

    /// The defaults in the order to try them (a later binding sits above an earlier one).
    static var resolved: [KeyBinding] {
        layer.reversed().compactMap { k, a, args in
            KeyChord(spelling: k).map { KeyBinding(chord: $0, action: a, args: args) }
        }
    }

    static var requestLayer: JSONObject {
        ["name": "default",
         "bindings": layer.map { k, a, args -> JSONObject in
             var o: JSONObject = ["keys": [k], "action": a]
             if let args { o["args"] = args }
             return o
         }]
    }
}

/// The keymap for one server: Rex's defaults under the user's init.lua, as `client.keymap` resolves it.
/// Falls back to the built-in defaults until (or unless) the server answers.
@MainActor
@Observable
final class KeymapStore {
    @ObservationIgnored private let control: RexControl
    /// Observed: the app's shortcut menu follows it (`AppShortcutCommands`).
    private(set) var bindings: [KeyBinding] = []
    /// Bumped on every change; key command lists cache against it.
    @ObservationIgnored private(set) var generation = 0
    @ObservationIgnored private var byChord: [KeyChord: [Int]] = [:]
    @ObservationIgnored private var hash: String?
    @ObservationIgnored private var instance: String?
    @ObservationIgnored private var loading = false

    init(control: RexControl) {
        self.control = control
        apply(KeyDefaults.resolved)
    }

    /// Bindings for a pressed key (its logical and physical spellings), in the order to try them.
    func bindings(for chords: [KeyChord]) -> [KeyBinding] {
        var idx: [Int] = []
        for c in chords { idx += byChord[c] ?? [] }
        return idx.sorted().map { bindings[$0] }
    }

    /// The binding a key runs: the first one the app can perform.
    func resolve(_ chords: [KeyChord]) -> (KeyBinding, AppAction)? {
        for b in bindings(for: chords) {
            if let a = AppAction.resolve(b.action, b.args) { return (b, a) }
        }
        return nil
    }

    /// The binding a press runs (`KeyInput.chordTiers`): the first tier that has one.
    func resolve(tiers: [[KeyChord]]) -> (KeyBinding, AppAction)? {
        for chords in tiers {
            if let hit = resolve(chords) { return hit }
        }
        return nil
    }

    /// The binding a key press runs, from a hardware keyboard (`TerminalHost.handleKey`) or the key
    /// bar's ⌘ (`KeyInput.press(barKey:mods:)`, `press(typing:mods:)`): one lookup for both.
    func resolve(press: KeyInput.Press) -> (KeyBinding, AppAction)? {
        resolve(tiers: KeyInput.chordTiers(press))
    }

    /// `keymap_changed`: re-read unless the file is the one we already have.
    func configChanged(hash newHash: String?) {
        guard newHash == nil || newHash != hash else { return }
        Task { await load() }
    }

    func load() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        let actions: [JSONObject] = KeyActions.all.map {
            ["name": $0.name, "kind": "client", "title": $0.title, "category": $0.category, "repeats": $0.repeats]
        }
        do {
            let r = try await control.call("client.keymap", [
                "actions": actions,
                "server_actions": "none",
                "defaults": [KeyDefaults.requestLayer],
            ])
            if let c = r.obj("config") {
                hash = c.str("hash")
                instance = c.str("instance_id")
            }
            apply(Self.bindings(in: r))
        } catch {
            // Older server or no connection: keep what we have (the defaults at first).
        }
    }

    /// The single-key bindings in a `client.keymap` response, top of each key's stack first.
    static func bindings(in response: JSONObject) -> [KeyBinding] {
        response.arr("bindings").compactMap { b in
            // Key sequences and modes aren't supported yet; their keys go to the terminal.
            guard b.str("mode") == nil, let keys = b["keys"] as? [String], keys.count == 1,
                  let action = b.str("action"), let chord = KeyChord(spelling: keys[0]) else { return nil }
            return KeyBinding(chord: chord, action: action, args: b.obj("args"))
        }
    }

    func apply(_ list: [KeyBinding]) {
        bindings = list
        byChord = [:]
        for (i, b) in list.enumerated() { byChord[b.chord, default: []].append(i) }
        generation += 1
    }
}
