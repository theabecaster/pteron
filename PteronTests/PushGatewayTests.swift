import Foundation
import Security
import Testing
import RexKit
@testable import Pteron

/// The phone's side of the push gateway: its addresses, requests and replies, and how the
/// registration is kept. When each request is made is in `PushReconcilerTests`.
@MainActor
struct PushGatewayTests {
    private let token = String(repeating: "ab", count: 32)
    private let server = "11111111-1111-1111-1111-111111111111"
    /// The gateway's own 401, the same for an unknown phone and a wrong key.
    private let gone = GatewayStandIn.unauthorized

    private func sample() -> GatewayRegistration {
        GatewayRegistration(gateway: "https://push.example", device: "dev1", ownerKey: "own1", token: token, environment: "sandbox")
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

    @Test func everyRequestIsAPutOrADeleteWithTheOwnerKey() async throws {
        let stand = GatewayStandIn()
        let gateway = stand.gateway()
        let owner = PushKeys.key(.system)
        var r = sample()
        r.ownerKey = owner
        r.device = PushKeys.deviceID(ownerKey: owner)
        let secret = PushKeys.key(.system), id = PushKeys.secretID(.system)
        try await gateway.putDevice(r, token: token, environment: "sandbox")
        try await gateway.putSecret(r, secretID: id, pushSecret: secret, label: "Studio")
        try await gateway.deleteSecret(r, secretID: id)
        #expect(stand.lines == ["PUT /v1/devices/\(r.device)", "PUT /v1/devices/\(r.device)/secrets/\(id)",
                                "DELETE /v1/devices/\(r.device)/secrets/\(id)"])
        #expect(stand.seen.allSatisfy { $0.bearer == owner })
        #expect(stand.seen[0].body == ["apns_token": token, "environment": "sandbox"])
        #expect(stand.seen[1].body == ["label": "Studio", "push_secret": secret])
        #expect(stand.seen[2].body.isEmpty)

        // The same requests again make and write nothing more.
        let writes = stand.writes
        try await gateway.putDevice(r, token: token, environment: "sandbox")
        try await gateway.deleteSecret(r, secretID: id)
        #expect(stand.writes == writes && stand.made == 1)

        // A device id that is not its key's is refused, and one the gateway does not have is unknown.
        var wrong = r
        wrong.device = String(repeating: "x", count: 22)
        await #expect(throws: GatewayError.rejected(400)) { try await gateway.putDevice(wrong, token: token, environment: "sandbox") }
        await #expect(throws: GatewayError.unknownRegistration) { try await gateway.putSecret(sample(), secretID: id, pushSecret: secret, label: "Studio") }
        await #expect(throws: GatewayError.unknownRegistration) { try await gateway.putDevice(sample(), token: token, environment: "sandbox") }
    }

    @Test func statusesMapToWhatToDoNext() {
        #expect(throws: Never.self) { try PushGateway.check(200) }
        #expect(throws: Never.self) { try PushGateway.check(204) }
        #expect(throws: GatewayError.unknownRegistration) { try PushGateway.check(401, body: Data(gone.utf8)) }
        // A 401 that isn't the gateway's own (a proxy, a sign-in page) is a passing fault.
        #expect(throws: GatewayError.unavailable(retryAfter: nil)) { try PushGateway.check(401, body: Data("<html>Sign in</html>".utf8)) }
        #expect(throws: GatewayError.unavailable(retryAfter: nil)) { try PushGateway.check(401) }
        // The phone's address is dead.
        #expect(throws: GatewayError.unknownRegistration) { try PushGateway.check(410) }
        #expect(throws: GatewayError.rejected(404)) { try PushGateway.check(404) }
        #expect(throws: GatewayError.rejected(409)) { try PushGateway.check(409) }
        // The two refusals of a secret, told apart by the gateway's word for each.
        #expect(throws: GatewayError.secretConflict) { try PushGateway.check(409, body: Data(#"{"error":"conflict"}"#.utf8)) }
        #expect(throws: GatewayError.tooManySecrets) { try PushGateway.check(409, body: Data(#"{"error":"too_many_secrets"}"#.utf8)) }
        #expect(throws: GatewayError.rejected(409)) { try PushGateway.check(409, body: Data(#"{"error":"too_many_devices"}"#.utf8)) }
        #expect(throws: GatewayError.rateLimited(retryAfter: nil)) { try PushGateway.check(429) }
        #expect(throws: GatewayError.rateLimited(retryAfter: 120)) { try PushGateway.check(429, retryAfter: 120) }
        #expect(throws: GatewayError.unavailable(retryAfter: 30)) { try PushGateway.check(503, retryAfter: 30) }
        #expect(throws: GatewayError.rejected(400)) { try PushGateway.check(400) }
        #expect(GatewayError.rateLimited(retryAfter: 9).retryAfter == 9 && GatewayError.rateLimited(retryAfter: 9).isRateLimit)
        #expect(GatewayError.unavailable(retryAfter: 9).retryAfter == 9 && !GatewayError.unavailable(retryAfter: 9).isRateLimit)
        #expect(GatewayError.unknownRegistration.retryAfter == nil)
    }

    @Test func retryAfterIsReadAsWholeSeconds() async {
        #expect(PushGateway.retryAfter("120") == 120 && PushGateway.retryAfter(" 3600 ") == 3600 && PushGateway.retryAfter("0") == 0)
        for odd in [nil, "", "soon", "-5", "1.5", "Wed, 21 Oct 2026 07:28:00 GMT", "99999999"] {
            #expect(PushGateway.retryAfter(odd) == nil)
        }
        // A request carries it out with the error.
        let stand = GatewayStandIn()
        stand.turns = [.refuse(429, retryAfter: 86_400), .refuse(503)]
        let gateway = stand.gateway()
        await #expect(throws: GatewayError.rateLimited(retryAfter: 86_400)) { try await gateway.putDevice(sample(), token: token, environment: "sandbox") }
        await #expect(throws: GatewayError.unavailable(retryAfter: nil)) { try await gateway.putDevice(sample(), token: token, environment: "sandbox") }
        stand.turns = [.loseAnswer]
        await #expect(throws: GatewayError.unavailable(retryAfter: nil)) { try await gateway.deleteSecret(sample(), secretID: "sid1") }
    }

    // MARK: The Keychain

    /// Records what the store hands to the Keychain. Locked, because the Keychain calls are
    /// plain functions that may be made from any thread.
    final class KeychainRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var held: [String: Data] = [:]
        private(set) var adds: [[String: Any]] = []
        private(set) var updates: [(query: [String: Any], changes: [String: Any])] = []
        private(set) var queries: [[String: Any]] = []

        private func name(_ query: [String: Any]) -> String {
            "\(query[kSecAttrService as String] ?? "")/\(query[kSecAttrAccount as String] ?? "")"
        }

        var calls: KeychainCalls {
            KeychainCalls(
                copy: { [self] query in
                    lock.withLock {
                        queries.append(query)
                        guard let data = held[name(query)] else { return (errSecItemNotFound, nil) }
                        return (errSecSuccess, data)
                    }
                },
                add: { [self] item in
                    lock.withLock {
                        adds.append(item)
                        held[name(item)] = item[kSecValueData as String] as? Data
                        return errSecSuccess
                    }
                },
                update: { [self] query, changes in
                    lock.withLock {
                        queries.append(query)
                        guard held[name(query)] != nil else { return errSecItemNotFound }
                        updates.append((query, changes))
                        held[name(query)] = changes[kSecValueData as String] as? Data
                        return errSecSuccess
                    }
                },
                delete: { [self] query in
                    lock.withLock {
                        queries.append(query)
                        return held.removeValue(forKey: name(query)) == nil ? errSecItemNotFound : errSecSuccess
                    }
                })
        }
    }

    @Test func everyItemStaysOnThisPhone() throws {
        let recorder = KeychainRecorder()
        let thisDeviceOnly = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        // Everything sign-up keeps is in the registration's item: the owner key and device id,
        // each computer's secret and its helper's pinned key, and what is not confirmed yet.
        let store = KeychainRegistrationStore(service: "tests.push", keychain: recorder.calls)
        var record = PushRecord.fresh(gateway: "https://push.example", keeping: nil, random: .system)
        try store.save(record)
        record.servers[server] = ServerPush(helperKey: "key1", secretID: "sid1", pushSecret: "sec1", unconfirmed: true)
        try store.save(record)
        record.unconfirmed = nil
        record.servers[server]?.unconfirmed = nil
        try store.save(record)
        #expect(try store.load() == record)
        // The other item of the feature: what the phone remembers of the helper's releases.
        let releases = KeychainReleaseStore(service: "tests.release", keychain: recorder.calls)
        try releases.save(ReleaseMemory(highWater: "0.3.1"))
        try releases.save(ReleaseMemory(highWater: "0.3.2"))

        #expect(recorder.adds.count == 2 && recorder.updates.count == 3)
        for item in recorder.adds {
            #expect(item[kSecAttrAccessible as String] as? String == thisDeviceOnly)
            #expect(item[kSecAttrSynchronizable as String] as? Bool == false)
            #expect(item[kSecClass as String] as? String == kSecClassGenericPassword as String)
        }
        for update in recorder.updates {
            // A write to an item that is there says the same again, and never moves it to iCloud.
            #expect(update.changes[kSecAttrAccessible as String] as? String == thisDeviceOnly)
            #expect(update.changes[kSecAttrSynchronizable as String] == nil)
            #expect(update.changes.keys.sorted() == [kSecAttrAccessible as String, kSecValueData as String].sorted())
        }
        // Nothing is ever looked for among the items iCloud carries.
        #expect(!recorder.queries.isEmpty && recorder.queries.allSatisfy { $0[kSecAttrSynchronizable as String] as? Bool == false })
        #expect(KeychainItem.protection[kSecAttrAccessible as String] as? String == thisDeviceOnly)

        try store.clear()
        #expect(try store.load() == nil)
    }

    @Test func theKeychainKeepsARegistration() throws {
        let store = KeychainRegistrationStore(service: "dev.abrahamgonzalez.rexduo.tests.\(UUID().uuidString)")
        defer { try? store.clear() }
        #expect(try store.load() == nil)
        var reg = sample()
        reg.unconfirmed = true
        reg.servers[server] = ServerPush(helperKey: "key1", secretID: "sid1", pushSecret: "sec1", unconfirmed: true)
        try store.save(reg)
        #expect(try store.load() == reg)
        reg.token = "ff"
        reg.unconfirmed = nil
        reg.retired = ["sid0"]
        reg.servers[server] = ServerPush(helperKey: "key1")
        try store.save(reg)
        #expect(try store.load() == reg)
        try store.clear()
        #expect(try store.load() == nil)
        // Clearing what isn't there is not a failure.
        try store.clear()
    }

    // MARK: Helper versions

    @Test func helperStatusSaysItsVersionAndHowItCanBeUpdated() {
        let able = HelperVersion(["version": "0.3.0", "can_update": true, "updating": false, "registered": false])
        #expect(able?.version == "0.3.0" && able?.canUpdate == true && able?.updating == false && able?.registered == false)
        // A development build can't replace itself; a helper that says nothing of it can't either.
        #expect(HelperVersion(["version": "0.3.0", "can_update": false])?.canUpdate == false)
        let plain = HelperVersion(["version": "0.3.0"])
        #expect(plain?.canUpdate == false && plain?.updating == false && plain?.registered == nil)
        #expect(HelperVersion(["version": "0.3.0", "updating": true])?.updating == true)
        // Without a version it is no status.
        #expect(HelperVersion(["latest_version": "0.3.1"]) == nil)
        // What the helper thinks of its own version is not read: with or without it, the same.
        let opinion = HelperVersion(["version": "0.3.0", "can_update": true, "updating": false, "registered": false,
                                     "latest_version": "9.9.9", "update_available": true, "update_required": true,
                                     "last_error": "The release list could not be downloaded.", "failing_since": 1_799_990_000])
        #expect(opinion == able)
    }

    @Test func aHelperFromBeforeTheGatewayIsRecognised() {
        #expect(HelperVersion.isLegacyRefusal("token must be the APNs device token in hex"))
        #expect(!HelperVersion.isLegacyRefusal("gateway must be an https URL"))
    }
}
