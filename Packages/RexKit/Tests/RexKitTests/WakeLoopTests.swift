import Network
import XCTest
@testable import RexKit

/// The sequence the owner's phone ran for an hour against an overloaded Mac: the connection
/// drops every few seconds, the app goes to the background and comes back, and Try Again brings
/// the control connection back, over and over. Builds 2611201727 and 2611201801 crashed in it
/// when URLSession called a data socket's pong handler a second time (`ResumeOnce`).
@MainActor
final class WakeLoopTests: XCTestCase {
    typealias Sink = StreamSnapshotHandoffTests.Sink

    /// Nothing else owns a stream: its tasks hold it weakly, as in the app.
    private var streams: [TerminalStream] = []

    /// A stream through drops, wakes and Try Again, with every ping answered as URLSession has:
    /// a pong, a failure or nothing first, often a second call at once, and one more call when
    /// the socket ends. Each round ends with the stream live again.
    func testStreamHoldsThroughRepeatedDropsWakesAndTryAgain() async {
        let link = FakeLink()
        let sink = Sink()
        let (stream, log) = makeStream(link: link, sink: sink)
        // The wake's wait for a pong really passes, short: a pong comes on another queue, as
        // URLSession's does, and a skipped wait would beat it.
        stream.wakeTimeout = .milliseconds(100)
        log.real.insert(.milliseconds(100))
        streams.append(stream)
        stream.start()
        let live = await eventually { sink.statuses.last == .live }
        XCTAssertTrue(live)

        let answers: [TwicePongTask.Answer] = [.pong, .fail, .never]
        var replaced = 0
        for round in 0..<150 {
            let socket = link.sockets.last!
            let answer = answers[round % 3], dropped = round % 5 == 1
            socket.pingPlan = .urlSession(first: answer, twice: round % 2 == 0)
            let before = link.sockets.count, pings = socket.pings
            // In the background the network goes, on most rounds.
            if round % 4 != 3 { link.disconnect() }
            // Back in front: the panes ping their sockets.
            stream.wake()
            // The connection drops again while the wake waits, now and then.
            if dropped { socket.drop() }
            // Try Again: the control connection is back.
            link.connect()
            await settle()
            XCTAssertEqual(socket.pings, pings + 1, "round \(round): the wake pinged once")
            // A socket that answered stays; any other is replaced by a RESUME.
            let keeps = answer == .pong && !dropped
            let back = await eventually {
                sink.statuses.last == .live && !stream.waitingForControl
                    && link.sockets.count == before + (keeps ? 0 : 1)
            }
            XCTAssertTrue(back, "round \(round): the stream did not come back \(sink.statuses.suffix(3)) wait=\(stream.waitingForControl) sockets=\(link.sockets.count) before=\(before)")
            if !back { break }
            if !keeps {
                replaced += 1
                XCTAssertTrue(link.sockets.last!.isResume, "round \(round): not resumed")
            }
        }
        await settle()
        XCTAssertEqual(replaced, 110, "every round that should replace its socket did")
        XCTAssertEqual(sink.statuses.last, .live)
        XCTAssertFalse(stream.waitingForControl)
    }

    /// Real URLSession sockets on a server in this process: the control connection and a data
    /// socket through drops, wakes, pings and Try Again. Nothing may crash or hang.
    func testRealSocketsHoldThroughRepeatedDropsWakesAndTryAgain() async throws {
        let server = try ControlReconnectTests.Server()
        let port = await server.start()
        defer { server.stop() }
        let control = RexControl(address: "http://127.0.0.1:\(port)",
                                 client: ClientInfo(name: "test", version: "0", label: "test"))
        var connects = 0
        control.observeConnected { connects += 1; return true }
        defer { control.disconnect() }
        try await control.connect()

        for round in 0..<30 {
            let socket = try control.openDataSocket(subprotocol: "rex.data.terminal.v1")
            // A ping on a live socket, then one in flight as the network goes.
            try? await socket.ping()
            let inFlight = Task { @MainActor in try? await socket.ping() }
            server.dropAll()
            _ = await inFlight.value
            // Back in front, then a ping on the dead socket, as `TerminalStream.wake` sends.
            control.wake()
            try? await socket.ping()
            socket.abort()
            try? await socket.ping()
            // Try Again.
            control.kick()
            let back = await waitFor({ control.state == .connected && connects > round + 1 }, seconds: 10)
            XCTAssertTrue(back, "round \(round): the control connection did not come back")
            if !back { break }
        }
    }

    private func waitFor(_ condition: @MainActor () -> Bool, seconds: Double) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}
