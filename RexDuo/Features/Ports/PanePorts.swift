import RexKit
import UIKit

/// One pane's ports: it follows them while the pane is on screen, routes the pane's tapped
/// links, and opens a port's page in the browser (docs/terminal.md, Ports).
///
/// A tapped link to the computer's loopback (`localhost`, `127.0.0.1`, `[::1]`, `0.0.0.0`, `[::]`) on a
/// local pane of a server that makes tunnels opens through Rex: at once when a program in the
/// pane listens on that port, else after one question. Debugger ports never open. Offline, a
/// notice says so; such a link never goes to Safari, where it would reach the phone itself.
/// A link to a private network address (`http://10.0.0.246:3000`) opens through Rex too, but
/// only when a program in the pane listens on that port: then it is the pane's own computer.
/// Every other link opens as before, in Safari. Whatever the user tapped, a link that can't
/// open says why in a notice; none fails silently.
@MainActor
final class PanePorts {
    let server: ServerConnection
    let sessionID: String
    let blockID: String
    weak var view: UIView?
    /// Opens a link that isn't the router's, and says whether it opened. Tests put their own here.
    var openElsewhere: (URL, @escaping @MainActor @Sendable (Bool) -> Void) -> Void = { url, done in
        UIApplication.shared.open(url, options: [:], completionHandler: done)
    }
    /// Says why a page didn't open. `Notice` by default; tests put their own here.
    var notify: (String) -> Void = { Notice.shared.show($0, style: .neutral) }
    /// Asks before an unlisted port opens; true to open. Nil: an alert over the pane.
    var ask: ((String, @escaping @MainActor (Bool) -> Void) -> Void)?
    /// Opens the page, once the forward listens. Tests put their own here.
    var present: ((URL) -> Void)?
    /// An address typed into the open browser's address line (`PortActions.go`).
    var typed: (@MainActor (String, PreviewBrowser) -> Void)?
    private var watching = false

    init(server: ServerConnection, sessionID: String, blockID: String) {
        self.server = server
        self.sessionID = sessionID
        self.blockID = blockID
    }

    // MARK: On screen

    func watch() {
        guard !watching else { return }
        watching = true
        server.watchPorts(session: sessionID, block: blockID)
    }

    func unwatch() {
        guard watching else { return }
        watching = false
        server.unwatchPorts(blockID)
    }

    // MARK: Links

    /// What a tapped link does. `asked`: the user confirmed it already (`LinkOpenPolicy`), so
    /// it isn't asked about again.
    enum Route: Equatable {
        case elsewhere
        case refuse
        case offline
        case open(LocalhostLink)
        case ask(LocalhostLink)
    }

    func route(_ url: URL, asked: Bool) -> Route {
        if let lan = LocalhostLink(lan: url) { return route(lan: lan) }
        guard let link = LocalhostLink(url), server.tunnelsAvailable,
              let b = server.blockInfo(session: sessionID, block: blockID), b.isTerminal, server.isLocal(b) else { return .elsewhere }
        if PortRules.debuggerPorts.contains(link.port) { return .refuse }
        guard server.phase == .online, server.control.state == .connected else { return .offline }
        if let e = server.ports.value(blockID)?.entry(link.port) {
            var l = link
            l.dialHost = e.dialHost
            return .open(l)
        }
        return asked ? .open(link) : .ask(link)
    }

    /// A private network address is the pane's own computer only when the pane listens on that
    /// port; then it opens as a listed localhost port does, dialed at that address. Anything
    /// else (another machine's address, an unknown port, no port list, offline) goes to Safari,
    /// which reaches it when the phone is on that network.
    private func route(lan link: LocalhostLink) -> Route {
        guard server.tunnelsAvailable, server.phase == .online, server.control.state == .connected,
              let b = server.blockInfo(session: sessionID, block: blockID), b.isTerminal, server.isLocal(b),
              server.ports.value(blockID)?.entry(link.port) != nil else { return .elsewhere }
        if PortRules.debuggerPorts.contains(link.port) { return .refuse }
        return .open(link)
    }

    func open(_ url: URL, asked: Bool) {
        switch route(url, asked: asked) {
        case .elsewhere:
            let name = url.host ?? "this link"
            openElsewhere(url) { [weak self] opened in
                if !opened { self?.notify("Couldn't open \(name).") }
            }
        case .refuse:
            notify("Debugger ports don't open on this iPhone.")
        case .offline:
            notify("Couldn't open \(LocalhostLink(url)?.name ?? "this page"). \(Messages.offline(server.config.name))")
        case .open(let link):
            browse(link)
        case .ask(let link):
            let question = "Open \(link.name) from \(server.config.name)?"
            let answer: @MainActor (Bool) -> Void = { [weak self] yes in if yes { self?.browse(link) } }
            if let ask {
                ask(question, answer)
            } else if let view {
                TerminalPrompt.ask(over: view, title: question, message: "Nothing in this pane listens on that port right now.",
                                   confirm: "Open", answer: answer)
            } else {
                notify("Couldn't open \(link.name). \(Messages.paneClosed)")
            }
        }
    }

    // MARK: Menu

    /// The pane menu's row: the port's page over http.
    func open(_ entry: PortEntry) {
        guard server.phase == .online else {
            notify("Couldn't open \(entry.name). \(Messages.offline(server.config.name))")
            return
        }
        browse(LocalhostLink(port: entry.port, dialHost: entry.dialHost))
    }

    /// A port someone named by typing its address: the page opens at the path typed, and shows
    /// the address as typed.
    func open(_ entry: PortEntry, as address: PortAddress) {
        guard server.phase == .online else {
            notify("\(server.config.name) is offline, so \(address.shown) can't open.")
            return
        }
        var link = LocalhostLink(port: entry.port, dialHost: entry.dialHost)
        link.scheme = address.scheme
        link.rest = address.rest
        link.shown = address.shown
        browse(link)
    }

    // MARK: Browser

    private func browse(_ link: LocalhostLink) {
        guard let forward = server.forward else {
            return notify("Couldn't open \(link.name). Try again in a moment.")
        }
        let target = PortForward.Target(sessionID: sessionID, port: link.port, dialHost: link.dialHost)
        Task {
            guard let local = try? await forward.open(target, on: server), let url = link.url(localPort: local) else {
                notify("Couldn't open \(link.name) on this iPhone. Try again in a moment.")
                return
            }
            #if DEBUG
            PortsTest.opened = url  // `-portsTest` fetches through it
            #endif
            if let present { return present(url) }
            let opened = forward.forward
            // The chrome names the address as the user knows it, never the phone's own listener.
            let page = PreviewPage(load: url, shown: link.shown, scheme: link.scheme,
                                   source: PortActions.source(server.id, port: link.port))
            guard PreviewBrowser.present(page, over: view, onAddress: typed, onClose: { forward.close(opened) }) else {
                forward.close(opened)
                notify("Couldn't open \(link.name): its pane is no longer on screen. Show the pane, then try again.")
                return
            }
        }
    }
}
