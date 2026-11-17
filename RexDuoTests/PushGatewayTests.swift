import Foundation
import Testing
import RexKit
@testable import RexDuo

/// The phone's side of the push gateway: requests, replies, and when it registers, updates or
/// deletes its registration.
@MainActor
struct PushGatewayTests {
    /// A gateway that records what it is asked and answers from a script.
    final class Fake: @unchecked Sendable {
        // Only touched from the main actor: the tests and `GatewayLink` both run there.
        nonisolated(unsafe) var requests: [URLRequest] = []
        nonisolated(unsafe) var replies: [(Int, String)] = []
        nonisolated(unsafe) var fails = false

        func gateway(_ address: String = "https://push.example") -> PushGateway {
            PushGateway(address: address) { [self] request in
                await MainActor.run {
                    requests.append(request)
                }
                if await MainActor.run(body: { fails }) { throw URLError(.notConnectedToInternet) }
                let (status, body) = await MainActor.run { replies.isEmpty ? (200, "{}") : replies.removeFirst() }
                let http = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
                return (Data(body.utf8), http)
            }!
        }

        var calls: [String] { requests.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" } }
    }

    private let created = #"{"device_id":"dev1","owner_key":"own1"}"#
    private let again = #"{"device_id":"dev2","owner_key":"own2"}"#
    private let minted = #"{"secret_id":"sid1","push_secret":"sec1"}"#
    /// The gateway's own 401, the same for an unknown phone and a wrong key.
    private let gone = #"{"error":"unauthorized","message":"Unknown device or key."}"#
    private let server = "11111111-1111-1111-1111-111111111111"

    /// A store whose Keychain calls can be made to fail.
    final class FailingStore: RegistrationStore {
        struct Refused: Error {}
        var value: GatewayRegistration?
        var failsLoad = false, failsSave = false, failsClear = false
        func load() throws -> GatewayRegistration? {
            if failsLoad { throw Refused() }
            return value
        }
        func save(_ registration: GatewayRegistration) throws {
            if failsSave { throw Refused() }
            value = registration
        }
        func clear() throws {
            if failsClear { throw Refused() }
            value = nil
        }
    }

    private func sample(_ device: String = "dev1", owner: String = "own1") -> GatewayRegistration {
        GatewayRegistration(gateway: "https://push.example", device: device, ownerKey: owner, token: token, environment: "sandbox")
    }

    /// A link that has registered and pinned `server`'s helper.
    private func pinned(_ fake: Fake, _ store: RegistrationStore) async -> GatewayLink {
        fake.replies = [(201, created)]
        let link = GatewayLink(gateway: fake.gateway(), store: store)
        _ = await link.registration(token: token, environment: "sandbox")
        #expect(link.pin(server, helperKey: "key1"))
        return link
    }
    private let token = String(repeating: "ab", count: 32)

    private func body(_ r: URLRequest) -> [String: String] {
        (try? JSONSerialization.jsonObject(with: r.httpBody ?? Data())) as? [String: String] ?? [:]
    }

    // MARK: Addresses

    @Test func onlyHTTPSOrThisMachine() {
        #expect(PushGateway.base(from: "https://push.example/")?.absoluteString == "https://push.example")
        #expect(PushGateway.base(from: " https://Push.Example/v1/x?y=1 ")?.absoluteString == "https://push.example")
        #expect(PushGateway.base(from: "http://127.0.0.1:8787")?.absoluteString == "http://127.0.0.1:8787")
        #expect(PushGateway.base(from: "http://localhost:8787") != nil)
        #expect(PushGateway.base(from: "http://push.example") == nil)
        #expect(PushGateway.base(from: "https://user:pw@push.example") == nil)
        #expect(PushGateway.base(from: "ftp://push.example") == nil)
        #expect(PushGateway.base(from: "push.example") == nil)
        #expect(PushGateway.base(from: "") == nil)
        #expect(PushGateway.base(from: PushGateway.defaultURL) != nil)
    }

    // MARK: Requests and replies

    @Test func registrationSendsTheTokenAndKeepsTheTwoValues() async throws {
        let fake = Fake()
        fake.replies = [(201, created)]
        let r = try await fake.gateway().register(token: token, environment: "sandbox")
        #expect(r == sample())
        let q = try #require(fake.requests.first)
        #expect(q.httpMethod == "POST" && q.url?.absoluteString == "https://push.example/v1/devices")
        #expect(body(q) == ["apns_token": token, "environment": "sandbox"])
        #expect(q.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(q.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    @Test func updateAndDeleteProveOwnership() async throws {
        let fake = Fake()
        let reg = sample()
        try await fake.gateway().update(reg, token: "cd", environment: "production")
        fake.replies = [(204, "")]
        try await fake.gateway().delete(reg)
        #expect(fake.calls == ["PUT /v1/devices/dev1", "DELETE /v1/devices/dev1"])
        #expect(fake.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer own1" })
        #expect(body(fake.requests[0]) == ["apns_token": "cd", "environment": "production"])
    }

    @Test func secretsAreMintedListedAndDeletedWithTheOwnerKey() async throws {
        let fake = Fake()
        fake.replies = [(201, minted), (200, #"{"environment":"sandbox","secrets":[{"secret_id":"sid1","label":"Studio","created_at":1700000000},{"secret_id":"sid2","label":"Desk","created_at":1700000001}]}"#), (204, "")]
        let gateway = fake.gateway()
        let made = try await gateway.mint(sample(), label: "Studio")
        #expect(made.secretID == "sid1" && made.pushSecret == "sec1")
        #expect(try await gateway.secrets(sample()) == ["sid1", "sid2"])
        try await gateway.deleteSecret(sample(), secretID: "sid1")
        #expect(fake.calls == ["POST /v1/devices/dev1/secrets", "GET /v1/devices/dev1", "DELETE /v1/devices/dev1/secrets/sid1"])
        #expect(fake.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer own1" })
        #expect(body(fake.requests[0]) == ["label": "Studio"])
        #expect(fake.requests[1].httpBody == nil)
        // The push secret is for helpers: the phone never sends it to the gateway.
        #expect(fake.requests.allSatisfy { !String(describing: $0.allHTTPHeaderFields).contains("sec1") })
    }

    @Test func aPhoneTheGatewayForgotAnswersTheSameOnEveryOwnerRoute() async {
        let fake = Fake()
        fake.replies = Array(repeating: (401, gone), count: 5)
        let gateway = fake.gateway()
        let r = sample()
        await #expect(throws: GatewayError.unknownRegistration) { try await gateway.secrets(r) }
        await #expect(throws: GatewayError.unknownRegistration) { try await gateway.mint(r, label: "Studio") }
        await #expect(throws: GatewayError.unknownRegistration) { try await gateway.deleteSecret(r, secretID: "sid1") }
        await #expect(throws: GatewayError.unknownRegistration) { try await gateway.update(r, token: "cd", environment: "sandbox") }
        await #expect(throws: GatewayError.unknownRegistration) { try await gateway.delete(r) }
    }

    @Test func statusesMapToWhatToDoNext() {
        #expect(throws: Never.self) { try PushGateway.check(200) }
        #expect(throws: Never.self) { try PushGateway.check(204) }
        #expect(throws: GatewayError.unknownRegistration) { try PushGateway.check(401, body: Data(gone.utf8)) }
        // A 401 that isn't the gateway's own (a proxy, a sign-in page) is a passing fault.
        #expect(throws: GatewayError.unavailable) { try PushGateway.check(401, body: Data("<html>Sign in</html>".utf8)) }
        #expect(throws: GatewayError.unavailable) { try PushGateway.check(401) }
        #expect(throws: GatewayError.rejected(404)) { try PushGateway.check(404) }
        #expect(throws: GatewayError.rejected(409)) { try PushGateway.check(409) }
        #expect(throws: GatewayError.rateLimited) { try PushGateway.check(429) }
        #expect(throws: GatewayError.unavailable) { try PushGateway.check(503) }
        #expect(throws: GatewayError.rejected(400)) { try PushGateway.check(400) }
    }

    @Test func aReplyMissingAValueIsRefused() throws {
        #expect(throws: GatewayError.malformedReply) { try PushGateway.registered(Data(#"{"device_id":"d"}"#.utf8)) }
        #expect(throws: GatewayError.malformedReply) { try PushGateway.registered(Data(#"{"device_id":"d","owner_key":""}"#.utf8)) }
        #expect(throws: GatewayError.malformedReply) { try PushGateway.registered(Data("<html>".utf8)) }
        #expect(throws: GatewayError.malformedReply) { try PushGateway.minted(Data(#"{"secret_id":"s"}"#.utf8)) }
        #expect(throws: GatewayError.malformedReply) { try PushGateway.minted(Data(#"{"secret_id":"s","push_secret":""}"#.utf8)) }
        #expect(throws: GatewayError.malformedReply) { try PushGateway.secretIDs(Data(#"{"environment":"sandbox"}"#.utf8)) }
        #expect(try PushGateway.secretIDs(Data(#"{"secrets":[]}"#.utf8)) == [])
    }

    // MARK: The link

    @Test func stepsFollowWhatIsStored() {
        let reg = sample()
        func step(_ r: GatewayRegistration?, gateway: String = "https://push.example", token t: String? = nil, env: String = "sandbox") -> GatewayLink.Step {
            GatewayLink.step(stored: r, gateway: gateway, token: t ?? token, environment: env)
        }
        #expect(step(nil) == .register)
        #expect(step(reg) == .use)
        #expect(step(reg, token: "ff") == .update)
        // A debug build and a TestFlight build on one phone have different environments.
        #expect(step(reg, env: "production") == .update)
        #expect(step(reg, gateway: "https://other.example") == .register)
        var revoked = reg
        revoked.revoked = true
        #expect(step(revoked) == .register)
    }

    @Test func registersOnceThenReusesIt() async {
        let fake = Fake()
        fake.replies = [(201, created)]
        let store = MemoryRegistrationStore()
        let link = GatewayLink(gateway: fake.gateway(), store: store)
        let first = await link.registration(token: token, environment: "sandbox")
        let second = await link.registration(token: token, environment: "sandbox")
        #expect(first == second)
        #expect((try? first.get())?.device == "dev1")
        #expect(fake.calls == ["POST /v1/devices"])
        #expect(store.value?.ownerKey == "own1")
    }

    @Test func callersAtTheSameTimeShareOneRegistration() async {
        let fake = Fake()
        fake.replies = [(201, created)]
        let link = GatewayLink(gateway: fake.gateway(), store: MemoryRegistrationStore())
        async let a = link.registration(token: token, environment: "sandbox")
        async let b = link.registration(token: token, environment: "sandbox")
        let (x, y) = await (a, b)
        #expect(x == y)
        #expect(fake.calls == ["POST /v1/devices"])
    }

    @Test func aRotatedTokenUpdatesAndKeepsTheSecrets() async {
        let fake = Fake()
        let store = MemoryRegistrationStore()
        let link = await pinned(fake, store)
        fake.replies = [(201, minted), (200, "{}")]
        #expect(await link.mint(server, label: "Studio") == .success("sec1"))
        let rotated = await link.registration(token: "ff00", environment: "sandbox")
        #expect((try? rotated.get())?.servers[server]?.pushSecret == "sec1")
        #expect(store.value?.token == "ff00")
        #expect(fake.calls == ["POST /v1/devices", "POST /v1/devices/dev1/secrets", "PUT /v1/devices/dev1"])
    }

    @Test func aRegistrationTheGatewayDroppedIsMadeAgain() async {
        let fake = Fake()
        let store = MemoryRegistrationStore()
        let link = await pinned(fake, store)
        fake.replies = [(201, minted), (401, gone), (201, again)]
        _ = await link.mint(server, label: "Studio")
        let r = await link.registration(token: "ff00", environment: "sandbox")
        #expect((try? r.get())?.device == "dev2")
        #expect(store.value?.device == "dev2" && store.value?.token == "ff00")
        // The helper is still who it was; its secret died with the old registration.
        #expect(store.value?.servers[server] == ServerPush(helperKey: "key1"))
        #expect(Array(fake.calls.suffix(2)) == ["PUT /v1/devices/dev1", "POST /v1/devices"])
    }

    // MARK: Per-server secrets

    @Test func aSecretIsMintedOnlyForAPinnedHelperAndKeptWithItsKey() async {
        let fake = Fake()
        let store = MemoryRegistrationStore()
        fake.replies = [(201, created)]
        let link = GatewayLink(gateway: fake.gateway(), store: store)
        _ = await link.registration(token: token, environment: "sandbox")
        #expect(link.server(server) == nil)
        #expect(await link.mint(server, label: "Studio") == .failure(.unavailable))
        #expect(link.pin(server, helperKey: "key1"))
        // The first key stays: a pin is only replaced through `trust`.
        #expect(link.pin(server, helperKey: "key2"))
        #expect(link.server(server) == ServerPush(helperKey: "key1"))
        fake.replies = [(201, minted)]
        #expect(await link.mint(server, label: "Studio") == .success("sec1"))
        #expect(link.server(server) == ServerPush(helperKey: "key1", secretID: "sid1", pushSecret: "sec1"))
        #expect(fake.calls == ["POST /v1/devices", "POST /v1/devices/dev1/secrets"])
    }

    @Test func twoServersKeepTheirOwnSecrets() async {
        let fake = Fake()
        let store = MemoryRegistrationStore()
        let link = await pinned(fake, store)
        let other = "22222222-2222-2222-2222-222222222222"
        #expect(link.pin(other, helperKey: "key2"))
        fake.replies = [(201, minted), (201, #"{"secret_id":"sid2","push_secret":"sec2"}"#)]
        async let a = link.mint(server, label: "Studio")
        async let b = link.mint(other, label: "Desk")
        _ = await (a, b)
        #expect(Set([link.server(server)?.pushSecret, link.server(other)?.pushSecret]) == ["sec1", "sec2"])
    }

    @Test func trustingAChangedHelperDeletesTheOldSecretAndPinsTheNewKey() async {
        let fake = Fake()
        let store = MemoryRegistrationStore()
        let link = await pinned(fake, store)
        fake.replies = [(201, minted), (204, "")]
        _ = await link.mint(server, label: "Studio")
        #expect(await link.trust(server, helperKey: "key2"))
        #expect(link.server(server) == ServerPush(helperKey: "key2"))
        #expect(fake.calls.last == "DELETE /v1/devices/dev1/secrets/sid1")
    }

    @Test func removingAServerDeletesItsSecretAndPin() async {
        let fake = Fake()
        let store = MemoryRegistrationStore()
        let link = await pinned(fake, store)
        fake.replies = [(201, minted)]
        _ = await link.mint(server, label: "Studio")
        // Best effort: the entry goes even when the gateway can't be told.
        fake.fails = true
        await link.forget(server, keepPin: false)
        #expect(link.server(server) == nil)
        #expect(fake.calls.last == "DELETE /v1/devices/dev1/secrets/sid1")
        #expect(store.value?.device == "dev1")
    }

    // MARK: Repair

    @Test func repairDecidesFromWhatTheGatewayStillHas() {
        #expect(SecretRepair.step(lookup: .failure(.unknownRegistration)) == .registerDevice)
        #expect(SecretRepair.step(lookup: .success([])) == .mintSecret)
        // Still listed, but the helper stopped accepting it: replaced all the same.
        #expect(SecretRepair.step(lookup: .success(["sid1"])) == .mintSecret)
        #expect(SecretRepair.step(lookup: .failure(.unavailable)) == .wait(.unavailable))
        #expect(SecretRepair.step(lookup: .failure(.rateLimited)) == .wait(.rateLimited))
        #expect(SecretRepair.onRefusal(repaired: false) == .repair)
        #expect(SecretRepair.onRefusal(repaired: true) == .giveUp)
        #expect(SecretRepair.gaveUp(helper: "Studio").hasSuffix("."))
    }

    @Test func aSecretTheGatewayLostIsDroppedSoANewOneIsMinted() async {
        let fake = Fake()
        let store = MemoryRegistrationStore()
        let link = await pinned(fake, store)
        fake.replies = [(201, minted), (200, #"{"environment":"sandbox","secrets":[]}"#), (204, ""),
                        (201, #"{"secret_id":"sid2","push_secret":"sec2"}"#)]
        _ = await link.mint(server, label: "Studio")
        #expect(await link.repair(server, token: token, environment: "sandbox") == nil)
        #expect(link.server(server) == ServerPush(helperKey: "key1"))
        #expect(await link.mint(server, label: "Studio") == .success("sec2"))
        #expect(Array(fake.calls.suffix(3)) == ["GET /v1/devices/dev1", "DELETE /v1/devices/dev1/secrets/sid1",
                                                "POST /v1/devices/dev1/secrets"])
    }

    @Test func aPhoneTheGatewayLostRegistersAfreshAndEveryServerNeedsANewSecret() async {
        let fake = Fake()
        let store = MemoryRegistrationStore()
        let link = await pinned(fake, store)
        let other = "22222222-2222-2222-2222-222222222222"
        #expect(link.pin(other, helperKey: "key2"))
        fake.replies = [(201, minted), (401, gone), (201, again)]
        _ = await link.mint(server, label: "Studio")
        #expect(await link.repair(server, token: token, environment: "sandbox") == nil)
        #expect(store.value?.device == "dev2" && store.value?.ownerKey == "own2")
        #expect(store.value?.servers == [server: ServerPush(helperKey: "key1"), other: ServerPush(helperKey: "key2")])
        #expect(Array(fake.calls.suffix(2)) == ["GET /v1/devices/dev1", "POST /v1/devices"])

        // The other server's repair finds the new registration and doesn't register a third time.
        fake.replies = [(200, #"{"environment":"sandbox","secrets":[]}"#)]
        #expect(await link.repair(other, token: token, environment: "sandbox") == nil)
        #expect(store.value?.device == "dev2")
        #expect(fake.calls.last == "GET /v1/devices/dev2")
    }

    @Test func aRepairThatCannotReachTheGatewayChangesNothing() async {
        let fake = Fake()
        let store = MemoryRegistrationStore()
        let link = await pinned(fake, store)
        fake.replies = [(201, minted)]
        _ = await link.mint(server, label: "Studio")
        fake.fails = true
        #expect(await link.repair(server, token: token, environment: "sandbox") == .unavailable)
        #expect(link.server(server)?.pushSecret == "sec1")
    }

    // MARK: A Keychain that fails

    @Test func aRegistrationThatCannotBeSavedFailsAndIsTakenBack() async {
        let fake = Fake()
        let store = FailingStore()
        store.failsSave = true
        fake.replies = [(201, created), (204, "")]
        let link = GatewayLink(gateway: fake.gateway(), store: store)
        #expect(await link.registration(token: token, environment: "sandbox") == .failure(.storeFailed))
        #expect(store.value == nil)
        #expect(fake.calls == ["POST /v1/devices", "DELETE /v1/devices/dev1"])
    }

    @Test func aKeychainThatCannotBeReadRegistersNothing() async {
        let fake = Fake()
        let store = FailingStore()
        store.failsLoad = true
        let link = GatewayLink(gateway: fake.gateway(), store: store)
        #expect(await link.registration(token: token, environment: "sandbox") == .failure(.storeFailed))
        #expect(fake.calls.isEmpty)
        // It may hold a registration that still needs deleting.
        #expect(link.hasRegistration)
        #expect(await link.revoke() == false)
    }

    @Test func aSecretThatCannotBeSavedIsNeverHandedOut() async {
        let fake = Fake()
        let store = FailingStore()
        let link = await pinned(fake, store)
        store.failsSave = true
        fake.replies = [(201, minted), (204, "")]
        #expect(await link.mint(server, label: "Studio") == .failure(.storeFailed))
        #expect(link.server(server) == ServerPush(helperKey: "key1"))
        #expect(fake.calls.last == "DELETE /v1/devices/dev1/secrets/sid1")
        // Nor is a helper pinned, or a changed one trusted, without a record of it.
        #expect(!link.pin("33333333-3333-3333-3333-333333333333", helperKey: "key3"))
        #expect(await link.trust(server, helperKey: "key2") == false)
        #expect(link.server(server)?.helperKey == "key1")
    }

    @Test func aRegistrationTheKeychainWillNotDeleteStaysRevoked() async {
        let fake = Fake()
        let store = FailingStore()
        let link = await pinned(fake, store)
        store.failsClear = true
        fake.replies = [(204, "")]
        #expect(await link.revoke() == false)
        #expect(store.value?.revoked == true)
        #expect(link.hasRegistration)
        // Revoked, so nothing of it is handed out meanwhile.
        #expect(link.server(server) == nil)

        // The retry: the gateway has already forgotten it, and now the Keychain lets go.
        store.failsClear = false
        fake.replies = [(401, gone)]
        #expect(await link.revoke())
        #expect(store.value == nil && !link.hasRegistration)
    }

    @Test func failuresComeBackAndNothingIsStored() async {
        let fake = Fake()
        let store = MemoryRegistrationStore()
        let link = GatewayLink(gateway: fake.gateway(), store: store)
        fake.replies = [(429, "{}")]
        #expect(await link.registration(token: token, environment: "sandbox") == .failure(.rateLimited))
        fake.fails = true
        #expect(await link.registration(token: token, environment: "sandbox") == .failure(.unavailable))
        #expect(store.value == nil)
        #expect(await GatewayLink(gateway: nil, store: store).registration(token: token, environment: "sandbox") == .failure(.badAddress))
    }

    @Test func turningOffDeletesTheRegistration() async {
        let fake = Fake()
        fake.replies = [(201, created), (204, "")]
        let store = MemoryRegistrationStore()
        let link = GatewayLink(gateway: fake.gateway(), store: store)
        _ = await link.registration(token: token, environment: "sandbox")
        #expect(link.hasRegistration)
        #expect(await link.revoke())
        #expect(store.value == nil && !link.hasRegistration)
        #expect(fake.calls.last == "DELETE /v1/devices/dev1")
        // Nothing stored: nothing to ask.
        #expect(await link.revoke())
        #expect(fake.calls.count == 2)
    }

    @Test func turningOffWhileOfflineIsRememberedAndRetried() async {
        let fake = Fake()
        fake.replies = [(201, created)]
        let store = MemoryRegistrationStore()
        let link = GatewayLink(gateway: fake.gateway(), store: store)
        _ = await link.registration(token: token, environment: "sandbox")
        fake.fails = true
        #expect(await link.revoke() == false)
        #expect(store.value?.revoked == true)
        #expect(link.hasRegistration)

        // Turned on again before the delete got through: the old registration is never used again.
        fake.fails = false
        fake.replies = [(204, ""), (201, again)]
        let r = await link.registration(token: token, environment: "sandbox")
        #expect((try? r.get())?.device == "dev2")
        #expect(Array(fake.calls.suffix(2)) == ["DELETE /v1/devices/dev1", "POST /v1/devices"])
        #expect(store.value?.revoked == nil)
    }

    @Test func aRegistrationTheGatewayAlreadyForgotCountsAsDeleted() async {
        let fake = Fake()
        fake.replies = [(201, created), (401, gone)]
        let store = MemoryRegistrationStore()
        let link = GatewayLink(gateway: fake.gateway(), store: store)
        _ = await link.registration(token: token, environment: "sandbox")
        #expect(await link.revoke())
        #expect(store.value == nil)
    }

    @Test func theKeychainKeepsARegistration() throws {
        let store = KeychainRegistrationStore(service: "dev.abrahamgonzalez.rexduo.tests.\(UUID().uuidString)")
        defer { try? store.clear() }
        #expect(try store.load() == nil)
        var reg = sample()
        reg.servers[server] = ServerPush(helperKey: "key1", secretID: "sid1", pushSecret: "sec1")
        try store.save(reg)
        #expect(try store.load() == reg)
        reg.token = "ff"
        reg.revoked = true
        reg.servers[server] = ServerPush(helperKey: "key1")
        try store.save(reg)
        #expect(try store.load() == reg)
        try store.clear()
        #expect(try store.load() == nil)
        // Clearing what isn't there is not a failure.
        try store.clear()
    }

    @Test func anItemFromBeforePerServerSecretsStillReads() throws {
        let old = #"{"gateway":"https://push.example","device":"dev1","ownerKey":"own1","pushSecret":"sec1","token":"ab","environment":"sandbox"}"#
        let r = try JSONDecoder().decode(GatewayRegistration.self, from: Data(old.utf8))
        #expect(r.device == "dev1" && r.servers.isEmpty && r.revoked == nil)
    }

    // MARK: Helper versions

    @Test func helperStatusReadsIntoOneLine() {
        let current = HelperVersion(["version": "0.3.0", "latest_version": "0.3.0", "update_available": false, "can_update": true])
        #expect(current?.summary == "Version 0.3.0, up to date.")
        #expect(current?.offersUpdate == false)

        let behind = HelperVersion(["version": "0.3.0", "latest_version": "0.3.1", "update_available": true, "can_update": true,
                                    "updating": false, "last_error": NSNull()])
        #expect(behind?.summary == "Version 0.3.0. Version 0.3.1 is available.")
        #expect(behind?.offersUpdate == true)
        #expect(behind?.lastError == nil)

        // A development build knows of a newer version but can't replace itself: no button.
        let dev = HelperVersion(["version": "0.3.0", "latest_version": "0.3.1", "update_available": true, "can_update": false])
        #expect(dev?.offersUpdate == false)

        var busy = behind
        busy?.updating = true
        #expect(busy?.summary == "Updating to 0.3.1…")
        #expect(busy?.offersUpdate == false)

        // Before the first check comes back, it doesn't claim to be current.
        #expect(HelperVersion(["version": "0.3.0"])?.summary == "Version 0.3.0.")
        #expect(HelperVersion(["latest_version": "0.3.1"]) == nil)

        // Below the oldest version the release list allows: said plainly, with the button.
        let required = HelperVersion(["version": "0.3.0", "update_required": true, "can_update": true, "registered": false])
        #expect(required?.summary == "Version 0.3.0 needs an update to keep working.")
        #expect(required?.offersUpdate == true)
        #expect(required?.registered == false)
        #expect(current?.registered == nil && current?.updateRequired == false)
    }

    @Test func aHelperFromBeforeTheGatewayIsRecognised() {
        #expect(HelperVersion.isLegacyRefusal("token must be the APNs device token in hex"))
        #expect(!HelperVersion.isLegacyRefusal("gateway must be an https URL"))
    }

    @Test func gatewayProblemsReadAsSentences() {
        for p in [GatewayError.rateLimited, .unavailable, .rejected(400), .malformedReply, .badAddress, .unknownRegistration, .storeFailed] {
            let text = NotificationSettingsSection.text(for: p)
            #expect(text.hasSuffix(".") && !text.contains("GatewayError"))
        }
    }
}
