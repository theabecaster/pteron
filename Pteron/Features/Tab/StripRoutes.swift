import Foundation
import RexKit

/// What tab mode's strip runs: every row of the session chip's popover, every action of a
/// chip's menu and its close button, the waiting pill and Change Session. They are the
/// sidebar's actions with no sidebar to hold them: the same server calls, and the same rename
/// alert and close confirmations (`SidebarActions`). The root shows the alert; the strip shows
/// each confirmation from the control that was tapped (`StripDialogs`). Each question holds
/// the ids it was asked about, so its answer closes those whatever moved meanwhile, and one
/// question is up at a time.
@MainActor
struct StripRoutes {
    let model: AppModel
    /// The rename alert and the close confirmations.
    let dialogs: SidebarActions
    /// Puts a tab on screen.
    let open: (Selection) -> Void

    // MARK: The session popover

    func run(_ action: SessionPopover.Action) {
        switch action {
        case .open(let sel):
            guard sel != model.selection else { return }
            Haptic.selection()
            open(sel)
        case .newSession(let id):
            guard let server = model.server(id) else { return }
            Haptic.tap()
            let open = open
            Task {
                if let sel = NewSession.opened(server, id: await server.createSession(label: nil)) { open(sel) }
            }
        case .reconnect(let id):
            model.server(id)?.reconnect()
        case .add(let host):
            NotAddedSection.add(host, model: model)
        case .renameSession(let id, let sid, _):
            guard !dialogs.asking, let server = model.server(id) else { return }
            // The alert starts from the session's own name, empty for one without.
            let label = server.sessions.first { $0.id == sid }?.label ?? ""
            dialogs.rename(.init(server: server, sessionID: sid, label: label), current: label)
        case .closeSession(let id, let sid, _):
            guard !dialogs.asking, let server = model.server(id) else { return }
            dialogs.closing = .init(server: server, sessionID: sid, label: server.sessions.first { $0.id == sid }?.label ?? "")
        case .goTo:
            model.perform(.goTo(.anything))
        case .agents:
            model.showAgents()
        case .ports(let id):
            model.showPorts(id)
        case .settings:
            model.showSettings = true
        }
    }

    /// The Change Session palette: the way to a session from a screen with no strip to tap.
    func changeSession() {
        model.perform(.goTo(.sessions))
    }

    /// The waiting pill: shows that agent's pane.
    func jump(_ item: Waiting.Item) {
        Haptic.selection()
        open(Waiting.prepare(model, item))
    }

    // MARK: A chip's menu

    /// `action` on tab `tab` of `session`: a row of its chip's menu, or its close button. A tab
    /// with an agent or several panes asks before it closes, as its sidebar row does; Close
    /// Other Tabs always asks. While a question is up, another asks nothing.
    func run(_ action: TabChip.Action, tab: String, session: String, server: ServerConnection) {
        let ids = server.orderedWindowIDs(session)
        guard let window = server.views[session]?.window(tab) else { return }
        let target = SidebarActions.Target(server: server, sessionID: session, windowID: tab, label: window.label)
        switch action {
        case .rename, .close, .closeOthers:
            guard !dialogs.asking else { return }
        case .moveLeft, .moveRight, .moveToSession:
            break
        }
        switch action {
        case .rename:
            dialogs.rename(target, current: window.label)
        case .close:
            if let ask = CloseTabAsk.decide(panes: window.allBlocks.count, agent: server.windowAgent(window) != nil) {
                dialogs.closingTabAsk = ask
                dialogs.closingTab = target
            } else {
                close(target)
            }
        case .closeOthers:
            let others = ids.filter { $0 != tab }
            guard !others.isEmpty else { return }
            let agent = others.contains { id in server.views[session]?.window(id).map { server.windowAgent($0) != nil } ?? false }
            dialogs.closingOthers = .init(target: target, tabs: others, agent: agent)
        case .moveLeft, .moveRight:
            guard server.capabilities.paneSupport.has(.moveTab),
                  let move = TabOrder.step(ids, moving: tab, by: action == .moveLeft ? -1 : 1) else {
                Haptic.bump()
                return
            }
            Haptic.selection()
            server.dragTab(session, tab, move)
        case .moveToSession(let dest):
            model.moveTab(server, session: session, window: tab, to: dest)
        }
    }

    /// Close Tab, answered: closes the tab the question was asked about, by its id, and clears
    /// the question. Returns that tab; nil with no question up.
    @discardableResult
    func confirmCloseTab() -> SidebarActions.Target? {
        guard let t = dialogs.closingTab else { return nil }
        dialogs.closingTab = nil
        close(t)
        return t
    }

    /// Closes the tab. When it is the tab on screen, the next one shows as soon as the server
    /// has closed it, as the title bar's Close Tab does (`AppModel.closedTab`).
    private func close(_ t: SidebarActions.Target) {
        guard let w = t.windowID else { return }
        let model = model, sel = Selection(serverID: t.server.id, sessionID: t.sessionID, windowID: w)
        Task {
            guard await t.server.closeWindow(t.sessionID, w) else { return }
            model.closedTab(sel)
        }
    }
}

extension SidebarActions {
    /// A rename or a close question is up.
    var asking: Bool {
        renaming != nil || closing != nil || closingTab != nil || closingOthers != nil
    }
}
