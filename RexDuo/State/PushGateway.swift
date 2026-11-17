import Foundation
import Security

/// What the phone keeps for one server's helper: the key that helper proved it holds the first
/// time (its pin), and the secret minted for it. A secret is only ever given to the helper whose
/// key is pinned here.
struct ServerPush: Codable, Equatable {
    /// The helper's public key, base64 of the 32 raw bytes.
    var helperKey: String
    /// The gateway's id for the secret, needed to delete it. Nil until one is minted.
    var secretID: String?
    /// What that helper needs to push to this phone. Handed to it through Rex.
    var pushSecret: String?
}

/// This phone's registration with the push gateway: the service that holds the APNs key and this
/// phone's APNs token, so no helper has to. Each computer's helper gets its own secret, which lets
/// it notify this one phone and nothing else. The API is in Gateway/README.md.
struct GatewayRegistration: Codable, Equatable {
    /// The gateway's base URL this registration belongs to.
    var gateway: String
    /// The gateway's id for this phone (not the 8-hex id in the Rex client label).
    var device: String
    /// Proves this phone owns the registration: needed to change or delete it. Never leaves the
    /// phone except in calls to the gateway.
    var ownerKey: String
    /// The APNs token and environment the gateway has for it.
    var token: String
    var environment: String
    /// Notifications were turned off but the gateway couldn't be told yet. No secret may be
    /// handed out again; the delete is retried.
    var revoked: Bool?
    /// One entry per server, keyed by the server config's id.
    var servers: [String: ServerPush] = [:]
}

extension GatewayRegistration {
    // Written out so an item saved before there were per-server secrets still reads.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        gateway = try c.decode(String.self, forKey: .gateway)
        device = try c.decode(String.self, forKey: .device)
        ownerKey = try c.decode(String.self, forKey: .ownerKey)
        token = try c.decode(String.self, forKey: .token)
        environment = try c.decode(String.self, forKey: .environment)
        revoked = try c.decodeIfPresent(Bool.self, forKey: .revoked)
        servers = try c.decodeIfPresent([String: ServerPush].self, forKey: .servers) ?? [:]
    }
}

enum GatewayError: Error, Equatable {
    /// The gateway's own 401: it no longer knows this phone, or the owner key is wrong. It answers
    /// the same for both. Register again.
    case unknownRegistration
    case rateLimited
    /// Another refusal, by HTTP status.
    case rejected(Int)
    /// No answer, or a 5xx: try again later.
    case unavailable
    case malformedReply
    case badAddress
    /// The Keychain refused to read, save or delete the registration. Nothing is handed to a helper.
    case storeFailed
}

/// The calls the phone makes to the gateway. Requests and replies are built and read by pure
/// functions; `transport` is the network, replaced in tests.
struct PushGateway: Sendable {
    /// The Rex DUO gateway. Debug builds can point elsewhere with `-pushGateway <url>`.
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
    static func check(_ status: Int, body: Data = Data()) throws {
        switch status {
        case 200...299: return
        // Only the gateway's own 401 means the registration is gone. One from something in
        // between (a proxy, a captive portal) must not make the phone throw its registration away.
        case 401: throw isOwnRefusal(body) ? GatewayError.unknownRegistration : GatewayError.unavailable
        case 429: throw GatewayError.rateLimited
        case 500...599: throw GatewayError.unavailable
        default: throw GatewayError.rejected(status)
        }
    }

    /// The gateway's 401 body is JSON with `"error": "unauthorized"`.
    static func isOwnRefusal(_ body: Data) -> Bool {
        object(body)?["error"] as? String == "unauthorized"
    }

    private static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// The two values a new registration comes back with.
    static func registered(_ data: Data) throws -> (device: String, ownerKey: String) {
        guard let o = object(data), let device = o["device_id"] as? String, let owner = o["owner_key"] as? String,
              !device.isEmpty, !owner.isEmpty else {
            throw GatewayError.malformedReply
        }
        return (device, owner)
    }

    /// A new secret and the id it is deleted by.
    static func minted(_ data: Data) throws -> (secretID: String, pushSecret: String) {
        guard let o = object(data), let id = o["secret_id"] as? String, let secret = o["push_secret"] as? String,
              !id.isEmpty, !secret.isEmpty else {
            throw GatewayError.malformedReply
        }
        return (id, secret)
    }

    /// The ids of the secrets the gateway still holds for this phone.
    static func secretIDs(_ data: Data) throws -> [String] {
        guard let o = object(data), let list = o["secrets"] as? [Any] else { throw GatewayError.malformedReply }
        return list.compactMap { ($0 as? [String: Any])?["secret_id"] as? String }
    }

    // MARK: Calls

    private func send(_ request: URLRequest) async throws -> Data {
        let data: Data, http: HTTPURLResponse
        do {
            (data, http) = try await transport(request)
        } catch let e as GatewayError {
            throw e
        } catch {
            throw GatewayError.unavailable
        }
        try Self.check(http.statusCode, body: data)
        return data
    }

    func register(token: String, environment: String) async throws -> GatewayRegistration {
        let data = try await send(Self.request("POST", base, path: "v1/devices",
                                               body: ["apns_token": token, "environment": environment]))
        let r = try Self.registered(data)
        return GatewayRegistration(gateway: base.absoluteString, device: r.device, ownerKey: r.ownerKey,
                                   token: token, environment: environment)
    }

    /// The APNs token (or the build's environment) changed. The helpers' secrets stay.
    func update(_ registration: GatewayRegistration, token: String, environment: String) async throws {
        _ = try await send(Self.request("PUT", base, path: "v1/devices/" + registration.device, bearer: registration.ownerKey,
                                        body: ["apns_token": token, "environment": environment]))
    }

    /// Every secret handed out for this phone stops working.
    func delete(_ registration: GatewayRegistration) async throws {
        _ = try await send(Self.request("DELETE", base, path: "v1/devices/" + registration.device, bearer: registration.ownerKey))
    }

    /// The secrets the gateway still holds for this phone. `unknownRegistration` when the phone
    /// itself is gone.
    func secrets(_ registration: GatewayRegistration) async throws -> [String] {
        try Self.secretIDs(try await send(Self.request("GET", base, path: "v1/devices/" + registration.device,
                                                       bearer: registration.ownerKey)))
    }

    /// A new secret for one helper. `label` is what the gateway lists it under.
    func mint(_ registration: GatewayRegistration, label: String) async throws -> (secretID: String, pushSecret: String) {
        try Self.minted(try await send(Self.request("POST", base, path: "v1/devices/" + registration.device + "/secrets",
                                                    bearer: registration.ownerKey, body: ["label": label])))
    }

    /// One helper's secret stops working. Fine when it is already gone.
    func deleteSecret(_ registration: GatewayRegistration, secretID: String) async throws {
        _ = try await send(Self.request("DELETE", base, path: "v1/devices/" + registration.device + "/secrets/" + secretID,
                                        bearer: registration.ownerKey))
    }
}

/// Where the registration is kept. The Keychain on a device; memory in tests. Every call throws
/// when the store didn't do what was asked, so a secret is never handed out unless it was saved.
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

/// One Keychain item, on this device only and readable once the phone has been unlocked after a
/// restart, so a token rotation delivered in the background can still be registered.
final class KeychainRegistrationStore: RegistrationStore {
    private let service: String
    private let account = "gateway-registration"

    init(service: String = "dev.abrahamgonzalez.rexduo.push") {
        self.service = service
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    /// Nil when there is no item. Throws when the Keychain can't be read (before the first unlock,
    /// say): "nothing stored" and "can't tell" must not look alike, or the phone would register again.
    func load() throws -> GatewayRegistration? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else { throw KeychainError(status: status) }
        // An item that no longer decodes counts as none: the next registration replaces it.
        return try? JSONDecoder().decode(GatewayRegistration.self, from: data)
    }

    func save(_ registration: GatewayRegistration) throws {
        let data = try JSONEncoder().encode(registration)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    func clear() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}

/// Keeps the phone's gateway registration in line with its APNs token: registers the first time,
/// tells the gateway when the token rotates, and deletes the registration when notifications are
/// turned off. It also keeps each server's helper pin and secret, which live in the same stored
/// item. One registration call at a time; callers that arrive meanwhile get the same answer.
@MainActor
final class GatewayLink {
    enum Step: Equatable { case use, update, register }

    private let gateway: PushGateway?
    private let store: RegistrationStore
    private var running: Task<Result<GatewayRegistration, GatewayError>, Never>?

    init(gateway: PushGateway?, store: RegistrationStore) {
        self.gateway = gateway
        self.store = store
    }

    /// What it takes to have a registration for this token: nothing, a token update, or a new
    /// registration (none yet, another gateway, or one that was revoked).
    static func step(stored: GatewayRegistration?, gateway: String, token: String, environment: String) -> Step {
        guard let stored, stored.gateway == gateway, stored.revoked != true else { return .register }
        return stored.token == token && stored.environment == environment ? .use : .update
    }

    /// The registration for this token, making or updating it first if needed.
    func registration(token: String, environment: String) async -> Result<GatewayRegistration, GatewayError> {
        await shared { await self.resolve(token: token, environment: environment, replacing: nil) }
    }

    /// The gateway no longer knows device `device`: register again, keeping each server's helper
    /// pin but none of the secrets, which died with the old registration. When another server's
    /// repair already replaced it, this returns the new one without registering twice.
    func registerAfresh(replacing device: String, token: String, environment: String) async -> Result<GatewayRegistration, GatewayError> {
        if let running { _ = await running.value }
        return await shared { await self.resolve(token: token, environment: environment, replacing: device) }
    }

    private func shared(_ work: @escaping @MainActor () async -> Result<GatewayRegistration, GatewayError>) async -> Result<GatewayRegistration, GatewayError> {
        if let running { return await running.value }
        let task = Task { await work() }
        running = task
        let result = await task.value
        running = nil
        return result
    }

    private func resolve(token: String, environment: String, replacing: String?) async -> Result<GatewayRegistration, GatewayError> {
        guard let gateway else { return .failure(.badAddress) }
        let address = gateway.base.absoluteString
        let stored: GatewayRegistration?
        do { stored = try store.load() } catch { return .failure(.storeFailed) }
        // Helper pins outlive a registration the gateway dropped: who the helper is hasn't changed.
        var pins: [String: ServerPush] = [:]
        do {
            if let stored, stored.device == replacing, stored.gateway == address, stored.revoked != true {
                pins = Self.pins(stored)
            } else {
                switch Self.step(stored: stored, gateway: address, token: token, environment: environment) {
                case .use:
                    if let stored { return .success(stored) }
                case .update:
                    if let stored {
                        do {
                            try await gateway.update(stored, token: token, environment: environment)
                            return .success(try change(stored.device) {
                                $0.token = token
                                $0.environment = environment
                            })
                        } catch GatewayError.unknownRegistration {
                            // The gateway dropped it (Apple said the old token was dead): start over.
                            pins = Self.pins(stored)
                        }
                    }
                case .register:
                    // A revoked one the gateway never heard about: delete it first, best effort.
                    if let stored, stored.revoked == true, stored.gateway == address {
                        try? await gateway.delete(stored)
                    }
                }
            }
            var fresh = try await gateway.register(token: token, environment: environment)
            fresh.servers = pins
            do {
                try store.save(fresh)
            } catch {
                // Unsaved, it could never be updated or deleted later: take it back now.
                try? await gateway.delete(fresh)
                return .failure(.storeFailed)
            }
            return .success(fresh)
        } catch let e as GatewayError {
            return .failure(e)
        } catch {
            return .failure(.unavailable)
        }
    }

    private static func pins(_ registration: GatewayRegistration) -> [String: ServerPush] {
        registration.servers.mapValues { ServerPush(helperKey: $0.helperKey) }
    }

    /// Reads, changes and saves the registration with no suspension in between, so two servers
    /// that sync at the same time can't overwrite each other's entry. Fails when the stored
    /// registration is no longer the one for `device`.
    @discardableResult
    private func change(_ device: String, _ edit: (inout GatewayRegistration) -> Void) throws -> GatewayRegistration {
        let loaded: GatewayRegistration?
        do { loaded = try store.load() } catch { throw GatewayError.storeFailed }
        guard var r = loaded, r.device == device else { throw GatewayError.unknownRegistration }
        edit(&r)
        do { try store.save(r) } catch { throw GatewayError.storeFailed }
        return r
    }

    /// The live registration: stored, for this gateway, and not waiting to be deleted.
    private var current: GatewayRegistration? {
        guard let gateway, let r = try? store.load(), r.gateway == gateway.base.absoluteString, r.revoked != true else { return nil }
        return r
    }

    // MARK: Per-server helpers

    /// The pin and secret kept for one server's helper.
    func server(_ id: String) -> ServerPush? { current?.servers[id] }

    /// Remembers the key a server's helper proved the first time. False when it couldn't be saved.
    func pin(_ id: String, helperKey: String) -> Bool {
        guard let r = current else { return false }
        return (try? change(r.device) { if $0.servers[id] == nil { $0.servers[id] = ServerPush(helperKey: helperKey) } }) != nil
    }

    /// A new secret for a pinned server's helper. It is returned only once it is saved.
    func mint(_ id: String, label: String) async -> Result<String, GatewayError> {
        guard let gateway else { return .failure(.badAddress) }
        guard let r = current else { return .failure(.unknownRegistration) }
        guard r.servers[id] != nil else { return .failure(.unavailable) }
        do {
            let made = try await gateway.mint(r, label: label)
            do {
                let saved = try change(r.device) {
                    $0.servers[id]?.secretID = made.secretID
                    $0.servers[id]?.pushSecret = made.pushSecret
                }
                // The entry went away meanwhile (the server was removed): nothing holds the secret.
                guard saved.servers[id]?.secretID == made.secretID else { throw GatewayError.unavailable }
            } catch {
                try? await gateway.deleteSecret(r, secretID: made.secretID)
                throw error
            }
            return .success(made.pushSecret)
        } catch let e as GatewayError {
            return .failure(e)
        } catch {
            return .failure(.unavailable)
        }
    }

    /// One server's secret stops working, at the gateway if it can be reached, and is never handed
    /// out again. `keepPin: false` also forgets the helper's key (the server was removed).
    func forget(_ id: String, keepPin: Bool = true) async {
        guard let gateway, let r = current, let entry = r.servers[id] else { return }
        _ = try? change(r.device) { $0.servers[id] = keepPin ? ServerPush(helperKey: entry.helperKey) : nil }
        if let secret = entry.secretID { try? await gateway.deleteSecret(r, secretID: secret) }
    }

    /// The user trusts a server's helper although its key changed: the secret the old helper held
    /// is deleted and `helperKey` becomes the pin. False when it couldn't be saved.
    func trust(_ id: String, helperKey: String) async -> Bool {
        guard let r = current else { return false }
        await forget(id)
        return (try? change(r.device) { $0.servers[id] = ServerPush(helperKey: helperKey) }) != nil
    }

    /// A helper says it has no working secret for this phone. Asks the gateway what is left and
    /// puts the stored registration in a state from which the server can register again: a new
    /// registration when the phone is gone, or that server's secret dropped so a new one is minted.
    /// Nil when that is done; the error when the gateway couldn't say, and nothing was changed.
    func repair(_ id: String, token: String, environment: String) async -> GatewayError? {
        guard let gateway else { return .badAddress }
        guard let r = current else { return nil }
        let lookup: Result<[String], GatewayError>
        do {
            lookup = .success(try await gateway.secrets(r))
        } catch {
            lookup = .failure(error as? GatewayError ?? .unavailable)
        }
        switch SecretRepair.step(lookup: lookup) {
        case .registerDevice:
            if case .failure(let e) = await registerAfresh(replacing: r.device, token: token, environment: environment) { return e }
            return nil
        case .mintSecret:
            await forget(id)
            return nil
        case .wait(let e):
            return e
        }
    }

    // MARK: Turning off

    /// Notifications were turned off: every helper's secret for this phone must stop working, also
    /// on computers that are off right now. If the gateway can't be reached, or the Keychain won't
    /// let go of the registration, it is kept, marked revoked, and this is called again later.
    /// True when nothing is left to do.
    @discardableResult
    func revoke() async -> Bool {
        if let running { _ = await running.value }
        guard var stored = try? store.load() else {
            // Nothing stored, or the Keychain can't say: only the first means done.
            return (try? store.load() == nil) ?? false
        }
        if let gateway, stored.gateway == gateway.base.absoluteString {
            do {
                try await gateway.delete(stored)
            } catch GatewayError.unknownRegistration {
                // Already gone.
            } catch {
                stored.revoked = true
                try? store.save(stored)
                return false
            }
        }
        do {
            try store.clear()
        } catch {
            stored.revoked = true
            try? store.save(stored)
            return false
        }
        return true
    }

    /// Something is still registered, or waiting to be deleted, or the Keychain can't say.
    var hasRegistration: Bool { (try? store.load() == nil) != true }
}
