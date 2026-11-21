import Foundation
import GlanceModel
import RexKit
import Testing
@testable import RexDuo

/// The app's words (`Messages`) and the small rules that came with them: no server text, error
/// description or action id reaches the user, New Session shows what it made, Reconnect only
/// where it helps, and Close Tab asks before several panes close.
@MainActor
@Suite struct WordingTests {
    private static let raw = "SERVER-SAID: block 9f3e not in window w2 (rpc)"

    private func server(name: String = "Desk") throws -> (AppModel, ServerConnection) {
        let suite = "wording-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let model = AppModel(prefs: Prefs(defaults: defaults), connect: false)
        let s = ServerConnection(config: ServerConfig(name: name, url: "https://desk-rex.tail1234.ts.net"),
                                 prefs: model.prefs, notifier: model.notifier, deviceID: "a1b2c3d4")
        model.servers.append(s)
        return (model, s)
    }

    // MARK: Errors in words

    /// Whatever the server answered, the user reads what happened, worded by the app: never the
    /// server's message, its code or the error's description.
    @Test func noMessagePassesTheServersTextThrough() {
        let codes = ["client", "not_found", "session_not_found", "revision_too_low", "method_not_found", "not_supported",
                     "bad_request", "conflict", "internal", "too_large", ""]
        var errors: [Error] = codes.map { RexError(code: $0, message: Self.raw, status: 400) }
        errors.append(RexError.unsent(Self.raw))
        errors.append(RexError.local(Self.raw))
        errors.append(NSError(domain: NSURLErrorDomain, code: -1001, userInfo: [NSLocalizedDescriptionKey: Self.raw]))
        for error in errors {
            for text in [Messages.reason(error, computer: "Desk"), Messages.couldNot("close the tab", error, computer: "Desk")] {
                #expect(!text.contains(Self.raw), "\(text)")
                #expect(!text.contains("rpc") && !text.contains("SERVER"), "\(text)")
                if let e = error as? RexError, !e.code.isEmpty { #expect(!text.contains(e.code), "\(text)") }
                #expect(!text.localizedCaseInsensitiveContains("server"), "\(text)")
            }
        }
    }

    @Test func eachFailureHasItsWords() {
        func reason(_ e: Error) -> String { Messages.reason(e, computer: "desk") }
        #expect(reason(RexError.unsent("x")) == "Not sent: the connection to desk dropped. Try again when it's back.")
        #expect(reason(RexError.local("connection lost")) == "The connection to desk dropped.")
        #expect(reason(RexError(code: "not_found", message: "x")) == "It's gone.")
        #expect(reason(RexError(code: "method_not_found", message: "x")) == "Rex on desk is too old for this. Update Rex there.")
        #expect(reason(RexError(code: "conflict", message: "x")) == "Desk refused it.")
        #expect(Messages.couldNot("close the tab", RexError(code: "bad_request", message: "x"), computer: "Desk")
            == "Couldn't close the tab. Desk refused it.")
    }

    /// A server call's notice names the computer it went to.
    @Test func aServerCallsFailureNamesItsComputer() throws {
        let (_, s) = try server(name: "Studio")
        #expect(s.reason(RexError(code: "bad_request", message: Self.raw)) == "Studio refused it.")
        #expect(s.moveFailure(RexError(code: "internal", message: Self.raw)) == "Couldn't move the pane. Studio refused it.")
        #expect(s.moveFailure(RexError(code: "conflict", message: Self.raw)) == "That tab can't take another pane.")
    }

    // MARK: A pane's input and actions

    /// An action is named as the palette names it, never by its id; the stream's notices are
    /// worded by the app.
    @Test func streamNoticesNameActionsByTheirTitles() {
        let id = "com.superlogical.terminal.clear"
        let title: (String) -> String = { KeyActions.blockTitles[$0] ?? "the action" }
        let notices: [TerminalStream.Notice] = [
            .actionNotSent(action: id, title: nil), .actionLost(action: id, title: nil),
            .actionRefused(action: id, title: nil, code: "bad_request"),
        ]
        for n in notices {
            let text = Messages.stream(n, computer: "Desk", title: title)
            #expect(!text.contains(id), "\(text)")
            #expect(text.contains("Clear Terminal"), "\(text)")
        }
        #expect(Messages.stream(.actionRefused(action: id, title: nil, code: "not_found"), computer: "Desk", title: title)
            == "Couldn't run Clear Terminal. It's gone.")
        // A palette pick keeps the name it was picked by.
        #expect(Messages.stream(.actionNotSent(action: "dev_layout", title: "Dev Layout"), computer: "Desk", title: title)
            == "Didn't run Dev Layout. Not sent: the connection to Desk dropped. Try again when it's back.")
        #expect(Messages.stream(.inputLost, computer: "Desk", title: title) == Messages.sentUnknown)
        #expect(Messages.stream(.stillReconnecting, computer: "Desk", title: title) == Messages.stillReconnecting)
        #expect(Messages.stream(.paneChanged, computer: "Desk", title: title) == Messages.paneChanged)
    }

    /// The pane's own notices: an id the keymap doesn't know reads as "the action".
    @Test func aPanesNoticeNeverShowsAnActionID() {
        let control = RexControl(address: "", client: ClientInfo(name: "test", version: "0", label: "test"))
        let stream = TerminalStream(control: control, sessionID: "s", blockID: "b")
        // The server owns its keymap; the stream holds it weakly.
        let keymap = KeymapStore(control: control)
        stream.showsNotices(computer: "Desk", keymap: keymap)
        Notice.shared.dismiss()
        stream.onActionFailed?(.actionRefused(action: "com.superlogical.terminal.clear", title: nil, code: "bad_request"))
        #expect(Notice.shared.message == "Couldn't run Clear Terminal. Desk refused it.")
        stream.onActionFailed?(.actionRefused(action: "zz.unknown.thing", title: nil, code: "bad_request"))
        #expect(Notice.shared.message == "Couldn't run the action. Desk refused it.")
        Notice.shared.dismiss()
        withExtendedLifetime(keymap) {}
    }

    // MARK: New Session, Reconnect

    /// New Session from a sidebar row shows the new session, as the + menu and the popover do.
    @Test func newSessionOpensTheSessionItMade() throws {
        let (_, s) = try server()
        s.views = ["fresh": SessionView(["revision": 1, "session_id": "fresh", "label": "", "active_window_id": "w1",
                                         "windows": [["window_id": "w1", "label": "", "layers": []] as JSONObject]])]
        #expect(NewSession.opened(s, id: "fresh") == Selection(serverID: s.id, sessionID: "fresh", windowID: "w1"))
        #expect(NewSession.opened(s, id: nil) == nil, "nothing made")
        #expect(NewSession.opened(s, id: "unknown") == nil, "no view yet: nothing to show")
    }

    /// The + menu lists only computers that can make a session; with one, + makes it there.
    @Test func newSessionOffersOnlyConnectedComputers() throws {
        let (model, desk) = try server()
        let laptop = ServerConnection(config: ServerConfig(name: "Laptop", url: "https://laptop-rex.tail1234.ts.net"),
                                      prefs: model.prefs, notifier: model.notifier, deviceID: "a1b2c3d4")
        model.servers.append(laptop)
        desk.phase = .online
        laptop.phase = .offline(ConnectionProblem(kind: .notAnswering, detail: "test"))
        #expect(NewSession.targets(model.servers).map(\.id) == [desk.id])
        laptop.phase = .online
        #expect(NewSession.targets(model.servers).count == 2)
        desk.phase = .connecting
        laptop.phase = .idle
        #expect(NewSession.targets(model.servers).isEmpty)
    }

    /// Reconnect only on a computer that is down and not already trying again.
    @Test func reconnectOnlyWhereItHelps() throws {
        let (_, s) = try server()
        s.phase = .online
        #expect(!s.offersReconnect, "connected: it would only drop a working connection")
        s.phase = .connecting
        #expect(!s.offersReconnect)
        s.phase = .offline(ConnectionProblem(kind: .notAnswering, detail: "test"))
        #expect(s.offersReconnect)
        s.retrying = true
        #expect(!s.offersReconnect, "an attempt is running")
    }

    // MARK: Close Tab

    /// Close Tab asks when an agent would stop or when several panes would close.
    @Test func closeTabAsksBeforeSeveralPanesClose() {
        #expect(CloseTabAsk.decide(panes: 1, agent: false) == nil)
        #expect(CloseTabAsk.decide(panes: 1, agent: true) == CloseTabAsk(panes: 1, agent: true))
        #expect(CloseTabAsk.decide(panes: 2, agent: false) == CloseTabAsk(panes: 2, agent: false))
        #expect(CloseTabAsk(panes: 3, agent: false).message(computer: "Desk") == "Its 3 panes close, and their programs stop on Desk too.")
        #expect(CloseTabAsk(panes: 1, agent: true).message(computer: "Desk") == "The agent running there stops on Desk too.")
        #expect(CloseTabAsk(panes: 2, agent: true).message(computer: "Desk")
            == "Its 2 panes close, and the agent running there stops on Desk too.")
    }

    /// The sidebar's and the strip's Close Tab follow it: a tab with two panes asks.
    @Test func aSidebarCloseOfASplitTabAsks() throws {
        let (_, s) = try server()
        let dialogs = SidebarActions()
        let target = SidebarActions.Target(server: s, sessionID: "work", windowID: "split", label: "split")
        dialogs.closeTab(target, hasAgent: false, panes: 2)
        #expect(dialogs.closingTab?.windowID == "split")
        #expect(dialogs.closingTabAsk == CloseTabAsk(panes: 2, agent: false))
        dialogs.closingTab = nil
        dialogs.closeTab(target, hasAgent: false, panes: 1)
        #expect(dialogs.closingTab == nil, "one pane, no agent: closes at once")
    }

    // MARK: Words that are the same everywhere

    @Test func waitingReasonsAreOneSet() {
        #expect(["permission", "question", "auth", nil].map { WatchScreen.words(why: $0) }
            == ["Needs your permission", "Has a question", "Needs your password", "Waiting for you"])
    }

    @Test func noComputersReadsTheSameEverywhere() {
        #expect(Messages.noComputers == "No computers yet. Pair one in Settings.")
        #expect(GlanceDigest.unpairedText == "No computers yet")
        #expect(AgentBoard.make([]).headline == "No computers yet")
    }
}
