import Foundation
import Testing
import RexKit
@testable import Pteron

/// The phone's presence key: its form, where it is kept, which computers' helpers are given
/// it, and that no description of it shows it.
@MainActor
struct PresenceKeyTests {
    private let studio = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let laptop = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    /// Bytes 0 to 31, as base64url without padding: plainly not a real key.
    private static let dummy = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"

    /// Whose computer each one is, as the app comes to know it.
    @MainActor
    private final class Owners {
        var own: [UUID: Bool] = [:]
    }

    private func world(two: Bool = false) -> (PushWorld, Owners) {
        let w = PushWorld()
        w.helpers.add(studio, name: "Studio")
        if two { w.helpers.add(laptop, name: "Laptop") }
        return (w, Owners())
    }

    private func reconciler(_ w: PushWorld, _ owners: Owners) -> PushReconciler {
        let r = w.reconciler()
        r.ownership = { owners.own[$0] }
        return r
    }

    // MARK: The form

    @Test func aKeyIs32BytesInTheOneSpellingTheHelperTakes() throws {
        let key = try #require(PresenceKey(Self.dummy))
        #expect(key.wireValue == Self.dummy && key.wireValue.count == 43)
        // A made key has that form too, and two are not the same.
        let a = try #require(PresenceKey.make(.system)), b = try #require(PresenceKey.make(.system))
        #expect(a.wireValue.count == 43 && PresenceKey(a.wireValue) == a && a != b)
        #expect(a.wireValue.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        // Not keys: another length, padding, the standard alphabet, a 43rd character that
        // spells bits 32 bytes do not have, text that is no base64 at all.
        let wrong = ["", String(Self.dummy.dropLast()), Self.dummy + "A", Self.dummy + "=", String(Self.dummy.dropLast()) + "=",
                     String(Self.dummy.dropLast()) + "9", "+" + Self.dummy.dropFirst(), "/" + Self.dummy.dropFirst(),
                     String(repeating: " ", count: 43), String(repeating: "é", count: 43)]
        for text in wrong { #expect(PresenceKey(text) == nil, "\(text.count) characters") }
    }

    @Test func aKeyIsStoredAsItsTextAndReadBack() throws {
        let key = try #require(PresenceKey(Self.dummy))
        var record = GatewayRegistration(gateway: "https://push.example", device: "d", ownerKey: "o", token: "t", environment: "sandbox")
        record.presenceKey = key
        let data = try JSONEncoder().encode(record)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["presenceKey"] as? String == Self.dummy)
        #expect(try JSONDecoder().decode(GatewayRegistration.self, from: data) == record)
    }

    @Test func anItemFromBeforeTheKeyOrWithABadOneStillReads() throws {
        let before = #"{"gateway":"https://push.example","device":"d","ownerKey":"o","token":"t","environment":"sandbox"}"#
        #expect(try JSONDecoder().decode(GatewayRegistration.self, from: Data(before.utf8)).presenceKey == nil)
        for bad in [#""short""#, "7", "null", #"{"a":1}"#] {
            let text = #"{"gateway":"https://push.example","device":"d","ownerKey":"o","token":"t","environment":"sandbox","presenceKey":\#(bad)}"#
            let read = try JSONDecoder().decode(GatewayRegistration.self, from: Data(text.utf8))
            #expect(read.presenceKey == nil && read.ownerKey == "o", "\(bad)")
        }
    }

    // MARK: Never shown

    /// There is no log to capture in the app's tests, so this holds every way a value turns
    /// into text: its description, its debug description, a dump, string interpolation, and
    /// the same for the record and an optional that hold it.
    @Test func noDescriptionOfTheKeyOrOfWhatHoldsItShowsIt() throws {
        let key = try #require(PresenceKey(Self.dummy))
        var record = GatewayRegistration(gateway: "https://push.example", device: "d", ownerKey: "o", token: "t", environment: "sandbox")
        record.presenceKey = key
        var dumped = ""
        dump(key, to: &dumped)
        dump(record, to: &dumped)
        dump(Optional(key) as Any, to: &dumped)
        let texts = [String(describing: key), String(reflecting: key), "\(key)", String(describing: Optional(key)),
                     String(describing: record), String(reflecting: record), "\(record)", dumped,
                     String(describing: Mirror(reflecting: key).children.map { "\($0)" })]
        for text in texts {
            #expect(!text.contains(Self.dummy))
            #expect(!text.contains(Self.dummy.prefix(8)))
        }
        #expect(String(describing: key) == "PresenceKey(<redacted>)")
        #expect(String(describing: record).contains("<redacted>"))
    }

    // MARK: Made once

    @Test func theKeyIsMadeOnceAndReusedAcrossLaunches() async throws {
        let (w, owners) = world()
        owners.own[studio] = true
        let first = reconciler(w, owners)
        await first.run(studio)
        let key = try #require(w.store.value?.presenceKey)
        #expect(w.helpers[studio].presenceKey == key.wireValue)
        // More runs, and a new connection: the same key.
        await first.run(studio, by: .person)
        w.helpers[studio].serial = 2
        await first.run(studio)
        #expect(w.store.value?.presenceKey == key)
        // The app started again over the same store: the same key again.
        let second = reconciler(w, owners)
        w.helpers[studio].serial = 3
        await second.run(studio)
        #expect(w.store.value?.presenceKey == key)
        #expect(w.helpers[studio].presenceKeys.compactMap { $0 }.allSatisfy { $0 == key.wireValue })
        #expect(w.helpers[studio].presenceKeys.count == 3 && w.helpers[studio].presenceKey == key.wireValue)
    }

    @Test func theSameKeyThroughTwoRegistrarsOverOneStore() async throws {
        let (w, _) = world()
        func registrar() -> PushRegistrar {
            let system = PushRegistrar.System(permission: { .allowed }, ask: {}, registerForNotifications: {},
                                              unregisterForNotifications: {}, openSettings: {}, deviceName: { "Test iPhone" })
            let push = PushRegistrar(prefs: w.prefs, deviceID: "abcd1234", environment: "sandbox", defaults: w.defaults,
                                     parts: w.parts, system: system)
            // The registrar's own answer comes from the app's servers, which a test has none
            // of: the rule itself is `ServerIdentity.isConfirmedOwn`, tested in RexKit.
            push.reconciler.ownership = { _ in true }
            return push
        }
        w.defaults.set(PushWorld.token, forKey: "pushToken.last")
        w.prefs.pushEnabled = true
        let first = registrar()
        await first.refresh()
        await w.eventually { w.helpers[studio].presenceKey != nil }
        let key = try #require(w.store.value?.presenceKey)
        #expect(w.helpers[studio].presenceKey == key.wireValue)
        w.helpers[studio].serial = 2
        let second = registrar()
        await second.refresh()
        await w.eventually { w.helpers[studio].presenceKeys.count >= 2 }
        await w.quiet()
        #expect(w.store.value?.presenceKey == key)
        #expect(w.helpers[studio].presenceKeys.allSatisfy { $0 == key.wireValue })
    }

    @Test func noKeyIsMadeWhileNoComputerIsThePersonsOwn() async {
        let (w, owners) = world(two: true)
        owners.own[laptop] = false
        let r = reconciler(w, owners)
        for id in w.helpers.computers { await r.run(id) }
        #expect(w.store.value?.presenceKey == nil)
        #expect(w.helpers[studio].presenceKeys == [nil] && w.helpers[laptop].presenceKeys == [nil])
    }

    // MARK: Who is given it

    @Test func aConfirmedOwnComputerIsGivenTheKey() async throws {
        let (w, owners) = world()
        owners.own[studio] = true
        let r = reconciler(w, owners)
        await r.run(studio)
        let key = try #require(w.store.value?.presenceKey)
        #expect(w.helpers[studio].presenceKeys == [key.wireValue])
        #expect(w.helpers[studio].count("register_push") == 1)
        #expect(PresenceKey(key.wireValue) != nil)
    }

    @Test func anUnknownAndAKnownOtherComputerAreNotGivenIt() async throws {
        let (w, owners) = world(two: true)
        owners.own[studio] = true
        let r = reconciler(w, owners)
        await r.run(studio)
        let key = try #require(w.store.value?.presenceKey)
        // Unknown.
        await r.run(laptop)
        #expect(w.helpers[laptop].presenceKeys == [nil] && w.helpers[laptop].secret != nil)
        // Known to be someone else's, on a new connection.
        owners.own[laptop] = false
        w.helpers[laptop].serial = 2
        await r.run(laptop)
        #expect(w.helpers[laptop].presenceKeys == [nil, nil])
        #expect(w.helpers[laptop].presenceKey == nil && w.helpers[studio].presenceKey == key.wireValue)
    }

    /// Registered before the app knew whose computer it is: once it knows, the helper is
    /// registered once more, now with the key, and then left alone.
    @Test func aComputerRegisteredBeforeItsOwnerWasKnownIsRegisteredAgainWithTheKey() async throws {
        let (w, owners) = world()
        let r = reconciler(w, owners)
        await r.run(studio)
        #expect(w.helpers[studio].presenceKeys == [nil])
        let secret = w.helpers[studio].secret
        owners.own[studio] = true
        await r.run(studio)
        let key = try #require(w.store.value?.presenceKey)
        #expect(w.helpers[studio].presenceKeys == [nil, key.wireValue])
        // The same secret, the helper's key proven again first, and not paused.
        #expect(w.helpers[studio].secret == secret && !w.helpers[studio].paused)
        #expect(w.helpers[studio].count("helper_identity") == 2)
        #expect(r.helpers[studio] == .running(pushEnabled: true) && r.relay(studio) != nil)
        for _ in 0..<3 { await r.run(studio, by: .person) }
        r.cameToFront()
        await w.quiet()
        #expect(w.helpers[studio].count("register_push") == 2)
    }

    @Test func aComputerThatStopsBeingOwnIsRegisteredAgainWithoutTheKey() async throws {
        let (w, owners) = world()
        owners.own[studio] = true
        let r = reconciler(w, owners)
        await r.run(studio)
        let key = try #require(w.store.value?.presenceKey)
        #expect(w.helpers[studio].presenceKey == key.wireValue)
        // Known to be someone else's now.
        owners.own[studio] = false
        await r.run(studio)
        #expect(w.helpers[studio].presenceKeys == [key.wireValue, nil] && w.helpers[studio].presenceKey == nil)
        #expect(w.helpers[studio].secret != nil, "it is registered, not skipped")
        // And when it can no longer be told: still without it, and no third registration.
        owners.own[studio] = nil
        await r.run(studio)
        #expect(w.helpers[studio].count("register_push") == 2 && w.helpers[studio].presenceKey == nil)
        // The phone keeps its key for its other computers.
        #expect(w.store.value?.presenceKey == key)
    }

    @Test func aPausedComputerIsNotRegisteredAgainForTheKey() async {
        let (w, owners) = world()
        let r = reconciler(w, owners)
        await r.run(studio)
        owners.own[studio] = true
        w.intents[studio] = .paused
        await r.run(studio, by: .person)
        #expect(w.helpers[studio].count("register_push") == 1 && w.helpers[studio].paused)
        // Turned on again: one registration, with the key, that also resumes.
        w.intents[studio] = nil
        await r.run(studio, by: .person)
        #expect(w.helpers[studio].count("register_push") == 2 && !w.helpers[studio].paused)
        #expect(w.helpers[studio].presenceKey != nil)
    }

    @Test func aKeyThatCannotBeStoredIsNotSent() async {
        let (w, owners) = world()
        let r = reconciler(w, owners)
        await r.run(studio)
        owners.own[studio] = true
        w.store.failsSave = true
        await r.run(studio)
        await r.run(studio)
        #expect(w.store.value?.presenceKey == nil)
        #expect(w.helpers[studio].presenceKeys == [nil, nil], "registered once more, without a key")
    }

    // MARK: Nowhere else

    @Test func theKeyGoesToTheHelperAndNeverToTheGateway() async throws {
        let (w, owners) = world(two: true)
        owners.own[studio] = true
        owners.own[laptop] = true
        let r = reconciler(w, owners)
        for id in w.helpers.computers { await r.run(id) }
        let key = try #require(w.store.value?.presenceKey).wireValue
        #expect(w.helpers[studio].presenceKey == key && w.helpers[laptop].presenceKey == key)
        #expect(!w.gateway.seen.isEmpty)
        for request in w.gateway.seen {
            #expect(!request.path.contains(key) && request.bearer != key)
            #expect(!request.body.values.contains(key) && !request.body.keys.contains("presence_key"))
        }
        // Nor in what Settings can show of a computer.
        for id in w.helpers.computers { #expect(!String(describing: r.helpers[id]).contains(key)) }
        #expect(!String(describing: r.problem).contains(key))
    }

    @Test func aFailedRegistrationSaysNothingOfTheKey() async throws {
        let (w, owners) = world()
        owners.own[studio] = true
        let r = reconciler(w, owners)
        await r.run(studio)
        let key = try #require(w.store.value?.presenceKey).wireValue
        // The helper refuses the next registration.
        w.helpers[studio].serial = 2
        let secret = try #require(w.helpers[studio].secret)
        w.helpers[studio].dropped = [secret]
        await r.run(studio)
        #expect(!String(describing: r.helpers[studio]).contains(key))
        #expect(!String(describing: r.problem).contains(key))
        let failure = HelperFailure(code: "bad_request", message: "presence_key must be a key")
        #expect(!failure.sentence(helper: "Studio").contains(key))
    }

    @Test func theArgumentIsThereOnlyWithAKey() throws {
        let key = try #require(PresenceKey(Self.dummy))
        func args(_ k: PresenceKey?) -> JSONObject {
            PushRegistration.arguments(gateway: "https://push.example", secret: "s", environment: "sandbox", deviceName: "n",
                                       deviceID: "abcd1234", presenceKey: k)
        }
        #expect(args(key)["presence_key"] as? String == Self.dummy)
        #expect(args(nil)["presence_key"] == nil && args(nil).count == 5)
    }
}
