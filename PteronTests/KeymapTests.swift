import Testing
import RexKit
@testable import Pteron

struct KeyChordTests {
    @Test(arguments: [
        ("cmd+d", "cmd+d"),
        ("shift+cmd+d", "shift+cmd+d"),
        ("Cmd+Shift+D", "shift+cmd+d"),
        ("command+return", "cmd+enter"),
        ("ctrl+esc", "ctrl+escape"),
        ("opt+PgUp", "alt+pageup"),
        ("cmd+[Digit1]", "cmd+[Digit1]"),
        ("ctrl+shift+tab", "shift+ctrl+tab"),
        ("cmd++", "cmd++"),
    ])
    func parsesAndRespells(input: String, spelling: String) throws {
        let c = try #require(KeyChord(spelling: input))
        #expect(c.spelling == spelling)
    }

    @Test(arguments: ["", "  ", "hyper+k", "cmd+"])
    func rejectsBadSpellings(input: String) {
        #expect(KeyChord(spelling: input) == nil)
    }

    @Test func physicalKeysKeepTheirCase() throws {
        let c = try #require(KeyChord(spelling: "cmd+[KeyA]"))
        #expect(c.isPhysical)
        #expect(c.key == "[KeyA]")
    }
}

@MainActor
struct AppActionTests {
    @Test func tabAndPaneActions() {
        #expect(AppAction.resolve("client.tab.new", nil).isCommand(.newTab))
        #expect(AppAction.resolve("client.tab.goto", ["index": 3]).isCommand(.goToTab(3)))
        #expect(AppAction.resolve("pane.split", ["direction": "down"]).isCommand(.splitDown))
        #expect(AppAction.resolve("pane.focus", ["direction": "left"]).isCommand(.previousPane))
    }

    @Test func unsupportedClientActionsFallThrough() {
        // Rex's own client actions the app doesn't have; the key goes to the next binding or the terminal.
        #expect(AppAction.resolve("client.find", nil) == nil)
        #expect(AppAction.resolve("pane.split", ["direction": "left"]) == nil)
        #expect(AppAction.resolve("client.tab.goto", nil) == nil)
    }

    @Test func otherActionsRunOnTheServer() {
        guard case .server(let name, _)? = AppAction.resolve("com.superlogical.terminal.clear", nil) else {
            Issue.record("expected a server action")
            return
        }
        #expect(name == "com.superlogical.terminal.clear")
    }

    @Test func sendKeyParsesTheChord() {
        guard case .sendKey(let c)? = AppAction.resolve("pane.send_key", ["key": "ctrl+u"]) else {
            Issue.record("expected sendKey")
            return
        }
        #expect(c.spelling == "ctrl+u")
    }

    @Test func everyDefaultBindingParsesAndResolves() {
        #expect(KeyDefaults.resolved.count == KeyDefaults.layer.count)
        for b in KeyDefaults.resolved {
            #expect(AppAction.resolve(b.action, b.args) != nil, "\(b.chord.spelling) → \(b.action)")
        }
    }
}

private extension Optional where Wrapped == AppAction {
    func isCommand(_ c: RexCommand) -> Bool {
        if case .command(let x)? = self { return x == c }
        return false
    }
}
