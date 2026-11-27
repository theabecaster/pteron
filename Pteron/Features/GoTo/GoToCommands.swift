import Foundation
import RexKit

/// What the palette knows of the target pane's host at open, for the rows that depend on it.
struct GoToPaneState: Equatable {
    /// Text is selected: Copy from Pane has something to copy.
    var hasSelection = false
    /// Find is open in the pane: Find Next and Find Previous have matches to step through.
    var findOpen = false
}

/// Whether Navigate Back and Navigate Forward have a place to go (`AppModel.canNavigate`).
struct NavAvailability: Equatable {
    var back = false
    var forward = false
}

/// What a key does in a pane that the palette runs too: a value that crosses to the pane's
/// host after the palette closes (`GoToRun.pane`).
enum PaneKeyAction: Equatable, Sendable {
    case splitAuto, copy, paste, selectAll, pageUp, pageDown, promptPrevious, promptNext
    case sendKey(KeyChord)

    init?(_ a: AppAction) {
        switch a {
        case .splitAuto: self = .splitAuto
        case .copy: self = .copy
        case .paste: self = .paste
        case .selectAll: self = .selectAll
        case .pageUp: self = .pageUp
        case .pageDown: self = .pageDown
        case .promptPrevious: self = .promptPrevious
        case .promptNext: self = .promptNext
        case .sendKey(let c): self = .sendKey(c)
        case .command, .files, .server, .forwardKey: return nil
        }
    }

    var action: AppAction {
        switch self {
        case .splitAuto: .splitAuto
        case .copy: .copy
        case .paste: .paste
        case .selectAll: .selectAll
        case .pageUp: .pageUp
        case .pageDown: .pageDown
        case .promptPrevious: .promptPrevious
        case .promptNext: .promptNext
        case .sendKey(let c): .sendKey(c)
        }
    }

    var symbol: String {
        switch self {
        case .splitAuto: "rectangle.split.2x1"
        case .copy: "doc.on.doc"
        case .paste: "doc.on.clipboard"
        case .selectAll: "character.textbox"
        case .pageUp, .promptPrevious: "arrow.up.to.line"
        case .pageDown, .promptNext: "arrow.down.to.line"
        case .sendKey: "keyboard"
        }
    }
}

/// The palette's command rows: the Rex Mac app's palette as far as the phone runs it, in its
/// groups and order (`MacPalette`), then the computers' ports and the server's Lua actions.
///
/// It lists every app command and every pane action the keymap can run: the actions the app
/// declares (`KeyActions`), and each binding with fixed arguments (Go to Tab 2, a Send Key) as a
/// row of its own. A row shows only where its menu item or key would work: pane and tab commands
/// need a target, and the Arrange commands ask the same `PaneArrange.isAvailable` the menu asks.
/// Each row shows the key that runs it, from the keymap.
@MainActor
enum GoToCommands {
    /// App actions that never get a row: the palette itself, duplicates of another row
    /// (`client.close` is Close Pane, the directional focus moves are next and previous), and
    /// actions that need the key that ran them (`client.key.forward`).
    static let excluded: Set<String> = [
        "client.palette.toggle",
        "client.close", "pane.focus.left", "pane.focus.right", "pane.focus.up", "pane.focus.down",
        "client.key.forward",
    ]

    static let destructive: Set<String> = [
        "pane.close", "client.tab.close", "client.tab.close_others", "session.close",
        "com.superlogical.terminal.clear", "com.superlogical.terminal.reset",
    ]

    static let copyModeNote = "Copy mode works only in the Rex app."
    static let argumentsNote = "Needs arguments this \(DeviceWord.current) can't fill in."

    /// Where a binding with arguments sits among its action's rows (under 100): Go to Tab by its
    /// number, the last tab last; the Mac's shell keys in the Mac's order; any other after them,
    /// in the keymap's order.
    static func argumentRank(_ b: KeyBinding, step: Int) -> Int {
        let a = b.args ?? [:]
        switch b.action {
        case "client.tab.goto":
            let i = a.int("index") ?? 0
            return i < 0 ? 99 : min(max(i, 1), 98)
        case "pane.send_key":
            let mac = ["ctrl+u", "ctrl+a", "ctrl+e", "alt+b", "alt+f"]
            if let k = a.str("key"), let i = mac.firstIndex(of: k) { return i + 1 }
            return min(10 + step, 98)
        default:
            return min(step, 98)
        }
    }

    /// The key of an app command's row.
    static func appKey(_ action: String) -> String { "app:" + action }

    /// The key of a port's row, and the words that find one besides its title.
    static func portKey(_ server: UUID, _ row: String) -> String { "port:\(server.uuidString):\(row)" }
    static let portKeywords = "ports browser page web server preview"

    /// A Mac action's row order: its place in the Mac's palette. The rows after them (ports,
    /// Lua actions) count on from `afterMac`.
    static func macOrder(_ action: String) -> Int { 100_000 + (MacPalette.rank(action) ?? 9_000) * 100 }
    static let afterMac = 2_000_000

    /// The bindings a key press runs, in the keymap's order: for each key the first binding the
    /// app can perform, with what it does.
    static func live(_ bindings: [KeyBinding], panes: PaneSupport) -> [(binding: KeyBinding, action: AppAction)] {
        var decided = Set<KeyChord>()
        var out: [(KeyBinding, AppAction)] = []
        for b in bindings where !decided.contains(b.chord) {
            guard let a = AppAction.resolve(b.action, b.args, panes: panes) else { continue }
            decided.insert(b.chord)
            out.append((b, a))
        }
        return out
    }

    /// The key a row shows: one bound to the action by its name, else any key that does the same.
    static func keyLabel(_ name: String, command: RexCommand?, pane: PaneKeyAction?,
                         live: [(binding: KeyBinding, action: AppAction)]) -> String? {
        if let hit = live.first(where: { $0.binding.action == name && $0.binding.args == nil }) { return KeyLabel.text(hit.binding.chord) }
        let same = live.first { l in
            if let command, case .command(let c) = l.action { return c == command }
            if let pane, let p = PaneKeyAction(l.action) { return p == pane }
            return false
        }
        return same.map { KeyLabel.text($0.binding.chord) }
    }

    /// `history`: whether Navigate Back and Navigate Forward have somewhere to go (`NavHistory`).
    static func add(_ servers: [ServerConnection], target: GoToTarget?, waitingCount: Int,
                    navigation: NavigationStyle = .sidebar, pane: GoToPaneState = .init(),
                    history: NavAvailability = .init(), into copy: inout GoToSource.Copy) {
        let targetServer = target.flatMap { t in servers.first { $0.id == t.serverID } }
        let server = targetServer ?? servers.first { $0.phase == .online } ?? servers.first
        let keymap = server?.keymap
        let support = server?.capabilities.paneSupport ?? .none
        let view = target.flatMap { t in targetServer?.views[t.sessionID] }
        let window = target.flatMap { view?.window($0.windowID) }
        let block = target?.blockID.flatMap { window?.block($0) }
        let live = live(keymap?.bindings ?? KeyDefaults.resolved, panes: keymap?.panes ?? support)
        var commands: [RexCommand] = []
        var paneRows: [PaneKeyAction] = []

        func add(_ item: GoToItem, _ run: GoToRun) {
            copy.items.append(item)
            copy.runs[item.id] = run
        }
        func applies(_ c: RexCommand) -> Bool {
            Self.applies(c, target: target, server: targetServer, window: window, block: block, tabs: view?.windows ?? [],
                         support: support, waitingCount: waitingCount, servers: servers, findOpen: pane.findOpen,
                         history: history)
        }
        func paneApplies(_ p: PaneKeyAction) -> Bool {
            guard block?.isTerminal == true else { return false }
            return p != .copy || pane.hasSelection
        }

        // The app's own, by name.
        for info in KeyActions.all where !excluded.contains(info.name) {
            let order = macOrder(info.name)
            switch AppAction.resolve(info.name, nil, panes: support) {
            case .command(let c)?:
                guard !commands.contains(c) else { continue }
                // Tab mode has no sidebar to toggle.
                if navigation == .tabs, c == .toggleSidebar { continue }
                guard applies(c) else { continue }
                commands.append(c)
                add(GoToItem(id: .command(appKey(info.name)), kind: .command, title: info.title, subtitle: info.category,
                             order: order, destructive: destructive.contains(info.name), symbol: symbol(c),
                             keyLabel: keyLabel(info.name, command: c, pane: nil, live: live), category: info.category),
                    .command(c))
            case let a?:
                guard let p = PaneKeyAction(a), !paneRows.contains(p), paneApplies(p) else { continue }
                paneRows.append(p)
                add(GoToItem(id: .command(appKey(info.name)), kind: .command, title: info.title, subtitle: info.category,
                             order: order, symbol: p.symbol, keyLabel: keyLabel(info.name, command: nil, pane: p, live: live),
                             category: info.category),
                    .pane(p))
            case nil:
                continue
            }
        }

        // Each binding with fixed arguments that does something no row above does: Go to Tab 2,
        // Delete to Line Start, a key sent to the pane.
        var step = 0
        for (b, a) in live where b.args?.isEmpty == false && !excluded.contains(b.action) {
            guard let info = KeyActions.byName[b.action] else { continue }
            let id = GoToItemID.command(appKey(b.action) + "|" + (argsSummary(b.args ?? [:]) ?? b.chord.spelling))
            guard copy.runs[id] == nil else { continue }
            step += 1
            func item(_ symbol: String, _ run: GoToRun) {
                add(GoToItem(id: id, kind: .command, title: KeyActions.title(b), subtitle: info.category,
                             order: macOrder(b.action) + argumentRank(b, step: step), symbol: symbol, keyLabel: KeyLabel.text(b.chord),
                             category: info.category), run)
            }
            if case .command(let c) = a {
                guard !commands.contains(c), applies(c) else { continue }
                commands.append(c)
                item(symbol(c), .command(c))
            } else if let p = PaneKeyAction(a), !paneRows.contains(p), paneApplies(p) {
                paneRows.append(p)
                item(p.symbol, .pane(p))
            }
        }

        // The target pane's files: the browser, Insert Path and the two pickers, each only where
        // the attach menu or its key would work for that pane (`ServerConnection.offers`).
        if let s = targetServer, s.phase == .online, let block, block.isTerminal {
            for c in FilesCommand.allCases where s.offers(c, host: block.hostID, block: block.id) {
                add(GoToItem(id: .command(appKey(c.action)), kind: .command, title: c.title, subtitle: "Pane",
                             fields: [.init(text: c.keywords, weight: 0.7)], order: macOrder(c.action), symbol: c.symbol,
                             keyLabel: KeyLabel.for(action: c.action, in: keymap), category: "Pane"),
                    .files(c))
            }
        }

        var order = afterMac
        let several = servers.count > 1
        // The pages of the dev servers that run in panes: every connected machine's Ports
        // group, one row a port ("Open localhost:3000 · Next.js").
        for s in servers where s.phase == .online {
            for row in s.portRows {
                order += 1
                let program = PortNames.program(row.entry), folder = PortNames.folder(row.entry.folder)
                var sub = ["Ports"]
                if let folder { sub.append(folder) }
                if several { sub.append(s.config.name) }
                var fields: [GoToItem.Field] = [.init(text: portKeywords, weight: 0.7)]
                if let folder { fields.append(.init(text: folder, weight: 0.7)) }
                add(GoToItem(id: .command(portKey(s.id, row.id)), kind: .command,
                             title: ["Open \(row.entry.name)", program].compactMap { $0 }.joined(separator: " · "),
                             subtitle: sub.joined(separator: " · "), fields: fields, order: order, symbol: "globe",
                             category: "Ports"),
                    .port(serverID: s.id, row: row.id))
            }
        }

        // The configuration file's actions: the target's server, or with no tab every online one.
        // An offline server's actions are hidden: they could only fail.
        let luaServers = (targetServer.map { [$0] } ?? servers).filter { $0.phase == .online }
        for s in luaServers {
            let bindings = s.keymap.bindings
            for a in s.keymap.luaActions {
                order += 1
                let key = "lua:\(s.id.uuidString):\(a.name)"
                var sub = [a.description ?? a.category]
                if several { sub.append(s.config.name) }
                var fields: [GoToItem.Field] = [.init(text: a.name, weight: 0.8)]
                if let k = a.keywords, !k.isEmpty { fields.append(.init(text: k, weight: 0.7)) }
                if let d = a.description { fields.append(.init(text: d, weight: 0.5)) }
                add(GoToItem(id: .command(key), kind: .command, title: a.title, subtitle: sub.joined(separator: " · "),
                             fields: fields, order: order, dimmed: a.needsArguments ? argumentsNote : nil, symbol: "command",
                             keyLabel: KeyLabel.for(action: a.name, in: s.keymap), category: a.category),
                    a.needsArguments ? .none
                        : .server(serverID: s.id, name: a.name, args: nil, title: a.title, onTarget: targetServer != nil))
                // A binding with fixed arguments is a row of its own, with that binding's key.
                var seen = Set<String>()
                for b in bindings where b.action == a.name {
                    guard let args = b.args, !args.isEmpty, let summary = argsSummary(args), seen.insert(summary).inserted else { continue }
                    order += 1
                    var bsub = [summary]
                    if several { bsub.append(s.config.name) }
                    add(GoToItem(id: .command(key + "|" + summary), kind: .command, title: a.title,
                                 subtitle: bsub.joined(separator: " · "), fields: fields + [.init(text: summary, weight: 0.8)],
                                 order: order, symbol: "command", keyLabel: KeyLabel.text(b.chord), category: a.category),
                        .server(serverID: s.id, name: a.name, args: args, title: a.title, onTarget: targetServer != nil))
                }
            }
        }

        // The target pane's block actions, only where its creator lists the method.
        if let s = targetServer, s.phase == .online, let block {
            for (name, title) in KeyActions.blockTitles.sorted(by: { $0.key < $1.key }) {
                let prefix = block.creator + "."
                guard name.hasPrefix(prefix),
                      s.capabilities.method(String(name.dropFirst(prefix.count)), creator: block.creator, host: block.hostID) == .present
                else { continue }
                add(GoToItem(id: .command("block:" + name), kind: .command, title: title, subtitle: "Pane", order: macOrder(name),
                             destructive: destructive.contains(name), symbol: "eraser",
                             keyLabel: KeyLabel.for(action: name, in: s.keymap), category: "Pane"),
                    .server(serverID: s.id, name: name, args: nil, title: title, onTarget: true))
            }
        }

        // Copy mode runs only in the Mac app: its rows show dimmed, and only where the keymap
        // binds one of its actions, so a setup without copy mode never reads the note.
        if let keymap {
            var seen = Set<String>()
            for b in keymap.bindings where b.action.hasPrefix("pane.copy_mode.") && seen.insert(b.action).inserted {
                add(GoToItem(id: .command("copy:" + b.action), kind: .command, title: copyModeTitle(b.action),
                             subtitle: copyModeNote, order: macOrder(b.action), dimmed: copyModeNote, symbol: "text.cursor",
                             category: "Pane"),
                    .none)
            }
        }
    }

    /// Whether an app command applies now, as its menu item would show.
    static func applies(_ c: RexCommand, target: GoToTarget?, server: ServerConnection?, window: WindowInfo?,
                        block: BlockInfo?, tabs: [WindowInfo], support: PaneSupport, waitingCount: Int,
                        servers: [ServerConnection] = [], findOpen: Bool = false,
                        history: NavAvailability = .init()) -> Bool {
        // Go to Anything… and Change Session… switch the palette's scope, with a tab or without.
        if case .goTo(let scope) = c { return scope != .commands }
        if c.isWindowCommand {
            guard let t = target, let server, let window else { return false }
            switch c {
            case .toggleZoom: return t.canZoom
            case .nextTab: return TabNav.neighbor(server, t.sessionID, t.windowID, by: 1) != nil
            case .previousTab: return TabNav.neighbor(server, t.sessionID, t.windowID, by: -1) != nil
            case .nextPane, .previousPane: return t.canSwitchPane ?? (window.pageBlockIDs.count > 1)
            case .find(.open): return block?.isTerminal == true
            // Find's steps do nothing with find closed.
            case .find: return block?.isTerminal == true && findOpen
            case .goToTab(let n): return n == -1 ? tabs.count > 1 : n >= 1 && n <= tabs.count
            case .closePane, .splitRight, .splitDown, .splitLeft, .splitUp, .clear: return block != nil
            case .balanceSplits, .closeOtherPanes, .moveToTab, .moveToNewTab, .moveTab, .minimizeFloat, .minimizeAllFloats:
                guard let b = t.blockID else { return false }
                let pc: PaneCommand = switch c {
                case .balanceSplits: .balance
                case .closeOtherPanes: .closeOthers
                case .moveToTab: .moveToTab
                case .moveToNewTab: .moveToNewTab
                case .minimizeFloat: .minimize
                case .minimizeAllFloats: .minimizeAll
                default: .moveTab
                }
                return PaneArrange.isAvailable(pc, target: PaneTarget(window: window, block: b, tabs: tabs), support: support)
            default: return true
            }
        }
        switch c {
        case .jumpToWaiting: return waitingCount > 0
        case .navigateBack: return history.back
        case .navigateForward: return history.forward
        case .nextSession, .previousSession:
            guard let t = target else { return false }
            return SessionNav.neighbor(servers, from: Selection(serverID: t.serverID, sessionID: t.sessionID, windowID: t.windowID),
                                       by: c == .nextSession ? 1 : -1) != nil
        case .renameSession, .closeSession: return target != nil && server != nil
        case .closeOtherTabs: return target != nil && server != nil && tabs.count > 1
        default: return true
        }
    }

    static func symbol(_ c: RexCommand) -> String {
        switch c {
        case .newTab: "plus.square"
        case .newSession: "plus.rectangle.on.rectangle"
        case .splitRight, .splitLeft: "rectangle.split.2x1"
        case .splitDown, .splitUp: "rectangle.split.1x2"
        case .nextSession, .previousSession: "rectangle.stack"
        case .renameSession: "pencil"
        case .closeSession, .closeOtherTabs: "xmark"
        case .addComputer: "plus"
        case .goToTab: "square.on.square"
        case .goTo(.sessions): "rectangle.stack"
        case .goTo: "magnifyingglass"
        case .closePane: "xmark.square"
        case .closeTab: "xmark"
        case .renameTab: "pencil"
        case .tabOverview: "square.on.square"
        case .toggleZoom: "arrow.up.left.and.arrow.down.right"
        case .find: "magnifyingglass"
        case .settings: "gearshape"
        case .toggleSidebar: "sidebar.left"
        case .jumpToWaiting: "bell"
        case .navigateBack: "chevron.backward"
        case .navigateForward: "chevron.forward"
        case .balanceSplits: "rectangle.split.3x1"
        case .closeOtherPanes: "xmark.square"
        case .moveToTab, .moveToNewTab: "rectangle.portrait.and.arrow.right"
        case .minimizeFloat, .minimizeAllFloats: "minus.square"
        case .fontBigger, .fontSmaller, .fontReset: "textformat.size"
        default: "command"
        }
    }

    /// The Mac's title (`pane.copy_mode.enter` as `Enter Copy Mode`); an action it doesn't list
    /// as `Copy Mode: Search`.
    static func copyModeTitle(_ action: String) -> String {
        if let t = MacPalette.copyModeTitles[action] { return t }
        let last = action.split(separator: ".").last.map(String.init) ?? ""
        if ["enter", "toggle", "copy_mode"].contains(last) || last.isEmpty { return "Copy Mode" }
        return "Copy Mode: " + LuaAction.title(last)
    }

    /// A binding's fixed arguments, short: `dir: api`. Nil when they don't read as text.
    static func argsSummary(_ args: JSONObject) -> String? {
        let parts = args.keys.sorted().compactMap { k -> String? in
            switch args[k] {
            case let s as String: "\(k): \(s)"
            case let n as NSNumber: "\(k): \(n)"
            default: nil
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}
