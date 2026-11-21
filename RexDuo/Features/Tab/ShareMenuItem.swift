import SwiftUI
import RexKit

/// "Share ▸" in the pane menu: plain text or with colors, the screen or the pane's whole output. Its own
/// view, so only it reads the server's capabilities and views: a change there redraws this row,
/// not the tab screen. All Output shows unless the pane's server is known to lack the two methods
/// it reads with; offline it stays and says it needs the connection.
struct ShareMenuItem: View {
    let server: ServerConnection
    let sessionID: String
    let block: String
    let action: (PaneShare.Scope, _ styled: Bool) -> Void

    var body: some View {
        let all = server.sharesAllOutput(session: sessionID, block: block)
        Menu {
            Section {
                Button("Screen") { action(.screen, false) }
                if all { Button("All Output") { action(.allOutput, false) } }
            }
            Section {
                Button("Screen with Colors") { action(.screen, true) }
                if all { Button("All Output with Colors") { action(.allOutput, true) } }
            }
        } label: {
            Label("Share", systemImage: "square.and.arrow.up")
        }
    }
}

extension ServerConnection {
    /// Whether a pane can share its whole output: its creator on its host isn't known to lack
    /// `format` or `blob_read`, and no read on this connection found one missing. Unknown counts
    /// as there: both methods exist from revision 13 and below.
    func sharesAllOutput(session: String, block: String) -> Bool {
        let b = views[session]?.windowContaining(block: block)?.block(block)
        let creator = b.map(\.creator).flatMap { $0.isEmpty ? nil : $0 } ?? Self.terminalCreator
        for (short, method) in [("format", OutputReader.format), ("blob_read", OutputReader.blobRead)] {
            if capabilities.method(short, creator: creator, host: b?.hostID) == .absent { return false }
            if capabilities.probe(method: method, host: b?.hostID) == false { return false }
        }
        return true
    }
}
