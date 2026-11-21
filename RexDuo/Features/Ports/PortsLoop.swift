#if DEBUG || BENCH
import Network
import UIKit

/// `-portsLoop <n>` (Debug and benchmark builds): opens the browser `n` times on a page this
/// app serves to itself on loopback, as fast as each page loads, closing it each time. No
/// computer is needed and no pane is touched. It reads the app's memory after 5 opens, after
/// 30 and after the last, logs `PORTS_LOOP opens=<k> footprint=<MB>` for each and
/// `PORTS_LOOP done growth=<MB>`, and writes `Documents/perf/portsLoop.json`.
///
/// The growth is the last reading less the one after 30 opens (after 5 in a shorter run). In
/// a build without memory tools the app's memory rises by about 5 MB over the first 25 or so
/// opens, in two steps, and then stays level (iOS 27.2 simulator), so a reading after 5 opens
/// is not yet the level. A page that leaves something behind shows after that: every open
/// from the 30th on must cost nothing, and `scripts/bench/ports-loop.sh` fails when 100 opens
/// end more than 1 MB over 30.
///
/// `-portsLoopHold <seconds>` keeps each page up that long, for a screenshot, and
/// `-portsLoopLandscape YES` turns the iPhone on its side first.
@MainActor
enum PortsLoop {
    /// The open after which the memory is level.
    private static let warm = 30

    private static var opens: Int? {
        let n = UserDefaults.standard.integer(forKey: "portsLoop")
        return n > 0 ? n : nil
    }

    static func runIfAsked() {
        guard let opens, !RexDuoApp.isTestHost else { return }
        Task { @MainActor in await run(opens) }
    }

    private static func run(_ opens: Int) async {
        let defaults = UserDefaults.standard
        let hold = max(defaults.double(forKey: "portsLoopHold"), 0.7)
        let page = LoopPage()
        guard let port = try? await page.start(), let url = URL(string: "http://127.0.0.1:\(port)/") else {
            return say("PORTS_LOOP failed: the page could not be served")
        }
        // The launch and the first screen settle first.
        await pause(6)
        guard let window = ScreenInspector.keyWindow, let root = window.rootViewController else {
            return say("PORTS_LOOP failed: no window")
        }
        if defaults.bool(forKey: "portsLoopLandscape") {
            window.windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight))
            await pause(2)
        }
        var afterFive = 0.0, afterThirty = 0.0, afterAll = 0.0
        for n in 1...opens {
            guard PreviewBrowser.present(PreviewPage(load: url, shown: "localhost:3000"), over: root.view, onClose: {}) else {
                return say("PORTS_LOOP failed: nothing to present from")
            }
            var top = root
            while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
            let browser = (top as? UINavigationController)?.viewControllers.first as? PreviewBrowser
            // Until the page is in (5 s at most).
            for _ in 0..<100 where browser?.shownTitle != LoopPage.title { await pause(0.05) }
            await pause(hold)
            browser?.close()
            await pause(1.2)
            if n == 5 || n == warm || n == opens {
                // What a close lets go of is gone by then.
                await pause(6)
                let megabytes = Double(PerfSystem.footprint()) / 1_048_576
                say(String(format: "PORTS_LOOP opens=%d footprint=%.2f MB", n, megabytes))
                if n == 5 { afterFive = megabytes }
                if n == warm { afterThirty = megabytes }
                afterAll = megabytes
            }
        }
        page.stop()
        let growth = opens > warm ? afterAll - afterThirty : opens > 5 ? afterAll - afterFive : 0
        say(String(format: "PORTS_LOOP done growth=%.2f MB", growth))
        let result: [String: Any] = [
            "opens": opens, "afterFiveMB": afterFive, "afterThirtyMB": afterThirty, "afterAllMB": afterAll, "growthMB": growth,
        ]
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("perf")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) {
            try? data.write(to: folder.appendingPathComponent("portsLoop.json"))
        }
    }

    private static func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
    }

    private static func say(_ line: String) {
        NSLog("%@", line)
    }
}

/// One small page on 127.0.0.1, for the loop.
private final class LoopPage: @unchecked Sendable {
    // `@unchecked`: `listener` is set once in `start`, before anything else can call `stop`;
    // the connections live on `queue`.
    static let title = "Ports loop"
    private static let body = "<!doctype html><meta name=viewport content=\"width=device-width\"><title>\(title)</title>"
        + "<style>body{font:17px -apple-system;margin:24px}</style><h1>ports loop</h1><p>"
        + String(repeating: "A dev server's page. ", count: 40)
    private let queue = DispatchQueue(label: "PortsLoop.page")
    private var listener: NWListener?

    func start() async throws -> Int {
        let made = try NWListener(using: .tcp, on: .any)
        listener = made
        let queue = queue
        made.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { _, _, _, _ in
                let body = LoopPage.body
                let head = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
                connection.send(content: Data((head + body).utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        return try await withCheckedThrowingContinuation { done in
            made.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    made.stateUpdateHandler = nil
                    done.resume(returning: Int(made.port?.rawValue ?? 0))
                case .failed(let error):
                    made.stateUpdateHandler = nil
                    done.resume(throwing: error)
                default:
                    break
                }
            }
            made.start(queue: queue)
        }
    }

    func stop() { listener?.cancel() }
}
#endif
