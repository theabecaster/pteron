import SwiftUI
import UIKit
import RexKit

/// One live terminal pane.
struct PaneView: View {
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

    @Environment(Prefs.self) private var prefs

    var body: some View {
        PaneHostView(server: server, sessionID: sessionID, blockID: blockID, active: active,
                     onFocus: onFocus, onSwipe: onSwipe, onCommand: onCommand)
    }
}

/// SwiftUI wrapper for the UIKit terminal host.
struct PaneHostView: UIViewRepresentable {
    let server: ServerConnection
    let sessionID: String
    let blockID: String
    let active: Bool
    let onFocus: () -> Void
    var onSwipe: ((Int) -> Void)?
    var onCommand: ((RexCommand) -> Void)?

    @Environment(\.colorScheme) private var scheme
    @Environment(Prefs.self) private var prefs
    @Environment(AppModel.self) private var model: AppModel?
    @Environment(TerminalHostPool.self) private var pool: TerminalHostPool?

    private var commandHandler: ((RexCommand) -> Void)? {
        if let onCommand { return onCommand }
        guard let model else { return nil }
        return { [weak model] in model?.perform($0) }
    }

    func makeUIView(context: Context) -> Container {
        let key = TerminalHostPool.Key(server: server.id, session: sessionID, block: blockID)
        // A fold or unfold rebuilt the layout: take over the pane's live host instead of starting over.
        if let pool, let host = pool.host(for: key) {
            let c = Container(host, key: key, pool: pool)
            pool.attach(c)
            apply(host)
            return c
        }
        let p = prefs
        let stream = TerminalStream(control: server.control, sessionID: sessionID, blockID: blockID)
        stream.onActionFailed = { Notice.shared.show($0) }
        let host = TerminalHost(stream: stream, sizing: p.sizing, fontSize: p.fontSize, theme: prefs.theme(for: scheme))
        host.keymap = server.keymap
        apply(host)
        let c = Container(host, key: key, pool: pool)
        if let pool {
            pool.add(host, for: key)
            pool.attach(c)
        } else {
            c.adopt()
        }
        return c
    }

    func updateUIView(_ c: Container, context: Context) {
        // A newer PaneView shows this host now; this one is on its way out.
        guard c.owns else { return }
        apply(c.host)
    }

    private func apply(_ host: TerminalHost) {
        let p = prefs
        let theme = prefs.theme(for: scheme)
        if host.theme != theme { host.applyTheme(theme) }
        host.setFontSize(p.fontSize)
        host.setSizing(p.sizing)
        host.onCommand = commandHandler
        host.isActive = active
        host.onFocus = onFocus
        host.onSwipe = onSwipe
    }

    static func dismantleUIView(_ c: Container, coordinator: ()) {
        if let pool = c.pool {
            pool.detach(c)
        } else {
            c.host.scheduleStop()
        }
    }

    /// Each PaneView gets its own container; the host moves between containers. SwiftUI may build a
    /// view and drop it again while it swaps layouts, and may tear an old container down after a new
    /// one took the host; neither may take the host from the container on screen.
    final class Container: UIView {
        let host: TerminalHost
        let key: TerminalHostPool.Key
        weak var pool: TerminalHostPool?

        init(_ host: TerminalHost, key: TerminalHostPool.Key, pool: TerminalHostPool?) {
            self.host = host
            self.key = key
            self.pool = pool
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError() }

        /// This container shows the host now.
        var owns: Bool { host.superview === self }

        func adopt() {
            guard !owns else { return }
            // UIKit takes the keyboard from a view it moves; the host takes it back where it lands.
            host.noteKeyboardBeforeMove()
            host.frame = bounds
            addSubview(host)
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { pool?.show(key) }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            if owns { host.frame = bounds }
        }
    }
}

/// The live terminal hosts, one per pane on screen. A fold or an unfold swaps the layout's view tree
/// (navigation stack, pages); the new `PaneView` takes the pane's host from here, so the stream, the
/// screen, the scroll position and the keyboard carry over instead of reconnecting. The newest
/// container shows the host; when it goes, the host moves back to the newest one left, and with none
/// left it lets go of its stream once it has been off screen for half a second
/// (`TerminalHost.scheduleStop`). Owned by `RootView`.
@MainActor
@Observable
final class TerminalHostPool {
    struct Key: Hashable {
        var server: UUID
        var session: String
        var block: String
    }

    private final class Weak {
        weak var c: PaneHostView.Container?
        init(_ c: PaneHostView.Container) { self.c = c }
    }

    @ObservationIgnored private var hosts: [Key: TerminalHost] = [:]
    @ObservationIgnored private var containers: [Key: [Weak]] = [:]

    func host(for key: Key) -> TerminalHost? { hosts[key] }

    func add(_ host: TerminalHost, for key: Key) {
        hosts[key] = host
        host.onStopped = { [weak self, weak host] in
            guard let self, let host, self.hosts[key] === host else { return }
            self.hosts[key] = nil
            self.containers[key] = nil
        }
    }

    @ObservationIgnored private var showing: Set<Key> = []
    @ObservationIgnored private var showAgain: Set<Key> = []

    /// A new container for the pane.
    func attach(_ c: PaneHostView.Container) {
        containers[c.key, default: []].removeAll { $0.c == nil || $0.c === c }
        containers[c.key, default: []].append(Weak(c))
        show(c.key)
    }

    /// A container went away. If it showed the host, the host goes back to one that is left.
    func detach(_ c: PaneHostView.Container) {
        containers[c.key]?.removeAll { $0.c == nil || $0.c === c }
        guard c.owns else { return }
        if Self.target(live(c.key)) != nil {
            show(c.key)
        } else {
            c.host.scheduleStop()
        }
    }

    private func live(_ key: Key) -> [PaneHostView.Container] { containers[key]?.compactMap(\.c) ?? [] }

    /// The container that shows the host: the newest one in a window, else the newest. SwiftUI
    /// builds containers it never puts on screen (to measure a transition, or for a layout it then
    /// drops) and doesn't always tear them down; one of those must not take the host from the
    /// container on screen, or the pane goes blank and loses the keyboard.
    static func target<C: UIView>(_ containers: [C]) -> C? {
        containers.last { $0.window != nil } ?? containers.last
    }

    /// Moves the pane's host to the container that should show it. Called for a new container and
    /// when one enters a window. Moving the host can make SwiftUI build more containers before the
    /// move returns; those wait for it to finish.
    func show(_ key: Key) {
        guard !showing.contains(key) else { showAgain.insert(key); return }
        showing.insert(key)
        defer { showing.remove(key) }
        repeat {
            showAgain.remove(key)
            Self.target(live(key))?.adopt()
        } while showAgain.contains(key)
    }
}
