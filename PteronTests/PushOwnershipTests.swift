import Foundation
import Testing
import RexKit
@testable import Pteron

/// The `presence` flag of a computer's secret at the gateway: sent as true only for a
/// computer that is confirmed as the person's own, counted at the gateway's stand-in.
@MainActor
struct PushOwnershipTests {
    private let studio = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let laptop = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    private func world(two: Bool = false) -> PushWorld {
        let w = PushWorld()
        w.helpers.add(studio, name: "Studio")
        if two { w.helpers.add(laptop, name: "Laptop") }
        return w
    }

    private func secretPuts(_ w: PushWorld) -> [GatewayStandIn.Seen] {
        w.gateway.seen.filter { $0.method == "PUT" && $0.path.contains("/secrets/") }
    }

    private func flag(_ w: PushWorld, _ id: UUID) -> Bool? {
        guard let device = w.gateway.devices.values.first, let secretID = w.store.value?.servers[id.uuidString]?.secretID else { return nil }
        return device.presence[secretID]
    }

    /// Whose computer it is, as the app comes to know it.
    @MainActor
    private final class Owner {
        var own: Bool?
    }

    // MARK: The request

    @Test func theFlagIsAJSONBooleanAndAbsentWhenUnknown() throws {
        let base = try #require(URL(string: GatewayStandIn.address))
        func sent(_ presence: Bool?) throws -> (text: String, json: [String: Any]) {
            let request = PushGateway.request("PUT", base, path: "v1/devices/d/secrets/s",
                                              body: PushGateway.secretBody(pushSecret: "p", label: "Studio", presence: presence))
            let data = try #require(request.httpBody)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            return (String(decoding: data, as: UTF8.self), try #require(json))
        }
        let none = try sent(nil), own = try sent(true), other = try sent(false)
        #expect(none.json.keys.sorted() == ["label", "push_secret"])
        #expect(own.json.keys.sorted() == ["label", "presence", "push_secret"])
        #expect(own.text.contains(#""presence":true"#))
        #expect(other.text.contains(#""presence":false"#))
    }

    // MARK: Signing up

    @Test func aConfirmedOwnComputerIsFlaggedWithItsSecretAndNoOtherIs() async {
        let w = world(two: true)
        let r = w.reconciler()
        r.ownership = { [studio] in $0 == studio ? true : nil }
        for id in w.helpers.computers { await r.run(id) }
        #expect(flag(w, studio) == true)
        #expect(flag(w, laptop) == nil)
        // One request each: the flag went along with the secret.
        let puts = secretPuts(w)
        #expect(puts.count == 2 && puts.compactMap(\.presence) == [true])
        // Nothing more on later runs.
        let requests = w.gateway.seen.count
        r.cameToFront()
        for id in w.helpers.computers { await r.run(id, by: .person) }
        await w.quiet()
        #expect(w.gateway.seen.count == requests)
    }

    @Test func anUnknownOwnerSendsNoFlagAtAll() async {
        let w = world()
        let r = w.reconciler()
        await r.run(studio)
        r.cameToFront()
        await r.run(studio, by: .person)
        await w.quiet()
        #expect(secretPuts(w).count == 1 && secretPuts(w).allSatisfy { $0.presence == nil })
        #expect(flag(w, studio) == nil)
    }

    @Test func someoneElsesComputerIsSaidNotToBeOwn() async {
        let w = world()
        let r = w.reconciler()
        r.ownership = { _ in false }
        await r.run(studio)
        #expect(secretPuts(w).map(\.presence) == [false])
        #expect(flag(w, studio) == false)
    }

    // MARK: A secret from before

    /// Signed up before the app knew whose computer it is: the same secret goes once more,
    /// with the flag, and only the flag is written.
    @Test func aSecretStoredBeforeIsFlaggedOnceWhenTheOwnerIsKnown() async throws {
        let w = world()
        let r = w.reconciler()
        await r.run(studio)
        let secret = try #require(w.store.value?.servers[studio.uuidString])
        let writes = w.gateway.writes
        let who = Owner()
        r.ownership = { _ in who.own }
        await r.run(studio)
        #expect(secretPuts(w).count == 1)
        who.own = true
        await r.run(studio)
        let puts = secretPuts(w)
        #expect(puts.count == 2 && puts.last?.presence == true)
        #expect(puts.last?.body["push_secret"] == secret.pushSecret && puts.last?.path.hasSuffix(secret.secretID ?? "?") == true)
        #expect(flag(w, studio) == true)
        // One row's flag at the gateway, and the computer's entry in the store as it was. (The
        // helper is registered once more for the presence key: PresenceKeyTests.)
        #expect(w.gateway.writes == writes + 1)
        #expect(w.store.value?.servers[studio.uuidString] == secret)
        // Said once: later runs and returns to the front send nothing.
        for _ in 0..<3 {
            r.cameToFront()
            await r.run(studio, by: .person)
        }
        await w.quiet()
        #expect(secretPuts(w).count == 2)
    }

    @Test func aChangeOfOwnerIsSaidOnce() async {
        let w = world()
        let r = w.reconciler()
        let who = Owner()
        who.own = true
        r.ownership = { _ in who.own }
        await r.run(studio)
        #expect(flag(w, studio) == true)
        who.own = false
        await r.run(studio)
        await r.run(studio)
        #expect(flag(w, studio) == false)
        #expect(secretPuts(w).map(\.presence) == [true, false])
        // Unknown again: nothing is sent, and the gateway keeps what it holds.
        who.own = nil
        await r.run(studio)
        #expect(secretPuts(w).count == 2 && flag(w, studio) == false)
    }

    @Test func theAppStartedAgainSaysItOnceMore() async {
        let w = world()
        let first = w.reconciler()
        first.ownership = { _ in true }
        await first.run(studio)
        let writes = w.gateway.writes
        let second = w.reconciler()
        second.ownership = { _ in true }
        await second.run(studio)
        await second.run(studio)
        // One request, which the gateway answers without a write: it holds the flag already.
        #expect(secretPuts(w).count == 2 && w.gateway.writes == writes)
    }

    @Test func aRefusedFlagChangesNothingAndIsSentAgainInTheNextStayInFront() async {
        let w = world()
        let r = w.reconciler()
        await r.run(studio)
        r.ownership = { _ in true }
        w.gateway.turns = [.refuse(503)]
        await r.run(studio)
        #expect(flag(w, studio) == nil)
        // Sign-up is as it was: no failure, no retry, no word in Settings.
        #expect(r.helpers[studio] == .running(pushEnabled: true))
        #expect(r.retrying.isEmpty && r.stopped.isEmpty && r.problem == nil && r.limit == nil)
        // Not again in this stay.
        await r.run(studio)
        #expect(secretPuts(w).count == 2)
        r.cameToFront()
        await w.eventually { flag(w, studio) == true }
        #expect(flag(w, studio) == true && secretPuts(w).count == 3)
    }

    /// The computer is removed from the app while the flag is on its way: the secret that
    /// request may have stored again is deleted, so nothing is left at the gateway.
    @Test func aComputerRemovedWhileItsFlagIsOnItsWayLeavesNoSecretBehind() async throws {
        let w = world()
        let r = w.reconciler()
        await r.run(studio)
        let secretID = try #require(w.store.value?.servers[studio.uuidString]?.secretID)
        let who = Owner()
        r.ownership = { [studio] _ in
            // Asked as the flag is about to go: the person removes the computer right then.
            if who.own == nil {
                who.own = true
                r.forget(studio)
            }
            return who.own
        }
        await r.run(studio)
        await w.eventually { w.gateway.devices.values.first?.secrets[secretID] == nil && w.store.value?.retired == nil }
        #expect(w.gateway.devices.values.first?.secrets.isEmpty == true)
        #expect(w.store.value?.servers[studio.uuidString] == nil && w.store.value?.retired == nil)
    }

    @Test func aComputerThatIsTurnedOffIsNotFlagged() async {
        let w = world()
        let r = w.reconciler()
        await r.run(studio)
        r.ownership = { _ in true }
        w.intents[studio] = .paused
        await r.run(studio, by: .person)
        #expect(secretPuts(w).count == 1 && flag(w, studio) == nil)
    }

    /// A gateway from before the flag ignores the field: sign-up is the same, and the app has
    /// said it once.
    @Test func aGatewayThatDoesNotKnowTheFlagTakesTheSameRequests() async {
        let w = world()
        w.gateway.knowsPresence = false
        let r = w.reconciler()
        r.ownership = { _ in true }
        await r.run(studio)
        await r.run(studio)
        #expect(secretPuts(w).count == 1 && flag(w, studio) == nil)
        #expect(r.helpers[studio] == .running(pushEnabled: true) && w.helpers[studio].secret != nil)
    }
}
