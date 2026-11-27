import Metal
import Synchronization
import XCTest
@testable import Pteron
@_spi(Bench) @testable import RexKit

/// The off path, through a whole pane: a host, its stream on a scripted link, typing through the
/// keyboard's path and the echoes coming back. On a link the gate calls fast, and with
/// predictions forced off on a slow one, the pane is the pane without predicted echo: nothing
/// listens to its input, no predictor is made, nothing is published, built or copied, the
/// writes are the same bytes, and the frame is the same picture.
@MainActor
final class EchoParityTests: XCTestCase {
    struct Outcome {
        var image: [UInt8]
        var written: [String]
        var screen: [String]
        var observed: Bool
        var predictors: Int
        var publishes: Int
        var builds: Int
        var fills: Int
        var hasBuffers: Bool
        var level: EchoLevel?
    }

    /// The stream's echo clock for a run: each write is timed as the next of `roundTrips`
    /// (seconds), over and over.
    private final class Link {
        var now = 1000.0
        var reads = 0
        let roundTrips: [Double]
        init(_ roundTrips: [Double]) { self.roundTrips = roundTrips }
        /// Read twice for each write: when it leaves, and when it is answered.
        func read() -> Double {
            if reads % 2 == 1 { now += roundTrips[(reads / 2) % roundTrips.count] } else { now += 0.25 }
            reads += 1
            return now
        }
    }

    private var panesBefore = 0

    override func setUp() async throws {
        panesBefore = GhosttyRenderThread.shared.paneCount
    }

    /// The panes of a run are gone when it ends.
    override func tearDown() async throws {
        var turns = 0
        let giveUp = ContinuousClock.now + .seconds(10)
        while GhosttyRenderThread.shared.paneCount > panesBefore, turns < 1500, ContinuousClock.now < giveUp {
            turns += 1
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(GhosttyRenderThread.shared.paneCount, panesBefore, "LEAKCHECK \(name)")
    }

    private func wait(_ what: String, _ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let giveUp = ContinuousClock.now + .seconds(16)
        for _ in 0..<4000 where ContinuousClock.now < giveUp {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("timed out waiting for \(what)", file: file, line: line)
    }

    /// Types `text` into a pane key by key, each echoed by the scripted shell before the next.
    private func run(gate: EchoGate?, roundTrips: [Double], text: String = "echo predicted typing must not change a fast pane") async throws -> Outcome {
        let metal = try XCTUnwrap(GhosttyMetal.shared)
        let scripted = ScriptedEchoLink(writeDelay: .zero) { _ in await Task.yield() }
        let control = RexControl(address: "", client: ClientInfo(name: "test", version: "0", label: "test"))
        let stream = scripted.stream(control: control, sessionID: "s", blockID: "b", echoGate: gate)
        let link = Link(roundTrips)
        stream.echoNow = { link.read() }
        let host = TerminalHost(stream: stream, sizing: .mirror, fontSize: 12, theme: ThemeStore.fallback)
        stream.start()
        await wait("the stream to be live with its fence down") { scripted.isOpen && !stream.isFenced }
        scripted.deliver(Array("$ ".utf8))
        await wait("the prompt") { host.term.core.sync(); return host.term.core.rowText(0) == "$" }

        var typed = ""
        for c in text {
            host.term.insertText(String(c))
            typed.append(c)
            let count = typed.count
            await wait("the write of key \(count)") { scripted.written.count == count && !stream.hasPendingInput }
            scripted.deliver(Array(String(c).utf8))
            let want = ("$ " + typed).trimmingCharacters(in: .whitespaces)
            await wait("the echo of key \(count)") { host.term.core.sync(); return host.term.core.rowText(0) == want }
        }

        let m = host.term.atlas.metrics
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 80 * m.cellWidth, height: 24 * m.cellHeight, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        let texture = try XCTUnwrap(metal.device.makeTexture(descriptor: d))
        XCTAssertTrue(host.term.renderer.renderOffscreen(into: texture, now: 100))
        var image = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        texture.getBytes(&image, bytesPerRow: texture.width * 4, from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        let core = host.term.core
        let outcome = Outcome(image: image, written: scripted.written, screen: (0..<3).map { core.rowText($0) },
                              observed: stream.inputObserver != nil || stream.writeObserver != nil,
                              predictors: core.echo.created.load(ordering: .relaxed), publishes: core.echo.publishes.load(ordering: .relaxed),
                              builds: host.term.renderer.frame.echoBuilds, fills: host.term.renderer.echoFills,
                              hasBuffers: host.term.renderer.hasEchoBuffers, level: gate?.level)
        host.stop()
        return outcome
    }

    private func assertOff(_ o: Outcome, _ reference: Outcome, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(o.observed, "\(what): nothing listens to the pane's input", file: file, line: line)
        XCTAssertEqual(o.predictors, 0, "\(what): no predictor", file: file, line: line)
        XCTAssertEqual(o.publishes, 0, "\(what): nothing published", file: file, line: line)
        XCTAssertEqual(o.builds, 0, "\(what): no echo instance built", file: file, line: line)
        XCTAssertEqual(o.fills, 0, "\(what): no echo buffer filled", file: file, line: line)
        XCTAssertFalse(o.hasBuffers, "\(what): no echo buffer made", file: file, line: line)
        XCTAssertEqual(o.written, reference.written, "\(what): the same writes", file: file, line: line)
        XCTAssertEqual(o.screen, reference.screen, "\(what): the same screen", file: file, line: line)
        XCTAssertTrue(o.image == reference.image, "\(what): the same frame", file: file, line: line)
    }

    func testAFastPaneIsThePaneWithoutPredictedEcho() async throws {
        // The pane as it always was: a stream with no gate.
        let reference = try await run(gate: nil, roundTrips: [0.005])
        XCTAssertEqual(reference.written.joined(), "echo predicted typing must not change a fast pane")
        XCTAssertEqual(reference.predictors, 0)

        // A local link: 5 ms.
        let fast = try await run(gate: EchoGate(), roundTrips: [0.005])
        XCTAssertEqual(fast.level, .off)
        assertOff(fast, reference, "5 ms")

        // Just under the mark, held steady.
        let near = try await run(gate: EchoGate(), roundTrips: [0.059])
        XCTAssertEqual(near.level, .off)
        assertOff(near, reference, "59 ms")

        // 20 ms with one write of 400 ms now and then: a radio waking up is not a slow link.
        let spiky = try await run(gate: EchoGate(), roundTrips: [Double](repeating: 0.02, count: 44) + [0.4])
        XCTAssertEqual(spiky.level, .off)
        assertOff(spiky, reference, "20 ms with a spike")
    }

    /// `-predict never`: the same pane at any speed.
    func testPredictionsForcedOffOnASlowLinkChangeNothing() async throws {
        let reference = try await run(gate: nil, roundTrips: [0.15])
        let gate = EchoGate(forced: .off)
        let never = try await run(gate: gate, roundTrips: [0.15])
        XCTAssertEqual(never.level, .slow, "the samples say slow")
        XCTAssertEqual(gate.effective, .off, "and the level the panes follow is off")
        assertOff(never, reference, "150 ms, forced off")
    }
}
