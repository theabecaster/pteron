import CryptoKit
import Foundation
import Testing
import RexKit
@testable import Pteron

/// Signing the phone up for notifications: what goes to the gateway and to each helper, counted
/// at stand-ins for both, with time moved by hand.
@MainActor
struct PushReconcilerTests {
    private let studio = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let laptop = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    /// A world with one or two computers, each with a helper.
    private func world(two: Bool = false) -> PushWorld {
        let w = PushWorld()
        w.helpers.add(studio, name: "Studio")
        if two { w.helpers.add(laptop, name: "Laptop") }
        return w
    }

    /// A world whose computers are signed up.
    private func signedUp(two: Bool = false) async -> (PushWorld, PushReconciler) {
        let w = world(two: two)
        let r = w.reconciler()
        for id in w.helpers.computers { await r.run(id) }
        return (w, r)
    }

    private func secret(_ w: PushWorld, _ id: UUID) -> ServerPush? { w.store.value?.servers[id.uuidString] }

    // MARK: The first sign-up

    @Test func theFirstSignUpIsOneDeviceAndOneSecretForEachComputer() async throws {
        let w = world(two: true)
        let r = w.reconciler()
        // Both computers connect at the same moment.
        r.reconcileAll()
        await w.eventually { w.helpers[studio].secret != nil && w.helpers[laptop].secret != nil }
        let record = try #require(w.store.value)
        #expect(w.gateway.lines.sorted() == ["PUT /v1/devices/\(record.device)",
                                             "PUT /v1/devices/\(record.device)/secrets/\(secret(w, laptop)?.secretID ?? "")",
                                             "PUT /v1/devices/\(record.device)/secrets/\(secret(w, studio)?.secretID ?? "")"].sorted())
        #expect(w.gateway.made == 1 && w.gateway.devices.count == 1)
        // The phone chose the key, the id that belongs to it, and both secrets.
        #expect(record.ownerKey.count == 43 && record.device == GatewayStandIn.deviceID(for: record.ownerKey))
        #expect(record.unconfirmed == nil && record.token == PushWorld.token && record.environment == "sandbox")
        for id in [studio, laptop] {
            let entry = try #require(secret(w, id))
            #expect(entry.secretID?.count == 16 && entry.pushSecret?.count == 43 && entry.unconfirmed == nil)
            #expect(entry.helperKey == w.helpers[id].publicKey)
            #expect(w.helpers[id].secret == entry.pushSecret && !w.helpers[id].paused)
            #expect(w.helpers[id].count("register_push") == 1)
            #expect(r.helpers[id] == .running(pushEnabled: true))
        }
        #expect(secret(w, studio)?.pushSecret != secret(w, laptop)?.pushSecret)
        #expect(w.prefs.helperSeen == [studio, laptop])
    }

    @Test func aReconcileWithNothingWrongAsksNothingAndWritesNothing() async {
        let (w, r) = await signedUp(two: true)
        let requests = w.gateway.seen.count, saves = w.store.saves
        let calls = w.helpers[studio].calls.count + w.helpers[laptop].calls.count
        r.reconcileAll()
        r.cameToFront()
        await r.run(studio)
        await r.run(laptop, by: .person)
        await w.quiet()
        #expect(w.gateway.seen.count == requests && w.store.saves == saves)
        #expect(w.helpers[studio].calls.count + w.helpers[laptop].calls.count == calls)

        // A new connection asks the helper again, and still nothing of the gateway or the store.
        w.helpers[studio].serial = 2
        await r.run(studio)
        #expect(w.gateway.seen.count == requests && w.store.saves == saves)
        #expect(w.helpers[studio].count("register_push") == 2)
    }

    @Test func aNewAddressIsOneRequestAndTheSecretsStay() async {
        let (w, r) = await signedUp(two: true)
        let before = w.gateway.seen.count
        let registers = w.helpers[studio].count("register_push")
        w.token = String(repeating: "cd", count: 32)
        r.reconcileAll()
        await w.eventually { w.store.value?.token == w.token }
        await w.quiet()
        #expect(w.gateway.seen.count == before + 1)
        #expect(w.gateway.seen.last?.body == ["apns_token": w.token, "environment": "sandbox"])
        #expect(w.gateway.devices.values.first?.token == w.token && w.gateway.made == 1)
        #expect(w.helpers[studio].count("register_push") == registers)
    }

    // MARK: Requests that are sent again

    @Test func aLostAnswerToTheDeviceRequestIsFollowedByTheSameRequest() async throws {
        let w = world()
        let r = w.reconciler()
        w.gateway.turns = [.loseAnswer]
        await r.run(studio)
        await w.eventually { w.helpers[studio].secret != nil }
        let first = try #require(w.gateway.seen.first), second = w.gateway.seen[1]
        #expect(first.line == second.line && first.bearer == second.bearer && first.body == second.body)
        #expect(w.gateway.made == 1 && w.gateway.devices.count == 1)
        #expect(w.store.value?.unconfirmed == nil)
        // One wait between the two, the first of the backoff.
        #expect(w.clock.sleeps == [2])
    }

    @Test func anAppClosedBeforeTheDeviceAnswerSendsTheSameRequest() async throws {
        let w = world()
        w.clock.passes = false
        w.gateway.turns = [.loseAnswer]
        var first: PushReconciler? = w.reconciler()
        await first?.run(studio)
        // The key and the id were written before the request, and are not confirmed.
        let written = try #require(w.store.value)
        #expect(written.unconfirmed == true && written.device == w.gateway.seen[0].path.split(separator: "/").last.map(String.init))
        first = nil

        let second = w.reconciler()
        await second.run(studio)
        #expect(w.gateway.seen[0].line == w.gateway.seen[1].line && w.gateway.seen[0].bearer == w.gateway.seen[1].bearer)
        #expect(w.gateway.made == 1 && w.gateway.devices.count == 1)
        #expect(w.store.value?.device == written.device && w.store.value?.ownerKey == written.ownerKey)
        #expect(w.helpers[studio].secret != nil)
        w.clock.release()
    }

    @Test func aLostAnswerToTheSecretRequestIsFollowedByTheSameRequest() async throws {
        let w = world()
        let r = w.reconciler()
        w.gateway.turns = [.answer, .loseAnswer]
        await r.run(studio)
        await w.eventually { w.helpers[studio].secret != nil }
        #expect(w.gateway.seen.count == 3)
        let first = w.gateway.seen[1], second = w.gateway.seen[2]
        #expect(first.line.contains("/secrets/") && first.line == second.line && first.body == second.body)
        #expect(w.gateway.devices.values.first?.secrets.count == 1 && w.gateway.made == 1)
        #expect(w.helpers[studio].secret == first.body["push_secret"])
    }

    @Test func anAppClosedBeforeTheSecretAnswerSendsTheSameRequest() async throws {
        let w = world()
        w.clock.passes = false
        w.gateway.turns = [.answer, .loseAnswer]
        var first: PushReconciler? = w.reconciler()
        await first?.run(studio)
        let written = try #require(secret(w, studio))
        #expect(written.unconfirmed == true && w.helpers[studio].secret == nil)
        first = nil

        let second = w.reconciler()
        await second.run(studio)
        // The device is confirmed, so only the secret goes again, with the id and value written before.
        #expect(w.gateway.seen.count == 3 && w.gateway.seen[1].line == w.gateway.seen[2].line)
        #expect(w.gateway.seen[2].body["push_secret"] == written.pushSecret)
        #expect(w.gateway.devices.values.first?.secrets == [written.secretID ?? "": written.pushSecret ?? ""])
        #expect(secret(w, studio)?.unconfirmed == nil && w.helpers[studio].secret == written.pushSecret)
        w.clock.release()
    }

    @Test func nothingIsSentThatCouldNotBeWrittenFirst() async {
        let w = world()
        let r = w.reconciler()
        w.store.failsSave = true
        await r.run(studio)
        await w.eventually { r.stopped.contains(studio) }
        #expect(w.gateway.seen.isEmpty && w.helpers[studio].secret == nil && r.problem == .storeFailed)

        // The device is there and the secret cannot be written: no secret goes anywhere.
        w.store.failsSave = false
        await r.run(studio, by: .person)
        #expect(w.helpers[studio].secret != nil)
        let other = w.helpers.add(laptop, name: "Laptop")
        w.store.failsSave = true
        await r.run(laptop)
        await w.eventually { r.stopped.contains(laptop) }
        #expect(w.gateway.seen.count == 2 && other.secret == nil && other.count("register_push") == 0)
    }

    // MARK: Waiting and giving up

    @Test func aRateLimitIsObeyedBeforeTheNextRequest() async {
        let w = world()
        w.clock.passes = false
        let r = w.reconciler()
        w.gateway.turns = [.refuse(429, retryAfter: 120)]
        await r.run(studio)
        await w.quiet()
        #expect(w.gateway.seen.count == 1 && r.limit == PushReconciler.Limit(retryAt: w.clock.now.addingTimeInterval(120)))
        #expect(w.clock.sleeps == [120])
        #expect(RateLimit(retryAt: r.limit?.retryAt, now: w.clock.now).text == "Too many tries. Try again in 2 minutes.")

        // Nothing brings a request forward: not the app's own triggers, not the person.
        r.reconcileAll()
        r.cameToFront()
        await r.run(studio, by: .person)
        await w.quiet()
        w.clock.advance(by: 119)
        await w.quiet()
        #expect(w.gateway.seen.count == 1)

        w.clock.advance(by: 1)
        await w.eventually { w.helpers[studio].secret != nil }
        #expect(w.gateway.seen.count == 3 && w.gateway.seen[1].at.timeIntervalSince(w.gateway.seen[0].at) >= 120)
        #expect(r.limit == nil && r.problem == nil)
        w.clock.release()
    }

    @Test func aBusyGatewaysRetryAfterIsObeyedToo() async {
        let w = world()
        let r = w.reconciler()
        w.gateway.turns = [.refuse(503, retryAfter: 30)]
        await r.run(studio)
        await w.eventually { w.helpers[studio].secret != nil }
        // Longer than the first backoff, so it wins; it is no rate limit for the row.
        #expect(w.clock.sleeps == [30] && w.gateway.seen[1].at.timeIntervalSince(w.gateway.seen[0].at) >= 30)
    }

    @Test func afterSixFailedTriesTheComputerWaitsForRetry() async {
        let w = world()
        let r = w.reconciler()
        w.gateway.down = true
        await r.run(studio)
        await w.eventually { r.stopped.contains(studio) }
        await w.quiet()
        #expect(w.gateway.seen.count == 6)
        #expect(w.clock.sleeps == [2, 4, 8, 16, 32])
        #expect(r.stopped == [studio] && r.retrying.isEmpty)

        // The app's own triggers do not start a seventh.
        r.reconcileAll()
        await r.run(studio)
        r.helperChanged(studio)
        await w.quiet()
        #expect(w.gateway.seen.count == 6)

        // Retry starts again.
        await r.run(studio, by: .person)
        await w.eventually { w.gateway.seen.count == 12 }
        await w.quiet()
        #expect(w.gateway.seen.count == 12 && r.stopped == [studio])

        // So does the app's next stay in front, and a try that works ends it.
        w.gateway.down = false
        r.cameToFront()
        await w.eventually { w.helpers[studio].secret != nil }
        #expect(r.stopped.isEmpty && r.retrying.isEmpty && w.gateway.made == 1)
    }

    @Test func eachWaitIsTwiceTheLastUpToFiveMinutes() {
        func delay(_ failures: Int, retryAfter: TimeInterval? = nil, fraction: Double = 0) -> TimeInterval {
            PushBackoff.delay(failures: failures, retryAfter: retryAfter, fraction: fraction)
        }
        #expect((1...9).map { delay($0) } == [2, 4, 8, 16, 32, 64, 128, 256, 300])
        // The spread adds up to half a wait and never passes the longest.
        #expect(delay(1, fraction: 0.5) == 2.5 && delay(3, fraction: 0.999) < 12 && delay(9, fraction: 0.9) == 300)
        // A longer `Retry-After` wins; a shorter one does not shorten the wait.
        #expect(delay(1, retryAfter: 120) == 120 && delay(5, retryAfter: 10) == 32 && delay(2, retryAfter: 3600) == 3600)
        #expect(PushBackoff.tries == 6)
    }

    // MARK: Switches

    @Test func aSwitchPausesAndResumesAndNothingElse() async throws {
        let (w, r) = await signedUp()
        let requests = w.gateway.seen.count, saves = w.store.saves
        let held = try #require(w.helpers[studio].secret)
        for flip in 0..<100 {
            let off = flip % 2 == 0
            w.intents[studio] = off ? .paused : nil
            if off { r.pause(studio) } else { await r.resume(studio) }
            await w.eventually { w.helpers[studio].paused == off && !r.isBusy(studio) }
        }
        await w.quiet()
        #expect(w.gateway.seen.count == requests && w.gateway.writes == 2 && w.store.saves == saves)
        #expect(w.helpers[studio].pauseCalls == (0..<100).map { "set_push_paused \($0 % 2 == 0)" })
        // The helper kept its secret throughout, and was never registered again.
        #expect(w.helpers[studio].secret == held && w.helpers[studio].count("register_push") == 1)
        #expect(w.helpers[studio].count("unregister_push") == 0 && w.prefs.helpersToTell.isEmpty)
    }

    @Test func flipsFasterThanTheHelperAnswersTellItOnlyOfChanges() async {
        let (w, r) = await signedUp()
        let requests = w.gateway.seen.count
        for flip in 0..<100 {
            let off = flip % 2 == 0
            w.intents[studio] = off ? .paused : nil
            if off { r.pause(studio) } else { r.trigger(studio, by: .person) }
        }
        await w.eventually { !r.isBusy(studio) }
        await w.quiet()
        // The last flip was on: the helper is not paused, and no call repeated the one before it.
        let calls = w.helpers[studio].pauseCalls
        #expect(!w.helpers[studio].paused && w.gateway.seen.count == requests)
        #expect(zip(calls, calls.dropFirst()).allSatisfy { $0 != $1 } && calls.count <= 100)
    }

    @Test func aComputerThatCannotBeReachedIsToldOnItsNextConnectionOnce() async {
        let (w, r) = await signedUp()
        let requests = w.gateway.seen.count
        w.helpers[studio].serial = nil
        w.intents[studio] = .paused
        r.pause(studio)
        await w.quiet()
        // The choice waits on the phone. Nothing went anywhere.
        #expect(w.prefs.helpersToTell == [studio] && w.helpers[studio].pauseCalls.isEmpty && !w.helpers[studio].paused)

        // It survives the app: a new one tells the helper when the computer connects.
        let again = w.reconciler()
        w.helpers[studio].serial = 2
        await again.run(studio)
        #expect(w.helpers[studio].paused && w.helpers[studio].pauseCalls == ["set_push_paused true"] && w.prefs.helpersToTell.isEmpty)
        // And never again.
        w.helpers[studio].serial = 3
        await again.run(studio)
        again.reconcileAll()
        await w.quiet()
        #expect(w.helpers[studio].pauseCalls.count == 1 && w.gateway.seen.count == requests)
        // The secret is still the phone's and the gateway's.
        #expect(w.gateway.devices.values.first?.secrets.count == 1 && secret(w, studio)?.pushSecret != nil)
    }

    @Test func turnedOnAgainBeforeItWasToldNothingIsSaidAtAll() async {
        let (w, r) = await signedUp()
        w.helpers[studio].serial = nil
        w.intents[studio] = .paused
        r.pause(studio)
        await w.quiet()
        w.intents[studio] = nil
        await r.resume(studio)
        w.helpers[studio].serial = 2
        await r.run(studio)
        #expect(w.prefs.helpersToTell.isEmpty && w.helpers[studio].pauseCalls.isEmpty && !w.helpers[studio].paused)
    }

    @Test func aComputerThatWasNeverSignedUpHasNobodyToTell() async {
        let w = world()
        let r = w.reconciler()
        w.intents[studio] = .paused
        r.pause(studio)
        await w.quiet()
        #expect(w.prefs.helpersToTell.isEmpty && w.helpers[studio].calls.isEmpty && w.gateway.seen.isEmpty)
    }

    @Test func aHelperWithoutPauseIsUnregisteredAndGetsTheSameSecretBack() async throws {
        let w = world()
        w.helpers[studio].pauses = false
        let r = w.reconciler()
        await r.run(studio)
        let held = try #require(w.helpers[studio].secret)
        let requests = w.gateway.seen.count

        w.intents[studio] = .paused
        r.pause(studio)
        await w.eventually { w.helpers[studio].secret == nil }
        #expect(w.helpers[studio].pauseCalls == ["set_push_paused true"] && w.helpers[studio].count("unregister_push") == 1)
        #expect(w.prefs.helpersToTell.isEmpty)

        w.intents[studio] = nil
        await r.resume(studio)
        #expect(w.helpers[studio].secret == held && w.helpers[studio].count("register_push") == 2)

        // It is asked for the action only once on a connection.
        w.intents[studio] = .paused
        r.pause(studio)
        await w.eventually { w.helpers[studio].secret == nil }
        #expect(w.helpers[studio].pauseCalls.count == 1 && w.helpers[studio].count("unregister_push") == 2)
        // The secret never changed, and the gateway heard nothing.
        #expect(secret(w, studio)?.pushSecret == held && w.gateway.seen.count == requests)
    }

    @Test func withoutThePermissionOrAnAddressNothingIsDone() async {
        let w = world()
        let r = w.reconciler()
        w.intents[studio] = .waiting
        await r.run(studio, by: .person)
        w.intents[studio] = .leaveAlone
        await r.run(studio, by: .person)
        #expect(w.gateway.seen.isEmpty && w.helpers[studio].calls.isEmpty && w.store.saves == 0)
    }

    // MARK: Self-healing

    @Test func aHelperInstalledAgainGetsTheStoredSecretAndTheGatewayHearsNothing() async throws {
        let (w, r) = await signedUp()
        let requests = w.gateway.seen.count, saves = w.store.saves
        let held = try #require(secret(w, studio)?.pushSecret)
        // The same files, so the same key; it has forgotten the phone.
        w.helpers[studio].reinstall(keepingKey: true)
        r.helperChanged(studio)
        await w.eventually { w.helpers[studio].secret != nil }
        #expect(w.helpers[studio].secret == held && w.helpers[studio].count("register_push") == 2)
        #expect(w.gateway.seen.count == requests && w.store.saves == saves)

        // The same when the helper itself says it holds nothing.
        w.helpers[studio].secret = nil
        r.helperLost(studio)
        await w.eventually { w.helpers[studio].secret != nil }
        #expect(w.helpers[studio].secret == held && w.helpers[studio].count("register_push") == 3)
        #expect(w.gateway.seen.count == requests && w.store.saves == saves)
    }

    @Test func aHelperWithAnotherKeyGetsNothingUntilItIsTrusted() async throws {
        let (w, r) = await signedUp()
        let requests = w.gateway.seen.count
        let old = try #require(secret(w, studio))
        w.helpers[studio].reinstall(keepingKey: false)
        r.helperChanged(studio)
        await w.eventually { r.helpers[studio] == .identityChanged }
        await w.quiet()
        r.reconcileAll()
        await r.run(studio, by: .person)
        #expect(r.helpers[studio] == .identityChanged && w.helpers[studio].secret == nil)
        #expect(w.helpers[studio].count("register_push") == 1 && w.gateway.seen.count == requests)
        #expect(secret(w, studio) == old)

        let offered = try #require(r.offeredKey(studio))
        #expect(await r.trust(studio, key: offered))
        let new = try #require(secret(w, studio))
        let device = try #require(w.store.value?.device)
        #expect(Array(w.gateway.lines.dropFirst(requests)) == ["DELETE /v1/devices/\(device)/secrets/\(old.secretID ?? "")",
                                                               "PUT /v1/devices/\(device)/secrets/\(new.secretID ?? "")"])
        #expect(new.helperKey == w.helpers[studio].publicKey && new.secretID != old.secretID && new.pushSecret != old.pushSecret)
        #expect(w.helpers[studio].secret == new.pushSecret && r.helpers[studio] == .running(pushEnabled: true))
        #expect(w.gateway.devices[device]?.secrets == [new.secretID ?? "": new.pushSecret ?? ""])
        #expect(w.store.value?.retired == nil)
    }

    @Test func trustPinsTheKeyTheConfirmWasShownFor() async throws {
        let (w, r) = await signedUp()
        w.helpers[studio].reinstall(keepingKey: false)
        r.helperChanged(studio)
        await w.eventually { r.offeredKey(studio) != nil }
        // The confirm goes up for the key offered now.
        let shown = try #require(r.offeredKey(studio))
        #expect(shown == w.helpers[studio].publicKey && r.helpers[studio] == .identityChanged)
        #expect(await r.trust(studio, key: shown))
        #expect(secret(w, studio)?.helperKey == shown && w.helpers[studio].secret == secret(w, studio)?.pushSecret)
        #expect(r.helpers[studio] == .running(pushEnabled: true) && r.offeredKey(studio) == nil)
    }

    @Test func trustOfAKeyTheHelperNoLongerOffersChangesNothing() async throws {
        let (w, r) = await signedUp()
        let old = try #require(secret(w, studio))
        w.helpers[studio].reinstall(keepingKey: false)
        r.helperChanged(studio)
        await w.eventually { r.offeredKey(studio) != nil }
        let shown = try #require(r.offeredKey(studio))
        // While the confirm is up, the helper there is replaced once more.
        w.helpers[studio].reinstall(keepingKey: false)
        r.helperChanged(studio)
        await w.eventually { r.offeredKey(studio) == w.helpers[studio].publicKey }
        let requests = w.gateway.seen.count, saves = w.store.saves

        #expect(await r.trust(studio, key: shown) == false)
        // Nothing is pinned, deleted or handed over, and the row still asks for Trust.
        #expect(secret(w, studio) == old && w.helpers[studio].secret == nil && r.helpers[studio] == .identityChanged)
        #expect(w.gateway.seen.count == requests && w.store.saves == saves)
        // A key nobody offered is no better.
        #expect(await r.trust(studio, key: "") == false && secret(w, studio) == old)

        // The confirm is shown again, for the key offered now, and that one is pinned.
        let now = try #require(r.offeredKey(studio))
        #expect(now != shown && now == w.helpers[studio].publicKey)
        #expect(await r.trust(studio, key: now))
        #expect(secret(w, studio)?.helperKey == now && w.helpers[studio].secret == secret(w, studio)?.pushSecret)
    }

    // MARK: A secret the gateway refuses

    @Test func aSecretTheGatewayHoldsInAnotherRowIsReplacedByAFreshOneOnce() async throws {
        let w = world()
        let r = w.reconciler()
        w.gateway.turns = [.answer, .refuse(409, error: "conflict")]
        await r.run(studio)
        #expect(w.gateway.seen.count == 3)
        let first = w.gateway.seen[1], second = w.gateway.seen[2]
        // The same id, another value, with no wait in between.
        #expect(first.line.contains("/secrets/") && first.line == second.line && w.clock.sleeps.isEmpty)
        let fresh = try #require(second.body["push_secret"])
        #expect(fresh.count == 43 && fresh != first.body["push_secret"])
        #expect(secret(w, studio)?.pushSecret == fresh && secret(w, studio)?.unconfirmed == nil)
        #expect(w.helpers[studio].secret == fresh && w.gateway.devices.values.first?.secrets.values.sorted() == [fresh])
        #expect(r.stopped.isEmpty && r.problem == nil)
    }

    @Test func aSecondConflictEndsTheRunAndTheComputerWaitsForRetry() async throws {
        let w = world()
        let r = w.reconciler()
        w.gateway.turns = [.answer, .refuse(409, error: "conflict"), .refuse(409, error: "conflict")]
        await r.run(studio)
        await w.quiet()
        #expect(w.gateway.seen.count == 3 && w.clock.sleeps.isEmpty)
        #expect(r.stopped == [studio] && r.retrying.isEmpty && r.problem == .secretConflict && r.full.isEmpty)
        // The value that was sent last was written first, and no helper got one.
        #expect(secret(w, studio)?.pushSecret == w.gateway.seen[2].body["push_secret"] && secret(w, studio)?.unconfirmed == true)
        #expect(w.helpers[studio].secret == nil && w.helpers[studio].count("register_push") == 0)
        // The app's own triggers ask for nothing more.
        r.reconcileAll()
        await r.run(studio)
        await w.quiet()
        #expect(w.gateway.seen.count == 3)
        // Retry does.
        await r.run(studio, by: .person)
        #expect(w.gateway.seen.count == 4 && w.helpers[studio].secret == secret(w, studio)?.pushSecret && r.stopped.isEmpty)
    }

    @Test func aDeviceWithAllItsSecretsTakenSaysSoAndIsNotTriedAgain() async {
        let (w, r) = await signedUp()
        let other = w.helpers.add(laptop, name: "Laptop")
        let requests = w.gateway.seen.count
        w.gateway.turns = [.refuse(409, error: "too_many_secrets")]
        await r.run(laptop)
        await w.quiet()
        #expect(w.gateway.seen.count == requests + 1 && w.clock.sleeps.isEmpty)
        #expect(r.full == [laptop] && r.stopped == [laptop] && r.retrying.isEmpty && r.problem == .tooManySecrets)
        #expect(other.secret == nil && other.count("register_push") == 0)
        #expect(ComputerStatus.make(ComputerFacts(name: "Laptop", full: true)).line?.text == "Too many computers for this \(DeviceWord.current)")
        // Not by the app's own triggers, and not on its next stay in front.
        r.reconcileAll()
        r.cameToFront()
        await r.run(laptop)
        await w.quiet()
        #expect(w.gateway.seen.count == requests + 1 && r.full == [laptop])
        // The computer that is signed up is as it was.
        #expect(r.helpers[studio] == .running(pushEnabled: true) && !r.full.contains(studio))
        // Retry asks once more.
        await r.run(laptop, by: .person)
        #expect(w.gateway.seen.count == requests + 2 && other.secret != nil && r.full.isEmpty && r.stopped.isEmpty)
    }

    // MARK: Entries of computers the app does not list

    @Test func whatHappensToAStoredEntryIsDecidedByTheListAndTheHelpersKey() throws {
        var record = GatewayRegistration(gateway: GatewayStandIn.address, device: "dev1", ownerKey: "own1", token: "ab", environment: "sandbox")
        let listed = ServerPush(helperKey: "key-studio", secretID: "sid-studio", pushSecret: "sec-studio")
        let gone = ServerPush(helperKey: "key-gone", secretID: "sid-gone", pushSecret: "sec-gone")
        let pinOnly = ServerPush(helperKey: "key-gone")
        let other = ServerPush(helperKey: "key-other", secretID: "sid-other", pushSecret: "sec-other", unconfirmed: true)
        record.servers = [studio.uuidString: listed, "A": gone, "B": pinOnly, "C": other]

        // Only entries of computers that are not listed are set aside. An empty Keychain has none.
        let orphans = PushOrphans.setAside(record, listed: [studio])
        #expect(orphans == ["A", "B", "C"])
        #expect(PushOrphans.setAside(nil, listed: [studio]).isEmpty && PushOrphans.setAside(record, listed: []) == [studio.uuidString, "A", "B", "C"])
        var none = record
        none.servers = [:]
        #expect(PushOrphans.setAside(none, listed: [studio]).isEmpty)

        // A helper's key picks the orphan pinned to it, the one that holds a secret first.
        #expect(PushOrphans.match("key-gone", among: orphans, in: record) == "A")
        #expect(PushOrphans.match("key-gone", among: ["B"], in: record) == "B")
        #expect(PushOrphans.match("key-other", among: orphans, in: record) == "C")
        #expect(PushOrphans.match("key-new", among: orphans, in: record) == nil)
        // The listed computer's key matches nothing: its entry was never set aside.
        #expect(PushOrphans.match("key-studio", among: orphans, in: record) == nil)

        // Adopted: the entry as it is, under the computer's id. A computer that has one keeps its own.
        var adopted = record
        PushOrphans.adopt("A", for: laptop, in: &adopted)
        #expect(adopted.servers[laptop.uuidString] == gone && adopted.servers["A"] == nil && adopted.retired == nil)
        #expect(adopted.servers[studio.uuidString] == listed && adopted.servers.count == 4)
        var kept = record
        PushOrphans.adopt("A", for: studio, in: &kept)
        #expect(kept == record)

        // Retired: the rest leave, and each secret id waits to be deleted at the gateway.
        PushOrphans.retire(["B", "C"], in: &adopted)
        #expect(adopted.servers == [studio.uuidString: listed, laptop.uuidString: gone] && adopted.retired == ["sid-other"])
        var untouched = record
        PushOrphans.retire([], in: &untouched)
        #expect(untouched == record && PushOrphans.wait == 60)
    }

    @Test func aComputerAddedAgainTakesOverItsEntryAndTheRestAreRetired() async throws {
        let (w, _) = await signedUp(two: true)
        let device = try #require(w.store.value?.device)
        let old = try #require(secret(w, studio)), unlisted = try #require(secret(w, laptop))
        let requests = w.gateway.seen.count
        // The app was deleted and installed again. Studio is added again and has a new id;
        // Laptop is not added.
        let again = UUID()
        w.helpers.add(again, computer: w.helpers.remove(studio))
        w.helpers.remove(laptop)
        w.clock.passes = false
        let r = w.reconciler()
        r.computersLoaded()
        await r.run(again)
        // Studio's helper proved the key pinned in the old entry: the entry is this computer's
        // now, and its helper has the secret it had. The gateway heard nothing of it.
        #expect(secret(w, again) == old && secret(w, studio) == nil)
        #expect(w.helpers[again].secret == old.pushSecret && r.helpers[again] == .running(pushEnabled: true))
        // Every listed computer was looked at, so the entry nobody took is retired.
        await w.eventually { !r.hasRetired && secret(w, laptop) == nil }
        #expect(Array(w.gateway.lines.dropFirst(requests)) == ["DELETE /v1/devices/\(device)/secrets/\(unlisted.secretID ?? "")"])
        #expect(w.gateway.devices[device]?.secrets == [old.secretID ?? "": old.pushSecret ?? ""])
        #expect(w.store.value?.servers.count == 1 && w.store.value?.retired == nil)
        w.clock.release()
    }

    @Test func entriesNobodyTakesOverAreRetiredAMinuteAfterAComputerIsListed() async throws {
        let (w, _) = await signedUp(two: true)
        let before = try #require(w.store.value)
        let requests = w.gateway.seen.count
        // Neither computer is in the list. The one that is has another helper and is turned off,
        // so its helper is not looked at.
        w.helpers.remove(studio)
        w.helpers.remove(laptop)
        w.clock.passes = false
        let r = w.reconciler()
        r.computersLoaded()
        r.reconcileAll()
        await w.quiet()
        // With no computer listed the entries stay as they are, and no wait starts.
        #expect(w.store.value == before && w.gateway.seen.count == requests && w.clock.sleeps.isEmpty)

        let mini = UUID()
        w.helpers.add(mini, name: "Mini")
        w.intents[mini] = .paused
        r.reconcileAll()
        await w.quiet()
        #expect(w.clock.sleeps == [60] && w.store.value == before)
        w.clock.advance(by: 59)
        await w.quiet()
        #expect(w.store.value == before && w.gateway.seen.count == requests)
        w.clock.advance(by: 1)
        await w.eventually { w.store.value?.servers.isEmpty == true && !r.hasRetired }
        let gone = [before.servers[studio.uuidString]?.secretID, before.servers[laptop.uuidString]?.secretID].compactMap { $0 }
        #expect(Array(w.gateway.lines.dropFirst(requests)).sorted() == gone.map { "DELETE /v1/devices/\(before.device)/secrets/\($0)" }.sorted())
        #expect(w.gateway.devices[before.device]?.secrets.isEmpty == true && w.gateway.devices.count == 1)
        w.clock.release()
    }

    @Test func aRetireTheGatewayDidNotConfirmIsTriedAgainLater() async throws {
        let (w, _) = await signedUp()
        let device = try #require(w.store.value?.device)
        let gone = try #require(secret(w, studio)?.secretID)
        let requests = w.gateway.seen.count
        w.helpers.remove(studio)
        // The computer in the list has no helper: that is all there is to look at.
        w.helpers.add(laptop, name: "Laptop").installed = false
        w.clock.passes = false
        w.gateway.down = true
        let r = w.reconciler()
        r.computersLoaded()
        await r.run(laptop)
        await w.eventually { w.gateway.seen.count == requests + 1 }
        // The entry is off the phone at once; its secret waits in the list of deletes.
        #expect(secret(w, studio) == nil && w.store.value?.retired == [gone] && r.hasRetired)
        #expect(w.gateway.lines.last == "DELETE /v1/devices/\(device)/secrets/\(gone)" && w.gateway.devices[device]?.secrets.count == 1)

        w.gateway.down = false
        r.reconcileAll()
        await w.eventually { !r.hasRetired }
        #expect(w.gateway.seen.count == requests + 2 && w.gateway.devices[device]?.secrets.isEmpty == true)
        // It survives the app as well: a list of deletes left in the store is worked off by the next launch.
        #expect(w.store.value?.retired == nil && w.store.value?.servers.isEmpty == true)
        w.clock.release()
    }

    @Test func listedComputersAndAnEmptyKeychainAreLeftAsTheyAre() async throws {
        // Every stored entry belongs to a listed computer: nothing is set aside, and no wait starts.
        let (w, _) = await signedUp(two: true)
        let before = try #require(w.store.value)
        let requests = w.gateway.seen.count, saves = w.store.saves
        let r = w.reconciler()
        r.computersLoaded()
        r.reconcileAll()
        await w.eventually { r.isSettled(studio) && r.isSettled(laptop) }
        await w.quiet()
        #expect(w.store.value == before && w.store.saves == saves && w.gateway.seen.count == requests && w.clock.sleeps.isEmpty)

        // Nothing stored: nothing to do.
        let empty = world()
        let fresh = empty.reconciler()
        fresh.computersLoaded()
        await empty.quiet()
        #expect(empty.store.value == nil && empty.store.saves == 0 && empty.gateway.seen.isEmpty && empty.clock.sleeps.isEmpty)
        #expect(!fresh.hasRetired)
    }

    @Test func aDeadAddressSendsTheDeviceAndEachSecretAgainOnce() async throws {
        let (w, r) = await signedUp(two: true)
        let requests = w.gateway.seen.count
        let before = try #require(w.store.value)
        let studioSecret = try #require(secret(w, studio)), laptopSecret = try #require(secret(w, laptop))
        // Apple said the address is dead; Studio's helper pushed, was refused, and dropped its secret.
        w.gateway.devices[before.device]?.dead = true
        w.helpers[studio].dropped.insert(studioSecret.pushSecret ?? "")
        w.helpers[studio].secret = nil
        r.helperLost(studio)
        await w.eventually { w.helpers[studio].secret != nil && secret(w, laptop)?.unconfirmed == nil && w.store.value?.unconfirmed == nil }
        await w.quiet()

        let after = try #require(w.store.value)
        #expect(after.device == before.device && after.ownerKey == before.ownerKey)
        #expect(Array(w.gateway.lines.dropFirst(requests)).sorted() == [
            "PUT /v1/devices/\(before.device)",
            "PUT /v1/devices/\(before.device)/secrets/\(studioSecret.secretID ?? "")",
            "PUT /v1/devices/\(before.device)/secrets/\(laptopSecret.secretID ?? "")",
        ].sorted())
        #expect(w.gateway.made == 1 && w.gateway.devices[before.device]?.dead == false)
        // Studio's helper never takes a secret it saw refused: a new value, under the same id.
        let renewed = try #require(secret(w, studio))
        #expect(renewed.secretID == studioSecret.secretID && renewed.pushSecret != studioSecret.pushSecret)
        #expect(w.helpers[studio].secret == renewed.pushSecret)
        // Laptop's is the one it had, and its helper was not asked again.
        #expect(secret(w, laptop) == laptopSecret && w.helpers[laptop].secret == laptopSecret.pushSecret)
        #expect(w.helpers[laptop].count("register_push") == 1)
        #expect(w.gateway.devices[before.device]?.secrets.count == 2)
    }

    @Test func aDeviceTheGatewayNoLongerHasIsMadeAgainFromTheSameRequest() async throws {
        let (w, r) = await signedUp()
        let before = try #require(w.store.value)
        // The gateway purged it. A second computer's secret is the first request to find out.
        w.gateway.devices = [:]
        w.helpers.add(laptop, name: "Laptop")
        await r.run(laptop)
        await w.eventually { w.helpers[laptop].secret != nil && secret(w, studio)?.unconfirmed == nil }
        let after = try #require(w.store.value)
        #expect(after.device == before.device && after.ownerKey == before.ownerKey && w.gateway.made == 2)
        #expect(w.gateway.devices[before.device]?.secrets.count == 2)
        #expect(secret(w, studio)?.pushSecret == before.servers[studio.uuidString]?.pushSecret)
    }

    @Test func anEmptyKeychainIsOneNewDevice() async throws {
        let (w, _) = await signedUp()
        let old = try #require(w.store.value?.device)
        let requests = w.gateway.seen.count
        w.store.value = nil
        let r = w.reconciler()
        await r.run(studio)
        let new = try #require(w.store.value)
        #expect(new.device != old && w.gateway.made == 2)
        #expect(Array(w.gateway.lines.dropFirst(requests)) == ["PUT /v1/devices/\(new.device)",
                                                               "PUT /v1/devices/\(new.device)/secrets/\(secret(w, studio)?.secretID ?? "")"])
        #expect(w.helpers[studio].secret == secret(w, studio)?.pushSecret)
    }

    @Test func aHelperThatSaysItIsPausedWhileTheComputerIsOnResumes() async {
        let (w, r) = await signedUp()
        let requests = w.gateway.seen.count, saves = w.store.saves
        // Paused behind the app's back: the app still takes it for resumed.
        w.helpers[studio].paused = true
        #expect(r.isSettled(studio))
        r.helperPaused(studio)
        // The row says the app is on it, until the helper has resumed.
        #expect(r.mending == [studio] && !r.isSettled(studio))
        await w.eventually { !w.helpers[studio].paused && !r.isBusy(studio) }
        #expect(w.helpers[studio].pauseCalls == ["set_push_paused false"] && r.mending.isEmpty && r.isSettled(studio))

        // The same when the app already took it for paused and the switch says on.
        w.intents[studio] = .paused
        r.pause(studio)
        await w.eventually { w.helpers[studio].paused && !r.isBusy(studio) }
        w.intents[studio] = nil
        r.helperPaused(studio, by: .person)
        await w.eventually { !w.helpers[studio].paused && !r.isBusy(studio) }
        #expect(r.isSettled(studio) && r.mending.isEmpty)

        // And on a new connection, whatever the helper was left at.
        w.helpers[studio].paused = true
        w.helpers[studio].serial = 2
        #expect(!r.isSettled(studio))
        await r.run(studio)
        #expect(!w.helpers[studio].paused && r.isSettled(studio))
        // While the computer is off it is none of this.
        w.intents[studio] = .paused
        r.helperPaused(studio)
        #expect(r.mending.isEmpty)
        #expect(w.gateway.seen.count == requests && w.store.saves == saves)
    }

    @Test func aSwitchThatMovesWhileTheHelperAnswersEndsWhereItWasLeft() async {
        let (w, r) = await signedUp()
        let requests = w.gateway.seen.count
        w.helpers[studio].latency = 3_000_000
        // Off, and on again while the helper is still being told.
        w.intents[studio] = .paused
        r.pause(studio)
        try? await Task.sleep(nanoseconds: 1_000_000)
        w.intents[studio] = nil
        r.trigger(studio, by: .person)
        await w.eventually { !r.isBusy(studio) && !w.helpers[studio].paused && r.isSettled(studio) }
        #expect(w.helpers[studio].pauseCalls == ["set_push_paused true", "set_push_paused false"])

        // On, and off again while the helper is still resuming.
        w.intents[studio] = .paused
        r.pause(studio)
        await w.eventually { w.helpers[studio].paused && !r.isBusy(studio) }
        w.intents[studio] = nil
        r.trigger(studio, by: .person)
        try? await Task.sleep(nanoseconds: 1_000_000)
        w.intents[studio] = .paused
        r.pause(studio)
        await w.eventually { !r.isBusy(studio) && w.helpers[studio].paused }
        await w.quiet()
        #expect(w.helpers[studio].pauseCalls.last == "set_push_paused true" && w.helpers[studio].paused)
        #expect(w.prefs.helpersToTell.isEmpty && w.gateway.seen.count == requests)
    }

    @Test func aHelperThatKeepsLosingThePhoneIsLeftAlone() async {
        let (w, r) = await signedUp()
        for _ in 0..<PushReconciler.lossesPerConnection {
            let registers = w.helpers[studio].count("register_push")
            r.helperLost(studio)
            await w.eventually { w.helpers[studio].count("register_push") == registers + 1 && !r.isBusy(studio) }
        }
        let registers = w.helpers[studio].count("register_push")
        r.helperLost(studio)
        await w.quiet()
        #expect(w.helpers[studio].count("register_push") == registers && r.stopped == [studio])
        if case .failed = r.helpers[studio] {} else { Issue.record("the row says it could not reconnect") }
        // Retry asks again.
        await r.run(studio, by: .person)
        #expect(w.helpers[studio].count("register_push") == registers + 1 && r.stopped.isEmpty)
        #expect(w.gateway.seen.count == 2)
    }

    // MARK: A registration from the earlier route

    private func earlier(_ w: PushWorld) -> GatewayRegistration {
        let device = String(repeating: "d", count: 27)
        let secret = String(repeating: "s", count: 43)
        w.gateway.devices[device] = GatewayStandIn.Device(ownerKey: "own1", token: PushWorld.token, environment: "sandbox",
                                                           secrets: ["sid-earlier": secret])
        var r = GatewayRegistration(gateway: GatewayStandIn.address, device: device, ownerKey: "own1", token: PushWorld.token,
                                    environment: "sandbox")
        r.servers[studio.uuidString] = ServerPush(helperKey: w.helpers[studio].publicKey, secretID: "sid-earlier", pushSecret: secret)
        w.store.value = r
        return r
    }

    @Test func aRegistrationFromTheEarlierRouteIsUsedAsItIs() async throws {
        let w = world()
        let stored = earlier(w)
        let r = w.reconciler()
        await r.run(studio)
        r.reconcileAll()
        await w.quiet()
        #expect(w.gateway.seen.isEmpty && w.store.saves == 0 && w.store.value == stored)
        #expect(w.helpers[studio].secret == stored.servers[studio.uuidString]?.pushSecret)

        // A computer that has no secret yet gets one on that device; the device is not made again.
        w.helpers.add(laptop, name: "Laptop")
        await r.run(laptop)
        #expect(w.gateway.lines == ["PUT /v1/devices/\(stored.device)/secrets/\(secret(w, laptop)?.secretID ?? "")"])
        #expect(w.store.value?.device == stored.device && w.store.value?.ownerKey == "own1" && w.gateway.made == 0)
        #expect(w.helpers[laptop].secret == secret(w, laptop)?.pushSecret)
    }

    @Test func whatAnEarlierVersionStoredIsReadAsItIsMeantNow() throws {
        let address = GatewayStandIn.address
        var stored = GatewayRegistration(gateway: address, device: "dev1", ownerKey: "own1", token: "ab", environment: "sandbox")
        stored.servers["a"] = ServerPush(helperKey: "key1", secretID: "sid1", pushSecret: "sec1")
        #expect(PushRecord.adopt(nil, gateway: address) == nil)
        #expect(PushRecord.adopt(stored, gateway: address) == stored)
        #expect(PushRecord.adopt(stored, gateway: "https://other.example") == nil)
        // Marked for deletion and never deleted: it is the registration, and nothing is deleted.
        var marked = stored
        marked.revoked = true
        #expect(PushRecord.adopt(marked, gateway: address) == stored)
        // Deleted: only each helper's key is left, and it goes over to the new record.
        var ended = stored
        ended.ended = true
        ended.ownerKey = ""
        #expect(PushRecord.adopt(ended, gateway: address) == nil)
        let fresh = PushRecord.fresh(gateway: address, keeping: ended, random: .system)
        #expect(fresh.unconfirmed == true && fresh.token.isEmpty && fresh.servers == ["a": ServerPush(helperKey: "key1")])
        #expect(fresh.ownerKey.count == 43 && fresh.isPhoneChosen && fresh.device == GatewayStandIn.deviceID(for: fresh.ownerKey))
        #expect(!stored.isPhoneChosen)

        // An item from before any of this still reads.
        let old = #"{"gateway":"https://push.example","device":"dev1","ownerKey":"own1","pushSecret":"sec1","token":"ab","environment":"sandbox"}"#
        let read = try JSONDecoder().decode(GatewayRegistration.self, from: Data(old.utf8))
        #expect(read.device == "dev1" && read.servers.isEmpty && read.unconfirmed == nil && read.holds(token: "ab", environment: "sandbox"))
    }

    @Test func aRegistrationAnEarlierVersionDeletedStartsANewOneWithTheSameHelpers() async throws {
        let w = world()
        var ended = GatewayRegistration(gateway: GatewayStandIn.address, device: "dev1", ownerKey: "", token: "", environment: "sandbox")
        ended.ended = true
        ended.servers[studio.uuidString] = ServerPush(helperKey: "another helper's key")
        w.store.value = ended
        let r = w.reconciler()
        await r.run(studio)
        // The helper there proves another key than the one known before: it waits for Trust.
        #expect(r.helpers[studio] == .identityChanged && w.gateway.lines.count == 1 && w.gateway.made == 1)
        #expect(w.helpers[studio].secret == nil)
    }

    // MARK: Taking a secret back

    @Test func removingAnAddOnDeletesItsSecretNowOrWhenTheGatewayAnswers() async throws {
        let (w, r) = await signedUp(two: true)
        // A removal leaves the computer alone until it is over.
        w.intents = [studio: .leaveAlone, laptop: .leaveAlone]
        let device = try #require(w.store.value?.device)
        let gone = try #require(secret(w, studio)?.secretID)
        await r.revoke(studio, keepPin: true)
        #expect(w.gateway.lines.last == "DELETE /v1/devices/\(device)/secrets/\(gone)")
        #expect(secret(w, studio) == ServerPush(helperKey: w.helpers[studio].publicKey) && w.store.value?.retired == nil)
        #expect(w.gateway.devices[device]?.secrets.count == 1)
        await r.revoke(studio, keepPin: false)
        #expect(secret(w, studio) == nil)

        // The gateway can't be reached: the phone lets go at once, and the gateway hears later.
        let other = try #require(secret(w, laptop)?.secretID)
        w.gateway.down = true
        await r.revoke(laptop, keepPin: false)
        #expect(secret(w, laptop) == nil && w.store.value?.retired == [other] && r.hasRetired)
        w.gateway.down = false
        r.reconcileAll()
        await w.eventually { !r.hasRetired }
        #expect(w.gateway.lines.last == "DELETE /v1/devices/\(device)/secrets/\(other)" && w.gateway.devices[device]?.secrets.isEmpty == true)
        // The device itself is never deleted.
        #expect(w.gateway.devices.count == 1 && !w.gateway.lines.contains("DELETE /v1/devices/\(device)"))
    }

    /// The computer is removed from the app while its first secret is on its way to the gateway.
    /// The removal's delete gets there first and finds nothing; the secret that arrives after
    /// it is deleted once its request has answered, so nothing is left at the gateway.
    @Test func aComputerRemovedWhileItsFirstSecretIsOnItsWayLeavesNoSecretBehind() async throws {
        let w = world()
        let r = w.reconciler()
        w.gateway.hold = { $0.httpMethod == "PUT" && $0.url?.path.contains("/secrets/") == true }
        let run = Task { await r.run(studio) }
        await w.eventually { w.gateway.holding == 1 }
        try #require(w.gateway.holding == 1)
        let device = try #require(w.store.value?.device)
        let secretID = try #require(secret(w, studio)?.secretID)
        let path = "/v1/devices/\(device)/secrets/\(secretID)"
        #expect(w.gateway.lines == ["PUT /v1/devices/\(device)"])

        w.helpers.remove(studio)
        r.forget(studio)
        await w.eventually { w.gateway.lines.last == "DELETE \(path)" && w.store.value?.retired == nil }
        #expect(w.gateway.lines == ["PUT /v1/devices/\(device)", "DELETE \(path)"])
        #expect(secret(w, studio) == nil && w.store.value?.retired == nil)

        w.gateway.release()
        await run.value
        await w.eventually { w.gateway.devices[device]?.secrets.isEmpty == true && w.store.value?.retired == nil }
        #expect(w.gateway.lines == ["PUT /v1/devices/\(device)", "DELETE \(path)", "PUT \(path)", "DELETE \(path)"])
        #expect(w.gateway.devices[device]?.secrets.isEmpty == true)
        #expect(secret(w, studio) == nil && w.store.value?.retired == nil && !r.hasRetired)
    }

    /// The same, and the answer to the secret's request is lost: the gateway may hold the
    /// secret, so it is kept to be deleted, and the next pass deletes it.
    @Test func aComputerRemovedWhileItsFirstSecretIsOnItsWayIsCleanedUpAfterALostAnswerToo() async throws {
        let w = world()
        let r = w.reconciler()
        w.gateway.hold = { $0.httpMethod == "PUT" && $0.url?.path.contains("/secrets/") == true }
        let run = Task { await r.run(studio) }
        await w.eventually { w.gateway.holding == 1 }
        try #require(w.gateway.holding == 1)
        let device = try #require(w.store.value?.device)
        let secretID = try #require(secret(w, studio)?.secretID)
        let path = "/v1/devices/\(device)/secrets/\(secretID)"

        w.helpers.remove(studio)
        r.forget(studio)
        await w.eventually { w.gateway.lines.last == "DELETE \(path)" && w.store.value?.retired == nil }
        try #require(w.gateway.lines.last == "DELETE \(path)" && w.store.value?.retired == nil)

        // The secret gets there, and its answer does not come back.
        w.gateway.turns = [.loseAnswer]
        w.gateway.release()
        await run.value
        #expect(w.gateway.devices[device]?.secrets[secretID] != nil)
        #expect(w.store.value?.retired == [secretID] && secret(w, studio) == nil)

        r.reconcileAll()
        await w.eventually { !r.hasRetired }
        #expect(w.gateway.lines.last == "DELETE \(path)" && w.gateway.devices[device]?.secrets.isEmpty == true)
        #expect(w.store.value?.retired == nil)
    }

    /// A request the gateway refused stored nothing there: nothing more is sent for a computer
    /// that was removed meanwhile.
    @Test func aComputerRemovedWhileItsFirstSecretIsRefusedHasNothingMoreToDelete() async throws {
        let w = world()
        let r = w.reconciler()
        w.gateway.hold = { $0.httpMethod == "PUT" && $0.url?.path.contains("/secrets/") == true }
        let run = Task { await r.run(studio) }
        await w.eventually { w.gateway.holding == 1 }
        try #require(w.gateway.holding == 1)
        let device = try #require(w.store.value?.device)
        let secretID = try #require(secret(w, studio)?.secretID)
        let path = "/v1/devices/\(device)/secrets/\(secretID)"

        w.helpers.remove(studio)
        r.forget(studio)
        await w.eventually { w.gateway.lines.last == "DELETE \(path)" && w.store.value?.retired == nil }

        w.gateway.turns = [.refuse(429, retryAfter: 60)]
        w.gateway.release()
        await run.value
        #expect(w.gateway.lines == ["PUT /v1/devices/\(device)", "DELETE \(path)", "PUT \(path)"])
        #expect(w.gateway.devices[device]?.secrets.isEmpty == true && w.store.value?.retired == nil)
    }

    // MARK: The values the phone chooses

    @Test func theDeviceIDBelongsToItsOwnerKey() {
        let key = PushKeys.key(.system)
        #expect(key.count == 43 && !key.contains("=") && !key.contains("+") && !key.contains("/"))
        #expect(PushKeys.deviceID(ownerKey: key) == GatewayStandIn.deviceID(for: key))
        #expect(PushKeys.deviceID(ownerKey: key).count == 22 && PushKeys.secretID(.system).count == 16)
        #expect(PushKeys.key(.system) != key)
        // A fixed key gives a fixed id.
        let fixed = String(repeating: "A", count: 43)
        let hash = Data(SHA256.hash(data: Data("rexduo-device-v1\n\(fixed)".utf8)))
        #expect(PushKeys.deviceID(ownerKey: fixed) == String(PushKeys.text(hash).prefix(22)))
    }
}
