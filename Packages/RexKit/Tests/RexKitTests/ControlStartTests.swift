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

    /// A method newer than the connection's revision: `start` takes nothing, and `call` gives
    /// the answer, which is known without asking the server.
    func testAMethodTheServerLacksDoesNotStartAndCallSaysItNeverLeft() async throws {
        let method = "com.superlogical.terminal.ports"
        let server = try FakeRexServer(revision: RexAPI.minimum(for: method) - 1)
        defer { server.stop() }
        server.reply(method, [:])
        server.reply(Self.write, [:])
        let c = try await connected(server)
        defer { c.disconnect() }

        var answers: [Result<JSONObject, Error>] = []
        XCTAssertFalse(c.start(method, [:]) { answers.append($0) })
        do {
            try await c.call(method, [:])
            XCTFail("the call went through")
        } catch {
            let e = try XCTUnwrap(error as? RexError)
            XCTAssertEqual(e.code, "revision_too_low")
            XCTAssertTrue(e.neverSent)
        }
        // A method the revision has starts on the same connection.
        XCTAssertTrue(c.start(Self.write, [:]) { answers.append($0) })
        let answered = await eventually { answers.count == 1 }
        XCTAssertTrue(answered)
        await settle()
        XCTAssertEqual(answers.count, 1, "the request that did not start is never answered")
        XCTAssertEqual(server.count(method), 0, "the server was not asked")
        XCTAssertEqual(server.count(Self.write), 1)
    }

    /// The socket ends the send with an error: the server never saw the request. The answer is
    /// a failure that says it never left, once, in a later turn; the connection stands, and
    /// the next request starts.
    func testASocketThatRefusesTheSendAnswersLaterThatItNeverLeft() async throws {
        let sockets = FakeControlSockets()
        let c = RexControl(address: "https://desk.example.ts.net",
                           client: ClientInfo(name: "test", version: "0", label: "test"),
                           clock: FakeControlClock(), sockets: sockets.factory,
                           governor: ReconnectGovernor(policy: .standard), random: { 0.5 })
        let connecting = Task { @MainActor in try? await c.connect() }
        await pump()
        sockets.last.welcome()
        _ = await connecting.value
        await pump()
        XCTAssertEqual(c.state, .connected)
        let socket = sockets.last
        let before = socket.sent.count

        var answers: [Result<JSONObject, Error>] = []
        XCTAssertTrue(c.start(Self.write, ["args": ["data": "a"]]) { answers.append($0) })
        XCTAssertEqual(socket.sent.count, before + 1, "handed to the socket in the caller's turn")
        socket.refuseLastSend()
        XCTAssertTrue(answers.isEmpty, "not inside the socket's own callback")
        await pump()
        XCTAssertEqual(answers.count, 1)
        XCTAssertEqual(Self.error(answers.first)?.neverSent, true, "the caller may send it again")
        // The socket's callback again, or an answer with the request's id: nothing more.
        socket.refuseLastSend()
        let id = try XCTUnwrap(JSONCodec.decode(Data(socket.sent[before].utf8))?.str("id"))
        socket.deliver(#"{"type":"response","id":"\#(id)","payload":{}}"#)
        await pump()
        XCTAssertEqual(answers.count, 1, "answered once")

        XCTAssertEqual(c.state, .connected)
        XCTAssertTrue(c.start(Self.write, ["args": ["data": "b"]]) { answers.append($0) })
        XCTAssertEqual(socket.sent.count, before + 2)
        c.disconnect()
        await pump()
    }

    /// What one `start` of a write of typed text costs the caller's turn on a real connection:
    /// the request's JSON, the socket's send, the watchdog. The benchmark's `echo.mainSendUs`
    /// runs on a scripted link and leaves this out (docs/ghostty-engine.md, Measurements).
    ///
    /// A measurement, so the unit suite skips it. By hand, with the Mac otherwise idle:
    /// `PTERON_MEASURE_START=1 swift test --package-path Packages/RexKit --filter ControlStartTests/testWhatAStartCostsTheCallersTurn`
    func testWhatAStartCostsTheCallersTurn() async throws {
        guard ProcessInfo.processInfo.environment["PTERON_MEASURE_START"] != nil else {
            throw XCTSkip("a measurement: run by hand")
        }
        let server = try FakeRexServer(revision: 18)
        defer { server.stop() }
        server.reply(Self.write, [:])
        let c = try await connected(server)
        defer { c.disconnect() }

        // One request out at a time, as the stream's queue sends them.
        var answered = 0
        func timed() async -> Double {
            let payload: JSONObject = ["session_id": "session:test", "block_id": "block:test", "args": ["data": "a"]]
            let want = answered + 1
            let t0 = DispatchTime.now().uptimeNanoseconds
            let started = c.start(Self.write, payload) { _ in answered += 1 }
            let t1 = DispatchTime.now().uptimeNanoseconds
            XCTAssertTrue(started)
            _ = await eventually { answered == want }
            return Double(t1 - t0) / 1000
        }
        for _ in 0..<50 { _ = await timed() }
        var us: [Double] = []
        for _ in 0..<400 { us.append(await timed()) }
        us.sort()
        print(String(format: "RexControl.start of a typed key, µs of the caller's turn over %d calls: median %.1f, p95 %.1f, min %.1f",
                     us.count, us[us.count / 2], us[us.count * 95 / 100], us[0]))
    }
}
