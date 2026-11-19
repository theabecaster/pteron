import CryptoKit
import Foundation
import RexKit
@testable import RexDuo

/// The push gateway, as far as the phone's routes go: it keeps devices and secrets as the real
/// one does (Gateway/README.md), counts every request it gets and every row it writes, and can
/// be made to lose an answer, refuse, or be down.
@MainActor
final class GatewayStandIn {
    struct Device {
        var ownerKey: String
        var token: String
        var environment: String
        /// Apple said the token is dead.
        var dead = false
        /// Push secrets by their id.
        var secrets: [String: String] = [:]
    }

    /// What to do with the next request in place of answering it.
    enum Turn {
        /// Answer as usual.
        case answer
        /// Do what was asked, and lose the answer on its way back.
        case loseAnswer
        /// Refuse with this status, with `Retry-After` and the gateway's word for why when
        /// given. Nothing is done.
        case refuse(Int, retryAfter: Int? = nil, error: String? = nil)
    }

    struct Seen: Equatable {
        var method: String
        var path: String
        var bearer: String?
        var body: [String: String]
        var at: Date

        var line: String { "\(method) \(path)" }
    }

    static let address = "https://push.example"
    static let unauthorized = #"{"error":"unauthorized","message":"Unknown device or key."}"#

    var devices: [String: Device] = [:]
    var seen: [Seen] = []
    /// Rows written: a device made, a token changed, a secret stored, replaced or deleted.
    var writes = 0
    /// Devices made.
    var made = 0
    var turns: [Turn] = []
    /// Every request is refused with 503.
    var down = false
    var now: () -> Date = { Date() }

    var lines: [String] { seen.map(\.line) }

    func gateway() -> PushGateway {
        PushGateway(address: Self.address) { [self] request in
            let (status, body, headers, lost) = await MainActor.run { self.take(request) }
            if lost { throw URLError(.networkConnectionLost) }
            let http = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
            return (Data(body.utf8), http)
        }!
    }

    /// The device id that belongs to an owner key, worked out here a second time.
    static func deviceID(for ownerKey: String) -> String {
        let hash = Data(SHA256.hash(data: Data(("rexduo-device-v1\n" + ownerKey).utf8))).base64EncodedString()
        return String(hash.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").prefix(22))
    }

    private func take(_ request: URLRequest) -> (Int, String, [String: String], Bool) {
        let method = request.httpMethod ?? ""
        let path = request.url?.path ?? ""
        let bearer = request.value(forHTTPHeaderField: "Authorization").map { String($0.dropFirst("Bearer ".count)) }
        let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: String] ?? [:]
        seen.append(Seen(method: method, path: path, bearer: bearer, body: body, at: now()))
        if down { return (503, "{}", [:], false) }
        var lost = false
        if !turns.isEmpty {
            switch turns.removeFirst() {
            case .answer: break
            case .loseAnswer: lost = true
            case .refuse(let status, let retryAfter, let error):
                let body = error.map { #"{"error":"\#($0)"}"# } ?? (status == 401 ? Self.unauthorized : "{}")
                return (status, body, retryAfter.map { ["Retry-After": String($0)] } ?? [:], false)
            }
        }
        let (status, text) = answer(method, path.split(separator: "/").map(String.init), bearer ?? "", body)
        return (status, text, [:], lost)
    }

    private func answer(_ method: String, _ parts: [String], _ key: String, _ body: [String: String]) -> (Int, String) {
        guard parts.count >= 3, parts[0] == "v1", parts[1] == "devices" else { return (404, "{}") }
        let id = parts[2]
        if parts.count == 3, method == "PUT" {
            guard let token = body["apns_token"], let environment = body["environment"] else { return (400, "{}") }
            if id.count == 22, id != Self.deviceID(for: key) { return (400, #"{"error":"invalid_request"}"#) }
            guard var device = devices[id] else {
                // Only an id the phone chose makes a device.
                guard id.count == 22, key.count == 43 else { return (401, Self.unauthorized) }
                devices[id] = Device(ownerKey: key, token: token, environment: environment)
                writes += 1
                made += 1
                return (201, #"{"device_id":"\#(id)"}"#)
            }
            guard device.ownerKey == key else { return (401, Self.unauthorized) }
            if device.token == token, device.environment == environment, !device.dead { return (200, "{}") }
            device.token = token
            device.environment = environment
            device.dead = false
            devices[id] = device
            writes += 1
            return (200, "{}")
        }
        guard parts.count == 5, parts[3] == "secrets", var device = devices[id], device.ownerKey == key else {
            return (401, Self.unauthorized)
        }
        let secretID = parts[4]
        switch method {
        case "PUT":
            guard let secret = body["push_secret"], secret.count == 43, secretID.count == 16, body["label"]?.isEmpty == false else {
                return (400, #"{"error":"invalid_request"}"#)
            }
            if device.secrets[secretID] == secret { return (200, #"{"secret_id":"\#(secretID)"}"#) }
            let elsewhere = devices.contains { other, d in d.secrets.contains { $0.value == secret && !(other == id && $0.key == secretID) } }
            if elsewhere { return (409, #"{"error":"conflict"}"#) }
            let replaced = device.secrets[secretID] != nil
            device.secrets[secretID] = secret
            devices[id] = device
            writes += 1
            return (replaced ? 200 : 201, #"{"secret_id":"\#(secretID)"}"#)
        case "DELETE":
            if device.secrets.removeValue(forKey: secretID) != nil { writes += 1 }
            devices[id] = device
            return (204, "")
        default:
            return (405, "{}")
        }
    }
}

/// Beacon on each computer, as the app reaches it through Rex: it proves its key,
/// takes a secret, pauses and resumes, and records every action it was asked for.
@MainActor
final class HelperStandIn: HelperChannel {
    @MainActor
    final class Computer {
        var name: String
        /// Counts connections. Nil while the computer cannot be reached.
        var serial: Int? = 1
        /// A helper is connected there.
        var installed = true
        var relay = "relay-1"
        var key = Curve25519.Signing.PrivateKey()
        /// The secret the helper holds for the phone.
        var secret: String?
        var paused = false
        /// The helper knows `set_push_paused`.
        var pauses = true
        /// Secrets the helper has seen the gateway refuse. It never takes one again.
        var dropped: Set<String> = []
        /// Every action asked for, in order; `set_push_paused` with the value it carried.
        var calls: [String] = []
        /// How long the helper takes to answer, so that a switch can move while it does.
        var latency: UInt64 = 0
        /// The helper's version, as its status says it.
        var version = "0.3.1"
        /// The helper's answer to a registration carries its version.
        var registrationSaysVersion = true
        /// The helper answers `helper_status`.
        var answersStatus = true
        /// More of what the helper's status says: `can_update`, `updating`, and its own view of
        /// which version is the latest.
        var statusSays: JSONObject = [:]
        /// What the helper does when asked to update itself.
        var update = Update.unknown

        enum Update {
            /// The helper does not know the action.
            case unknown
            /// It answers that it started, and from then on reports this version; nil when the
            /// update never gets there.
            case starts(reaching: String?)
            /// Its own check finds nothing newer: it answers that nothing started.
            case nothingToDo
            /// It refuses, as within its pause between two updates.
            case refuses
        }

        init(name: String) { self.name = name }

        var publicKey: String { key.publicKey.rawRepresentation.base64EncodedString() }

        func count(_ action: String) -> Int { calls.filter { $0 == action }.count }

        /// The values pause and resume carried, in order.
        var pauseCalls: [String] { calls.filter { $0.hasPrefix("set_push_paused") } }

        /// The helper was installed again: it keeps nothing, and has a new key unless it kept its files.
        func reinstall(keepingKey: Bool) {
            secret = nil
            paused = false
            if !keepingKey { key = Curve25519.Signing.PrivateKey() }
        }
    }

    static let app = "app-client-1"

    private(set) var order: [UUID] = []
    private var all: [UUID: Computer] = [:]

    @discardableResult
    func add(_ id: UUID, name: String) -> Computer {
        let computer = Computer(name: name)
        order.append(id)
        all[id] = computer
        return computer
    }

    subscript(_ id: UUID) -> Computer { all[id]! }

    /// The computer leaves the app's list. Its helper goes on as it is.
    @discardableResult
    func remove(_ id: UUID) -> Computer {
        order.removeAll { $0 == id }
        return all.removeValue(forKey: id)!
    }

    /// A computer that was in the app before is listed again, under the id it gets now.
    func add(_ id: UUID, computer: Computer) {
        order.append(id)
        all[id] = computer
    }

    var computers: [UUID] { order }

    func connection(_ computer: UUID) -> Int? { all[computer]?.serial }

    func clientID(_ computer: UUID) -> String? { Self.app }

    func name(_ computer: UUID) -> String { all[computer]?.name ?? "" }

    func clients(_ computer: UUID) async -> [JSONObject]? {
        guard let c = all[computer], c.serial != nil else { return nil }
        guard c.installed else { return [] }
        return [["client_id": c.relay, "connection_state": "connected", "info": ["name": RelayLookup.clientName],
                 "principal": ["kind": "peer"]]]
    }

    func perform(_ computer: UUID, relay: String, action: String, args: JSONObject, timeout: Int) async -> Result<JSONObject, HelperFailure> {
        guard let c = all[computer], c.serial != nil, c.installed, relay == c.relay else {
            return .failure(HelperFailure(code: "", message: "not connected"))
        }
        func refuse(_ code: String) -> Result<JSONObject, HelperFailure> { .failure(HelperFailure(code: code, message: code)) }
        if c.latency > 0 { try? await Task.sleep(nanoseconds: c.latency) }
        switch action {
        case "helper_identity":
            c.calls.append(action)
            let message = HelperIdentity.message(challenge: args.str("challenge") ?? "", helper: relay, requester: Self.app,
                                                 device: args.str("device_id") ?? "")
            guard let signature = try? c.key.signature(for: message) else { return refuse("failed") }
            return .success(["public_key": c.publicKey, "signature": signature.base64EncodedString(), "client_id": relay])
        case "helper_status":
            c.calls.append(action)
            guard c.answersStatus else { return refuse("timeout") }
            var status: JSONObject = ["version": c.version, "registered": c.secret != nil, "paused": c.paused]
            status.merge(c.statusSays) { $1 }
            return .success(status)
        case "update_helper":
            c.calls.append(action)
            switch c.update {
            case .unknown: return refuse("not_supported")
            case .refuses: return refuse("update_cooldown")
            case .nothingToDo: return .success(["started": false, "version": c.version])
            case .starts(let reaching):
                if let reaching { c.version = reaching }
                return .success(["started": true, "version": reaching ?? c.version])
            }
        case "register_push":
            c.calls.append(action)
            guard let secret = args.str("push_secret"), !secret.isEmpty else { return refuse("bad_request") }
            if c.dropped.contains(secret) { return refuse("secret_dropped") }
            // Left out, a registration with the secret the helper holds keeps its pause.
            c.paused = args.bool("paused") ?? (c.paused && c.secret == secret)
            c.secret = secret
            var reply: JSONObject = ["registered": true, "push_enabled": true]
            if c.registrationSaysVersion { reply["helper_version"] = c.version }
            return .success(reply)
        case "set_push_paused":
            let value = args.bool("paused") ?? false
            c.calls.append("set_push_paused \(value)")
            guard c.pauses else { return refuse("not_supported") }
            guard c.secret != nil else { return refuse("not_registered") }
            c.paused = value
            return .success(["paused": value, "registered": true])
        case "unregister_push":
            c.calls.append(action)
            c.secret = nil
            c.paused = false
            return .success([:])
        case "push_presence":
            c.calls.append(action)
            return .success(["registered": c.secret != nil])
        case "send_test":
            c.calls.append(action)
            guard c.secret != nil else { return refuse("not_registered") }
            return c.paused ? refuse("paused") : .success(["sent": true])
        default:
            c.calls.append(action)
            return refuse("not_supported")
        }
    }
}

/// Time the tests move by hand. `sleep` either returns at once and moves the clock on by the
/// time asked for, or holds the sleeper until `advance` reaches its time.
@MainActor
final class TestClock {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    /// Sleepers return at once. Off: they wait for `advance`.
    var passes = true
    /// Every wait that was asked for, in order.
    private(set) var sleeps: [TimeInterval] = []
    private var waiting: [(until: Date, wake: CheckedContinuation<Void, Never>)] = []

    func sleep(_ seconds: TimeInterval) async {
        sleeps.append(seconds)
        if passes {
            now = now.addingTimeInterval(seconds)
            await Task.yield()
            return
        }
        let until = now.addingTimeInterval(seconds)
        await withCheckedContinuation { waiting.append((until, $0)) }
    }

    func advance(by seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
        let due = waiting.filter { $0.until <= now }
        waiting.removeAll { $0.until <= now }
        for sleeper in due { sleeper.wake.resume() }
    }

    /// Lets every sleeper go, at the end of a test.
    func release() {
        let all = waiting
        waiting = []
        for sleeper in all { sleeper.wake.resume() }
    }
}

/// A registration store that counts its writes and can be made to refuse them.
final class CountingStore: RegistrationStore {
    struct Refused: Error {}
    var value: GatewayRegistration?
    var saves = 0
    var failsLoad = false, failsSave = false

    init(_ value: GatewayRegistration? = nil) { self.value = value }

    func load() throws -> GatewayRegistration? {
        if failsLoad { throw Refused() }
        return value
    }

    func save(_ registration: GatewayRegistration) throws {
        if failsSave { throw Refused() }
        saves += 1
        value = registration
    }

    func clear() throws {
        saves += 1
        value = nil
    }
}

/// A phone with stand-ins for everything sign-up touches.
@MainActor
final class PushWorld {
    static let token = String(repeating: "ab", count: 32)

    let clock = TestClock()
    let gateway = GatewayStandIn()
    let helpers = HelperStandIn()
    let store = CountingStore()
    let defaults: UserDefaults
    let prefs: Prefs
    /// What the person wants, per computer. A computer that is not here is on.
    var intents: [UUID: PushIntent] = [:]
    var token = PushWorld.token

    init() {
        let name = "RexDuoTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        prefs = Prefs(defaults: defaults)
        gateway.now = { [clock] in clock.now }
    }

    var parts: PushRegistrar.Parts {
        PushRegistrar.Parts(gateway: gateway.gateway(), store: store, channel: helpers, now: { [clock] in clock.now },
                            sleep: { [clock] in await clock.sleep($0) },
                            random: PushRandom(bytes: PushRandom.system.bytes, fraction: { 0 }))
    }

    /// A reconciler over this world's store, gateway and helpers. A second one is the app
    /// started again.
    func reconciler() -> PushReconciler {
        let parts = parts
        let r = PushReconciler(gateway: parts.gateway, store: store, channel: helpers, prefs: prefs,
                               phone: PushReconciler.Phone(deviceID: "abcd1234", environment: "sandbox", deviceName: { "Test iPhone" }),
                               now: parts.now, sleep: parts.sleep, random: parts.random)
        r.intent = { [unowned self] in self.intents[$0] ?? .on(token: self.token) }
        return r
    }

    /// Waits for work that started by itself.
    func eventually(_ done: () -> Bool) async {
        for _ in 0..<400 where !done() { try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    /// Long enough for anything that was going to happen by itself to have happened.
    func quiet() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 40_000_000)
    }
}
