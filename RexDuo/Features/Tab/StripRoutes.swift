import Foundation
import RexKit

/// What tab mode's strip runs: every row of the session chip's popover, every action of a
/// chip's menu, the waiting pill and Change Session. They are the sidebar's actions with no
/// sidebar to hold them: the same server calls, and the same rename alert and close
/// confirmations (`SidebarActions`, shown by the root).
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
            guard let server = model.server(id) else { return }
            // The alert starts from the session's own name, empty for one without.
            let label = server.sessions.first { $0.id == sid }?.label ?? ""
            dialogs.rename(.init(server: server, sessionID: sid, label: label), current: label)
        case .closeSession(let id, let sid, _):
            guard let server = model.server(id) else { return }
            dialogs.closing = .init(server: server, sessionID: sid, label: server.sessions.first { $0.id == sid }?.label ?? "")
        case .goTo:
            model.perform(.goTo(.anything))
        case .agents:
            model.showAgents()
        case .settings:
            model.showSettings = true
        case .useSidebar:
            model.prefs.navigation = .sidebar
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

    /// `action` on tab `tab` of `session`. A tab with an agent asks before it closes, as its
    /// sidebar row does; Close Other Tabs always asks.
    func run(_ action: TabChip.Action, tab: String, session: String, server: ServerConnection) {
        let ids = server.orderedWindowIDs(session)
        guard let window = server.views[session]?.window(tab) else { return }
        let target = SidebarActions.Target(server: server, sessionID: session, windowID: tab, label: window.label)
        switch action {
        case .rename:
            dialogs.rename(target, current: window.label)
        case .close:
            dialogs.closeTab(target, hasAgent: server.windowAgent(window) != nil, panes: window.allBlocks.count)
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
        }
    }
}
