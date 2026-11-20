import RexKit
import SafariServices
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
            notify("Debugger ports don't open on the phone.")
        case .offline:
            notify("\(server.config.name) is offline, so \(LocalhostLink(url)?.name ?? "this page") can't open.")
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
                notify("Couldn't open \(link.name): its pane is closed.")
            }
        }
    }

    // MARK: Menu

    /// The pane menu's row: the port's page over http.
    func open(_ entry: PortEntry) {
        guard server.phase == .online else {
            notify("\(server.config.name) is offline, so \(entry.name) can't open.")
            return
        }
        browse(LocalhostLink(port: entry.port, dialHost: entry.dialHost))
    }

    // MARK: Browser

    private func browse(_ link: LocalhostLink) {
        guard let forward = server.forward else {
            return notify("Couldn't open \(link.name): the app isn't ready to show pages yet.")
        }
        let target = PortForward.Target(sessionID: sessionID, port: link.port, dialHost: link.dialHost)
        Task {
            guard let local = try? await forward.open(target, on: server), let url = link.url(localPort: local) else {
                notify("Couldn't open \(link.name): the phone couldn't get ready to show it.")
                return
            }
            #if DEBUG
            PortsTest.opened = url  // `-portsTest` fetches through it
            #endif
            if let present { return present(url) }
            let opened = forward.forward
            guard BrowserPresenter.present(url, over: view, onClose: { forward.close(opened) }) else {
                forward.close(opened)
                notify("Couldn't open \(link.name): its pane is no longer on screen.")
                return
            }
        }
    }
}

/// The page, in Safari's view inside the app. Its Done, or a swipe down, ends the forward. The
/// pane that had the keyboard when the page came up gets it back when the page goes: opening a
/// link leaves the keyboard as it was.
@MainActor
final class BrowserPresenter: NSObject, SFSafariViewControllerDelegate, UIAdaptivePresentationControllerDelegate {
    private let onClose: () -> Void
    private var closed = false
    /// The pane's view that held the keyboard when the page came up.
    private weak var keyboardHolder: UIResponder?
    /// The one shown now; it keeps itself alive while up.
    private static var current: BrowserPresenter?

    private init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    /// False when there is no window to present from.
    @discardableResult
    static func present(_ url: URL, over view: UIView?, onClose: @escaping () -> Void) -> Bool {
        guard var top = view?.window?.rootViewController else { return false }
        while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
        let p = BrowserPresenter(onClose: onClose)
        if let view, let holder = UIResponder.rexCurrentFirstResponder() as? UIView, holder.isDescendant(of: view) {
            p.keyboardHolder = holder
        }
        let config = SFSafariViewController.Configuration()
        config.entersReaderIfAvailable = false
        let safari = SFSafariViewController(url: url, configuration: config)
        safari.dismissButtonStyle = .done
        safari.delegate = p
        current = p
        top.present(safari, animated: true)
        safari.presentationController?.delegate = p
        return true
    }

    nonisolated func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
        MainActor.assumeIsolated { finish() }
    }

    nonisolated func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        MainActor.assumeIsolated { finish() }
    }

    private func finish() {
        guard !closed else { return }
        closed = true
        onClose()
        if Self.current === self { Self.current = nil }
        if let holder = keyboardHolder { Self.giveKeyboardBack(to: holder, tries: 20) }
    }

    /// Once the page is gone (Done calls `finish` before the page slides away), the pane takes
    /// the keyboard again, unless something else took it or the pane left the screen meanwhile.
    private static func giveKeyboardBack(to holder: UIResponder, tries: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak holder] in
            guard let view = holder as? UIView, let window = view.window, !view.isFirstResponder,
                  UIResponder.rexCurrentFirstResponder() == nil else { return }
            if window.rootViewController?.presentedViewController != nil {
                if tries > 0 { giveKeyboardBack(to: view, tries: tries - 1) }
                return
            }
            _ = view.becomeFirstResponder()
        }
    }
}
