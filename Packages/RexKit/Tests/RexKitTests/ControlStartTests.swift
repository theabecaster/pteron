import Foundation
import XCTest
@testable import RexKit

/// `RexControl.start`: a request that is with the socket before the call returns, and whose
/// answer comes in a later turn of the main actor.
@MainActor
final class ControlStartTests: XCTestCase {
    private static let write = "com.superlogical.terminal.write"

    private static func error(_ answer: Result<JSONObject, Error>?) -> RexError? {
        if case .failure(let error)? = answer { return error as? RexError }
        return nil
    }

    private func connected(_ server: FakeRexServer) async throws -> RexControl {
        let address = await server.start()
        let c = RexControl(address: address, client: ClientInfo(name: "Sample App", version: "0.1.0", label: "test"))
        try await c.connect()
        return c
    }

    func testARequestLeavesInTheCallersTurnAndIsAnsweredLater() async throws {
        let server = try FakeRexServer(revision: 18)
        defer { server.stop() }
        server.reply(Self.write, ["ok": true])
        let c = try await connected(server)
        defer { c.disconnect() }

        var answers: [Result<JSONObject, Error>] = []
        XCTAssertTrue(c.start(Self.write, ["args": ["data": "a"]]) { answers.append($0) })
        XCTAssertTrue(answers.isEmpty, "the answer never comes inside the call")
        // What is sent after it in the same turn is behind it on the wire.
        XCTAssertTrue(c.start(Self.write, ["args": ["data": "b"]]) { answers.append($0) })
        let answered = await eventually { answers.count == 2 }
        XCTAssertTrue(answered)
        XCTAssertEqual(try answers[0].get().bool("ok"), true)
        XCTAssertEqual(server.calls(Self.write).compactMap { $0.obj("args")?.str("data") }, ["a", "b"])
    }

    func testAServerErrorIsTheAnswer() async throws {
        let server = try FakeRexServer(revision: 18)
        defer { server.stop() }
        server.reply(Self.write, .error(code: "not_found", status: 404))
        let c = try await connected(server)
        defer { c.disconnect() }
        var answers: [Result<JSONObject, Error>] = []
        XCTAssertTrue(c.start(Self.write, [:]) { answers.append($0) })
        let answered = await eventually { answers.count == 1 }
        XCTAssertTrue(answered)
        XCTAssertEqual(Self.error(answers.first)?.code, "not_found")
    }

    func testNothingStartsWithoutAConnectionOnADelayedLinkOrForAMethodTheServerLacks() async throws {
        let offline = RexControl(address: "http://127.0.0.1:1", client: ClientInfo(name: "Sample App", version: "0.1.0", label: "test"))
        var called = 0
        XCTAssertFalse(offline.start(Self.write, [:]) { _ in called += 1 }, "`call` says that it never left")

        let server = try FakeRexServer(revision: 18)
        defer { server.stop() }
        server.reply(Self.write, [:])
        let c = try await connected(server)
        defer { c.disconnect() }
        let before = server.calls(Self.write).count
        c.linkDelay = LinkDelay(roundTrip: .milliseconds(40))
        XCTAssertFalse(c.start(Self.write, [:]) { _ in called += 1 }, "a delayed link waits before it sends: `call` does that")
        c.linkDelay = .none
        await settle()
        XCTAssertEqual(server.calls(Self.write).count, before)
        XCTAssertEqual(called, 0, "a request that did not start is never answered")
    }

    func testALostConnectionFailsARequestThatIsOutInALaterTurn() async throws {
        let server = try FakeRexServer(revision: 18)
        defer { server.stop() }
        server.reply(Self.write, .none)
        let c = try await connected(server)
        var answers: [Result<JSONObject, Error>] = []
        XCTAssertTrue(c.start(Self.write, [:]) { answers.append($0) })
        _ = await eventually { server.calls(Self.write).count == 1 }
        c.disconnect()
        XCTAssertTrue(answers.isEmpty, "not inside the connection's own handling of the loss")
        let answered = await eventually { answers.count == 1 }
        XCTAssertTrue(answered)
        let error = Self.error(answers.first)
        XCTAssertNotNil(error)
        XCTAssertNotEqual(error?.neverSent, true, "it left: nobody knows whether the server ran it")
    }
}
