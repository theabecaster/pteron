import Foundation
import XCTest
@testable import RexKit

/// `RexControl.callInOrder`: every request leaves in one turn, in the order given, and each
/// answer comes back in its own slot whatever order the server answers in.
@MainActor
final class CallInOrderTests: XCTestCase {
    private func connected(_ server: FakeRexServer) async throws -> RexControl {
        let address = await server.start()
        let c = RexControl(address: address, client: ClientInfo(name: "Sample App", version: "0.1.0", label: "test"))
        try await c.connect()
        return c
    }

    func testRequestsLeaveInOrderAndAnswersKeepTheirPlace() async throws {
        let server = try FakeRexServer(revision: 18)
        defer { server.stop() }
        server.reply("session.move_block", ["revision": 4])
        server.reply("block.close", .error(code: "not_found", status: 404))
        server.reply("session.move_window", ["revision": 5])
        // The first answer leaves last: the results must still line up with the calls.
        server.delay("session.move_block", seconds: 0.2)
        let c = try await connected(server)
        defer { c.disconnect() }

        let results = await c.callInOrder([
            ("session.move_block", ["block_id": "a"]),
            ("block.close", ["block_id": "p"]),
            ("session.move_window", ["window_id": "w"]),
        ])

        XCTAssertEqual(server.requests.map(\.method), ["session.move_block", "block.close", "session.move_window"])
        XCTAssertEqual(server.requests.map { $0.payload.str("block_id") ?? $0.payload.str("window_id") }, ["a", "p", "w"])
        XCTAssertEqual(try results[0].get().int("revision"), 4)
        XCTAssertEqual((results[1].failure as? RexError)?.code, "not_found")
        XCTAssertEqual(try results[2].get().int("revision"), 5)
    }

    func testManyCallsKeepTheirOrderOnTheWire() async throws {
        let server = try FakeRexServer(revision: 18)
        defer { server.stop() }
        server.reply("block.close", [:])
        let c = try await connected(server)
        defer { c.disconnect() }
        let ids = (0..<40).map { "block:\($0)" }

        let results = await c.callInOrder(ids.map { ("block.close", ["block_id": $0] as JSONObject) })

        XCTAssertEqual(results.count, 40)
        XCTAssertTrue(results.allSatisfy { (try? $0.get()) != nil })
        XCTAssertEqual(server.calls("block.close").compactMap { $0.str("block_id") }, ids)
    }

    func testWithoutAConnectionNothingIsSent() async throws {
        let c = RexControl(address: "http://127.0.0.1:1", client: ClientInfo(name: "Sample App", version: "0.1.0", label: "test"))
        let results = await c.callInOrder([("block.close", [:]), ("block.close", [:])])
        XCTAssertEqual(results.count, 2)
        for r in results { XCTAssertEqual((r.failure as? RexError)?.neverSent, true) }
        let none = await c.callInOrder([])
        XCTAssertTrue(none.isEmpty)
    }

    func testALostConnectionFailsEveryCallThatIsOut() async throws {
        let server = try FakeRexServer(revision: 18)
        defer { server.stop() }
        server.reply("block.close", .none)
        let c = try await connected(server)
        defer { c.disconnect() }

        let calls = Task { @MainActor in
            await c.callInOrder([("block.close", ["block_id": "a"]), ("block.close", ["block_id": "b"])]).map { $0.failure != nil }
        }
        _ = await eventually { server.count("block.close") == 2 }
        c.disconnect()

        let failed = await calls.value
        XCTAssertEqual(failed, [true, true])
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let e) = self { return e }
        return nil
    }
}
