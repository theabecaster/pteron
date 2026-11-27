import Foundation

/// The Rex Mac app's command palette: its groups and its order, as Rex's docs list them
/// ("Mac Actions"), with the app's own commands beside their kin. The commands palette lists its
/// rows by group in this order, and each group in this order (`GoToCommands`).
///
/// Every Mac action is here, those the phone doesn't run too, so the order of the ones it runs
/// never depends on which they are. The app's own: Show All Tabs after Go to Tab, Clear and Reset
/// Terminal at the end of Pane (Rex lists them under Pane as the terminal's actions), Jump to
/// Waiting after the agents' toggle.
enum MacPalette {
    static let groups: [(category: String, actions: [String])] = [
        ("Window", ["client.window.new", "client.window.close", "client.window.fullscreen.toggle", "client.close"]),
        ("App", ["client.palette.toggle", "client.settings", "client.diagnostics", "client.onboarding",
                 "client.permissions", "client.visibility.toggle", "client.version.copy", "client.debug.copy",
                 "client.pair_device", "client.update.accept", "client.update.accept_when_idle", "client.update.check",
                 "client.update.status", "client.update.install", "client.update.set_automation",
                 "client.update.set_channel", "client.notice.dismiss", "client.shortcuts.edit", "client.agents.setup",
                 "client.server.restart"]),
        ("Session", ["session.new", "session.new.on_host", "session.switch", "session.select", "session.next",
                     "session.previous", "session.rename", "session.close", "session.undo_close", "session.refresh",
                     "session.collapse", "session.expand", "session.collapse_others"]),
        ("Host", ["client.host.switch", "client.host.add", "client.host.remove", "client.host.disconnect",
                  "client.host.connect", "client.host.forward_port"]),
        ("Tab", ["client.tab.new", "client.tab.close", "client.tab.close_others", "client.tab.rename", "client.tab.next",
                 "client.tab.previous", "client.tab.goto", "client.tab.overview", "client.tab.move",
                 "client.tab.move.backward", "client.tab.move.forward", "client.tab.move_to_session",
                 "client.tab.move_to_new_window",
                 "client.tab.mute", "client.tab.unread"]),
        ("Pane", ["pane.split", "pane.split.left", "pane.split.right", "pane.split.up", "pane.split.down",
                  "pane.split.auto", "pane.focus", "pane.focus.left", "pane.focus.right", "pane.focus.up",
                  "pane.focus.down", "pane.focus_next", "pane.focus_previous", "client.navigate.back",
                  "client.navigate.forward", "pane.move", "pane.move.left", "pane.move.right", "pane.move.up",
                  "pane.move.down", "pane.float", "pane.new_floating", "pane.minimize_floating",
                  "pane.minimize_all_floating", "pane.zoom", "pane.close", "pane.close_others", "pane.balance",
                  "pane.resize", "pane.move_to_new_tab", "pane.move_to_tab", "pane.go_to_directory", "pane.go_to",
                  "pane.view_activity", "pane.insert_path", "pane.insert_photo", "pane.insert_file", "pane.copy_id",
                  "pane.rename", "pane.paste", "pane.copy", "pane.select_all", "pane.copy_mode.enter",
                  "pane.copy_mode.exit", "pane.copy_mode.move", "pane.copy_mode.select", "pane.copy_mode.swap_ends",
                  "pane.copy_mode.yank", "pane.copy_mode.copy_to_line_end", "pane.copy_mode.search",
                  "pane.copy_mode.search_again", "pane.copy_mode.find", "pane.copy_mode.find_again",
                  "pane.copy_mode.count", "pane.send_key", "client.key.forward", "client.prompt.previous",
                  "client.prompt.next", "client.scroll.page_up", "client.scroll.page_down", "client.quick_look",
                  "com.superlogical.terminal.clear", "com.superlogical.terminal.reset"]),
        ("Keys", ["client.mode.enter", "client.mode.exit", "client.mode.exit_all"]),
        ("Find", ["client.find.open", "client.find.next", "client.find.previous"]),
        ("View", ["client.font.increase", "client.font.decrease", "client.font.reset", "client.sidebar.toggle",
                  "client.sidebar.activity.toggle", "client.agents.jump_to_waiting",
                  "client.sidebar.activity.by_session", "client.sidebar.activity.by_priority",
                  "client.sidebar.filter.focus", "client.tab_style.toggle", "client.toolbar.reveal",
                  "client.pane_header.reveal", "client.theme.change", "client.theme.import",
                  "client.appearance.switch_mode", "client.config.copy_path", "client.config.reload"]),
    ]

    /// An action's place in the palette, from 0; nil for one the Mac doesn't list.
    static func rank(_ action: String) -> Int? { ranks[action] }

    /// The group the Mac lists an action in.
    static func category(_ action: String) -> String? { categories[action] }

    private static let ranks: [String: Int] = {
        var r: [String: Int] = [:]
        for name in groups.flatMap(\.actions) where r[name] == nil { r[name] = r.count }
        return r
    }()

    private static let categories: [String: String] = {
        var c: [String: String] = [:]
        for g in groups { for a in g.actions { c[a] = g.category } }
        return c
    }()

    /// The Mac's titles of copy mode's actions, which run only there.
    static let copyModeTitles: [String: String] = [
        "pane.copy_mode.enter": "Enter Copy Mode",
        "pane.copy_mode.exit": "Exit Copy Mode",
        "pane.copy_mode.move": "Move Copy Mode Cursor",
        "pane.copy_mode.select": "Select in Copy Mode",
        "pane.copy_mode.swap_ends": "Swap Copy Mode Selection Ends",
        "pane.copy_mode.yank": "Yank Copy Mode Selection",
        "pane.copy_mode.copy_to_line_end": "Yank to End of Line in Copy Mode",
        "pane.copy_mode.search": "Search in Copy Mode",
        "pane.copy_mode.search_again": "Repeat Copy Mode Search",
        "pane.copy_mode.find": "Find Character in Copy Mode",
        "pane.copy_mode.find_again": "Repeat Copy Mode Character Find",
        "pane.copy_mode.count": "Type Copy Mode Count",
    ]
}
