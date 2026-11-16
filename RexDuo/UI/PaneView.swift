import SwiftUI

/// One live terminal pane.
struct PaneView: View {
    let server: ServerConnection
    let sessionID: String
    let blockID: String
    let active: Bool
    let onFocus: () -> Void
    /// Horizontal swipe on the terminal: +1 = next pane, -1 = previous pane.
    var onSwipe: ((Int) -> Void)? = nil

    var body: some View {
        let engine = Prefs.shared.terminalEngine
        PaneHostView(server: server, sessionID: sessionID, blockID: blockID, active: active,
                     engine: engine, onFocus: onFocus, onSwipe: onSwipe)
            // An engine can't be swapped inside a live pane: a new engine is a new pane.
            .id(engine)
    }
}

/// SwiftUI wrapper for the UIKit terminal host.
private struct PaneHostView: UIViewRepresentable {
    let server: ServerConnection
    let sessionID: String
    let blockID: String
    let active: Bool
    let engine: TerminalEngineKind
    let onFocus: () -> Void
    var onSwipe: ((Int) -> Void)?

    @Environment(\.colorScheme) private var scheme

    func makeUIView(context: Context) -> TerminalHost {
        let p = Prefs.shared
        let stream = TerminalStream(control: server.control, sessionID: sessionID, blockID: blockID)
        let host = TerminalHost(stream: stream, sizing: p.sizing, fontSize: p.fontSize, theme: ThemeStore.current(scheme),
                                engine: engine)
        host.isActive = active
        host.onFocus = onFocus
        host.onSwipe = onSwipe
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
        host.onSwipe = onSwipe
    }

    static func dismantleUIView(_ host: TerminalHost, coordinator: ()) {
        host.stop()
    }
}
