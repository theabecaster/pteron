import XCTest
@testable import RexKit

/// The rules of reconnecting as the app ships them (`ReconnectPolicy.standard`), and the pure
/// decisions: the waits, the kinds of failure, what a request for an attempt gets, the shared
/// budget and the tunnel breaker. A change of strategy changes this file and `ReconnectPolicy`.
final class ReconnectPolicyTests: XCTestCase {
    private let p = ReconnectPolicy.standard

    // MARK: The values in use

    func testTheStandardNumbers() {
        XCTAssertEqual(p.waits, [1, 10, 120, 300])
        XCTAssertTrue(p.fullJitterFirst)
        XCTAssertEqual(p.jitter, 0.2)
        XCTAssertEqual(p.floor, 120)
        XCTAssertEqual(p.attemptsBeforeFloor, 2)
        XCTAssertEqual(p.userSpacing, 10)
        XCTAssertEqual(p.routeSettle, 2)
        XCTAssertEqual(p.dormantAfter, 5)
        XCTAssertEqual(p.dormantInterval, 600)
        XCTAssertEqual([p.budgetAttempts, p.maxInFlight], [2, 2])
        XCTAssertEqual(p.budgetWindow, 100)
        XCTAssertEqual(p.breakerHosts, 2)
        XCTAssertEqual(p.breakerWindow, 30)
        XCTAssertEqual(p.breakerResumeSpacing, 0.5)
        XCTAssertEqual([p.connectDeadline(expensive: false), p.connectDeadline(expensive: true)], [10, 15])
        XCTAssertEqual([p.pongDeadline(expensive: false), p.pongDeadline(expensive: true)], [10, 20])
        XCTAssertEqual([p.wakePongDeadline(expensive: false), p.wakePongDeadline(expensive: true)], [2.5, 5])
        XCTAssertEqual([p.activityTimeout(expensive: false), p.activityTimeout(expensive: true)], [5, 10])
        XCTAssertEqual(p.idlePing, 30)
        XCTAssertFalse(p.worksInBackground)
        XCTAssertTrue(p.retriesAtOnceAfterWake)
    }

    // MARK: The waits (spec test 1)

    func testTheWaitsAndTheirJitterBounds() {
        XCTAssertEqual((1...6).map { p.delay(step: $0) }, [0.5, 10, 120, 300, 300, 300])
        // The first: anywhere from 0 to 1 s.
        XCTAssertEqual([p.delay(step: 1, unit: 0), p.delay(step: 1, unit: 1)], [0, 1])
        // The second: 10 s, a fifth either way.
        XCTAssertEqual([p.delay(step: 2, unit: 0), p.delay(step: 2, unit: 1)], [8, 12])
        // The third: 2 min, and never under it.
        XCTAssertEqual([p.delay(step: 3, unit: 0), p.delay(step: 3, unit: 1)], [120, 144])
        // The fourth and after: 5 min, a fifth either way.
        XCTAssertEqual([p.delay(step: 4, unit: 0), p.delay(step: 9, unit: 1)], [240, 360])
        XCTAssertEqual(p.delay(step: 0), 0.5, "a step below 1 is the first")
        XCTAssertEqual(p.delay(step: 3, unit: -4), 120, "a draw out of range is its nearest end")
    }

    func testNoWaitFromTheThirdOnIsUnderTheFloorWhateverTheNumbers() {
        var odd = ReconnectPolicy()
        odd.waits = [1, 2, 3, 4, 50]
        odd.jitter = 0.9
        for step in 3...12 {
            for unit in stride(from: 0.0, through: 1.0, by: 0.05) {
                XCTAssertGreaterThanOrEqual(odd.delay(step: step, unit: unit), 120)
            }
        }
        XCTAssertLessThan(odd.delay(step: 2, unit: 0), 120, "the second is not held")
    }

    // MARK: Kinds of failure (spec test 9)

    func testWhichFailuresAreSilentAnsweredOrFinal() {
        func url(_ code: URLError.Code, posix: Int32? = nil, http: Int? = nil, close: Int? = nil, reason: String? = nil) -> ConnectionFailure {
            ConnectionFailure(domain: NSURLErrorDomain, code: code.rawValue, message: "x",
                              underlyingDomain: posix == nil ? nil : NSPOSIXErrorDomain, underlyingCode: posix.map(Int.init),
                              httpStatus: http, closeCode: close, closeReason: reason)
        }
        for f in [ConnectionFailure.timedOut(), url(.networkConnectionLost), url(.cannotFindHost),
                  url(.cannotConnectToHost, posix: EHOSTUNREACH), url(.cannotConnectToHost, posix: ETIMEDOUT),
                  url(.notConnectedToInternet)] {
            XCTAssertEqual(p.kind(of: f), .silent, f.detail)
        }
        for f in [url(.cannotConnectToHost, posix: ECONNREFUSED), url(.badServerResponse, http: 502),
                  url(.badServerResponse, http: 503), url(.networkConnectionLost, close: 1001),
                  url(.networkConnectionLost, close: 1008, reason: "event backlog exceeded")] {
            XCTAssertEqual(p.kind(of: f), .answered, f.detail)
        }
        // TLS: tried again on the normal schedule, and final only at the third in a row while
        // another host is connected (a tunnel that is half up fails TLS too).
        for f in [url(.serverCertificateUntrusted), url(.secureConnectionFailed)] {
            XCTAssertEqual(p.kind(of: f), .answered, f.detail)
            XCTAssertEqual(p.kind(of: f, tlsInARow: 1, tunnelWorks: true), .answered)
            XCTAssertEqual(p.kind(of: f, tlsInARow: 2, tunnelWorks: true), .final)
            XCTAssertEqual(p.kind(of: f, tlsInARow: 9, tunnelWorks: false), .answered, "no other host is up: never final")
            XCTAssertTrue(p.isTLS(f))
        }
        XCTAssertEqual(p.tlsFinalAfter, 3)
        for f in [url(.badServerResponse, http: 401), url(.badServerResponse, http: 403), url(.badServerResponse, http: 404),
                  url(.badServerResponse, http: 426),
                  url(.networkConnectionLost, close: 4401),
                  url(.networkConnectionLost, close: 1008, reason: "no common API revision: update the server"),
                  ConnectionFailure.invalidAddress("x")] {
            XCTAssertEqual(p.kind(of: f), .final, f.detail)
        }
    }

    // MARK: The floor (ruling: it counts attempt starts)

    func testTheFloorCountsFromTheStartOfTheAttemptBeforeFromTheThirdOn() {
        XCTAssertEqual(p.untilFloor(attempts: 0, sinceLastAttempt: nil), 0)
        XCTAssertEqual(p.untilFloor(attempts: 1, sinceLastAttempt: 3), 0, "the second follows the first by its 10 s")
        XCTAssertEqual(p.untilFloor(attempts: 2, sinceLastAttempt: 20), 100, "the third: 120 s after the second began")
        XCTAssertEqual(p.untilFloor(attempts: 7, sinceLastAttempt: 119), 1)
        XCTAssertEqual(p.untilFloor(attempts: 7, sinceLastAttempt: 120), 0)
        XCTAssertEqual(p.untilFloor(attempts: 7, sinceLastAttempt: 119.9999), 0, "under a millisecond is now")
    }

    func testOnlyAFreshFailureIsEvidenceAboutTheTunnel() {
        XCTAssertTrue(p.isTunnelEvidence(attempts: 0, dormant: false), "a connection that dropped")
        XCTAssertTrue(p.isTunnelEvidence(attempts: 1, dormant: false))
        XCTAssertTrue(p.isTunnelEvidence(attempts: 2, dormant: false))
        XCTAssertFalse(p.isTunnelEvidence(attempts: 3, dormant: false), "already backing off: nothing new")
        XCTAssertFalse(p.isTunnelEvidence(attempts: 1, dormant: true), "a dormant host timing out again")
    }

    // MARK: A request for an attempt

    private func kick(_ t: AttemptTrigger, connecting: Bool = false, dormant: Bool = false, stopped: Bool = false,
                      held: Bool = false, selected: Bool = false, suspended: Bool = false, path: Bool = true,
                      attempts: Int = 3, since: Double? = 500, user: Double? = nil, network: Double? = nil,
                      left: Double? = nil) -> ReconnectPolicy.Kick {
        p.kick(t, connecting: connecting, dormant: dormant, stopped: stopped, held: held, selected: selected,
               suspended: suspended, pathSatisfied: path, attempts: attempts, sinceLastAttempt: since,
               sinceLastUser: user, sinceLastNetwork: network, dormantLeft: left)
    }

    func testNothingIsAskedInTheBackgroundOrWhileAnAttemptIsUnderWay() {
        for t in AttemptTrigger.allCases {
            XCTAssertEqual(kick(t, suspended: true), .ignore)
            XCTAssertEqual(kick(t, connecting: true), .ignore)
        }
    }

    func testAUserIsAlwaysLetThroughOncePerTenSeconds() {
        XCTAssertEqual(kick(.user, dormant: true, stopped: true, held: true, path: false, since: 0.1), .now)
        XCTAssertEqual(kick(.user, since: nil), .now)
        XCTAssertEqual(kick(.user, since: 4, user: 4), .after(6), "the tap before was 4 s ago")
        XCTAssertEqual(kick(.user, since: 10, user: 10), .now)
        XCTAssertEqual(kick(.user, since: 2, user: nil), .now, "the attempt before was not the user's")
    }

    func testANetworkChangeAsksOnlyPastTheFloor() {
        XCTAssertEqual(kick(.network, since: 119), .ignore)
        XCTAssertEqual(kick(.network, dormant: true, since: 119), .ignore)
        XCTAssertEqual(kick(.network, attempts: 1, since: 5), .ignore, "the floor holds from the first attempt here")
        XCTAssertEqual(kick(.network, since: 120), .budgeted)
        XCTAssertEqual(kick(.network, dormant: true, since: 120), .budgeted)
        XCTAssertEqual(kick(.network, since: nil), .budgeted)
        XCTAssertEqual(kick(.network, stopped: true), .ignore)
        XCTAssertEqual(kick(.network, held: true), .ignore)
        XCTAssertEqual(kick(.network, path: false), .ignore)
    }

    func testANetworkChangeBringsADormantHostForwardOncePerTenMinutes() {
        XCTAssertEqual(kick(.network, dormant: true, since: 130, network: 130), .ignore)
        XCTAssertEqual(kick(.network, dormant: true, since: 130, network: 599), .ignore)
        XCTAssertEqual(kick(.network, dormant: true, since: 130, network: 600), .budgeted)
        XCTAssertEqual(kick(.network, dormant: false, since: 130, network: 130), .budgeted, "a host that is not dormant keeps the floor alone")
    }

    func testTheReturnMovesABackingOffHostForwardSubjectToTheFloor() {
        XCTAssertEqual(kick(.foreground, attempts: 1, since: 3), .budgeted, "before the floor applies")
        XCTAssertEqual(kick(.foreground, attempts: 2, since: 20), .after(100))
        XCTAssertEqual(kick(.foreground, attempts: 4, since: 120), .budgeted)
        XCTAssertEqual(kick(.foreground, held: true), .ignore)
        XCTAssertEqual(kick(.foreground, stopped: true), .ignore)
    }

    func testTheReturnLeavesDormantHostsAloneExceptTheSelectedOne() {
        XCTAssertEqual(kick(.foreground, dormant: true, since: 100, left: 500), .after(500), "what was left of its ten minutes")
        XCTAssertEqual(kick(.foreground, dormant: true, since: 4000, left: 40), .after(40), "time in the background is not counted")
        XCTAssertEqual(kick(.foreground, dormant: true, since: 4000), .after(600), "nothing was kept: a whole interval")
        XCTAssertEqual(kick(.foreground, dormant: true, selected: true, since: 100), .after(20))
        XCTAssertEqual(kick(.foreground, dormant: true, selected: true, since: 130), .budgeted)
    }

    func testAHostTheBreakerLetGoKeepsItsFloorAndTheBudget() {
        XCTAssertEqual(kick(.peer, dormant: true, since: 3), .after(117), "inside its floor: not yet")
        XCTAssertEqual(kick(.peer, attempts: 1, since: 3), .budgeted, "its second attempt: within the budget")
        XCTAssertEqual(kick(.peer, since: 120), .budgeted)
        XCTAssertEqual(kick(.peer, stopped: true), .ignore)
    }

    // MARK: The budget (spec test 4)

    func testTheBudgetGivesTwoAttemptsPerHundredSeconds() {
        var b = AttemptBudget()
        XCTAssertNil(b.take(1, now: 0, policy: p))
        XCTAssertNil(b.take(2, now: 10, policy: p))
        XCTAssertEqual(b.take(3, now: 20, policy: p), 80, "the third waits for the first to be 100 s old")
        XCTAssertEqual(b.take(3, now: 99.5, policy: p), 0.5)
        XCTAssertNil(b.take(3, now: 100, policy: p))
        XCTAssertEqual(b.take(1, now: 105, policy: p), 5)
        // Over an hour, asked every second: 2 per 100 s and no more.
        var busy = AttemptBudget(), granted = 0
        for t in 0..<3600 where busy.take(1, now: Double(t), policy: p) == nil { granted += 1 }
        XCTAssertEqual(granted, 72)
    }

    func testAWelcomeGivesTheBudgetItsAttemptsBack() {
        var b = AttemptBudget()
        XCTAssertNil(b.take(1, now: 0, policy: p))
        XCTAssertNil(b.take(2, now: 1, policy: p))
        XCTAssertNotNil(b.take(3, now: 2, policy: p))
        b.forget(2)
        XCTAssertNil(b.take(3, now: 2, policy: p), "host 2 answered: its attempt was not to a host that is down")
        XCTAssertNotNil(b.take(1, now: 3, policy: p))
    }

    // MARK: The breaker (spec test 5)

    func testTwoHostsSilentWithinThirtySecondsOpenTheBreakerAndAnAnswerClosesIt() {
        var b = TunnelBreaker()
        XCTAssertFalse(b.failedSilently(1, now: 0, policy: p) { [1] })
        XCTAssertFalse(b.failedSilently(1, now: 5, policy: p) { [1] }, "the same host twice is one host")
        XCTAssertFalse(b.isOpen)
        XCTAssertFalse(b.failedSilently(2, now: 36, policy: p) { [1, 2] }, "31 s apart: two separate hosts")
        XCTAssertTrue(b.failedSilently(3, now: 50, policy: p) { [2, 3, 1] })
        XCTAssertEqual(b.testHost, 2, "the first in order")
        XCTAssertTrue(b.allows(2))
        XCTAssertFalse(b.allows(1))
        XCTAssertFalse(b.allows(3))
        XCTAssertFalse(b.failedSilently(1, now: 51, policy: p) { [1] }, "open already")
        XCTAssertEqual(b.testHost, 2)
        XCTAssertTrue(b.answered(2))
        XCTAssertFalse(b.isOpen)
        XCTAssertTrue(b.allows(1))
        XCTAssertFalse(b.answered(1), "nothing to close")
        XCTAssertFalse(b.failedSilently(1, now: 60, policy: p) { [1] }, "the count started over at the answer")
    }

    func testTheHostsTakeTurnsInOrderRoundAfterRound() {
        var b = TunnelBreaker()
        _ = b.failedSilently(1, now: 0, policy: p) { [1, 2, 3] }
        _ = b.failedSilently(2, now: 1, policy: p) { [1, 2, 3] }
        XCTAssertEqual(b.testHost, 1)
        XCTAssertEqual(b.nextTurn(order: [1, 2, 3]), 2)
        XCTAssertEqual(b.nextTurn(order: [1, 2, 3]), 3, "not back to the first: every host gets its turn")
        XCTAssertEqual(b.nextTurn(order: [1, 2, 3]), 1, "a new round")
        XCTAssertEqual(b.nextTurn(order: [3, 1]), 3, "host 2 is gone, and the order changed")
        XCTAssertEqual(b.nextTurn(order: [3]), 3, "the only one left keeps the turn")
        XCTAssertTrue(b.give(1))
        XCTAssertEqual(b.testHost, 1, "the turn was given out of order")
        XCTAssertNil(b.nextTurn(order: []), "no host left to try")
        XCTAssertFalse(b.isOpen)
        XCTAssertFalse(b.give(1), "nothing to give while it is closed")
    }

    // MARK: The route (ruling: a real change of route)

    func testWhatCountsAsAChangeOfRoute() {
        let wifi = PathFacts(satisfied: true, interface: .wifi, tunnel: ["a"])
        var same = wifi
        same.expensive = true
        XCTAssertFalse(same.isRouteChange(from: wifi), "cost alone is no change of route")
        XCTAssertTrue(PathFacts(satisfied: true, interface: .cellular, tunnel: ["a"]).isRouteChange(from: wifi))
        XCTAssertTrue(PathFacts(satisfied: true, interface: .wifi, tunnel: ["b"]).isRouteChange(from: wifi), "another tunnel")
        XCTAssertTrue(PathFacts(satisfied: true, interface: .wifi, tunnel: []).isRouteChange(from: wifi), "the tunnel went")
        let none = PathFacts(satisfied: false, interface: .none)
        XCTAssertFalse(none.isRouteChange(from: wifi), "no path: nothing to try on")
        XCTAssertTrue(wifi.isRouteChange(from: none), "a path after none")
        XCTAssertFalse(wifi.isRouteChange(from: wifi))
    }
}
