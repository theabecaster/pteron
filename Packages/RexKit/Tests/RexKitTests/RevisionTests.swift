import Foundation
import XCTest
@testable import RexKit

/// `RexControl` against servers of different API revisions: what the hello offers, what each
/// welcome leaves the connection with, and which close stops the retries.
@MainActor
final class RevisionTests: XCTestCase {
    private func control(_ address: String, label: String = "test") -> RexControl {
        RexControl(address: address, client: ClientInfo(name: "Sample App", version: "0.1.0", label: label))
    }

    private func waitFor(_ condition: @MainActor () -> Bool, seconds: Double = 5) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while !condition(), Date() < end { try? await Task.sleep(for: .milliseconds(5)) }
        return condition()
    }

    // MARK: Hello

    func testTheHelloOffersRevision18AndNoMinimum() async throws {
        let server = try FakeRexServer(revision: 18, serverRevision: 18)
        let address = await server.start()
        defer { server.stop() }
        // The longest label Rex keeps is 64 bytes.
        let c = control(address, label: String(repeating: "x", count: 55) + " #a1b2c3d4")
        defer { c.disconnect() }
        try await c.connect()

        let hello = try XCTUnwrap(server.lastHello)
        XCTAssertEqual(hello.int("api_revision"), 18)
        XCTAssertNil(hello["api_min_revision"], "no minimum: a server on any revision connects, as before")
        XCTAssertEqual(Set(hello.keys), ["type", "api_revision", "client"])
        XCTAssertEqual(hello.obj("client")?.str("name"), "Sample App")
        XCTAssertLessThan(server.lastHelloBytes, 512)
    }

    func testAHelloThatResumesStaysUnder512Bytes() {
        // A reconnect token as long as the server's (43 characters in practice), twice over.
        let client = ClientInfo(name: "Sample App", version: "10.20.30", label: String(repeating: "x", count: 64))
        let hello = RexControl.hello(client: client, reconnectToken: String(repeating: "t", count: 96))
        XCTAssertNil(hello["api_min_revision"])
        XCTAssertLessThan(JSONCodec.data(hello).count, 512)
    }

    // MARK: Welcome, by server revision

    func testEachServerRevisionConnectsAndIsRecorded() async throws {
        // (welcome api_revision, api_server_revision) → what the connection must report.
        let cases: [(Int?, Int?, Int, Int)] = [
            (nil, nil, 0, 0),    // a server from before revisions: both fields left out
            (13, 13, 13, 13),
            (16, 16, 16, 16),
            (18, 18, 18, 18),
            (18, 21, 18, 21),    // a newer server translates down to ours
        ]
        for (revision, newest, wantNegotiated, wantServer) in cases {
            let server = try FakeRexServer(revision: revision, serverRevision: newest)
            let address = await server.start()
            let c = control(address)
            try await c.connect()
            XCTAssertEqual(c.state, .connected, "revision \(String(describing: revision))")
            XCTAssertEqual(c.negotiatedRevision, wantNegotiated)
            XCTAssertEqual(c.serverRevision, wantServer)
            XCTAssertEqual(c.features, [])
            XCTAssertEqual(server.lastHello?.int("api_revision"), 18, "the hello is the same for every server")
            c.disconnect()
            server.stop()
        }
    }

    func testFeaturesAndUnknownWelcomeFieldsAreKeptOrIgnored() async throws {
        let server = try FakeRexServer(revision: 18, serverRevision: 19, features: ["some_future_thing", "another"])
        let address = await server.start()
        defer { server.stop() }
        let c = control(address)
        defer { c.disconnect() }
        try await c.connect()
        XCTAssertEqual(c.features, ["some_future_thing", "another"])
        XCTAssertEqual(c.negotiatedRevision, 18)
    }

    func testAReconnectToAnotherRevisionReplacesTheOldOne() async throws {
        let server = try FakeRexServer(revision: 18, serverRevision: 18)
        let address = await server.start()
        defer { server.stop() }
        let c = control(address)
        defer { c.disconnect() }
        var seen: [Int] = []
        c.observeConnected { seen.append(c.negotiatedRevision); return true }
        try await c.connect()
        XCTAssertEqual(c.negotiatedRevision, 18)

        // The server was downgraded under the app.
        server.play(revision: 13, serverRevision: 13)
        server.dropAll()
        let down = await waitFor { seen.count == 2 }
        XCTAssertTrue(down)
        XCTAssertEqual(c.negotiatedRevision, 13)
        XCTAssertEqual(c.serverRevision, 13)

        // And updated again.
        server.play(revision: 18, serverRevision: 18)
        server.dropAll()
        let up = await waitFor { seen.count == 3 }
        XCTAssertTrue(up)
        XCTAssertEqual(seen, [18, 13, 18], "observers read the new revision as soon as it connects")
    }

    // MARK: Methods newer than the connection

    func testACallBelowItsRevisionFailsHereAndIsNeverSent() async throws {
        let server = try FakeRexServer(revision: 13, serverRevision: 13)
        let address = await server.start()
        defer { server.stop() }
        let c = control(address)
        defer { c.disconnect() }
        try await c.connect()

        for method in ["com.superlogical.terminal.ports", "com.superlogical.tunnel.info"] {
            do {
                try await c.blockCall(method, session: "s", block: "b")
                XCTFail("\(method) must not run at revision 13")
            } catch let e as RexError {
                XCTAssertEqual(e.code, "revision_too_low")
                XCTAssertTrue(e.neverSent)
                XCTAssertEqual(e.presence(targetExists: true), .absent)
            }
        }
        XCTAssertEqual(server.requests.count, 0, "nothing left the client")

        // A method from revision 13 or before goes out as always.
        server.reply("session.list", ["sessions": [JSONObject]()])
        try await c.call("session.list")
        XCTAssertEqual(server.count("session.list"), 1)
    }

    func testRevisionGatesOpenAtTheirRevision() async throws {
        for (revision, portsSent, tunnelSent) in [(14, 0, 1), (15, 1, 1), (18, 1, 1)] {
            let server = try FakeRexServer(revision: revision)
            let address = await server.start()
            server.replyOtherwise(.result([:]))
            let c = control(address)
            try await c.connect()
            _ = try? await c.blockCall("com.superlogical.terminal.ports", session: "s", block: "b")
            _ = try? await c.blockCall("com.superlogical.tunnel.info", session: "s", block: "b")
            XCTAssertEqual(server.count("com.superlogical.terminal.ports"), portsSent, "revision \(revision)")
            XCTAssertEqual(server.count("com.superlogical.tunnel.info"), tunnelSent, "revision \(revision)")
            c.disconnect()
            server.stop()
        }
    }

    func testAServerWithoutAMethodAnswersMethodNotFound() async throws {
        let server = try FakeRexServer(revision: 18)
        let address = await server.start()
        defer { server.stop() }
        let c = control(address)
        defer { c.disconnect() }
        try await c.connect()
        do {
            try await c.blockCall("com.superlogical.terminal.ports", session: "s", block: "b")
            XCTFail("the fake server has no such method")
        } catch let e as RexError {
            XCTAssertEqual(e.code, "method_not_found")
            XCTAssertEqual(e.status, 404)
            XCTAssertFalse(e.neverSent)
            XCTAssertEqual(e.presence(targetExists: false), .absent)
        }
    }

    // MARK: Close 1008

    func testNoCommonRevisionStopsTheRetries() async throws {
        for (reason, side) in [
            ("no common API revision: server speaks 19 to 24, client needs 0 to 18; update the client", ConnectionFailure.RevisionRefusal.updateClient),
            ("no common API revision: server speaks 0 to 5, client needs 13 to 18; update the server", .updateServer),
            ("no common API revision: nothing in common", .unclear),
        ] {
            let server = try FakeRexServer()
            let address = await server.start()
            server.refuse(code: 1008, reason: reason)
            // The taps below come seconds apart; the 10 s between one host's taps is another
            // test's subject (`ControlTimingTests.testTapsOnOneHostAreTenSecondsApart`).
            var policy = ReconnectPolicy()
            policy.userSpacing = 0.1
            let c = RexControl(address: address, client: ClientInfo(name: "Sample App", version: "0.1.0", label: "test"),
                               governor: ReconnectGovernor(policy: policy))
            do {
                try await c.connect()
                XCTFail("refused servers don't welcome")
            } catch {
                let f = ConnectionFailure(error)
                XCTAssertEqual(f.closeCode, 1008)
                XCTAssertEqual(f.closeReason, reason)
                XCTAssertEqual(f.revisionRefusal, side)
            }
            guard case .failed(let f) = c.state else { XCTFail("state \(c.state)"); continue }
            XCTAssertEqual(f.revisionRefusal, side)
            XCTAssertTrue(c.retryStopped)

            // The first retry would come after 1 s. None does.
            try? await Task.sleep(for: .milliseconds(2600))
            XCTAssertEqual(server.helloCount, 1, "no retry after: \(reason)")

            // The user taps Try Again: one attempt, refused again, and it stops again.
            c.kick()
            let asked = await waitFor { server.helloCount == 2 }
            XCTAssertTrue(asked)
            let stopped = await waitFor { c.retryStopped }
            XCTAssertTrue(stopped)
            try? await Task.sleep(for: .milliseconds(1500))
            XCTAssertEqual(server.helloCount, 2)

            // Rex was updated: the next attempt the user asks for connects.
            server.acceptAgain()
            c.kick()
            let connected = await waitFor { c.state == .connected }
            XCTAssertTrue(connected)
            XCTAssertFalse(c.retryStopped)
            c.disconnect()
            server.stop()
        }
    }

    func testEventBacklogExceededReconnectsAsAnyDropDoes() async throws {
        let server = try FakeRexServer()
        let address = await server.start()
        defer { server.stop() }
        let c = control(address)
        defer { c.disconnect() }
        var connects = 0
        var reconnected = 0
        c.observeConnected { connects += 1; return true }
        c.onReconnected = { _ in reconnected += 1 }
        var failures: [ConnectionFailure] = []
        c.onStateChange = { if case .failed(let f) = $0 { failures.append(f) } }
        try await c.connect()

        // The phone fell 8 MiB of events behind.
        server.close(code: 1008, reason: "event backlog exceeded")
        let back = await waitFor({ connects == 2 }, seconds: 6)
        XCTAssertTrue(back, "a 1008 for the backlog is retried like any other drop")
        XCTAssertEqual(c.state, .connected)
        XCTAssertEqual(reconnected, 1, "and the state is read again")
        XCTAssertFalse(c.retryStopped)
        XCTAssertEqual(failures.first?.closeCode, 1008)
        XCTAssertEqual(failures.first?.closeReason, "event backlog exceeded")
        XCTAssertNil(failures.first?.revisionRefusal)
    }

    func testOnlyTheRevisionReasonCountsAsARefusal() {
        func f(_ code: Int?, _ reason: String?) -> ConnectionFailure {
            ConnectionFailure(domain: NSPOSIXErrorDomain, code: 57, message: "closed", closeCode: code, closeReason: reason)
        }
        XCTAssertNil(f(1008, "event backlog exceeded").revisionRefusal)
        XCTAssertNil(f(1008, nil).revisionRefusal)
        XCTAssertNil(f(1008, "").revisionRefusal)
        XCTAssertNil(f(1001, "no common API revision: x; update the server").revisionRefusal, "the code must be 1008")
        XCTAssertNil(f(1008, "policy: no common API revision").revisionRefusal, "the reason must start with it")
        XCTAssertEqual(f(1008, "no common API revision").revisionRefusal, .unclear)
        XCTAssertEqual(f(1008, "no common API revision: server speaks 0 to 18, client needs 99 to 99; update the server").revisionRefusal,
                       .updateServer)
    }

    // MARK: post

    func testPostSendsInTheCallersTurnAndIgnoresTheAnswer() async throws {
        let server = try FakeRexServer()
        let address = await server.start()
        defer { server.stop() }
        let c = control(address)
        XCTAssertFalse(c.post("client.reply", PromptRequest.decline(callID: "x")), "not connected: nothing to send on")
        defer { c.disconnect() }
        try await c.connect()
        XCTAssertTrue(c.post("client.reply", PromptRequest.decline(callID: "call:1")))
        let arrived = await waitFor { server.count("client.reply") == 1 }
        XCTAssertTrue(arrived)
        let p = try XCTUnwrap(server.calls("client.reply").first)
        XCTAssertEqual(p.str("call_id"), "call:1")
        XCTAssertEqual(p.obj("error")?.str("code"), "not_supported")
        XCTAssertNil(p["result"], "error or result, never both")
        // The answer (an error here) arrives with nobody waiting, and nothing breaks.
        server.reply("session.list", ["sessions": [JSONObject]()])
        try await c.call("session.list")
    }
}
