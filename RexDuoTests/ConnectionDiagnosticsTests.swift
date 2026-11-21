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
        let server = ServerConnection(config: config, prefs: prefs, notifier: model.notifier,
                                      deviceID: "a1b2c3d4", log: log)
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
