import XCTest
@testable import RelayCore

final class PolicyTests: XCTestCase {
    let ref = BlockRef(server: "https://rex.example.ts.net", sessionID: "session:s1", blockID: "block:b1")
    let other = BlockRef(server: "https://rex.example.ts.net", sessionID: "session:s1", blockID: "block:b2")
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }

    func status(_ state: String, msg: String? = nil, id: String = "", on r: BlockRef? = nil) -> RelayEvent {
        .status(r ?? ref, StatusReport(recordID: id, state: state, kind: "question", app: "claude", msg: msg))
    }

    func intent(_ d: Decision) -> PushIntent? {
        if case .push(let i) = d { return i }
        return nil
    }

    func testBlockedPushes() {
        var p = PushPolicy()
        let i = intent(p.decide(status("blocked", msg: "Which DB?"), now: t0))
        XCTAssertEqual(i?.category, .blocked)
        XCTAssertEqual(i?.agent, "claude")
        XCTAssertEqual(i?.text, "Which DB?")
        XCTAssertEqual(i?.blockedKind, "question")
    }

    func testRepeatedBlockedReportIsDropped() {
        var p = PushPolicy()
        _ = p.decide(status("blocked", msg: "Q"), now: t0)
        XCTAssertEqual(p.decide(status("blocked", msg: "Q"), now: at(5)), .drop("repeat report"))
        // Same report much later is still the same blocked state.
        XCTAssertEqual(p.decide(status("blocked", msg: "Q"), now: at(500)), .drop("repeat report"))
    }

    func testFlappingIsDeferredToOneTrailingPush() {
        var p = PushPolicy(debounce: 30)
        XCTAssertNotNil(intent(p.decide(status("blocked", msg: "Q1"), now: t0)))
        _ = p.decide(status("working"), now: at(3))
        XCTAssertEqual(p.decide(status("blocked", msg: "Q2"), now: at(5)), .deferred(until: at(30)))
        XCTAssertEqual(p.nextDue, at(30))
        XCTAssertTrue(p.due(now: at(29)).isEmpty)
        let trailing = p.due(now: at(30))
        XCTAssertEqual(trailing.count, 1)
        XCTAssertEqual(trailing.first?.text, "Q2")
        XCTAssertNil(p.nextDue)
    }

    func testTrailingPushCancelledWhenUnblocked() {
        var p = PushPolicy(debounce: 30)
        _ = p.decide(status("blocked", msg: "Q1"), now: t0)
        _ = p.decide(status("working"), now: at(2))
        _ = p.decide(status("blocked", msg: "Q2"), now: at(4))
        _ = p.decide(status("working"), now: at(6))
        XCTAssertTrue(p.due(now: at(31)).isEmpty)
    }

    func testBlockedAgainAfterWindowPushesImmediately() {
        var p = PushPolicy(debounce: 30)
        _ = p.decide(status("blocked", msg: "Q1"), now: t0)
        _ = p.decide(status("working"), now: at(10))
        XCTAssertNotNil(intent(p.decide(status("blocked", msg: "Q2"), now: at(31))))
    }

    func testDebounceIsPerBlock() {
        var p = PushPolicy()
        XCTAssertNotNil(intent(p.decide(status("blocked", msg: "Q"), now: t0)))
        XCTAssertNotNil(intent(p.decide(status("blocked", msg: "Q", on: other), now: at(1))))
    }

    func testDoneAndErrorArePassiveDonePushes() {
        var p = PushPolicy()
        _ = p.decide(status("working"), now: t0)
        let done = intent(p.decide(status("done", msg: "All good"), now: at(1)))
        XCTAssertEqual(done?.category, .done)
        XCTAssertEqual(done?.state, "done")
        XCTAssertEqual(p.decide(status("done", msg: "All good"), now: at(2)), .drop("repeat report"))
        let err = intent(p.decide(status("error", msg: "boom"), now: at(3)))
        XCTAssertEqual(err?.state, "error")
        let m = PushMessage.compose(err!, context: BlockContext(tabLabel: "api"))
        XCTAssertEqual(m.interruptionLevel, "passive")
        XCTAssertFalse(m.sound)
        XCTAssertEqual(m.body, "Error: boom")
    }

    func testDoneFlapWithinWindowIsDropped() {
        var p = PushPolicy(debounce: 30)
        XCTAssertNotNil(intent(p.decide(status("done"), now: t0)))
        _ = p.decide(status("working"), now: at(2))
        XCTAssertEqual(p.decide(status("done"), now: at(4)), .drop("debounced"))
        _ = p.decide(status("working"), now: at(40))
        XCTAssertNotNil(intent(p.decide(status("done"), now: at(41))))
    }

    func testWorkingAndIdleNeverPush() {
        var p = PushPolicy()
        XCTAssertEqual(p.decide(status("working"), now: t0), .drop("not notable"))
        XCTAssertEqual(p.decide(status("idle"), now: t0), .drop("not notable"))
    }

    func testClearedRecordForgetsState() {
        var p = PushPolicy()
        _ = p.decide(status("blocked", msg: "Q", id: "a"), now: t0)
        _ = p.decide(.statusRemoved(ref, ids: ["a"]), now: at(40))
        XCTAssertNotNil(intent(p.decide(status("blocked", msg: "Q", id: "a"), now: at(41))))
    }

    func testNotificationsDeduped() {
        var p = PushPolicy(debounce: 30)
        let n = RelayEvent.notification(ref, title: nil, body: "Build finished")
        XCTAssertEqual(intent(p.decide(n, now: t0))?.category, .notice)
        XCTAssertEqual(p.decide(n, now: at(5)), .drop("duplicate notification"))
        XCTAssertNotNil(intent(p.decide(.notification(ref, title: nil, body: "Other"), now: at(6))))
        XCTAssertNotNil(intent(p.decide(n, now: at(31))))
    }

    func testRateLimiter() {
        var r = RateLimiter(capacity: 3, perMinute: 6)
        XCTAssertTrue(r.allow("d", now: t0))
        XCTAssertTrue(r.allow("d", now: t0))
        XCTAssertTrue(r.allow("d", now: t0))
        XCTAssertFalse(r.allow("d", now: t0))
        XCTAssertTrue(r.allow("other", now: t0))
        XCTAssertFalse(r.allow("d", now: at(5)))
        XCTAssertTrue(r.allow("d", now: at(10)))   // 6/min refills one every 10 s
    }

    func testStatusReportParsing() {
        let e: JSONObject = ["id": "", "reason": "report",
                             "record": ["state": "blocked", "kind": "permission", "app": "claude",
                                        "effective_app": "claude", "msg": "Allow?", "updated_at": "2026-11-16T00:00:00Z"]]
        let r = StatusReport(event: e)
        XCTAssertEqual(r?.state, "blocked")
        XCTAssertEqual(r?.kind, "permission")
        XCTAssertEqual(r?.msg, "Allow?")
        XCTAssertNil(StatusReport(event: ["id": ""]))
    }
}

final class PushMessageTests: XCTestCase {
    let ref = BlockRef(server: "https://rex.example.ts.net", sessionID: "session:s1", blockID: "block:01a1-b1")

    func testBlockedPayload() {
        let i = PushIntent(category: .blocked, ref: ref, state: "blocked", recordID: "", blockedKind: "question",
                           agent: "claude", text: "Which DB?")
        let m = PushMessage.compose(i, context: BlockContext(windowID: "window:w1", tabLabel: "api", sessionLabel: "work"))
        XCTAssertEqual(m.title, "Claude · api")
        XCTAssertEqual(m.subtitle, "work")
        XCTAssertEqual(m.priority, 10)
        let p = m.payload
        let aps = p["aps"] as? JSONObject
        XCTAssertEqual(aps?["interruption-level"] as? String, "time-sensitive")
        XCTAssertEqual(aps?["thread-id"] as? String, "block:01a1-b1")
        XCTAssertEqual(aps?["category"] as? String, "AGENT_BLOCKED")
        XCTAssertEqual(aps?["sound"] as? String, "default")
        XCTAssertEqual((aps?["alert"] as? JSONObject)?["body"] as? String, "Which DB?")
        XCTAssertEqual(p["server"] as? String, "https://rex.example.ts.net")
        XCTAssertEqual(p["session_id"] as? String, "session:s1")
        XCTAssertEqual(p["window_id"] as? String, "window:w1")
        XCTAssertEqual(p["block_id"] as? String, "block:01a1-b1")
        XCTAssertLessThanOrEqual(m.collapseID!.utf8.count, 64)
    }

    func testBlockedFallbackText() {
        let i = PushIntent(category: .blocked, ref: ref, blockedKind: "permission")
        let m = PushMessage.compose(i, context: BlockContext(blockLabel: "codex"))
        XCTAssertEqual(m.title, "Codex · Rex")
        XCTAssertEqual(m.body, "Needs your permission")
    }

    func testNoticeUsesGivenTitleOrTab() {
        let n = PushMessage.compose(PushIntent(category: .notice, ref: ref, headline: "Deploy", text: "Live"),
                                    context: BlockContext(tabLabel: "ops"))
        XCTAssertEqual(n.title, "Deploy")
        XCTAssertEqual(n.body, "Live")
        XCTAssertEqual(n.interruptionLevel, "active")
        XCTAssertEqual((n.payload["aps"] as? JSONObject)?["category"] as? String, "NOTICE")
        let osc9 = PushMessage.compose(PushIntent(category: .notice, ref: ref, text: "Done"), context: BlockContext(tabLabel: "ops"))
        XCTAssertEqual(osc9.title, "ops")
    }

    func testDonePayloadIsPassive() {
        let m = PushMessage.compose(PushIntent(category: .done, ref: ref, state: "done", agent: "claude"),
                                    context: BlockContext(tabLabel: "api"))
        let aps = m.payload["aps"] as? JSONObject
        XCTAssertEqual(aps?["interruption-level"] as? String, "passive")
        XCTAssertEqual(aps?["category"] as? String, "AGENT_DONE")
        XCTAssertNil(aps?["sound"])
        XCTAssertEqual(m.priority, 5)
        XCTAssertEqual(m.body, "Finished")
    }

    func testLongBodyClipped() {
        let m = PushMessage.compose(PushIntent(category: .notice, ref: ref, text: String(repeating: "x", count: 5000)),
                                    context: BlockContext())
        XCTAssertEqual(m.body.count, 1000)
        XCTAssertLessThan(m.payloadData.count, 4096)
    }
}
