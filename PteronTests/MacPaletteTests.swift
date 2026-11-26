import Foundation
import Testing
import RexKit
@testable import Pteron

/// The Rex Mac app's palette as the app declares it: the order, the groups, the names, the
/// default keys, and what the new actions do.
@MainActor
struct MacPaletteTests {
    @Test func theAppsActionsAreInTheMacsOrderAndGroups() {
        let ranks = KeyActions.all.map { MacPalette.rank($0.name) }
        #expect(!ranks.contains(nil), "every declared action has the Mac's place")
        let known = ranks.compactMap { $0 }
        #expect(known == known.sorted())
        for info in KeyActions.all {
            #expect(info.category == MacPalette.category(info.name), "\(info.name)")
        }
    }

    @Test func titlesAreTheMacsWhereTheWordingRulesAllow() {
        let mac: [String: String] = [
            "pane.minimize_all_floating": "Minimize All Floating Windows",
            "pane.paste": "Paste into Pane",
            "pane.copy": "Copy from Pane",
            "pane.select_all": "Select All in Pane",
            "pane.split.left": "Split Pane Left",
            "pane.split.up": "Split Pane Up",
            "session.next": "Next Session",
            "session.previous": "Previous Session",
            "session.close": "Close Session",
            "client.tab.close_others": "Close Other Tabs",
            "pane.go_to_directory": "Go to Directory…",
        ]
        for (name, title) in mac { #expect(KeyActions.byName[name]?.title == title, "\(name)") }
        // The app's wording: "…" where a question follows, Show/Hide, Rex, Computer.
        #expect(KeyActions.byName["session.rename"]?.title == "Rename Session…")
        #expect(KeyActions.byName["client.sidebar.toggle"]?.title == "Show/Hide Sidebar")
        #expect(KeyActions.byName["client.key.forward"]?.title == "Send Key to Rex")
        #expect(KeyActions.byName["client.host.add"]?.title == "Add Computer…")
    }

    @Test func theDefaultKeysAreTheMacs() {
        func keys(_ action: String) -> [String] {
            KeyDefaults.layer.filter { $0.1 == action && $0.2 == nil }.map(\.0)
        }
        #expect(keys("session.new") == ["cmd+n"])
        #expect(!KeyDefaults.layer.contains { $0.0 == "shift+cmd+n" }, "the Mac's New Window: none here")
        #expect(keys("pane.split.left") == ["shift+cmd+left"])
        #expect(keys("pane.split.up") == ["shift+cmd+up"])
        #expect(keys("client.tab.move.backward") == ["ctrl+shift+pageup"])
        #expect(keys("client.tab.move.forward") == ["ctrl+shift+pagedown"])
        #expect(keys("pane.minimize_floating") == ["alt+cmd+m"])
        #expect(keys("pane.minimize_all_floating") == ["alt+shift+cmd+enter"])
        #expect(keys("pane.insert_path") == ["ctrl+cmd+i"])
        #expect(keys("client.find.previous") == ["shift+cmd+g"], "⇧⌘G stays Find Previous")
    }

    @Test func theNewActionsResolve() {
        func command(_ name: String, _ args: JSONObject? = nil) -> RexCommand? {
            if case .command(let c)? = AppAction.resolve(name, args) { return c }
            return nil
        }
        #expect(command("pane.split.left") == .splitLeft)
        #expect(command("pane.split.up") == .splitUp)
        #expect(command("pane.split", ["direction": "left"]) == .splitLeft)
        #expect(command("pane.split", ["direction": "up"]) == .splitUp)
        #expect(command("session.next") == .nextSession)
        #expect(command("session.previous") == .previousSession)
        #expect(command("session.rename") == .renameSession)
        #expect(command("session.close") == .closeSession)
        #expect(command("client.tab.close_others") == .closeOtherTabs)
        #expect(command("client.host.add") == .addComputer)
        // The session ones and Add Computer run app-wide; the splits on the tab on screen.
        #expect(!RexCommand.nextSession.isWindowCommand && !RexCommand.closeOtherTabs.isWindowCommand)
        #expect(RexCommand.splitLeft.isWindowCommand)
    }

    @Test func aSentKeyWithoutANameReadsAsItsKey() {
        let b = KeyBinding(chord: KeyChord(spelling: "delete")!, action: "pane.send_key", args: ["key": "ctrl+d"])
        #expect(KeyActions.title(b) == "Send ⌃D")
        let known = KeyBinding(chord: KeyChord(spelling: "cmd+backspace")!, action: "pane.send_key", args: ["key": "ctrl+u"])
        #expect(KeyActions.title(known) == "Delete to Line Start")
    }

    @Test func copyModeRowsUseTheMacsTitles() {
        #expect(GoToCommands.copyModeTitle("pane.copy_mode.enter") == "Enter Copy Mode")
        #expect(GoToCommands.copyModeTitle("pane.copy_mode.yank") == "Yank Copy Mode Selection")
        #expect(GoToCommands.copyModeTitle("pane.copy_mode.later") == "Copy Mode: Later")
    }

    @Test func paneKeyActionsRoundTrip() {
        let all: [PaneKeyAction] = [.splitAuto, .copy, .paste, .selectAll, .pageUp, .pageDown, .promptPrevious, .promptNext,
                                    .sendKey(KeyChord(spelling: "ctrl+u")!)]
        for p in all { #expect(PaneKeyAction(p.action) == p) }
        #expect(PaneKeyAction(.forwardKey) == nil)
        #expect(PaneKeyAction(.command(.newTab)) == nil)
    }

    @Test func sessionStepsStopAtTheEnds() {
        let a = UUID(), b = UUID()
        let order = [SessionNav.Place(serverID: a, sessionID: "1"), .init(serverID: a, sessionID: "2"),
                     .init(serverID: b, sessionID: "1")]
        #expect(SessionNav.step(order, from: order[1], by: 1) == order[2])
        #expect(SessionNav.step(order, from: order[1], by: -1) == order[0])
        #expect(SessionNav.step(order, from: order[2], by: 1) == nil)
        #expect(SessionNav.step(order, from: order[0], by: -1) == nil)
        #expect(SessionNav.step(order, from: .init(serverID: b, sessionID: "9"), by: 1) == nil)
    }
}
