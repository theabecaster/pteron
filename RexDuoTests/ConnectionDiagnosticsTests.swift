import SwiftUI
import XCTest
import RexKit
@testable import RexDuo

/// The connection log as the app feeds it: a server's connection, reported by `ServerConnection`,
/// comes out as "Server 1" with no name and no address, in the text and in the file.
@MainActor
final class ConnectionDiagnosticsTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("clog-app-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func wait(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<1000 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    func testAServersConnectionIsLoggedWithoutItsNameOrAddress() async throws {
        let fake = try FakeRexServer()
        let address = await fake.start()
        defer { fake.stop() }
        let name = "ConnectionDiagnosticsTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        defer { d.removePersistentDomain(forName: name) }
        let prefs = Prefs(defaults: d)
        let model = AppModel(prefs: prefs, connect: false)
        XCTAssertNil(model.connectionLog, "a model that doesn't connect keeps no log")

        let file = folder.appendingPathComponent("Diagnostics/connections.clog")
        let log = ConnectionLog(file: file)
        log.record(.launch(build: ConnectionDiagnostics.buildNumber("2611201913")))
        let config = ServerConfig(name: "Kitchen Mac", url: address)
        // A schedule with no jitter. The app's first retry falls anywhere from 0 to 1 s: near 0
        // the connection is back before this test sees it down, and the logged wait changes
        // from run to run. Here it is exactly 1 s.
        var policy = ReconnectPolicy()
        policy.fullJitterFirst = false
        policy.jitter = 0
        let server = ServerConnection(config: config, prefs: prefs, notifier: model.notifier,
                                      deviceID: "a1b2c3d4", log: log, governor: ReconnectGovernor(policy: policy))
        server.start()
        let up = await wait { server.control.state == .connected }
        XCTAssertTrue(up)
        fake.dropAll()
        let down = await wait { server.control.state != .connected }
        XCTAssertTrue(down)
        server.stop()

        log.flush()
        let text = await ConnectionDiagnostics.export(log, servers: [config])
        XCTAssertTrue(text.contains("App       launch build=2611201913"), text)
        XCTAssertTrue(text.contains("Server 1  connecting"), text)
        XCTAssertTrue(text.contains("Server 1  connected after="), text)
        XCTAssertTrue(text.contains("Server 1  closed "), text)
        XCTAssertTrue(text.contains("Server 1  retry in=1000ms"), text)
        XCTAssertTrue(text.contains("Server 1  stopped"), text)

        let port = String(address.split(separator: ":").last ?? "")
        let bytes = try Data(contentsOf: file)
        XCTAssertGreaterThanOrEqual(bytes.count, 16 + 6 * ConnectionEvent.size)
        for secret in ["Kitchen", "127.0.0.1", "http://", address, config.id.uuidString] {
            XCTAssertFalse(text.contains(secret), "“\(secret)” is in the exported text")
            XCTAssertNil(bytes.range(of: Data(secret.utf8)), "“\(secret)” is in the file")
        }
        XCTAssertFalse(text.contains(":\(port)"), "the port is in the exported text")
    }

    /// The probe of Tailscale's own service is for the log: one line there, and no server's
    /// screen changes with it.
    func testTheTunnelProbeWritesOneLineAndChangesNothingOnScreen() async throws {
        let name = "ConnectionDiagnosticsTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        defer { d.removePersistentDomain(forName: name) }
        let prefs = Prefs(defaults: d)
        let model = AppModel(prefs: prefs, connect: false)
        let log = ConnectionLog(file: folder.appendingPathComponent("Diagnostics/connections.clog"))
        let config = ServerConfig(name: "Kitchen Mac", url: "https://kitchen-rex.tail1234.ts.net")
        let server = ServerConnection(config: config, prefs: prefs, notifier: model.notifier,
                                      deviceID: "a1b2c3d4", log: log)
        let before = (server.phase, server.retrying, server.recovering, server.waking, server.lastError)

        await TunnelProbe.record(into: log) { TunnelProbe.Result(reachable: false, milliseconds: 3000) }
        await TunnelProbe.record(into: log) { TunnelProbe.Result(reachable: true, milliseconds: 4) }

        log.flush()
        let text = await ConnectionDiagnostics.export(log, servers: [config])
        XCTAssertTrue(text.contains("App       probe tailscale reachable=no after=3000ms"), text)
        XCTAssertTrue(text.contains("App       probe tailscale reachable=yes after=4ms"), text)
        XCTAssertFalse(text.contains("100.100"), "no address in the log")
        let after = (server.phase, server.retrying, server.recovering, server.waking, server.lastError)
        XCTAssertTrue(before == after)
        XCTAssertEqual(server.phase, .idle)
        XCTAssertEqual(server.control.state, .idle)
        XCTAssertTrue(model.servers.isEmpty)
    }

    /// A port nothing listens on: no answer, well inside the limit, and nothing is left open.
    func testTheProbeOfAClosedPortSaysNotReachable() async {
        let result = await TunnelProbe.connect(host: "127.0.0.1", port: 1, timeout: 2)
        XCTAssertFalse(result.reachable)
        XCTAssertLessThan(result.milliseconds, 2500)
    }

    func testTheServersKeyIsItsIdAndTheBuildIsANumber() {
        let config = ServerConfig(name: "Kitchen Mac", url: "https://desk.example.ts.net")
        XCTAssertEqual(ConnectionDiagnostics.key(config), config.id.uuidString)
        XCTAssertEqual(ConnectionDiagnostics.buildNumber("2611201913"), 2_611_201_913)
        XCTAssertEqual(ConnectionDiagnostics.buildNumber("1.2"), 0)
        XCTAssertEqual(ConnectionDiagnostics.buildNumber(nil), 0)
        XCTAssertEqual(ConnectionDiagnostics.scene(.active), .active)
        XCTAssertEqual(ConnectionDiagnostics.scene(.inactive), .inactive)
        XCTAssertEqual(ConnectionDiagnostics.scene(.background), .background)
        XCTAssertEqual(ConnectionDiagnostics.file.lastPathComponent, "connections.clog")
        XCTAssertTrue(ConnectionDiagnostics.file.path.contains("Application Support/Diagnostics"))
    }
}
