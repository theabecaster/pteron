import XCTest
@testable import RexKit

/// Whether the server still has a connection's client, and who waits for a session's attach.
@MainActor
final class ClientContinuityTests: XCTestCase {
    func testOnlyAWelcomeThatRefusedToContinueTheClientSaysItIsGone() {
        XCTAssertTrue(ClientContinuity.ended(sentToken: true, resumed: false, previousID: "client:1", id: "client:2"))
        XCTAssertTrue(ClientContinuity.ended(sentToken: true, resumed: false, previousID: "client:1", id: nil))
        XCTAssertTrue(ClientContinuity.ended(sentToken: true, resumed: nil, previousID: "client:1", id: "client:2"), "another ID than before")
        XCTAssertFalse(ClientContinuity.ended(sentToken: true, resumed: true, previousID: "client:1", id: "client:1"), "continued")
        XCTAssertFalse(ClientContinuity.ended(sentToken: false, resumed: false, previousID: nil, id: "client:1"), "a first connection")
        XCTAssertFalse(ClientContinuity.ended(sentToken: true, resumed: nil, previousID: "client:1", id: "client:1"),
                       "a server that doesn't say leaves it unknown, and unknown is not gone")
        XCTAssertFalse(ClientContinuity.ended(sentToken: true, resumed: nil, previousID: nil, id: nil))
    }

    func testAStreamSurvivesOnlyUnderTheClientItWasWelcomedUnder() {
        XCTAssertTrue(ClientContinuity.streamSurvives(welcomedUnder: 3, now: 3))
        XCTAssertFalse(ClientContinuity.streamSurvives(welcomedUnder: 3, now: 4))
        XCTAssertTrue(ClientContinuity.streamSurvives(welcomedUnder: nil, now: 4), "never welcomed: nothing is known to be gone")
    }

    // MARK: Waiting for a session's attach

    func testAWaitEndsWithTheAttachOfItsSessionAndOnlyThat() {
        let waits = AttachWaits()
        var heard: [String] = []
        XCTAssertNotNil(waits.wait(for: "session:a") { heard.append("a \($0)") })
        XCTAssertNotNil(waits.wait(for: "session:b") { heard.append("b \($0)") })
        waits.attach(["session:c"])
        XCTAssertEqual(heard, [])
        waits.attach(["session:a"])
        XCTAssertEqual(heard, ["a true"])
        XCTAssertEqual(waits.waiting, 1)
        waits.attach(["session:a", "session:b"])
        XCTAssertEqual(heard, ["a true", "b true"], "once each")
        XCTAssertEqual(waits.waiting, 0)
    }

    func testASessionThatIsAttachedHasNothingToWaitFor() {
        let waits = AttachWaits()
        waits.attach(["session:a"])
        var heard = 0
        XCTAssertNil(waits.wait(for: "session:a") { _ in heard += 1 })
        XCTAssertEqual(heard, 0)
        XCTAssertEqual(waits.waiting, 0)
    }

    func testANewClientIsAttachedToNothingAndThoseWhoWaitKeepWaiting() {
        let waits = AttachWaits()
        waits.attach(["session:a"])
        var heard: [Bool] = []
        XCTAssertNotNil(waits.wait(for: "session:b") { heard.append($0) })
        waits.newClient()
        XCTAssertEqual(waits.attached, [])
        XCTAssertEqual(waits.waiting, 1)
        XCTAssertNotNil(waits.wait(for: "session:a") { heard.append($0) }, "attached to the old client only")
        waits.attach(["session:a", "session:b"])
        XCTAssertEqual(heard.count, 2)
        XCTAssertTrue(heard.allSatisfy { $0 })
    }

    func testACancelledWaitIsToldOnceAndNeverAgain() {
        let waits = AttachWaits()
        var heard: [Bool] = []
        let one = waits.wait(for: "session:a") { heard.append($0) }
        _ = waits.wait(for: "session:a") { heard.append($0) }
        waits.cancel(one!)
        XCTAssertEqual(heard, [false])
        waits.cancel(one!)
        XCTAssertEqual(heard, [false], "a wait that has ended is left alone")
        waits.cancelAll()
        XCTAssertEqual(heard, [false, false])
        waits.attach(["session:a"])
        XCTAssertEqual(heard, [false, false], "nobody waits any more")
        XCTAssertEqual(waits.waiting, 0)
    }

    func testOnlyAnAttachCallsAnswerSaysASessionIsAttached() {
        XCTAssertEqual(AttachWaits.attaches(method: "session.attach", payload: ["session_id": "session:a"]), ["session:a"])
        XCTAssertEqual(AttachWaits.attaches(method: "session.bootstrap", payload: ["attach_session_ids": ["session:a", "session:b"]]),
                       ["session:a", "session:b"])
        XCTAssertEqual(AttachWaits.attaches(method: "session.bootstrap", payload: ["event_scope": "all", "attach_session_ids": [String]()]), [])
        XCTAssertEqual(AttachWaits.attaches(method: "session.view", payload: ["session_id": "session:a"]), [])
        XCTAssertEqual(AttachWaits.attaches(method: "data.connect", payload: ["session_id": "session:a"]), [])
        XCTAssertEqual(AttachWaits.attaches(method: "session.attach", payload: nil), [])
    }
}

/// What `RexControl` makes of a welcome's word on its client, and of an attach's answer.
@MainActor
final class ControlClientTests: XCTestCase {
    private var clock: FakeControlClock!
    private var sockets: FakeControlSockets!
    private var control: RexControl!
    private var notes: [ConnectionEvent] = []

    override func setUp() async throws {
        clock = FakeControlClock()
        clock.yields = 40
        sockets = FakeControlSockets()
        control = RexControl(address: "https://desk.example.ts.net",
                             client: ClientInfo(name: "test", version: "0", label: "test"),
                             clock: clock, sockets: sockets.factory, random: { 0.5 })
        notes = []
        control.onNote = { [unowned self] in self.notes.append($0) }
    }

    override func tearDown() async throws {
        control.disconnect()
        await pump()
        control = nil
    }

    private func welcome(id: String, resumed: Bool?) {
        let said = resumed.map { #","resumed":\#($0)"# } ?? ""
        sockets.last.deliver(#"{"type":"welcome","protocol":"rex.control.v1","client":{"id":"\#(id)","reconnect_token":"t"}\#(said)}"#)
    }

    /// The connection is lost and the next attempt's socket is open, waiting for its welcome.
    private func dropAndDial() async {
        let before = sockets.count
        sockets.last.failReceive()
        await pump()
        await clock.advance(by: 1)
        let dialed = await eventually { self.sockets.count == before + 1 }
        XCTAssertTrue(dialed, "no new attempt")
    }

    func testTheClientCountGoesUpOnlyWhenTheServerStartedANewClient() async {
        let control = control!
        Task { @MainActor in try? await control.connect() }
        await pump()
        welcome(id: "client:1", resumed: false)
        await pump()
        XCTAssertEqual(control.state, .connected)
        XCTAssertEqual(control.clientGeneration, 0, "a first welcome continues nothing, so nothing is gone")
        XCTAssertEqual(notes, [])

        await dropAndDial()
        welcome(id: "client:1", resumed: true)
        await pump()
        XCTAssertEqual(control.clientGeneration, 0, "the client goes on: its streams are still there")
        XCTAssertEqual(notes, [.client(continued: true)])

        await dropAndDial()
        welcome(id: "client:2", resumed: false)
        await pump()
        XCTAssertEqual(control.clientGeneration, 1, "the old client left the server")
        XCTAssertEqual(notes, [.client(continued: true), .client(continued: false)])

        await dropAndDial()
        welcome(id: "client:2", resumed: nil)
        await pump()
        XCTAssertEqual(control.clientGeneration, 1, "a server that doesn't say: unknown is not gone")
    }

    func testAnAttachsAnswerEndsTheWaitAndANewClientForgetsWhatWasAttached() async throws {
        let control = control!
        Task { @MainActor in try? await control.connect() }
        await pump()
        welcome(id: "client:1", resumed: false)
        await pump()
        var heard: [Bool] = []
        XCTAssertNotNil(control.whenAttached("session:a") { heard.append($0) })
        Task { @MainActor in _ = try? await control.call("session.attach", ["session_id": "session:a"]) }
        await pump()
        XCTAssertEqual(heard, [], "asked is not attached: only the server's answer counts")
        let request = try XCTUnwrap(sockets.last.sent.last.flatMap { JSONCodec.decode($0) })
        let id = try XCTUnwrap(request.str("id"))
        sockets.last.deliver(#"{"type":"response","id":"\#(id)","payload":{}}"#)
        await pump()
        XCTAssertEqual(heard, [true])
        XCTAssertNil(control.whenAttached("session:a") { heard.append($0) }, "attached now")

        await dropAndDial()
        welcome(id: "client:2", resumed: false)
        await pump()
        XCTAssertNotNil(control.whenAttached("session:a") { heard.append($0) }, "the new client is attached to nothing")
        // Lost again: whoever waits is told, and nothing is left waiting.
        sockets.last.failReceive()
        await pump()
        XCTAssertEqual(heard, [true, false])
        XCTAssertEqual(control.attachWaits.waiting, 0)
    }

    func testTheBackgroundAndAStopEndEveryWait() async {
        let control = control!
        Task { @MainActor in try? await control.connect() }
        await pump()
        welcome(id: "client:1", resumed: false)
        await pump()
        var heard: [Bool] = []
        _ = control.whenAttached("session:a") { heard.append($0) }
        control.enteredBackground()
        XCTAssertEqual(heard, [false], "nothing waits in the background")
        _ = control.whenAttached("session:a") { heard.append($0) }
        control.disconnect()
        XCTAssertEqual(heard, [false, false], "the computer was removed")
        XCTAssertEqual(control.attachWaits.waiting, 0)
    }
}
