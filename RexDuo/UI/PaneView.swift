import SwiftUI

/// SwiftUI wrapper for one live terminal pane.
struct PaneView: UIViewRepresentable {
    let server: ServerConnection
    let sessionID: String
    let blockID: String
    let active: Bool
    let onFocus: () -> Void

    @Environment(\.colorScheme) private var scheme

    func makeUIView(context: Context) -> TerminalHost {
        let p = Prefs.shared
        let stream = TerminalStream(control: server.control, sessionID: sessionID, blockID: blockID)
        let host = TerminalHost(stream: stream, sizing: p.sizing, fontSize: p.fontSize, theme: ThemeStore.current(scheme))
        host.isActive = active
        host.onFocus = onFocus
        return host
    }

    func updateUIView(_ host: TerminalHost, context: Context) {
        let p = Prefs.shared
        let theme = ThemeStore.current(scheme)
        if host.theme != theme { host.applyTheme(theme) }
        host.setFontSize(p.fontSize)
        host.setSizing(p.sizing)
        host.isActive = active
        host.onFocus = onFocus
    }

    static func dismantleUIView(_ host: TerminalHost, coordinator: ()) {
        host.stop()
    }
}
