import XCTest
@_spi(Bench) @testable import RexKit

/// The benchmark's way to a stream with no server: a scripted link behind the real stream.
@MainActor
final class ScriptedEchoLinkTests: XCTestCase {
    typealias Sink = StreamSnapshotHandoffTests.Sink

    func testAScriptedLinkRunsAStreamWithNoServer() async {
        var waits: [Duration] = []
        let scripted = ScriptedEchoLink(writeDelay: .milliseconds(150)) { waits.append($0) }
        let control = RexControl(address: "http://127.0.0.1:9", client: ClientInfo(name: "test", version: "0", label: "test"))
        let gate = EchoGate()
        let s = scripted.stream(control: control, sessionID: "session:test", blockID: "block:test", echoGate: gate)
        let sink = Sink(), log = SleepLog()
        s.sink = sink
        log.attach(to: s)
        // The stream's echo clock moves 150 ms with each reading: a write leaves, and is answered.
        var now = 100.0
        s.echoNow = {
            now += 0.15
            return now
        }
        s.start()
        _ = await eventually { sink.statuses.last == .live }
        XCTAssertEqual(sink.statuses.last, .live)
        // A pane that just opened holds no key until its screen is current.
        _ = await eventually { !s.isFenced }
        XCTAssertFalse(s.isFenced)
        s.send(text: "l")
        _ = await eventually { gate.roundTrip.samples == 1 }
        s.send(text: "s")
        _ = await eventually { gate.roundTrip.samples == 2 }
        XCTAssertEqual(scripted.written, ["l", "s"])
        XCTAssertEqual(waits, [.milliseconds(150), .milliseconds(150)], "each write is answered after the scripted delay")
        XCTAssertEqual(gate.roundTrip.last ?? 0, 150, accuracy: 0.001, "and is a sample for the gate")
        scripted.deliver(Array("ls".utf8))
        _ = await eventually { sink.calls.contains(.feed(Array("ls".utf8))) }
        XCTAssertTrue(sink.calls.contains(.feed(Array("ls".utf8))), "the data socket carries what the script delivers")
        s.stop()
    }
}
