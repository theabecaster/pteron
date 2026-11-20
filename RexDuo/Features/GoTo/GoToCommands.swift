import Foundation
import RexKit

/// The palette's command rows: the app's own commands that apply now, the server's Lua actions,
/// the target pane's block actions, and Mac-only copy mode, shown dimmed.
///
/// A command row shows only where its menu item or key would work: pane and tab commands need a
/// target, and the Arrange commands ask the same `PaneArrange.isAvailable` the menu asks.
@MainActor
enum GoToCommands {
    /// App actions that never get a row: the palette's own, duplicates of another row
    /// (`client.close` is Close Pane, the directional focus moves are next and previous), and
    /// find's steps, which do nothing with find closed.
    static let excluded: Set<String> = [
        "pane.go_to", "session.switch", "client.palette.toggle",
        "client.close", "pane.focus.left", "pane.focus.right", "pane.focus.up", "pane.focus.down",
        "client.find.next", "client.find.previous",
    ]

    static let destructive: Set<String> = [
        "pane.close", "client.tab.close", "com.superlogical.terminal.clear", "com.superlogical.terminal.reset",
    ]

    static let copyModeNote = "Copy mode is only on the Mac."
    static let argumentsNote = "Needs arguments the phone can't fill in."

    /// The key of an app command's row.
    static func appKey(_ action: String) -> String { "app:" + action }

    static func add(_ servers: [ServerConnection], target: GoToTarget?, waitingCount: Int, into copy: inout GoToSource.Copy) {
        let targetServer = target.flatMap { t in servers.first { $0.id == t.serverID } }
        let server = targetServer ?? servers.first { $0.phase == .online } ?? servers.first
        let keymap = server?.keymap
        let support = server?.capabilities.paneSupport ?? .none
        let view = target.flatMap { t in targetServer?.views[t.sessionID] }
        let window = target.flatMap { view?.window($0.windowID) }
        let block = target?.blockID.flatMap { window?.block($0) }
        var order = 100_000
        var commands: [RexCommand] = []

        func add(_ item: GoToItem, _ run: GoToRun) {
            copy.items.append(item)
            copy.runs[item.id] = run
        }

        // The app's own.
        for info in KeyActions.all where !excluded.contains(info.name) {
            guard case .command(let c)? = AppAction.resolve(info.name, nil, panes: support), !commands.contains(c) else { continue }
            guard applies(c, target: target, server: targetServer, window: window, block: block, tabs: view?.windows ?? [],
                          support: support, waitingCount: waitingCount) else { continue }
            commands.append(c)
            order += 1
            add(GoToItem(id: .command(appKey(info.name)), kind: .command, title: info.title, subtitle: info.category,
                         order: order, destructive: destructive.contains(info.name), symbol: symbol(c),
                         keyLabel: KeyLabel.for(action: info.name, in: keymap), category: info.category),
                .command(c))
        }

        let several = servers.count > 1
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
                order += 1
                add(GoToItem(id: .command("block:" + name), kind: .command, title: title, subtitle: "Pane", order: order,
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
                order += 1
                add(GoToItem(id: .command("copy:" + b.action), kind: .command, title: copyModeTitle(b.action),
                             subtitle: copyModeNote, order: order, dimmed: copyModeNote, symbol: "text.cursor",
                             category: "Pane"),
                    .none)
            }
        }
    }

    /// Whether an app command applies now, as its menu item would show.
    static func applies(_ c: RexCommand, target: GoToTarget?, server: ServerConnection?, window: WindowInfo?,
                        block: BlockInfo?, tabs: [WindowInfo], support: PaneSupport, waitingCount: Int) -> Bool {
        if c.isWindowCommand {
            guard let t = target, let server, let window else { return false }
            switch c {
            case .toggleZoom: return t.canZoom
            case .nextTab: return TabNav.neighbor(server, t.sessionID, t.windowID, by: 1) != nil
            case .previousTab: return TabNav.neighbor(server, t.sessionID, t.windowID, by: -1) != nil
            case .nextPane, .previousPane: return window.orderedBlockIDs.count > 1
            case .find: return block?.isTerminal == true
            case .closePane, .splitRight, .splitDown, .clear: return block != nil
            case .balanceSplits, .closeOtherPanes, .moveToTab, .moveToNewTab, .moveTab:
                guard let b = t.blockID else { return false }
                let pc: PaneCommand = switch c {
                case .balanceSplits: .balance
                case .closeOtherPanes: .closeOthers
                case .moveToTab: .moveToTab
                case .moveToNewTab: .moveToNewTab
                default: .moveTab
                }
                return PaneArrange.isAvailable(pc, target: PaneTarget(window: window, block: b, tabs: tabs), support: support)
            case .goTo: return false
            default: return true
            }
        }
        switch c {
        case .jumpToWaiting: return waitingCount > 0
        default: return true
        }
    }

    static func symbol(_ c: RexCommand) -> String {
        switch c {
        case .newTab: "plus.square"
        case .newSession: "plus.rectangle.on.rectangle"
        case .splitRight: "rectangle.split.2x1"
        case .splitDown: "rectangle.split.1x2"
        case .closePane: "xmark.square"
        case .closeTab: "xmark"
        case .renameTab: "pencil"
        case .tabOverview: "square.on.square"
        case .toggleZoom: "arrow.up.left.and.arrow.down.right"
        case .find: "magnifyingglass"
        case .settings: "gearshape"
        case .toggleSidebar: "sidebar.left"
        case .jumpToWaiting: "bell"
        case .balanceSplits: "rectangle.split.3x1"
        case .closeOtherPanes: "xmark.square"
        case .moveToTab, .moveToNewTab: "rectangle.portrait.and.arrow.right"
        case .fontBigger, .fontSmaller, .fontReset: "textformat.size"
        default: "command"
        }
    }

    /// `pane.copy_mode.enter` as `Copy Mode`, `pane.copy_mode.search` as `Copy Mode: Search`.
    static func copyModeTitle(_ action: String) -> String {
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
