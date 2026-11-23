#if DEBUG
import Observation
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
/// - `process`: one `terminal.process` read, logged as `PORTS_PROCESS`.
/// - `watch`: from now on, each change of the pane's ports or foreground process is logged
///   as `PORTS_EVENT`, in the order the app took them.
/// - `owner:<port>`: has the port's process read as a ports row does when it shows, and logs
///   what the app holds and makes of it (`PORTS_ROW`). `row:<port>` logs that line again.
/// - `ask:<action>:<port>`: sends `port_owner` or `port_share` to the Beacon on the computer's
///   connection whether or not it holds this phone, and logs its answer's code (`PORTS_ASK_BEACON`).
/// - `browser:<port>`, `stop:<port>`, `restart:<port>` (the question), `confirm:<port>`,
///   `cancel:<port>`: what the row's menu and its question do, each logged with how it ended.
///   The port may be in another tab of the session under test.
///
/// `-portsOwner <hex of JSON>` answers `port_owner` in the Beacon's place with that object, as
/// a Beacon that held this phone would, and says in its status that it can hand pages out: a
/// simulator is no registered phone, so a real Beacon tells it nothing. Use it only with facts
/// read from your own `zz-` session's processes.
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
        if let hex = UserDefaults.standard.string(forKey: "portsOwner"), let model = ports.testModel, let answer = JSONCodec.decode(unhex(hex)) {
            NSLog("PORTS_TEST owner fixture pid=%@", "\(answer.int("pid") ?? -1)")
            model.ports.parts.beacon = { _, action, _, _ in
                action == "port_owner" ? .success(answer) : .failure(HelperFailure(code: "not_registered", message: "fixture"))
            }
            model.ports.parts.sharePossible = { _ in true }
        }
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
        case "process":
            let reply = try? await s.control.blockCall("com.superlogical.terminal.process", session: ports.sessionID, block: ports.blockID)
            func who(_ o: JSONObject?) -> String { o.map { "\($0.int("pid") ?? -1):\($0.str("name") ?? "-"):\($0.str("argv0") ?? "-")" } ?? "nil" }
            NSLog("PORTS_PROCESS foreground=%@ child=%@ ancestors=%@", who(reply?.obj("foreground")), who(reply?.obj("child")),
                  (reply?.arr("ancestors") ?? []).map { who($0) }.joined(separator: ">"))
        case "watch":
            watch(s, ports.blockID)
        case "ask":
            let bits = arg.split(separator: ":").map(String.init)
            guard bits.count == 2, let port = Int(bits[1]), let model = ports.testModel else { return }
            var args: JSONObject = ["port": port]
            if bits[0] == "port_share" { args["block"] = ports.blockID; args["phone_ip"] = PrivateNetwork.address() ?? "100.64.0.9" }
            if bits[0] == "port_owner", let pid = s.ports.value(ports.blockID)?.entry(port)?.pid { args = ["pid": pid] }
            switch await model.push.testAsk(s.id, action: bits[0], args: args) {
            case nil: NSLog("PORTS_ASK_BEACON %@ no Beacon on the connection", bits[0])
            case .success(let r)?: NSLog("PORTS_ASK_BEACON %@ ok keys=%@", bits[0], r.keys.sorted().joined(separator: ","))
            case .failure(let f)?: NSLog("PORTS_ASK_BEACON %@ code=%@ unknownAction=%@", bits[0], f.code, "\(f.isUnknownAction)")
            }
        case "owner", "row", "browser", "stop", "restart", "confirm", "cancel":
            // The port's row in the session under test, in this pane or another of its tabs.
            guard let model = ports.testModel, let row = s.portRows.first(where: { $0.sessionID == ports.sessionID && $0.entry.port == Int(arg) })
            else { return NSLog("PORTS_TEST no row %@", arg) }
            let actions = model.ports
            switch verb {
            case "owner":
                actions.learnOwner(s, row)
                try? await Task.sleep(for: .seconds(2))
            case "browser":
                NSLog("PORTS_BROWSER %@", "\(await actions.openInBrowserNow(s, row))")
            case "stop":
                NSLog("PORTS_STOP %@", "\(await actions.stopNow(s, row))")
            case "restart":
                actions.askRestart(s, row)
            case "confirm":
                // Not awaited: the steps after it look at the row while it restarts.
                Task { @MainActor in NSLog("PORTS_RESTART %@", "\(await actions.restartNow(s, row))") }
            case "cancel":
                actions.dismissRestart(s, row)
            default:
                break
            }
            NSLog("PORTS_ROW %@ %@", verb, s.portRow(row.id).map { actions.testSummary(s, $0) } ?? "gone")
        default:
            NSLog("PORTS_TEST unknown step %@", step)
        }
    }

    /// Logs the pane's ports and foreground each time either changes, as the app holds them.
    private static func watch(_ s: ServerConnection, _ bid: String) {
        let now = withObservationTracking {
            "ports=\(s.ports.value(bid)?.entries.map { "\($0.port)/\($0.pid ?? -1)" }.joined(separator: ",") ?? "-") "
                + "fg=\(s.meta[bid]?.foregroundPID ?? -1)/\(s.meta[bid]?.foreground ?? "-") rows=\(s.portRowIDs.count)"
        } onChange: {
            Task { @MainActor in watch(s, bid) }
        }
        NSLog("PORTS_EVENT %@", now)
    }

    private static func unhex(_ hex: String) -> Data {
        var data = Data(), digits = Substring(hex.trimmingCharacters(in: CharacterSet(charactersIn: "<> ")))
        while digits.count >= 2, let byte = UInt8(digits.prefix(2), radix: 16) {
            data.append(byte)
            digits = digits.dropFirst(2)
        }
        return data
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
