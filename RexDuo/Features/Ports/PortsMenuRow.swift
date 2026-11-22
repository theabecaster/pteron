import RexKit
import SwiftUI

/// The pane menu's ports row, last in its section: `localhost:5173` with the program under it
/// for one web port, `Ports ▸` for two or more, nothing for none: the ports the Ports list
/// shows, a port held for its probe or found no web page left out (`shownPorts`). Its own view,
/// so only it reads the pane's ports boxes: a port that opens or closes redraws this row, not
/// the tab screen. It shows only for a local pane on a server that lists ports and makes tunnels.
struct PortsMenuRow: View {
    let server: ServerConnection
    let sessionID: String
    let block: String
    let action: (PortEntry) -> Void

    var body: some View {
        let web = server.showsPorts(session: sessionID, block: block) ? server.shownPorts(block) : []
        if web.count == 1, let e = web.first {
            Button { action(e) } label: {
                Label(e.name, systemImage: "globe")
                if let p = e.process { Text(p) }
            }
        } else if web.count > 1 {
            Menu {
                ForEach(web, id: \.port) { e in
                    Button { action(e) } label: {
                        Text(e.name)
                        if let p = e.process { Text(p) }
                    }
                }
            } label: {
                Label("Ports", systemImage: "globe")
            }
        }
    }
}
