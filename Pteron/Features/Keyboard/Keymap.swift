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
    /// The pane's files: the browser, Insert Path, and the pickers that send a file or a photo
    /// (`PaneFiles.run`). The pane runs it where its host can; elsewhere the key does nothing.
    case files(FilesCommand)
    case pageUp, pageDown
    case promptPrevious, promptNext
    /// A configuration-file or block action, run by the server (`client.action`).
    case server(String, JSONObject?)
    /// A key bound to a Lua function: send the key itself with `client.key`.
    case forwardKey

    /// Nil when the app can't perform the action; the next binding on the key, or the terminal, gets it.
    /// The pane and tab order commands resolve only where the pane's server can run them
    /// (`panes`, `PaneArrange.isAvailable`), so elsewhere their keys fall through as before.
    static func resolve(_ name: String, _ args: JSONObject?, panes: PaneSupport = .none) -> AppAction? {
        let a = args ?? [:]
        if let c = PaneCommand.forAction(name) {
            guard PaneArrange.isAvailable(c, target: nil, support: panes) else { return nil }
            switch name {
            case "pane.balance": return .command(.balanceSplits)
            case "pane.close_others": return .command(.closeOtherPanes)
            case "pane.move_to_tab": return .command(.moveToTab)
            case "pane.move_to_new_tab": return .command(.moveToNewTab)
            case "pane.minimize_floating": return .command(.minimizeFloat)
            case "pane.minimize_all_floating": return .command(.minimizeAllFloats)
            case "client.tab.move.backward": return .command(.moveTab(-1))
            default: return .command(.moveTab(1))
            }
        }
        if let c = FilesCommand.forAction(name) { return .files(c) }
        switch name {
        case "client.tab.new": return .command(.newTab)
        case "client.tab.close": return .command(.closeTab)
        case "client.tab.rename": return .command(.renameTab)
        case "client.tab.next": return .command(.nextTab)
        case "client.tab.previous": return .command(.previousTab)
        case "client.tab.goto":
            guard let i = a.int("index") else { return nil }
            return .command(.goToTab(i))
        case "client.tab.overview": return .command(.tabOverview)
        // One palette, three ways in (`GoToScope`).
        case "pane.go_to": return .command(.goTo(.anything))
        case "session.switch": return .command(.goTo(.sessions))
        case "client.palette.toggle": return .command(.goTo(.commands))
        case "client.close", "pane.close": return .command(.closePane)
        case "session.new": return .command(.newSession)
        case "session.next": return .command(.nextSession)
        case "session.previous": return .command(.previousSession)
        case "session.rename": return .command(.renameSession)
        case "session.close": return .command(.closeSession)
        case "client.host.add": return .command(.addComputer)
        case "client.tab.close_others": return .command(.closeOtherTabs)
        case "pane.split.left": return .command(.splitLeft)
        case "pane.split.right": return .command(.splitRight)
        case "pane.split.up": return .command(.splitUp)
        case "pane.split.down": return .command(.splitDown)
        case "pane.split.auto": return .splitAuto
        case "pane.split":
            switch a.str("direction") {
            case "left": return .command(.splitLeft)
            case "right": return .command(.splitRight)
            case "up": return .command(.splitUp)
            case "down": return .command(.splitDown)
            case "auto": return .splitAuto
            default: return nil
            }
        case "pane.focus_next", "pane.focus.right", "pane.focus.down": return .command(.nextPane)
        case "pane.focus_previous", "pane.focus.left", "pane.focus.up": return .command(.previousPane)
        case "pane.focus":
            switch a.str("direction") {
            case "right", "down": return .command(.nextPane)
            case "left", "up": return .command(.previousPane)
            default: return nil
            }
        case "client.navigate.back": return .command(.navigateBack)
        case "client.navigate.forward": return .command(.navigateForward)
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
        case "client.find.open": return .command(.find(.open))
        case "client.find.next": return .command(.find(.next))
        case "client.find.previous": return .command(.find(.previous))
        default:
            // Rex's own client actions that the app doesn't have (resize, copy mode, mute, …).
            // Their keys stay unbound here: never sent to the server as a `client.action`.
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

    /// In the Rex Mac app's palette order and groups (`MacPalette`), with the Mac's titles. Where
    /// the app's wording rules differ, the app's title: "…" where a question follows (Rename Tab…),
    /// Show/Hide in place of Toggle, Rex in place of Server.
    static let all: [Info] = [
        Info(name: "client.close", title: "Close Pane", category: "Window", repeats: false),
        Info(name: "client.palette.toggle", title: "Command Palette…", category: "App", repeats: false),
        Info(name: "client.settings", title: "Settings…", category: "App", repeats: false),
        Info(name: "session.new", title: "New Session", category: "Session", repeats: false),
        Info(name: "session.switch", title: "Change Session…", category: "Session", repeats: false),
        Info(name: "session.next", title: "Next Session", category: "Session", repeats: true),
        Info(name: "session.previous", title: "Previous Session", category: "Session", repeats: true),
        Info(name: "session.rename", title: "Rename Session…", category: "Session", repeats: false),
        Info(name: "session.close", title: "Close Session", category: "Session", repeats: false),
        Info(name: "client.host.add", title: "Add Computer…", category: "Host", repeats: false),
        Info(name: "client.tab.new", title: "New Tab", category: "Tab", repeats: false),
        Info(name: "client.tab.close", title: "Close Tab", category: "Tab", repeats: false),
        Info(name: "client.tab.close_others", title: "Close Other Tabs", category: "Tab", repeats: false),
        Info(name: "client.tab.rename", title: "Rename Tab…", category: "Tab", repeats: false),
        Info(name: "client.tab.next", title: "Show Next Tab", category: "Tab", repeats: true),
        Info(name: "client.tab.previous", title: "Show Previous Tab", category: "Tab", repeats: true),
        Info(name: "client.tab.goto", title: "Go to Tab", category: "Tab", repeats: false),
        Info(name: "client.tab.overview", title: "Show All Tabs", category: "Tab", repeats: false),
        Info(name: "client.tab.move.backward", title: "Move Tab Backward", category: "Tab", repeats: true),
        Info(name: "client.tab.move.forward", title: "Move Tab Forward", category: "Tab", repeats: true),
        Info(name: "pane.split", title: "Split Pane", category: "Pane", repeats: false),
        Info(name: "pane.split.left", title: "Split Pane Left", category: "Pane", repeats: false),
        Info(name: "pane.split.right", title: "Split Pane Right", category: "Pane", repeats: false),
        Info(name: "pane.split.up", title: "Split Pane Up", category: "Pane", repeats: false),
        Info(name: "pane.split.down", title: "Split Pane Down", category: "Pane", repeats: false),
        Info(name: "pane.split.auto", title: "Split Pane Best Fit", category: "Pane", repeats: false),
        Info(name: "pane.focus", title: "Focus Pane", category: "Pane", repeats: true),
        Info(name: "pane.focus.left", title: "Focus Pane Left", category: "Pane", repeats: true),
        Info(name: "pane.focus.right", title: "Focus Pane Right", category: "Pane", repeats: true),
        Info(name: "pane.focus.up", title: "Focus Pane Up", category: "Pane", repeats: true),
        Info(name: "pane.focus.down", title: "Focus Pane Down", category: "Pane", repeats: true),
        Info(name: "pane.focus_next", title: "Focus Next Pane", category: "Pane", repeats: true),
        Info(name: "pane.focus_previous", title: "Focus Previous Pane", category: "Pane", repeats: true),
        Info(name: "client.navigate.back", title: "Navigate Back", category: "Pane", repeats: true),
        Info(name: "client.navigate.forward", title: "Navigate Forward", category: "Pane", repeats: true),
        Info(name: "pane.minimize_floating", title: "Minimize Floating Window", category: "Pane", repeats: false),
        Info(name: "pane.minimize_all_floating", title: "Minimize All Floating Windows", category: "Pane", repeats: false),
        Info(name: "pane.zoom", title: "Zoom Pane", category: "Pane", repeats: false),
        Info(name: "pane.close", title: "Close Pane", category: "Pane", repeats: false),
        Info(name: "pane.close_others", title: "Close Other Panes", category: "Pane", repeats: false),
        Info(name: "pane.balance", title: "Balance Splits", category: "Pane", repeats: false),
        Info(name: "pane.move_to_new_tab", title: "Move Pane to New Tab", category: "Pane", repeats: false),
        Info(name: "pane.move_to_tab", title: "Move Pane to Tab…", category: "Pane", repeats: false),
        Info(name: "pane.go_to_directory", title: "Go to Directory…", category: "Pane", repeats: false),
        Info(name: "pane.go_to", title: "Go to Anything…", category: "Pane", repeats: false),
        Info(name: "pane.insert_path", title: "Insert Path…", category: "Pane", repeats: false),
        Info(name: "pane.insert_photo", title: "Insert Photo…", category: "Pane", repeats: false),
        Info(name: "pane.insert_file", title: "Insert File…", category: "Pane", repeats: false),
        Info(name: "pane.paste", title: "Paste into Pane", category: "Pane", repeats: false),
        Info(name: "pane.copy", title: "Copy from Pane", category: "Pane", repeats: false),
        Info(name: "pane.select_all", title: "Select All in Pane", category: "Pane", repeats: false),
        Info(name: "pane.send_key", title: "Send Key", category: "Pane", repeats: true),
        Info(name: "client.key.forward", title: "Send Key to Rex", category: "Pane", repeats: true),
        Info(name: "client.prompt.previous", title: "Jump to Previous Prompt", category: "Pane", repeats: true),
        Info(name: "client.prompt.next", title: "Jump to Next Prompt", category: "Pane", repeats: true),
        Info(name: "client.scroll.page_up", title: "Scroll Page Up", category: "Pane", repeats: true),
        Info(name: "client.scroll.page_down", title: "Scroll Page Down", category: "Pane", repeats: true),
        Info(name: "client.find.open", title: "Find…", category: "Find", repeats: false),
        Info(name: "client.find.next", title: "Find Next", category: "Find", repeats: true),
        Info(name: "client.find.previous", title: "Find Previous", category: "Find", repeats: true),
        Info(name: "client.font.increase", title: "Increase Font Size", category: "View", repeats: true),
        Info(name: "client.font.decrease", title: "Decrease Font Size", category: "View", repeats: true),
        Info(name: "client.font.reset", title: "Reset Font Size", category: "View", repeats: false),
        Info(name: "client.sidebar.toggle", title: "Show/Hide Sidebar", category: "View", repeats: false),
        Info(name: "client.sidebar.activity.toggle", title: "Show/Hide Agents", category: "View", repeats: false),
        Info(name: "client.agents.jump_to_waiting", title: "Jump to Waiting", category: "View", repeats: false),
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
            case let k?: return KeyChord(spelling: k).map { "Send \(KeyLabel.text($0))" } ?? "Send \(k)"
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
        bind(["cmd+n"], "session.new")
        bind(["cmd+k"], "session.switch")
        bind(["cmd+t"], "client.tab.new")
        bind(["alt+cmd+w"], "client.tab.close")
        bind(["ctrl+shift+pageup"], "client.tab.move.backward")
        bind(["ctrl+shift+pagedown"], "client.tab.move.forward")
        bind(["ctrl+tab", "shift+cmd+]"], "client.tab.next")
        bind(["ctrl+shift+tab", "shift+cmd+["], "client.tab.previous")
        for i in 1...8 { bind(["cmd+[Digit\(i)]"], "client.tab.goto", ["index": i]) }
        bind(["cmd+[Digit9]"], "client.tab.goto", ["index": -1])
        bind(["cmd+d", "shift+cmd+right"], "pane.split.right")
        bind(["shift+cmd+d", "shift+cmd+down"], "pane.split.down")
        bind(["shift+cmd+left"], "pane.split.left")
        bind(["shift+cmd+up"], "pane.split.up")
        bind(["cmd+enter"], "pane.split.auto")
        bind(["alt+cmd+left"], "pane.focus.left")
        bind(["alt+cmd+right"], "pane.focus.right")
        bind(["alt+cmd+up"], "pane.focus.up")
        bind(["alt+cmd+down"], "pane.focus.down")
        bind(["cmd+]"], "pane.focus_next")
        bind(["cmd+["], "pane.focus_previous")
        bind(["alt+cmd+["], "client.navigate.back")
        bind(["alt+cmd+]"], "client.navigate.forward")
        bind(["alt+cmd+m"], "pane.minimize_floating")
        bind(["alt+shift+cmd+enter"], "pane.minimize_all_floating")
        bind(["shift+cmd+enter"], "pane.zoom")
        bind(["cmd+w"], "pane.close")
        bind(["cmd+p"], "pane.go_to")
        bind(["shift+cmd+p"], "client.palette.toggle")
        bind(["ctrl+cmd+i"], "pane.insert_path")
        bind(["cmd+backspace"], "pane.send_key", ["key": "ctrl+u"])
        bind(["cmd+left"], "pane.send_key", ["key": "ctrl+a"])
        bind(["cmd+right"], "pane.send_key", ["key": "ctrl+e"])
        bind(["alt+left"], "pane.send_key", ["key": "alt+b"])
        bind(["alt+right"], "pane.send_key", ["key": "alt+f"])
        bind(["cmd+f"], "client.find.open")
        bind(["cmd+g"], "client.find.next")
        // The Mac also gives ⇧⌘G to Go to Directory…, which it runs while find is closed. Here a
        // key runs one binding, so it stays Find Previous; Browse Files… has no key of its own.
        bind(["shift+cmd+g"], "client.find.previous")
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
    /// Which pane and tab order commands the server runs (`ServerConnection.panesSupportChanged`).
    /// Observed, as `bindings` is: the app's shortcut menu follows it. A change is a new
    /// `generation`, so key command lists built for the old one are built again.
    var panes = PaneSupport.none {
        didSet { if panes != oldValue { generation += 1 } }
    }

    /// The configuration file's actions (`rex.action`), for the palette's rows. Read at open,
    /// never observed: a reload while the palette is open shows on its next rebuild.
    @ObservationIgnored private(set) var luaActions: [LuaAction] = []

    init(control: RexControl) {
        self.control = control
        apply(KeyDefaults.resolved)
    }

    /// The name to show for an action the keymap knows: a Lua action's title, a block action's,
    /// the app's own; else the name itself.
    func title(forAction name: String) -> String {
        if let a = luaActions.first(where: { $0.name == name }) { return a.title }
        if let t = KeyActions.blockTitles[name] ?? KeyActions.byName[name]?.title { return t }
        return name
    }

    /// Bindings for a pressed key (its logical and physical spellings), in the order to try them.
    func bindings(for chords: [KeyChord]) -> [KeyBinding] {
        var idx: [Int] = []
        for c in chords { idx += byChord[c] ?? [] }
        return idx.sorted().map { bindings[$0] }
    }

    /// What a binding does on this server; nil when the app can't perform it here.
    func action(_ b: KeyBinding) -> AppAction? { AppAction.resolve(b.action, b.args, panes: panes) }

    /// The binding a key runs: the first one the app can perform.
    func resolve(_ chords: [KeyChord]) -> (KeyBinding, AppAction)? {
        for b in bindings(for: chords) {
            if let a = action(b) { return (b, a) }
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
                // The configuration file's actions only (about 2 KB): the palette's Lua rows.
                "server_actions": "configured",
                "defaults": [KeyDefaults.requestLayer],
            ])
            if let c = r.obj("config") {
                hash = c.str("hash")
                instance = c.str("instance_id")
            }
            luaActions = LuaAction.list(in: r)
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

/// One action the server's configuration file defines (`rex.action`), as `client.keymap` lists
/// it. Only `kind: "lua"` entries count, so a server that lists every action (an older one that
/// ignores `server_actions`) gives the same list.
struct LuaAction: Equatable, Sendable {
    let name: String
    let title: String
    let description: String?
    let category: String
    let keywords: String?
    /// Its argument schema names a required property: the phone can't fill it in.
    let needsArguments: Bool

    static func list(in response: JSONObject) -> [LuaAction] {
        response.arr("actions").compactMap { a in
            guard a.str("kind") == "lua", let name = a.str("name"), !name.isEmpty, !name.contains(".") else { return nil }
            let required = (a.obj("args")?["required"] as? [Any])?.isEmpty == false
            return LuaAction(name: name, title: a.str("title").flatMap { $0.isEmpty ? nil : $0 } ?? Self.title(name),
                             description: a.str("description").flatMap { $0.isEmpty ? nil : $0 },
                             category: a.str("category").flatMap { $0.isEmpty ? nil : $0 } ?? "Actions",
                             keywords: a.str("keywords"), needsArguments: required)
        }
    }

    /// `dev_layout` as `Dev Layout`, for an action that gives no title.
    static func title(_ name: String) -> String {
        name.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ").capitalized
    }
}
