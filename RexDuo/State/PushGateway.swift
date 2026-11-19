import CryptoKit
import Foundation
import Security

/// What the phone keeps for one server's helper: the key that helper proved it holds the first
/// time (its pin), and the secret made for it. A secret is only ever given to the helper whose
/// key is pinned here.
struct ServerPush: Codable, Equatable {
    /// The helper's public key, base64 of the 32 raw bytes.
    var helperKey: String
    /// The id the gateway stores the secret under, chosen by the phone. Nil until one is made.
    var secretID: String?
    /// What that helper needs to push to this phone. Handed to it through Rex.
    var pushSecret: String?
    /// The secret is written here before it is sent, and the gateway has not confirmed storing
    /// it yet. The same id and value are sent again until it has.
    var unconfirmed: Bool?
}

/// This phone's registration with the push gateway: the service that holds the APNs key and this
/// phone's APNs token, so no helper has to. Each computer's helper gets its own secret, which lets
/// it notify this one phone and nothing else. The API is in Gateway/README.md.
///
/// The phone chooses the owner key, the device id and every secret, and writes them here before
/// the request that uses them, so a request that is sent again is the same request.
struct GatewayRegistration: Codable, Equatable {
    /// The gateway's base URL this registration belongs to.
    var gateway: String
    /// The gateway's id for this phone (not the 8-hex id in the Rex client label).
    var device: String
    /// Proves this phone owns the registration: needed to change it. Never leaves the phone
    /// except in calls to the gateway.
    var ownerKey: String
    /// The APNs token and environment the gateway has confirmed holding. Empty before the first
    /// confirmation.
    var token: String
    var environment: String
    /// The device is written here and the gateway has not confirmed making it yet (or it has to
    /// be made again). The same id and key are sent until it has.
    var unconfirmed: Bool?
    /// One entry per server, keyed by the server config's id.
    var servers: [String: ServerPush] = [:]
    /// Ids of secrets that were taken back from their helpers and that the gateway has not
    /// confirmed deleting yet. They are never handed out again; the delete is retried.
    var retired: [String]?
    /// Read from an item an earlier version of the app saved: its registration was being deleted
    /// (`revoked`) or had been (`ended`). `PushRecord.adopt` says what each means now.
    var revoked: Bool?
    var ended: Bool?
}

extension GatewayRegistration {
    // Written out so an item saved by an earlier version of the app still reads.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        gateway = try c.decode(String.self, forKey: .gateway)
        device = try c.decode(String.self, forKey: .device)
        ownerKey = try c.decode(String.self, forKey: .ownerKey)
        token = try c.decode(String.self, forKey: .token)
        environment = try c.decode(String.self, forKey: .environment)
        unconfirmed = try c.decodeIfPresent(Bool.self, forKey: .unconfirmed)
        revoked = try c.decodeIfPresent(Bool.self, forKey: .revoked)
        servers = try c.decodeIfPresent([String: ServerPush].self, forKey: .servers) ?? [:]
        retired = try c.decodeIfPresent([String].self, forKey: .retired)
        ended = try c.decodeIfPresent(Bool.self, forKey: .ended)
    }

    /// The gateway holds this device with this token and environment.
    func holds(token: String, environment: String) -> Bool {
        unconfirmed != true && self.token == token && self.environment == environment
    }

    /// The device id is one the phone chose, so the gateway makes the device again from the
    /// same request. A device from the registration route of earlier versions has another
    /// length; it is used as it is for as long as the gateway knows it.
    var isPhoneChosen: Bool { device.count == PushKeys.deviceIDLength }
}

/// The values the phone chooses for the gateway, in the forms the gateway accepts.
enum PushKeys {
    static let deviceIDLength = 22
    static let secretIDLength = 16
    static let devicePrefix = "rexduo-device-v1\n"

    /// base64url without padding.
    static func text(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// 32 random bytes: 43 characters. The form of an owner key and of a push secret.
    static func key(_ random: PushRandom) -> String { text(random.bytes(32)) }

    /// 12 random bytes: 16 characters. The id a secret is stored under.
    static func secretID(_ random: PushRandom) -> String { text(random.bytes(12)) }

    /// The device id that belongs to an owner key: the first 22 characters of
    /// base64url(SHA-256("rexduo-device-v1\n" + owner key)). The gateway checks the two fit.
    static func deviceID(ownerKey: String) -> String {
        String(text(Data(SHA256.hash(data: Data((devicePrefix + ownerKey).utf8)))).prefix(deviceIDLength))
    }
}

/// Where the phone's random values come from; replaced in tests.
struct PushRandom: Sendable {
    /// `count` random bytes, for keys and ids.
    var bytes: @Sendable (Int) -> Data
    /// A number from 0 up to 1, for the spread of retry delays.
    var fraction: @Sendable () -> Double

    /// The system's cryptographic generator.
    static let system = PushRandom(
        bytes: { count in
            var generator = SystemRandomNumberGenerator()
            return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
        },
        fraction: { Double.random(in: 0..<1) })
}

/// What the stored item means to this version of the app.
enum PushRecord {
    /// The record to work from, or nil when the phone has to choose a new owner key and device:
    /// nothing is stored, the stored item is another gateway's, or its registration was deleted
    /// by an earlier version of the app. One that version had marked for deletion and never
    /// deleted is used as it is: nothing is deleted when notifications are turned off.
    static func adopt(_ stored: GatewayRegistration?, gateway: String) -> GatewayRegistration? {
        guard var r = stored, r.gateway == gateway, r.ended != true, !r.ownerKey.isEmpty else { return nil }
        r.revoked = nil
        return r
    }

    /// A new record with a new owner key and its device id, not confirmed yet. Each helper's
    /// pinned key goes over from `old`; who a helper is does not change with the registration.
    static func fresh(gateway: String, keeping old: GatewayRegistration?, random: PushRandom) -> GatewayRegistration {
        let owner = PushKeys.key(random)
        var r = GatewayRegistration(gateway: gateway, device: PushKeys.deviceID(ownerKey: owner), ownerKey: owner, token: "",
                                    environment: "", unconfirmed: true)
        r.servers = (old?.servers ?? [:]).mapValues { ServerPush(helperKey: $0.helperKey) }
        return r
    }
}

/// Entries the store holds for computers the app does not list. The Keychain item stays on the
/// phone when the app is deleted, and the list of computers does not; a computer that is added
/// again gets a new id. Such an entry is set aside at launch, taken over by the computer whose
/// helper proves the key pinned in it (`match`, `adopt`), and retired otherwise (`retire`).
enum PushOrphans {
    /// How long after the app has a computer listed the entries wait for one to take them over.
    static let wait: TimeInterval = 60

    /// The store keys of the entries no listed computer owns.
    static func setAside(_ record: GatewayRegistration?, listed: [UUID]) -> Set<String> {
        guard let record else { return [] }
        return Set(record.servers.keys).subtracting(listed.map(\.uuidString))
    }

    /// The orphan to take over for a helper that proved `helperKey`: one whose pinned key is that
    /// key, one with a secret before one without, then by its key in the store.
    static func match(_ helperKey: String, among orphans: Set<String>, in record: GatewayRegistration) -> String? {
        orphans.filter { record.servers[$0]?.helperKey == helperKey }
            .min { a, b in
                let (hasA, hasB) = (record.servers[a]?.pushSecret != nil, record.servers[b]?.pushSecret != nil)
                return hasA != hasB ? hasA : a < b
            }
    }

    /// The orphan's entry becomes the computer's, as it is: its pin, its secret and whether the
    /// gateway confirmed it. Nothing changes for a computer that has an entry.
    static func adopt(_ orphan: String, for computer: UUID, in record: inout GatewayRegistration) {
        let key = computer.uuidString
        guard record.servers[key] == nil, let entry = record.servers[orphan] else { return }
        record.servers[orphan] = nil
        record.servers[key] = entry
    }

    /// The orphans leave the record. Each one's secret id joins `retired`, the list of secrets
    /// to delete at the gateway, where it stays until the gateway has confirmed the delete.
    static func retire(_ orphans: Set<String>, in record: inout GatewayRegistration) {
        for key in orphans.sorted() {
            guard let entry = record.servers.removeValue(forKey: key) else { continue }
            if let secret = entry.secretID { record.retired = (record.retired ?? []) + [secret] }
        }
    }
}

enum GatewayError: Error, Equatable {
    /// The gateway's own 401 or 410: it no longer knows this phone, or the phone's address is
    /// dead. It answers the same for an unknown phone and a wrong key.
    case unknownRegistration
    /// 429, with the gateway's `Retry-After` in seconds when it gave one.
    case rateLimited(retryAfter: TimeInterval?)
    /// 409 `conflict` to a secret: the gateway holds that push secret in another row. The phone
    /// makes a fresh one.
    case secretConflict
    /// 409 `too_many_secrets`: the device holds as many secrets as it may.
    case tooManySecrets
    /// Another refusal, by HTTP status.
    case rejected(Int)
    /// No answer, or a 5xx (with its `Retry-After` when it gave one): try again later.
    case unavailable(retryAfter: TimeInterval?)
    case malformedReply
    case badAddress
    /// The Keychain refused to read or save the registration. Nothing is sent or handed to a helper.
    case storeFailed

    /// How long the gateway asked the phone to wait.
    var retryAfter: TimeInterval? {
        switch self {
        case .rateLimited(let wait), .unavailable(let wait): wait
        default: nil
        }
    }

    var isRateLimit: Bool {
        if case .rateLimited = self { return true }
        return false
    }
}

/// The calls the phone makes to the gateway. Requests and replies are built and read by pure
/// functions; `transport` is the network, replaced in tests. Every call is a `PUT` or a `DELETE`
/// that can be sent again and gives the same answer.
struct PushGateway: Sendable {
    /// The app's gateway. Debug builds can point elsewhere with `-pushGateway <url>`.
    static let defaultURL = "https://rexduo-push.keptday.workers.dev"

    var base: URL
    var transport: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    /// Nil for an address that isn't https (or plain http to this machine, for tests).
    init?(address: String, transport: (@Sendable (URLRequest) async throws -> (Data, HTTPURLResponse))? = nil) {
        guard let base = Self.base(from: address) else { return nil }
        self.base = base
        self.transport = transport ?? Self.network
    }

    static func base(from address: String) -> URL? {
        guard let c = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = c.host?.lowercased(), !host.isEmpty, c.user == nil, c.password == nil else { return nil }
        let local = host == "127.0.0.1" || host == "localhost"
        guard c.scheme == "https" || (c.scheme == "http" && local) else { return nil }
        var out = URLComponents()
        out.scheme = c.scheme
        out.host = host
        out.port = c.port
        return out.url
    }

    private static let network: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse) = { request in
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        cfg.waitsForConnectivity = false
        let session = URLSession(configuration: cfg)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GatewayError.malformedReply }
        return (data, http)
    }

    // MARK: Requests

    static func request(_ method: String, _ base: URL, path: String, bearer: String? = nil, body: [String: String]? = nil) -> URLRequest {
        var r = URLRequest(url: base.appendingPathComponent(path))
        r.httpMethod = method
        r.cachePolicy = .reloadIgnoringLocalCacheData
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bearer { r.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization") }
        if let body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        }
        return r
    }

    /// What a reply's status means, for every call. 2xx is fine.
    static func check(_ status: Int, body: Data = Data(), retryAfter: TimeInterval? = nil) throws {
        switch status {
        case 200...299: return
        // Only the gateway's own 401 means the registration is gone. One from something in
        // between (a proxy, a captive portal) must not make the phone set itself up again.
        case 401: throw isOwnRefusal(body) ? GatewayError.unknownRegistration : GatewayError.unavailable(retryAfter: nil)
        case 409:
            switch refusal(body) {
            case "conflict": throw GatewayError.secretConflict
            case "too_many_secrets": throw GatewayError.tooManySecrets
            default: throw GatewayError.rejected(status)
            }
        case 410: throw GatewayError.unknownRegistration
        case 429: throw GatewayError.rateLimited(retryAfter: retryAfter)
        case 500...599: throw GatewayError.unavailable(retryAfter: retryAfter)
        default: throw GatewayError.rejected(status)
        }
    }

    /// The gateway's 401 body is JSON with `"error": "unauthorized"`.
    static func isOwnRefusal(_ body: Data) -> Bool { refusal(body) == "unauthorized" }

    /// The `error` of a refusal's JSON body, the gateway's word for why.
    static func refusal(_ body: Data) -> String? {
        ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["error"] as? String
    }

    /// The longest wait a `Retry-After` may ask for. A daily limit asks for up to a day.
    static let longestWait: TimeInterval = 48 * 3600

    /// `Retry-After` as whole seconds. The gateway sends nothing else; a date, a negative
    /// number or a wait of more than two days is no answer.
    static func retryAfter(_ header: String?) -> TimeInterval? {
        guard let text = header?.trimmingCharacters(in: .whitespaces), !text.isEmpty, text.allSatisfy(\.isASCII),
              text.allSatisfy(\.isNumber), let seconds = TimeInterval(text), seconds <= longestWait else { return nil }
        return seconds
    }

    // MARK: Calls

    private func send(_ request: URLRequest) async throws {
        let data: Data, http: HTTPURLResponse
        do {
            (data, http) = try await transport(request)
        } catch let e as GatewayError {
            throw e
        } catch {
            throw GatewayError.unavailable(retryAfter: nil)
        }
        try Self.check(http.statusCode, body: data, retryAfter: Self.retryAfter(http.value(forHTTPHeaderField: "Retry-After")))
    }

    /// Makes the device, or gives it this token and environment. For a device id the phone
    /// chose, the gateway makes the device when it has none under the id, and writes nothing
    /// when it already holds these values. The helpers' secrets stay.
    func putDevice(_ registration: GatewayRegistration, token: String, environment: String) async throws {
        try await send(Self.request("PUT", base, path: "v1/devices/" + registration.device, bearer: registration.ownerKey,
                                    body: ["apns_token": token, "environment": environment]))
    }

    /// Stores one helper's secret under an id, both chosen by the phone. `label` is what the
    /// gateway lists it under. The gateway writes nothing when it already holds this secret
    /// under the id.
    func putSecret(_ registration: GatewayRegistration, secretID: String, pushSecret: String, label: String) async throws {
        try await send(Self.request("PUT", base, path: "v1/devices/" + registration.device + "/secrets/" + secretID,
                                    bearer: registration.ownerKey, body: ["label": label, "push_secret": pushSecret]))
    }

    /// One helper's secret stops working. Fine when it is already gone.
    func deleteSecret(_ registration: GatewayRegistration, secretID: String) async throws {
        try await send(Self.request("DELETE", base, path: "v1/devices/" + registration.device + "/secrets/" + secretID,
                                    bearer: registration.ownerKey))
    }
}

/// Where the registration is kept. The Keychain on a device; memory in tests. Every call throws
/// when the store didn't do what was asked, so nothing is sent or handed out unless it was saved.
protocol RegistrationStore: AnyObject {
    func load() throws -> GatewayRegistration?
    func save(_ registration: GatewayRegistration) throws
    func clear() throws
}

final class MemoryRegistrationStore: RegistrationStore {
    var value: GatewayRegistration?
    init(_ value: GatewayRegistration? = nil) { self.value = value }
    func load() -> GatewayRegistration? { value }
    func save(_ registration: GatewayRegistration) { value = registration }
    func clear() { value = nil }
}

/// A Keychain call that didn't succeed, with the status it gave.
struct KeychainError: Error, Equatable {
    var status: OSStatus
}

/// The four Keychain calls, replaced in tests to read the dictionaries they are given.
struct KeychainCalls: Sendable {
    var copy: @Sendable ([String: Any]) -> (OSStatus, Data?)
    var add: @Sendable ([String: Any]) -> OSStatus
    var update: @Sendable ([String: Any], [String: Any]) -> OSStatus
    var delete: @Sendable ([String: Any]) -> OSStatus

    static let system = KeychainCalls(
        copy: { query in
            var out: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &out)
            return (status, out as? Data)
        },
        add: { SecItemAdd($0 as CFDictionary, nil) },
        update: { SecItemUpdate($0 as CFDictionary, $1 as CFDictionary) },
        delete: { SecItemDelete($0 as CFDictionary) })
}

/// One Keychain item of the notifications feature. It stays on this device: it is readable once
/// the phone has been unlocked after a restart (so a token rotation delivered in the background
/// can still be sent on), it is in no backup that another phone can restore, and it never goes
/// to iCloud Keychain. Every item the feature writes goes through here, so each has the same
/// protection.
struct KeychainItem {
    let service: String
    let account: String
    var keychain = KeychainCalls.system

    /// What every write says about where the item may go.
    static var protection: [String: Any] {
        [kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, kSecAttrSynchronizable as String: false]
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }

    /// Nil when there is no item. Throws when the Keychain can't be read (before the first
    /// unlock, say): "nothing stored" and "can't tell" must not look alike.
    func read() throws -> Data? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, data) = keychain.copy(q)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data else { throw KeychainError(status: status) }
        return data
    }

    func write(_ data: Data) throws {
        var changes = Self.protection
        changes[kSecAttrSynchronizable as String] = nil
        changes[kSecValueData as String] = data
        var status = keychain.update(query, changes)
        if status == errSecItemNotFound {
            var add = query.merging(Self.protection) { _, new in new }
            add[kSecValueData as String] = data
            status = keychain.add(add)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    func remove() throws {
        let status = keychain.delete(query)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}

/// The registration in its Keychain item: the owner key and device id, each computer's secret
/// and its helper's pinned key, and what the gateway has not confirmed yet.
final class KeychainRegistrationStore: RegistrationStore {
    private let item: KeychainItem

    init(service: String = "dev.abrahamgonzalez.rexduo.push", keychain: KeychainCalls = .system) {
        item = KeychainItem(service: service, account: "gateway-registration", keychain: keychain)
    }

    func load() throws -> GatewayRegistration? {
        // An item that no longer decodes counts as none: the next registration replaces it.
        try item.read().flatMap { try? JSONDecoder().decode(GatewayRegistration.self, from: $0) }
    }

    func save(_ registration: GatewayRegistration) throws {
        try item.write(try JSONEncoder().encode(registration))
    }

    func clear() throws {
        try item.remove()
    }
}
