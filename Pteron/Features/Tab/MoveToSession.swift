import SwiftUI

/// A session a tab can move to, as the tab menus list it.
struct SessionChoice: Identifiable, Hashable {
    var id: String
    /// The session's name; "session" for one without.
    var name: String

    /// The computer's other sessions, in sidebar order: none where it can't move tabs.
    @MainActor
    static func destinations(_ server: ServerConnection, from sid: String) -> [SessionChoice] {
        server.moveDestinations(from: sid).map { SessionChoice(id: $0.id, name: $0.label.isEmpty ? "session" : $0.label) }
    }
}

/// Move to Session in a tab's menu: a submenu of the computer's other sessions, in sidebar order
/// (docs/sidebar.md, Move to Session).
struct MoveToSessionMenu: View {
    nonisolated static let title = "Move to Session"
    nonisolated static let symbol = "rectangle.portrait.and.arrow.right"

    let choices: [SessionChoice]
    let pick: (String) -> Void

    var body: some View {
        if !choices.isEmpty {
            Menu {
                ForEach(choices) { c in
                    Button(c.name) { pick(c.id) }
                }
            } label: {
                Label(Self.title, systemImage: Self.symbol)
            }
        }
    }
}

/// The sidebar tab row's Move to Session. Its own view, so the session list it reads redraws
/// this menu and not the row.
struct TabRowMoveMenu: View {
    let server: ServerConnection
    let sessionID: String
    let windowID: String
    @Environment(AppModel.self) private var model

    var body: some View {
        MoveToSessionMenu(choices: SessionChoice.destinations(server, from: sessionID)) { dest in
            model.moveTab(server, session: sessionID, window: windowID, to: dest)
        }
    }
}
