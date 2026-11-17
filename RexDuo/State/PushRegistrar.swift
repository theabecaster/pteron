import UIKit
import UserNotifications
import RexKit

/// Registers this phone with Rex DUO Helper on every server, so the Mac can push when the app
/// is closed. The contract (actions, arguments, when to call them) is in docs/notifications.md.
///
/// - After each new connection to a server: find the helper with `client.list`, then
///   `register_push`. Idempotent, so a reconnect simply registers again.
/// - On background and foreground: `push_presence`, so the helper skips pushes while the app shows
///   its own toasts.
/// - When the user turns push off: `unregister_push`, now or on the server's next connect.
///
/// Nothing here runs while push is off and was never registered: no `client.list`, no calls.
@MainActor
@Observable
final class PushRegistrar {
    enum Authorization: Equatable {
        case unknown, notDetermined, denied, authorized, provisional, ephemeral
        /// iOS shows our pushes in some form (provisional ones go quietly to Notification Center).
        var delivers: Bool { self == .authorized || self == .provisional || self == .ephemeral }
    }

    /// What we know of a server's helper, for Settings. Checked only while push is on.
    enum Helper: Equatable {
        case missing
        /// `pushEnabled` is false while the helper has no APNs key or runs with `--dry-run`.
        case running(pushEnabled: Bool)
        case failed(String)
    }

    let deviceID: String
    let environment: String
    private(set) var authorization: Authorization = .unknown
    private(set) var token: String?
    private(set) var helpers: [UUID: Helper] = [:]

    /// The servers to register with. AppModel sets it.
    @ObservationIgnored var servers: () -> [ServerConnection] = { [] }
    @ObservationIgnored private let prefs: Prefs
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var links: [UUID: Link] = [:]
    @ObservationIgnored private var syncing: Set<UUID> = []
    @ObservationIgnored private var syncAgain: Set<UUID> = []
    @ObservationIgnored private var started = false
    /// The app is in front. A connection that resumes keeps its client id, so the helper still
    /// thinks it's in the background until told otherwise.
    @ObservationIgnored private var inFront = true
    /// `-pushToken <hex>` (debug builds): use this token and skip the permission check, to test
    /// registration in a simulator.
    @ObservationIgnored private let tokenOverride: String?

    /// One server connection's registration. A new connection starts a fresh one.
    private struct Link {
        var connection: Int
        var relayID: String?
        var token: String?
    }

    private static let tokenKey = "pushToken.last"
    private static let registeredKey = "pushToken.servers"

    init(prefs: Prefs, deviceID: String, environment: String = APNsEnvironment.current, defaults: UserDefaults = .standard) {
        self.prefs = prefs
        self.deviceID = deviceID
        self.environment = environment
        self.defaults = defaults
        token = defaults.string(forKey: Self.tokenKey)
        #if DEBUG
        tokenOverride = defaults.string(forKey: "pushToken").map { $0.lowercased() }
        #else
        tokenOverride = nil
        #endif
        if let tokenOverride { token = tokenOverride }
    }

    /// Push is on and iOS will show it.
    var wantsPush: Bool { prefs.pushEnabled && (authorization.delivers || tokenOverride != nil) }

    /// The gentle "Get notified" card: push is off, the user hasn't said "Not now", and iOS hasn't
    /// been told no.
    var offersPrompt: Bool {
        !prefs.pushEnabled && !prefs.pushPromptDismissed && authorization != .denied && authorization != .unknown
    }

    /// Servers that are connected but have no helper, while push is on.
    var missingHelpers: [ServerConnection] {
        guard wantsPush else { return [] }
        return servers().filter { $0.phase == .online && helpers[$0.id] == .missing }
    }

    // MARK: Lifecycle

    /// Called once the app is on screen. Reads the permission and asks APNs for a token if push is on.
    func start() {
        guard !started else { return }
        started = true
        Task {
            await refreshAuthorization()
            apply()
        }
    }

    /// Back in front: the user may have changed the permission in iOS Settings.
    func becameActive() {
        inFront = true
        guard started else { return }
        sendPresence(active: true)
        Task {
            await refreshAuthorization()
            apply()
        }
    }

    func enteredBackground() {
        inFront = false
        sendPresence(active: false)
    }

    // MARK: User actions

    /// Turn On (prompt card or Settings). Asks iOS the first time; later it only registers.
    func enable() {
        prefs.pushEnabled = true
        prefs.pushPromptDismissed = true
        Task {
            if authorization == .notDetermined || authorization == .unknown {
                _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            }
            await refreshAuthorization()
            apply()
        }
    }

    func disable() {
        prefs.pushEnabled = false
        apply()
    }

    /// "Not now" on the prompt card: never offer it again. Settings still has the toggle.
    func declinePrompt() {
        prefs.pushPromptDismissed = true
    }

    // MARK: Token

    func tokenReceived(_ data: Data) {
        guard tokenOverride == nil else { return }
        let hex = PushIdentity.hex(data)
        if hex != token {
            // A new or rotated token: every helper hears about it on the next sync.
            token = hex
            defaults.set(hex, forKey: Self.tokenKey)
        }
        syncAll()
    }

    func tokenFailed(_ error: Error) {
        print("[push] no APNs token: \(error.localizedDescription)")
    }

    // MARK: Servers

    /// A server finished a (re)sync. Registers on a new connection; otherwise usually does nothing.
    func serverReady(_ s: ServerConnection) {
        Task { await sync(s) }
    }

    /// A helper joined or left this server: look for it again.
    func relayChanged(_ s: ServerConnection) {
        links[s.id]?.relayID = nil
        Task { await sync(s) }
    }

    func isRelay(_ clientID: String, on s: ServerConnection) -> Bool {
        links[s.id]?.relayID == clientID
    }

    // MARK: Internals

    private var registeredServers: Set<String> {
        get { Set(defaults.stringArray(forKey: Self.registeredKey) ?? []) }
        set { defaults.set(Array(newValue).sorted(), forKey: Self.registeredKey) }
    }

    private func refreshAuthorization() async {
        let status = await withCheckedContinuation { (c: CheckedContinuation<UNAuthorizationStatus, Never>) in
            UNUserNotificationCenter.current().getNotificationSettings { c.resume(returning: $0.authorizationStatus) }
        }
        let a: Authorization
        switch status {
        case .notDetermined: a = .notDetermined
        case .denied: a = .denied
        case .authorized: a = .authorized
        case .provisional: a = .provisional
        case .ephemeral: a = .ephemeral
        @unknown default: a = .authorized
        }
        if authorization != a { authorization = a }
    }

    private func apply() {
        if wantsPush, tokenOverride == nil { UIApplication.shared.registerForRemoteNotifications() }
        if !wantsPush, !helpers.isEmpty { helpers = [:] }
        syncAll()
    }

    private func syncAll() {
        for s in servers() { Task { await sync(s) } }
    }

    /// Brings one server's helper in line with what we want: registered with the current token, or
    /// unregistered. One sync per server at a time; a request during a sync runs once more after it.
    private func sync(_ s: ServerConnection) async {
        guard !syncing.contains(s.id) else { syncAgain.insert(s.id); return }
        syncing.insert(s.id)
        defer {
            syncing.remove(s.id)
            if syncAgain.remove(s.id) != nil { Task { await self.sync(s) } }
        }
        guard s.control.state == .connected else { return }
        let key = s.config.id.uuidString
        let want = wantsPush && token != nil
        guard want || registeredServers.contains(key) else { return }

        var link = links[s.id] ?? Link(connection: -1)
        if link.connection != s.connectionSerial { link = Link(connection: s.connectionSerial) }
        if want, link.token == token, link.relayID != nil { return }

        guard let list = try? await s.control.call("client.list") else { return }
        guard let relay = RelayLookup.relayID(in: list.arr("clients")) else {
            link.relayID = nil
            links[s.id] = link
            if want { helpers[s.id] = .missing }
            return
        }
        if want, let token {
            do {
                let r = try await perform(s, relay, "register_push", [
                    "token": token, "environment": environment,
                    "device_name": UIDevice.current.name, "device_id": deviceID,
                ])
                link.relayID = relay
                link.token = token
                registeredServers.insert(key)
                helpers[s.id] = .running(pushEnabled: r.obj("result")?.bool("push_enabled") ?? true)
                if inFront { await presence(s, relay, true) }
            } catch {
                helpers[s.id] = .failed((error as? RexError)?.message ?? error.localizedDescription)
            }
        } else if let token {
            if (try? await perform(s, relay, "unregister_push", ["token": token])) != nil {
                registeredServers.remove(key)
            }
            link.relayID = nil
            link.token = nil
            helpers[s.id] = nil
        }
        links[s.id] = link
    }

    @discardableResult
    private func perform(_ s: ServerConnection, _ relay: String, _ action: String, _ args: JSONObject) async throws -> JSONObject {
        try await s.control.call("client.perform", ["client_id": relay, "action": action, "args": args, "timeout_ms": 5000])
    }

    private func presence(_ s: ServerConnection, _ relay: String, _ active: Bool) async {
        _ = try? await perform(s, relay, "push_presence", ["active": active])
    }

    /// Tells each helper we're registered with whether the app is in front. Going to the
    /// background runs inside a background task, since iOS suspends the app right after.
    private func sendPresence(active: Bool) {
        let targets = servers().compactMap { s -> (ServerConnection, String)? in
            guard let l = links[s.id], l.connection == s.connectionSerial, l.token != nil, let relay = l.relayID,
                  s.control.state == .connected else { return nil }
            return (s, relay)
        }
        guard !targets.isEmpty else { return }
        let bg = BackgroundTask(name: "push_presence", enabled: !active)
        Task {
            await withTaskGroup(of: Void.self) { g in
                for (s, relay) in targets {
                    g.addTask { await self.presence(s, relay, active) }
                }
            }
            bg.end()
        }
    }
}

/// `beginBackgroundTask`, ended once by whichever comes first: the work or iOS's deadline.
@MainActor
private final class BackgroundTask {
    private var id: UIBackgroundTaskIdentifier = .invalid

    init(name: String, enabled: Bool) {
        guard enabled else { return }
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in self?.end() }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
