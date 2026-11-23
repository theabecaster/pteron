import RexKit
import XCTest
@testable import Pteron

/// `FitTenure`: whether a fitted pane lost its size to another client, or only to this phone's
/// own absence.
final class FitTenureTests: XCTestCase {
    private let phone = "client:phone"
    private let mac = "client:mac"

    private func change(_ reason: BlockOwnerChange.Reason, owner: String?, previous: String? = nil) -> BlockOwnerChange {
        BlockOwnerChange(blockID: "block:1", owner: owner, previous: previous, reason: reason)
    }

    /// A tenure whose claim was answered on the first connection.
    private func held() -> FitTenure {
        var t = FitTenure()
        t.claimed(as: 0, welcomes: 0)
        return t
    }

    // MARK: H-10: a take by another client is never taken back

    func testOnAConnectionThatNeverDroppedAnotherClientsSizeIsThatClientsDoing() {
        let t = held()
        XCTAssertEqual(t.verdict(link: .steady, settled: false), .lost)
        XCTAssertEqual(t.verdict(link: .steady, settled: true), .lost)
    }

    func testATakeThatWasHeardIsNeverTakenBackWhateverTheConnectionDid() {
        for reason in [BlockOwnerChange.Reason.take, .request] {
            var t = held()
            t.ownerChanged(change(reason, owner: mac, previous: phone), me: phone)
            XCTAssertTrue(t.taken)
            let links: [FitTenure.Link] = [.steady, .down, .back(sameClient: true), .back(sameClient: false)]
            for link in links {
                XCTAssertEqual(t.verdict(link: link, settled: false), .lost, "\(reason) \(link)")
                XCTAssertEqual(t.verdict(link: link, settled: true), .lost, "\(reason) \(link)")
            }
        }
    }

    func testAContinuedClientThatWasNotGivenThePaneBackLostItToSomebody() {
        // The server gives a continued client its panes back unless their owner changed again
        // while it was away, and only a client's own call changes it then.
        let t = held()
        XCTAssertEqual(t.verdict(link: .back(sameClient: true), settled: true), .lost)
    }

    func testAfterATakeBackTheNextSizeIsAnotherClientsDoing() {
        var t = held()
        XCTAssertEqual(t.verdict(link: .back(sameClient: false), settled: false), .takeBack)
        // The take back's claim was answered on the new connection, as the new client: a new tenure.
        t.released()
        t.claimed(as: 1, welcomes: 1)
        let link = FitTenure.Link.now(welcomes: 1, heldAt: t.heldAt, down: false, client: 1, heldAs: t.heldAs)
        XCTAssertEqual(link, .steady)
        XCTAssertEqual(t.verdict(link: link, settled: false), .lost, "never a second take back")
    }

    // MARK: A pane that passed on because the phone was away is not lost

    func testAContinuedClientsPaneIsNotJudgedWhileItsStreamReplaysTheTimeAway() {
        // The server gave the pane back; the stream shows the other client's size first and
        // this client's own after it.
        let t = held()
        XCTAssertEqual(t.verdict(link: .back(sameClient: true), settled: false), .wait)
    }

    func testAPaneFoundInPlaceAfterTheReturnGoesOnFromThere() {
        var t = held()
        t.settled(as: 0, welcomes: 1)
        let link = FitTenure.Link.now(welcomes: 1, heldAt: t.heldAt, down: false, client: 0, heldAs: t.heldAs)
        XCTAssertEqual(link, .steady)
        XCTAssertEqual(t.verdict(link: link, settled: false), .lost, "a size that turns up later is somebody's")
    }

    func testANewClientTakesThePaneAgain() {
        // Away longer than the server keeps a client: no event can say what happened meanwhile,
        // and the return is a claim moment.
        let t = held()
        XCTAssertEqual(t.verdict(link: .back(sameClient: false), settled: false), .takeBack)
        XCTAssertEqual(t.verdict(link: .back(sameClient: false), settled: true), .takeBack)
    }

    func testAPaneThatPassedOnWithoutAWishIsNoTake() {
        for reason in [BlockOwnerChange.Reason.lost, .disconnect, .disown, .create, .restore, .unknown] {
            var t = held()
            t.ownerChanged(change(reason, owner: mac, previous: phone), me: phone)
            XCTAssertFalse(t.taken, "\(reason)")
        }
    }

    func testThisPhonesOwnTakeEndsATakeHeardBefore() {
        var t = held()
        t.ownerChanged(change(.take, owner: mac, previous: phone), me: phone)
        t.ownerChanged(change(.take, owner: phone, previous: mac), me: phone)
        XCTAssertFalse(t.taken)
    }

    // MARK: H-11: only a pane the user is looking at

    func testOnlyAPaneOnScreenInTheAppInFrontIsTakenBack() {
        func may(window: Bool = true, background: Bool = false, parked: Bool = false, warm: Bool = false, covered: Bool = false) -> Bool {
            FitTenure.mayTakeBack(inWindow: window, background: background, parked: parked, warm: warm, covered: covered)
        }
        XCTAssertTrue(may())
        XCTAssertFalse(may(window: false), "left the screen")
        XCTAssertFalse(may(background: true), "the app is in the background")
        XCTAssertFalse(may(parked: true))
        XCTAssertFalse(may(warm: true))
        XCTAssertFalse(may(covered: true), "under the agent board")
    }

    func testAClaimThatWasGivenUpHoldsNothing() {
        var t = held()
        // The grace ran out, the app went to the background, or the pane stopped.
        t.released()
        XCTAssertFalse(t.holds)
        XCTAssertEqual(t.verdict(link: .back(sameClient: true), settled: false), .lost)
        XCTAssertEqual(t.verdict(link: .back(sameClient: false), settled: true), .lost)
        t.settled(as: 0, welcomes: 1)
        XCTAssertFalse(t.holds, "finding the pane in place claims nothing")
    }

    // MARK: H-12: nothing is decided or sent while the connection is down

    func testWithTheConnectionDownThePaneWaits() {
        let t = held()
        XCTAssertEqual(t.verdict(link: .down, settled: false), .wait)
        XCTAssertEqual(t.verdict(link: .down, settled: true), .wait)
    }

    func testTheLinkIsReadFromTheWelcomesAndTheClient() {
        func link(welcomes: Int, down: Bool = false, client: Int = 3) -> FitTenure.Link {
            .now(welcomes: welcomes, heldAt: 2, down: down, client: client, heldAs: 3)
        }
        XCTAssertEqual(link(welcomes: 2), .steady)
        XCTAssertEqual(link(welcomes: 2, down: true), .down)
        XCTAssertEqual(link(welcomes: 3, down: true), .down, "down wins: the client is not known until the welcome")
        XCTAssertEqual(link(welcomes: 3), .back(sameClient: true))
        XCTAssertEqual(link(welcomes: 3, client: 4), .back(sameClient: false))
        XCTAssertEqual(link(welcomes: 2, client: 4), .steady, "no welcome since the answer: the claim is this client's")
    }
}
