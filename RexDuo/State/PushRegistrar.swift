import UIKit
import UserNotifications
import RexKit

/// Registers this phone with Rex DUO Helper on every server, so the Mac can push when the app
/// is closed. The contract (actions, arguments, when to call them) is in docs/notifications.md.
///
/// - The phone's APNs token goes to the push gateway only (`GatewayLink`). Each server's helper
///   gets a secret of its own, never the token.
/// - After each new connection to a server: find the helper with `client.list`, have it prove its
///   key (`helper_identity`) and compare that with the key pinned for the server, mint the
///   server's secret if it has none, then `register_push`. A reconnect simply registers again.
/// - A helper's key is pinned on first use only outside an install from the app. While an install
///   that sent its setup code runs on a server, that server's helper gets nothing until it showed
///   the run's setup proof (`proveSetup`, `HelperAdmission`); the helper that did is pinned,
///   also in place of a key pinned before, and its `register_push` carries `setup_seal`
///   (`SetupSeal`).
/// - A helper that says its secret stopped working is set up again once per connection
///   (`SecretRepair`).
/// - On background and foreground: `push_presence`, so the helper skips pushes while the app shows
///   its own toasts.
/// - When the user turns push off: the gateway registration is deleted, which stops every helper's
///   secret at once, and each helper hears `unregister_push`, now or on the server's next connect.
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
        /// `pushEnabled` is false while the helper runs with `--dry-run`.
        case running(pushEnabled: Bool)
        /// A helper from before the gateway: it wants an APNs token, which the app no longer gives out.
        case outdated
        /// The helper proved another key than the one pinned for this server, or an install there
        /// ended without the helper's setup proof. It gets nothing until the user trusts it in
        /// Settings.
        case identityChanged
        /// A sentence for Settings.
        case failed(String)
    }

    let deviceID: String
    let environment: String
    private(set) var authorization: Authorization = .unknown
    private(set) var token: String?
    private(set) var helpers: [UUID: Helper] = [:]
    /// Each helper's version and whether a newer one is out, for Settings.
    private(set) var versions: [UUID: HelperVersion] = [:]
    /// The gateway couldn't register this phone. Cleared by the next registration that works.
    private(set) var gatewayProblem: GatewayError?

    /// The servers to register with. AppModel sets it.
    @ObservationIgnored var servers: () -> [ServerConnection] = { [] }
    @ObservationIgnored private let prefs: Prefs
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let gateway: GatewayLink
    @ObservationIgnored private var links: [UUID: Link] = [:]
    @ObservationIgnored private var syncing: Set<UUID> = []
    @ObservationIgnored private var syncAgain: Set<UUID> = []
    @ObservationIgnored private var started = false
    /// Servers where an install of the helper has sent its setup code, with that code. While one
    /// is here, the server's helper is registered only after it showed that run's proof.
    @ObservationIgnored private var setups: [UUID: String] = [:]
    /// The key of the helper that showed the proof during a server's install.
    @ObservationIgnored private var provenKeys: [UUID: String] = [:]
    /// Servers whose install's proven helper has registered.
    @ObservationIgnored private var setupRegistered: Set<UUID> = []
    /// Servers where an install ended without a proof. Their helper waits for "Trust" even when
    /// no key is pinned. Kept while the app runs.
    @ObservationIgnored private var heldBack: Set<UUID> = []
    /// The app is in front. A connection that resumes keeps its client id, so the helper still
    /// thinks it's in the background until told otherwise.
    @ObservationIgnored private var inFront = true
    /// `-pushToken <hex>` (debug builds): use this token and skip the permission check, to test
    /// registration in a simulator.
    @ObservationIgnored private let tokenOverride: String?

    /// One server connection's registration. A new connection starts a fresh one. A class, so a
    /// sync that is waiting on the network and a reply that arrives meanwhile change the same one.
    @MainActor
    private final class Link {
        let connection: Int
        /// The helper found on this connection, verified or not.
        var relayID: String?
        /// The push secret this helper was given, once `register_push` succeeded.
        var registeredSecret: String?
        /// The helper said its secret no longer works; the next sync repairs it.
        var refused = false
        /// This connection has used its one repair.
        var repaired = false
        /// The helper refused again after the repair. Nothing more is tried on this connection.
        var gaveUp = false
        /// The key a helper offered that differs from the pinned one, kept for "Trust".
        var offeredKey: String?

        init(connection: Int) { self.connection = connection }
    }

    private static let tokenKey = "pushToken.last"
    private static let registeredKey = "pushToken.servers"

    init(prefs: Prefs, deviceID: String, environment: String = APNsEnvironment.current, defaults: UserDefaults = .standard,
         gateway: GatewayLink? = nil) {
        self.prefs = prefs
        self.deviceID = deviceID
        self.environment = environment
        self.defaults = defaults
        var address = PushGateway.defaultURL
        #if DEBUG
        // `-pushGateway <url>` (debug builds): another gateway, to test against a local one.
        if let other = defaults.string(forKey: "pushGateway") { address = other }
        #endif
        self.gateway = gateway ?? GatewayLink(gateway: PushGateway(address: address), store: KeychainRegistrationStore())
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

    /// Install in the helper sheet: turns push on, asking iOS the first time, and waits for the
    /// answer. False when iOS doesn't let the app show notifications, so nothing is installed.
    func enableForSetup() async -> Bool {
        prefs.pushEnabled = true
        prefs.pushPromptDismissed = true
        await refreshAuthorization()
        // `-pushToken` (debug builds) stands in for the permission, so it is not asked for.
        if authorization == .notDetermined, tokenOverride == nil {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            await refreshAuthorization()
        }
        apply()
        return wantsPush
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
        if let link = links[s.id] {
            link.relayID = nil
            link.registeredSecret = nil
            link.offeredKey = nil
            // A helper that restarted gets one more registration, but no second repair.
            link.gaveUp = false
        }
        Task { await sync(s) }
    }

    /// "Trust" in Settings, for a helper whose key changed: right when the helper was reinstalled
    /// on that computer. The secret the old helper held is deleted, the key it offered becomes the
    /// pin, and the server registers again with a new secret.
    func trustHelper(_ s: ServerConnection) {
        guard helpers[s.id] == .identityChanged, let link = links[s.id], let offered = link.offeredKey else { return }
        Task {
            guard await gateway.trust(s.config.id.uuidString, helperKey: offered) else {
                gatewayProblem = .storeFailed
                return
            }
            link.offeredKey = nil
            heldBack.remove(s.id)
            helpers[s.id] = nil
            await sync(s)
        }
    }

    /// What one request for a helper's setup proof came to.
    enum SetupReply: Equatable {
        /// Nothing was asked: no helper is connected yet, or the phone isn't ready to register.
        case notAsked
        /// The helper answered without a proof, or didn't answer.
        case missing
        /// The helper answered with a proof that isn't this run's, or couldn't prove its key.
        case wrong
        /// The helper showed the proof and is not registered yet (`syncAfterSetup` goes on).
        case proven
        /// The helper showed the proof, its key is pinned and it holds its secret.
        case registered
    }

    /// An install on this server has typed its setup code into the installer: from now until
    /// `setupEnded`, the server's helper is registered only after it showed the proof for `code`.
    /// What this connection knew of a helper is dropped, since the install replaces it.
    func beginSetup(_ id: UUID, code: String) {
        setups[id] = code
        provenKeys[id] = nil
        setupRegistered.remove(id)
        if let link = links[id] {
            link.relayID = nil
            link.registeredSecret = nil
            link.offeredKey = nil
            link.gaveUp = false
        }
    }

    /// Asks the helper now connected on this server for the proof that the install started it,
    /// once. With a valid proof the helper's key becomes the server's pin, also in place of one
    /// pinned before, and the helper is registered. Without one nothing is pinned and nothing is
    /// handed over. The run calls this after the installer's `start` step, and counts the replies.
    func proveSetup(_ s: ServerConnection) async -> SetupReply {
        guard let code = setups[s.id], !syncing.contains(s.id) else { return .notAsked }
        syncing.insert(s.id)
        defer {
            syncing.remove(s.id)
            if syncAgain.remove(s.id) != nil { Task { await self.sync(s) } }
        }
        guard s.control.state == .connected, wantsPush, let token else { return .notAsked }
        let link = currentLink(s)
        let registration: GatewayRegistration
        switch await gateway.registration(token: token, environment: environment) {
        case .success(let r):
            registration = r
            if gatewayProblem != nil { gatewayProblem = nil }
        case .failure(let e):
            if gatewayProblem != e { gatewayProblem = e }
            return .notAsked
        }
        guard s.control.state == .connected, link === links[s.id],
              let list = try? await s.control.call("client.list"), link === links[s.id],
              let relay = RelayLookup.relayID(in: list.arr("clients")) else { return .notAsked }
        link.relayID = relay
        return await register(s, relay, link, gateway: registration.gateway, token: token, proving: code)
    }

    /// Registers again with the helper that showed the proof, when the registration that followed
    /// the proof didn't finish. True once that helper is registered.
    func syncAfterSetup(_ s: ServerConnection) async -> Bool {
        if !setupRegistered.contains(s.id) { await sync(s) }
        return setupRegistered.contains(s.id)
    }

    /// The install on this server ended without the helper's proof: the helper there gets nothing
    /// until the user trusts it in Settings, as a helper whose key changed.
    func setupUnproven(_ s: ServerConnection) {
        heldBack.insert(s.id)
        if let link = links[s.id], link.connection == s.connectionSerial, link.offeredKey != nil { fail(s, link, .identityChanged) }
    }

    /// The install is over, whichever way: registrations follow the usual rules again.
    func setupEnded(_ id: UUID) {
        guard setups[id] != nil else { return }
        setups[id] = nil
        provenKeys[id] = nil
        setupRegistered.remove(id)
        if let s = servers().first(where: { $0.id == id }) { Task { await sync(s) } }
    }

    /// The server was removed from the app: its helper's secret stops working and its pin is
    /// forgotten. Best effort; a secret the gateway couldn't be told about dies with the next
    /// "notifications off".
    func serverRemoved(_ id: UUID) {
        links[id] = nil
        helpers[id] = nil
        versions[id] = nil
        setups[id] = nil
        provenKeys[id] = nil
        setupRegistered.remove(id)
        heldBack.remove(id)
        registeredServers.remove(id.uuidString)
        Task { await gateway.forget(id.uuidString, keepPin: false) }
    }

    func isRelay(_ clientID: String, on s: ServerConnection) -> Bool {
        links[s.id]?.relayID == clientID
    }

    // MARK: Helper updates

    /// Asks one server's helper what version it is and whether a newer one is out.
    func refreshVersion(_ s: ServerConnection) {
        guard let relay = registeredRelay(s) else { return }
        Task { await readVersion(s, relay) }
    }

    /// "Update" in Settings: the helper downloads the new version, checks it, and restarts into it.
    /// It leaves and rejoins the server as it does, which brings a fresh registration and version.
    func updateHelper(_ s: ServerConnection) {
        guard let relay = registeredRelay(s), versions[s.id]?.updating != true else { return }
        versions[s.id]?.updating = true
        versions[s.id]?.lastError = nil
        Task {
            switch await ask(s, relay, "update_helper", [:], timeout: 30_000) {
            case .success(let r):
                if r.bool("started") != true { await readVersion(s, relay) }
            case .failure(let f):
                versions[s.id]?.updating = false
                versions[s.id]?.lastError = f.message
            }
        }
    }

    /// The helper on this connection, once it is verified and registered. Nothing else is asked
    /// for its status or told to update.
    private func registeredRelay(_ s: ServerConnection) -> String? {
        guard let l = links[s.id], l.connection == s.connectionSerial, l.registeredSecret != nil,
              s.control.state == .connected else { return nil }
        return l.relayID
    }

    private func readVersion(_ s: ServerConnection, _ relay: String) async {
        guard case .success(let result) = await ask(s, relay, "helper_status", [:]), let v = HelperVersion(result) else { return }
        guard let link = links[s.id], link.relayID == relay else { return }
        versions[s.id] = v
        if v.registered == false { refused(s, link) }
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
        if !wantsPush {
            if !helpers.isEmpty { helpers = [:] }
            if !versions.isEmpty { versions = [:] }
            gatewayProblem = nil
            // Off: the gateway forgets this phone, so no helper can reach it, connected or not.
            // Retried here on each launch and return to front until it gets through.
            if permissionKnown, gateway.hasRegistration { Task { await gateway.revoke() } }
        }
        syncAll()
    }

    /// iOS has said whether notifications are allowed. Before that, "push is off" may only mean
    /// "not asked yet", and nothing may be unregistered on the strength of it.
    private var permissionKnown: Bool { authorization != .unknown || tokenOverride != nil }

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
        guard s.control.state == .connected, permissionKnown else { return }
        let key = s.config.id.uuidString
        let want = wantsPush && token != nil
        guard want || registeredServers.contains(key) else { return }

        let link = currentLink(s)

        // The phone's registration with the gateway, for the token iOS gave us now.
        var registration: GatewayRegistration?
        if want, let token {
            guard !link.gaveUp else { return }
            switch await gateway.registration(token: token, environment: environment) {
            case .success(let r):
                registration = r
                if gatewayProblem != nil { gatewayProblem = nil }
            case .failure(let e):
                // Nothing to hand out. The next sync (a reconnect, a return to front) tries again.
                if gatewayProblem != e { gatewayProblem = e }
                return
            }
            guard s.control.state == .connected, link === links[s.id] else { return }
            // Already registered on this connection with the secret that is still the stored one.
            // During an install only the registration of the helper that showed the proof counts.
            if link.relayID != nil, !link.refused, let given = link.registeredSecret,
               given == gateway.server(key)?.pushSecret, setups[s.id] == nil || setupRegistered.contains(s.id) { return }
        }

        guard let list = try? await s.control.call("client.list"), link === links[s.id] else { return }
        guard let relay = RelayLookup.relayID(in: list.arr("clients")) else {
            link.relayID = nil
            link.registeredSecret = nil
            if want {
                helpers[s.id] = .missing
                versions[s.id] = nil
            }
            return
        }
        link.relayID = relay
        if let registration, let token {
            await register(s, relay, link, gateway: registration.gateway, token: token)
        } else if !want {
            // `token` is for a helper from before the gateway, which removes by token.
            var args: JSONObject = ["device_id": deviceID]
            if let token { args["token"] = token }
            if case .success = await ask(s, relay, "unregister_push", args) {
                registeredServers.remove(key)
            }
            link.relayID = nil
            link.registeredSecret = nil
            helpers[s.id] = nil
            versions[s.id] = nil
        }
    }

    /// This connection's registration with a server, made on first use.
    private func currentLink(_ s: ServerConnection) -> Link {
        if let l = links[s.id], l.connection == s.connectionSerial { return l }
        let link = Link(connection: s.connectionSerial)
        links[s.id] = link
        return link
    }

    /// Gives one server's helper its secret, after the helper proved its key and `HelperAdmission`
    /// let it in: the key is the one pinned for the server, or the first one outside an install,
    /// or the one whose helper showed an install's setup proof. Any step that fails leaves the
    /// helper without a secret and says why in `helpers`.
    ///
    /// `code` is set for an install's own request (`proveSetup`): the helper is then asked for the
    /// setup proof too, and the result says what it answered. Other callers ignore the result.
    @discardableResult
    private func register(_ s: ServerConnection, _ relay: String, _ link: Link, gateway address: String, token: String,
                          proving code: String? = nil) async -> SetupReply {
        let key = s.config.id.uuidString
        let name = s.config.name
        guard let me = s.control.clientID else { return .notAsked }
        // An install that sent its code decides who this server's helper is. Until a helper
        // showed the proof, only the install's own request goes out.
        if code == nil, setups[s.id] != nil, provenKeys[s.id] == nil { return .notAsked }

        // Who is this? A fresh challenge each time, so an old answer can't be replayed.
        let challenge = HelperIdentity.challenge()
        let setupChallenge = HelperIdentity.challenge()
        var identityArgs: JSONObject = ["challenge": challenge, "device_id": deviceID]
        if code != nil { identityArgs["setup_challenge"] = setupChallenge }
        let reply: JSONObject
        switch await ask(s, relay, "helper_identity", identityArgs) {
        case .success(let r):
            reply = r
        case .failure(let f):
            // The install reads its own request's answer; Settings keeps what it showed.
            if code != nil { return .missing }
            // A helper that doesn't know the action is too old to be given anything.
            fail(s, link, f.isUnknownAction || f.isLegacyRefusal ? .outdated : .failed(f.sentence(helper: name)))
            return .notAsked
        }
        guard link === links[s.id], setups[s.id] == code || code == nil else { return code == nil ? .notAsked : .missing }
        guard case .success(let helperKey) = HelperIdentity.verify(reply: reply, challenge: challenge, called: relay,
                                                                    requester: me, device: deviceID) else {
            if code != nil { return .wrong }
            fail(s, link, .failed("Rex DUO Helper on \(name) couldn't prove its identity."))
            return .notAsked
        }
        if let code {
            // Only the helper this install started can answer the setup challenge: the key of
            // the answer is the code the installer handed it.
            switch SetupProof.answer(proof: reply.str("setup_proof"), code: code, challenge: setupChallenge, helper: relay, requester: me) {
            case .missing:
                link.offeredKey = helperKey
                return .missing
            case .wrong:
                link.offeredKey = helperKey
                return .wrong
            case .valid:
                provenKeys[s.id] = helperKey
                heldBack.remove(s.id)
                link.offeredKey = nil
            }
        }
        let setup: HelperAdmission.Setup = setups[s.id] == nil ? .none
            : provenKeys[s.id].map { .proven(sameKey: $0 == helperKey) } ?? .unproven
        let proven = setup == .proven(sameKey: true)
        // The code of the install this helper showed its proof for, for the registration's seal.
        let setupCode = setups[s.id]
        // What an install's request reports when a later step doesn't finish.
        let unfinished: SetupReply = code == nil ? .notAsked : .proven
        let pinned = HelperIdentity.pin(pinned: gateway.server(key)?.helperKey, offered: helperKey)
        switch HelperAdmission.decide(pin: pinned, setup: setup, heldBack: heldBack.contains(s.id)) {
        case .wait:
            return .notAsked
        case .changed:
            link.offeredKey = helperKey
            fail(s, link, .identityChanged)
            return .notAsked
        case .register(.keep):
            break
        case .register(.first):
            guard gateway.pin(key, helperKey: helperKey) else {
                gatewayProblem = .storeFailed
                return unfinished
            }
        case .register(.replace):
            // The install replaced the helper: its key becomes the pin, and the secret the old
            // one held is deleted, as "Trust" does.
            guard await self.gateway.trust(key, helperKey: helperKey) else {
                gatewayProblem = .storeFailed
                return unfinished
            }
            guard link === links[s.id] else { return unfinished }
        }

        if link.refused {
            link.refused = false
            link.repaired = true
            if let e = await gateway.repair(key, token: token, environment: environment) {
                // The gateway couldn't say what is left, so nothing was repaired yet.
                link.repaired = false
                gatewayProblem = e
                return unfinished
            }
            // A new registration left every server without a secret: the others mint theirs.
            for other in servers() where other.id != s.id { Task { await self.sync(other) } }
        }

        var secret = gateway.server(key)?.pushSecret
        if secret == nil {
            switch await gateway.mint(key, label: SecretLabel.make(name)) {
            case .success(let minted):
                secret = minted
            case .failure(.unknownRegistration):
                // The gateway forgot this phone since the registration was read.
                refused(s, link)
                return unfinished
            case .failure(let e):
                gatewayProblem = e
                return unfinished
            }
        }
        guard let secret, s.control.state == .connected, link === links[s.id] else { return unfinished }

        // The seal goes along only while the install the proof was shown for is still the one running.
        let args = PushRegistration.arguments(gateway: address, secret: secret, environment: environment,
                                              deviceName: UIDevice.current.name, deviceID: deviceID,
                                              setup: setup, code: setups[s.id] == setupCode ? setupCode : nil)
        switch await ask(s, relay, "register_push", args) {
        case .success(let r):
            guard link === links[s.id] else { return unfinished }
            link.registeredSecret = secret
            registeredServers.insert(key)
            helpers[s.id] = .running(pushEnabled: r.bool("push_enabled") ?? true)
            if proven, setups[s.id] != nil { setupRegistered.insert(s.id) }
            if inFront { await presence(s, relay, true) }
            await readVersion(s, relay)
            return code == nil ? .notAsked : .registered
        case .failure(let f):
            if f.isSecretDropped {
                refused(s, link)
            } else {
                fail(s, link, f.isLegacyRefusal ? .outdated : .failed(f.sentence(helper: name)))
            }
            return unfinished
        }
    }

    /// The helper holds nothing from this connection, and Settings says why.
    private func fail(_ s: ServerConnection, _ link: Link, _ state: Helper) {
        guard link === links[s.id] else { return }
        link.registeredSecret = nil
        helpers[s.id] = state
        versions[s.id] = nil
    }

    /// A helper said its secret for this phone no longer works (`registered: false`, or the
    /// `secret_dropped` error). The first time on a connection the next sync repairs it; a helper
    /// that still refuses after that is left alone, with a line in Settings.
    private func refused(_ s: ServerConnection, _ link: Link) {
        guard link === links[s.id], !link.refused, !link.gaveUp, wantsPush else { return }
        switch SecretRepair.onRefusal(repaired: link.repaired) {
        case .repair:
            link.refused = true
            Task { await sync(s) }
        case .giveUp:
            link.gaveUp = true
            fail(s, link, .failed(SecretRepair.gaveUp(helper: s.config.name)))
        }
    }

    private func ask(_ s: ServerConnection, _ relay: String, _ action: String, _ args: JSONObject,
                     timeout: Int = 5000) async -> Result<JSONObject, HelperFailure> {
        do {
            return HelperFailure.read(try await s.control.call(
                "client.perform", ["client_id": relay, "action": action, "args": args, "timeout_ms": timeout]))
        } catch {
            return .failure(HelperFailure(error))
        }
    }

    private func presence(_ s: ServerConnection, _ relay: String, _ active: Bool) async {
        guard case .success(let r) = await ask(s, relay, "push_presence", ["active": active]) else { return }
        // Only while in front: on the way to the background iOS is about to suspend the app.
        if active, r.bool("registered") == false, let link = links[s.id], link.relayID == relay { refused(s, link) }
    }

    /// Tells each helper we're registered with whether the app is in front. Going to the
    /// background runs inside a background task, since iOS suspends the app right after.
    private func sendPresence(active: Bool) {
        let targets = servers().compactMap { s -> (ServerConnection, String)? in
            guard let relay = registeredRelay(s) else { return nil }
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
