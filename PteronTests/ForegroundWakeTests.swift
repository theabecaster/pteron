import Foundation
import Testing
@testable import Pteron

/// A drop around a trip to the background is waking up, held for a few seconds; a clear answer or
/// the end of the grace shows it.
struct ForegroundWakeTests {
    private let net = NetworkSnapshot(reachable: true, onPrivateNetwork: true)
    private let noNet = NetworkSnapshot(reachable: false, onPrivateNetwork: false)
    private let grace = ForegroundWake.grace

    /// Backgrounded while online, back at t = 100.
    private func woken() -> ForegroundWake {
        var w = ForegroundWake()
        w.enteredBackground(online: true)
        let r1 = w.enteredForeground(now: 100)
        #expect(r1)
        return w
    }

    @Test func dropsShowAsUsualWhenAwake() {
        var w = ForegroundWake()
        #expect(!w.holds)
        let r2 = w.failure(.notAnswering, answered: false, network: net, now: 0)
        #expect(r2 == .show)
    }

    @Test func aDropInTheBackgroundIsHeldUntilTheReturn() {
        var w = ForegroundWake()
        w.enteredBackground(online: true)
        let r3 = w.failure(.offPrivateNetwork, answered: false, network: net, now: 5)
        #expect(r3 == .hold)
        let r4 = w.failure(.noInternet, answered: false, network: noNet, now: 6)
        #expect(r4 == .hold, "nobody sees it yet")
        #expect(w.holds)
    }

    @Test func wakingThenConnectedShowsNothing() {
        var w = woken()
        #expect(w.deadline == 100 + grace)
        let r5 = w.failure(.offPrivateNetwork, answered: false, network: net, now: 100.1)
        #expect(r5 == .hold)
        let r6 = w.failure(.notAnswering, answered: false, network: net, now: 101)
        #expect(r6 == .hold)
        w.connected()
        #expect(!w.holds)
        let r7 = w.expire(now: 100 + grace)
        #expect(!r7, "nothing is left to show")
    }

    @Test func onCellularTheHoldIsEightSecondsAndOnWiFiFiveAsBefore() {
        #expect(ForegroundWake.grace == 5)
        #expect(ForegroundWake.grace(expensive: false) == 5)
        #expect(ForegroundWake.grace(expensive: true) == 8)
        var w = ForegroundWake()
        w.enteredBackground(online: true)
        let began = w.enteredForeground(now: 100, expensive: true)
        #expect(began)
        #expect(w.deadline == 108)
        let held = w.failure(.notAnswering, answered: false, network: net, now: 105.5)
        #expect(held == .hold, "past the Wi-Fi hold, inside the cellular one")
        let early = w.expire(now: 107.9)
        #expect(!early)
        let ended = w.expire(now: 108)
        #expect(ended)
        // A clear answer still ends it at once.
        var c = ForegroundWake()
        c.enteredBackground(online: true)
        _ = c.enteredForeground(now: 100, expensive: true)
        let clear = c.failure(.noInternet, answered: false, network: noNet, now: 101)
        #expect(clear == .show)
    }

    @Test func wakingThatOutlastsTheGraceShows() {
        var w = woken()
        let r8 = w.failure(.offPrivateNetwork, answered: false, network: net, now: 101)
        #expect(r8 == .hold)
        let r9 = w.expire(now: 100 + grace - 0.1)
        #expect(!r9)
        #expect(w.holds)
        let r10 = w.expire(now: 100 + grace)
        #expect(r10)
        #expect(!w.holds)
        // From then on drops show as usual.
        let r11 = w.failure(.offPrivateNetwork, answered: false, network: net, now: 106)
        #expect(r11 == .show)
    }

    @Test func aFailureAfterTheDeadlineShowsEvenBeforeTheTimer() {
        var w = woken()
        let r12 = w.failure(.notAnswering, answered: false, network: net, now: 100 + grace + 0.01)
        #expect(r12 == .show)
        #expect(!w.holds)
    }

    @Test func noNetworkShowsAtOnce() {
        var w = woken()
        let r13 = w.failure(.offPrivateNetwork, answered: false, network: noNet, now: 100.2)
        #expect(r13 == .show)
        var v = woken()
        let r14 = v.failure(.noInternet, answered: false, network: net, now: 100.2)
        #expect(r14 == .show, "a decisive kind")
    }

    @Test func losingTheNetworkWhileWakingEndsTheHold() {
        var w = woken()
        let r15 = w.networkChanged(net)
        #expect(!r15)
        #expect(w.holds)
        let r16 = w.networkChanged(noNet)
        #expect(r16)
        #expect(!w.holds)
        var awake = ForegroundWake()
        let r17 = awake.networkChanged(noNet)
        #expect(!r17, "only a hold ends")
    }

    @Test func aServerThatRefusesShowsAtOnce() {
        var w = woken()
        let r18 = w.failure(.notAnswering, answered: true, network: net, now: 100.3)
        #expect(r18 == .show)
        var v = woken()
        let r19 = v.failure(.notAllowed, answered: true, network: net, now: 100.3)
        #expect(r19 == .show)
        var u = woken()
        let r20 = u.failure(.insecure, answered: false, network: net, now: 100.3)
        #expect(r20 == .show)
    }

    @Test func aServerAlreadyOfflineGetsNoHold() {
        var w = ForegroundWake()
        w.enteredBackground(online: false)
        #expect(!w.holds)
        let r21 = w.enteredForeground(now: 100)
        #expect(!r21, "its offline screen stays")
    }

    @Test func aReturnWithoutABackgroundIsNotAWake() {
        var w = ForegroundWake()
        let r22 = w.enteredForeground(now: 100)
        #expect(!r22)
        #expect(!w.holds)
    }

    @Test func aConnectWhileStillInTheBackgroundKeepsTheHold() {
        var w = ForegroundWake()
        w.enteredBackground(online: true)
        w.connected()
        #expect(w.state == .background, "the next drop, as the app suspends, is still held")
    }
}
