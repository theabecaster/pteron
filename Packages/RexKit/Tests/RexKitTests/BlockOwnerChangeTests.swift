import XCTest
@testable import RexKit

/// `block_owner_changed` as the app reads it, and its line in the connection log.
final class BlockOwnerChangeTests: XCTestCase {
    // MARK: The reason tells a take from a handoff

    func testEveryReasonTheServerNamesIsRead() {
        let names = ["create": BlockOwnerChange.Reason.create, "take": .take, "request": .request, "disown": .disown,
                     "lost": .lost, "disconnect": .disconnect, "restore": .restore]
        for (name, reason) in names { XCTAssertEqual(BlockOwnerChange.Reason(name: name), reason, name) }
    }

    func testAReasonThisBuildDoesNotKnowAndNoReasonAreUnknown() {
        XCTAssertEqual(BlockOwnerChange.Reason(name: "something_new"), .unknown)
        XCTAssertEqual(BlockOwnerChange.Reason(name: nil), .unknown)
    }

    func testOnlyATakeAndARequestAreAClientAskingForThePane() {
        for reason in BlockOwnerChange.Reason.allCases {
            XCTAssertEqual(reason.isClaim, reason == .take || reason == .request, "\(reason)")
        }
    }

    func testThePayloadIsRead() throws {
        let change = try XCTUnwrap(BlockOwnerChange(["block_id": "block:1", "owner": "client:b", "previous": "client:a",
                                                     "reason": "lost"]))
        XCTAssertEqual(change, BlockOwnerChange(blockID: "block:1", owner: "client:b", previous: "client:a", reason: .lost))
        // The owner gave the pane up and nobody was in line: no owner, and an older server names no reason.
        let none = try XCTUnwrap(BlockOwnerChange(["block_id": "block:1", "previous": "client:a"]))
        XCTAssertNil(none.owner)
        XCTAssertEqual(none.reason, .unknown)
        XCTAssertNil(BlockOwnerChange(["owner": "client:b"]), "no block, no change")
    }

    func testATakeIsAnotherClientAskingAndGettingThePane() {
        func change(_ owner: String?, _ reason: BlockOwnerChange.Reason) -> BlockOwnerChange {
            BlockOwnerChange(blockID: "block:1", owner: owner, previous: "client:phone", reason: reason)
        }
        XCTAssertTrue(change("client:mac", .take).isTake(from: "client:phone"))
        XCTAssertTrue(change("client:mac", .request).isTake(from: "client:phone"))
        // The pane passed on because this phone dropped, left or gave it up: nobody asked.
        for reason in [BlockOwnerChange.Reason.lost, .disconnect, .disown, .restore, .create, .unknown] {
            XCTAssertFalse(change("client:mac", reason).isTake(from: "client:phone"), "\(reason)")
        }
        XCTAssertFalse(change("client:phone", .take).isTake(from: "client:phone"), "this phone's own take")
        XCTAssertFalse(change(nil, .take).isTake(from: "client:phone"))
    }

    func testWhoAClientIsToThisOne() {
        XCTAssertEqual(BlockOwnerChange.party(nil, me: "client:phone"), .none)
        XCTAssertEqual(BlockOwnerChange.party("client:phone", me: "client:phone"), .me)
        XCTAssertEqual(BlockOwnerChange.party("client:mac", me: "client:phone"), .other)
        XCTAssertEqual(BlockOwnerChange.party("client:mac", me: nil), .other, "an unknown id is nobody's")
    }

    // MARK: The connection log's lines

    func testAnOwnerChangeIsALineOfWordsWithNoID() {
        let lost = BlockOwnerChange(blockID: "block:secret", owner: "client:mac-id", previous: "client:phone-id", reason: .lost)
        let line = ConnectionEvent.owner(lost, me: "client:phone-id")
        XCTAssertEqual(line.summary, "pane owner reason=lost previous=phone owner=other")
        let restore = BlockOwnerChange(blockID: "block:secret", owner: "client:phone-id", previous: "client:mac-id", reason: .restore)
        XCTAssertEqual(ConnectionEvent.owner(restore, me: "client:phone-id").summary,
                       "pane owner reason=restore previous=other owner=phone")
        let gone = BlockOwnerChange(blockID: "block:secret", owner: nil, previous: "client:mac-id", reason: .disown)
        XCTAssertEqual(ConnectionEvent.owner(gone, me: "client:phone-id").summary,
                       "pane owner reason=disown previous=other owner=none")
        for text in [line.summary, "\(line)"] {
            XCTAssertFalse(text.contains("secret"))
            XCTAssertFalse(text.contains("-id"))
        }
    }

    func testEveryReasonHasItsWordInTheLine() {
        for reason in BlockOwnerChange.Reason.allCases {
            let change = BlockOwnerChange(blockID: "b", owner: "o", previous: nil, reason: reason)
            XCTAssertEqual(ConnectionEvent.owner(change, me: nil).summary, "pane owner reason=\(reason) previous=none owner=other")
        }
    }

    func testWhatFitModeDidIsALine() {
        XCTAssertEqual(ConnectionEvent.fit(.takenBack).summary, "pane fit taken back")
        XCTAssertEqual(ConnectionEvent.fit(.givenBack).summary, "pane fit given back")
        for loss in ConnectionEvent.FitLoss.allCases {
            XCTAssertEqual(ConnectionEvent.fit(.lost, loss: loss).summary, "pane fit lost how=\(loss)")
        }
    }

    func testTheLinesReadBackTheSameFromTheirBytes() throws {
        var events = BlockOwnerChange.Reason.allCases.map {
            ConnectionEvent.owner(BlockOwnerChange(blockID: "b", owner: "me", previous: "you", reason: $0), me: "me")
        }
        events += [.fit(.takenBack), .fit(.givenBack), .fit(.lost, loss: .taken)]
        for var e in events {
            e.time = 1_700_000_000_000
            e.server = 42
            let bytes = e.encoded()
            XCTAssertEqual(bytes.count, ConnectionEvent.size)
            XCTAssertEqual(try XCTUnwrap(ConnectionEvent(bytes: bytes)), e)
        }
    }

    func testTheKindsNumbersAreFixed() {
        // The file holds the numbers: a kind added before these must not move them.
        XCTAssertEqual(ConnectionEvent.Kind.owner.rawValue, 40)
        XCTAssertEqual(ConnectionEvent.Kind.fit.rawValue, 41)
    }
}
