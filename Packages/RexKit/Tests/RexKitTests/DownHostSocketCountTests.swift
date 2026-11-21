import XCTest
@testable import RexKit

/// Everything that could open a socket to a host, counted, while the host is down: its control
/// connection, three panes' terminal streams, a port tunnel's dial and the Ports list's reads.
/// Only the control connection may ask a host that is down, on its schedule; the rest wait for
/// its welcome.
@MainActor
final class DownHostSocketCountTests: XCTestCase {
    /// The control connection as the streams, the tunnel and the transfers see it, with every
    /// request that reached the socket and every data socket asked for counted.
    @MainActor
    final class CountingLink: StreamLink {
        let control: RexControl
        private(set) var dataSockets = 0
        private(set) var callsSent = 0
        private(set) var callsRefused = 0

        init(_ control: RexControl) { self.control = control }

        var isConnected: Bool { control.isConnected }
        var clientID: String? { control.clientID }
        func observeConnected(_ body: @escaping @MainActor () -> Bool) { control.observeConnected(body) }

        func call(_ method: String, _ payload: JSONObject?) async throws -> JSONObject {
            do {
                let r = try await control.call(method, payload)
                callsSent += 1
                return r
            } catch {
                if (error as? RexError)?.neverSent == true { callsRefused += 1 } else { callsSent += 1 }
                throw error
            }
        }

        func openDataSocket(subprotocol: String) throws -> any StreamSocket {
            dataSockets += 1
            throw RexError.local("a data socket was asked for while the host is down")
        }
    }

    func testAHostDownForAnHourGetsOnlyTheSchedulesAttemptsFromEveryPathTogether() async {
        let clock = FakeControlClock()
        clock.yields = 40
        let sockets = FakeControlSockets()
        let control = RexControl(address: "https://desk.example.ts.net",
                                 client: ClientInfo(name: "test", version: "0", label: "test"),
                                 clock: clock, sockets: sockets.factory, random: { 0.5 })
        defer { control.disconnect() }
        let link = CountingLink(control)

        // Three panes of the host: their streams are started and wait for the control connection.
        var streams: [TerminalStream] = []
        var logs: [SleepLog] = []
        for n in 0..<3 {
            let s = TerminalStream(control: control, link: link, sessionID: "session:1", blockID: "block:\(n)")
            s.sink = StreamSnapshotHandoffTests.Sink()
            let log = SleepLog()
            log.attach(to: s)
            logs.append(log)
            streams.append(s)
            s.start()
        }
        Task { @MainActor in try? await control.connect() }
        await pump()

        /// What the app does with a host on screen, once a minute: the panes are woken and typed
        /// into, a page asks the tunnel to dial, and the Ports list reads.
        func poke() async {
            for s in streams {
                s.wake()
                _ = s.send(text: "x")
            }
            _ = try? await link.call("data.connect", ["session_id": "session:1", "block_id": "block:0", "port": 3000])
            _ = try? await link.call("terminal.ports", ["session_id": "session:1", "block_id": "block:0"])
            await pump(40)
        }

        // One hour in the foreground. The host never answers: every attempt runs into its deadline.
        for _ in 0..<60 {
            await poke()
            await clock.advance(by: 60)
        }
        XCTAssertEqual(sockets.count, 10, "the control connection's schedule: five attempts, then one per ten minutes")
        XCTAssertEqual(link.dataSockets, 0, "no terminal, tunnel or file socket")
        XCTAssertEqual(link.callsSent, 0, "no request reached a socket")
        XCTAssertGreaterThan(link.callsRefused, 100, "they were refused before the socket")
        XCTAssertTrue(control.dormant)

        // One hour in the background, with the same things asked: nothing at all.
        control.enteredBackground()
        for _ in 0..<60 {
            await poke()
            await clock.advance(by: 60)
        }
        XCTAssertEqual(sockets.count, 10, "no control attempt in the background")
        XCTAssertEqual(link.dataSockets, 0)
        XCTAssertEqual(link.callsSent, 0)
        for s in streams { s.stop() }
        _ = logs
    }

    /// The gate is at the stream itself: with the control connection down, a stream asks for no
    /// data socket even when its start is forced.
    func testAStreamAsksForNoDataSocketWithoutTheWelcome() async {
        let control = RexControl(address: "https://desk.example.ts.net",
                                 client: ClientInfo(name: "test", version: "0", label: "test"),
                                 clock: FakeControlClock(), sockets: FakeControlSockets().factory)
        let link = CountingLink(control)
        let s = TerminalStream(control: control, link: link, sessionID: "session:1", blockID: "block:0")
        s.sink = StreamSnapshotHandoffTests.Sink()
        SleepLog().attach(to: s)
        s.start()
        for _ in 0..<20 {
            s.restart()
            s.wake()
            await pump(40)
        }
        XCTAssertEqual(link.dataSockets, 0)
        XCTAssertEqual(link.callsSent, 0)
        s.stop()
    }
}
