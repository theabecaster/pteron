#if DEBUG
import RexKit
import UIKit

/// `-portsTest '<step>;<step>…'` (Debug builds, testing): drives ports in the active pane once it
/// is live, where the simulator can't tap through the pane menu. Steps run a second apart:
///
/// - `list`: logs the pane's ports and gates (`PORTS_LIST`).
/// - `menu:<port>`: the pane menu's row for that port.
/// - `link:<url>`: a tapped link; `yes:<url>` answers its question with Open, `no:<url>` with
///   Cancel.
/// - `fetch:<path>`: loads the open page's `path` through the forward from inside the app, and
///   logs `PORTS_FETCH <status> <bytes>`, without reading the browser.
/// - `parallel:<n>`: that many fetches at once.
/// - `done`: Done in the browser.
/// - `wait:<seconds>`: pause.
///
/// The forward logs each connection's end (`PORTS_CONN`). Use only with a throwaway `zz-`
/// session and a test server started in it.
@MainActor
enum PortsTest {
    private static var ran = false
    /// The page the browser opened, for `fetch`.
    static var opened: URL?

    static func run(on host: TerminalHost) {
        guard !ran, let script = UserDefaults.standard.string(forKey: "portsTest"), let ports = host.ports else { return }
        ran = true
        let steps = script.split(separator: ";").map(String.init)
        Task { @MainActor [weak host] in
            try? await Task.sleep(for: .seconds(2))
            for step in steps {
                guard let host else { return }
                await perform(step, ports, host)
                try? await Task.sleep(for: .seconds(1))
            }
            NSLog("PORTS_TEST end")
        }
    }

    private static func perform(_ step: String, _ ports: PanePorts, _ host: TerminalHost) async {
        let (verb, arg) = step.firstIndex(of: ":").map { (String(step[..<$0]), String(step[step.index(after: $0)...])) } ?? (step, "")
        NSLog("PORTS_TEST %@", step)
        let s = ports.server
        switch verb {
        case "list":
            let list = s.ports.value(ports.blockID)
            NSLog("PORTS_LIST ports=%@ tunnels=%@ local=%@ status=%@ entries=%@ web=%@",
                  "\(s.portsAvailable)", "\(s.tunnelsAvailable)", "\(s.showsPorts(session: ports.sessionID, block: ports.blockID))",
                  list.map { $0.status.rawValue } ?? "-",
                  list.map { $0.entries.map { "\($0.port)@\($0.dialHost)/\($0.process ?? "-")" }.joined(separator: ",") } ?? "-",
                  list.map { $0.webPorts.map { "\($0.port)" }.joined(separator: ",") } ?? "-")
        case "menu":
            guard let e = s.ports.value(ports.blockID)?.entry(Int(arg) ?? 0) else { return NSLog("PORTS_TEST no port %@", arg) }
            ports.open(e)
        case "link", "yes", "no":
            guard let url = URL(string: arg) else { return }
            let old = ports.ask
            ports.ask = { question, answer in
                NSLog("PORTS_ASK %@", question)
                answer(verb == "yes")
            }
            NSLog("PORTS_ROUTE %@", "\(ports.route(url, asked: false))")
            ports.open(url, asked: false)
            ports.ask = old
        case "fetch":
            await fetch(arg)
        case "parallel":
            await withTaskGroup(of: Void.self) { g in
                for _ in 0..<(Int(arg) ?? 4) { g.addTask { await fetch("/") } }
            }
        case "done":
            var top = ScreenInspector.keyWindow?.rootViewController
            while let next = top?.presentedViewController { top = next }
            NSLog("PORTS_TEST top %@", String(describing: top.map { type(of: $0) }))
            if let browser = (top as? UINavigationController)?.viewControllers.first as? PreviewBrowser { browser.close() }
        case "wait":
            try? await Task.sleep(for: .seconds(Double(arg) ?? 1))
        default:
            NSLog("PORTS_TEST unknown step %@", step)
        }
    }

    private static func fetch(_ path: String) async {
        guard let base = opened, var c = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            return NSLog("PORTS_FETCH no page")
        }
        c.path = path.isEmpty ? "/" : path
        c.query = nil
        guard let url = c.url else { return }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: cfg)
        defer { session.invalidateAndCancel() }
        do {
            let (data, r) = try await session.data(from: url)
            NSLog("PORTS_FETCH %ld %ld %@", (r as? HTTPURLResponse)?.statusCode ?? -1, data.count, url.absoluteString)
        } catch {
            NSLog("PORTS_FETCH error %@ %@", "\(error)", url.absoluteString)
        }
    }
}
#endif
