import Foundation
import XCTest
import RexKit
@testable import Pteron

/// The floating-window calls against a Rex server in this process (`FakeRexServer`, through the
/// panes tests' rig): what goes on the wire, in which order, and what a server without
/// `session.set_layer_state` leaves.
@MainActor
final class FloatsServerTests: XCTestCase {
    typealias Rig = PanesServerTests.Rig
    static let method = FloatArrange.layerStateMethod

    override func setUp() async throws {
        Notice.shared.plainSeconds = 30
        Notice.shared.dismiss()
    }

    override func tearDown() async throws {
        Notice.shared.dismiss()
        Notice.shared.plainSeconds = 3.5
    }

    func testMinimizeAllSendsEveryLayerInOrderInOneTurn() async throws {
        let rig = try await Rig()
        defer { rig.stop() }
        rig.fake.reply(Self.method, ["revision": 9])
        rig.fake.delay(Self.method, seconds: 0.4)
        await rig.connect()

        let done = Task { await rig.server.minimizeFloats("session:1", ["layer:a", "layer:b", "layer:c"]) }
        // All three are out before the first answer comes back.
        let together = await eventually(seconds: 0.3) { rig.fake.count(Self.method) == 3 }
        XCTAssertTrue(together)
        await done.value
        let calls = rig.fake.calls(Self.method)
        XCTAssertEqual(calls.compactMap { $0.str("layer_id") }, ["layer:a", "layer:b", "layer:c"])
        XCTAssertTrue(calls.allSatisfy { $0.str("state") == "minimized" && $0["focus"] == nil })
        XCTAssertNil(Notice.shared.message)
    }

    func testARefusedMinimizeShowsOneNotice() async throws {
        let rig = try await Rig()
        defer { rig.stop() }
        // Another phone minimized first: the window's last visible pane.
        rig.fake.reply(Self.method, .error(code: "bad_request", status: 400))
        await rig.connect()

        await rig.server.minimizeFloats("session:1", ["layer:a", "layer:b"])

        XCTAssertEqual(rig.fake.count(Self.method), 2)
        XCTAssertTrue(Notice.shared.message?.hasPrefix("Couldn't minimize the floating windows.") == true)
        XCTAssertTrue(rig.server.capabilities.paneSupport.has(.minimize), "a refusal is no missing method")
    }

    func testARaiseFocusesTheLayerThenTheTappedPaneInOrder() async throws {
        let rig = try await Rig()
        defer { rig.stop() }
        rig.fake.reply(Self.method, ["revision": 9])
        rig.fake.reply("session.focus_block", ["revision": 10])
        await rig.connect()

        await rig.server.raiseFloat("session:1", "layer:s", focus: "s2")

        XCTAssertEqual(Array(rig.sent.prefix(2)), [Self.method, "session.focus_block"])
        let raise = try XCTUnwrap(rig.fake.calls(Self.method).first)
        XCTAssertEqual(raise.str("state"), "normal")
        XCTAssertEqual(raise["focus"] as? Bool, true)
        XCTAssertEqual(rig.fake.calls("session.focus_block").first?.str("block_id"), "s2")
    }

    /// A server without `set_layer_state`: the raise says nothing, and from then on the float
    /// commands hide on that connection while every other command stays.
    func testAMissingLayerStateHidesOnlyTheFloatCommandsWithoutANotice() async throws {
        let rig = try await Rig()
        defer { rig.stop() }
        await rig.connect()
        XCTAssertTrue(rig.server.capabilities.paneSupport.has(.raise))

        // The fake answers `method_not_found` for anything it wasn't told.
        await rig.server.raiseFloat("session:1", "layer:f", focus: nil)

        let s = rig.server.capabilities.paneSupport
        XCTAssertFalse(s.has(.raise) || s.has(.minimize) || s.has(.minimizeAll) || s.has(.restore))
        XCTAssertTrue(s.has(.swap) && s.has(.balance) && s.has(.closeOthers) && s.has(.moveToTab))
        XCTAssertEqual(rig.server.keymap.panes, s, "the minimize keys fall through at once")
        XCTAssertNil(Notice.shared.message, "the first failure is silent")
        XCTAssertNil(AppAction.resolve("pane.minimize_floating", nil, panes: s))
    }

    func testARevisionZeroServerGetsNoFloatCommands() async throws {
        let rig = try await Rig(revision: nil)
        defer { rig.stop() }
        await rig.connect()
        let s = rig.server.capabilities.paneSupport
        XCTAssertFalse(s.has(.raise) || s.has(.minimize) || s.has(.restore))
        XCTAssertNil(AppAction.resolve("pane.minimize_all_floating", nil, panes: s))
    }
}

@MainActor
private func eventually(seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}
