import SwiftUI

/// SwiftUI wrapper for one live terminal pane.
struct PaneView: UIViewRepresentable {
    let server: ServerConnection
    let sessionID: String
    let blockID: String
    let active: Bool
    let onFocus: () -> Void
    /// Horizontal swipe on the terminal: +1 = next pane, -1 = previous pane.
    var onSwipe: ((Int) -> Void)? = nil
    /// App-level commands from this pane (hardware keyboard shortcuts, two-finger tap).
    /// Defaults to the environment's `AppModel.perform(_:)`.
    var onCommand: ((RexCommand) -> Void)? = nil

    @Environment(\.colorScheme) private var scheme
    @Environment(AppModel.self) private var model: AppModel?

    private var commandHandler: ((RexCommand) -> Void)? {
        if let onCommand { return onCommand }
        guard let model else { return nil }
        return { [weak model] in model?.perform($0) }
    }

    func makeUIView(context: Context) -> TerminalHost {
        let p = Prefs.shared
        let stream = TerminalStream(control: server.control, sessionID: sessionID, blockID: blockID)
        let host = TerminalHost(stream: stream, sizing: p.sizing, fontSize: p.fontSize, theme: ThemeStore.current(scheme))
        host.keymap = server.keymap
        host.onCommand = commandHandler
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
        host.onCommand = commandHandler
        host.isActive = active
        host.onFocus = onFocus
        host.onSwipe = onSwipe
    }

    static func dismantleUIView(_ host: TerminalHost, coordinator: ()) {
        host.stop()
    }
}
