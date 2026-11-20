import UIKit
import UserNotifications
import RexKit

/// Notifications from the computers, as Settings shows them and as the rest of the app drives
/// them. Signing the phone up is `PushReconciler`'s; this type tells it what the person wants,
/// renders what it found, and makes the calls that are not sign-up. The contract with the
/// helper (actions, arguments, when to call them) is in docs/notifications.md.
///
/// - What the person wants for a computer is `intent(for:)`: the master switch, the computer's
///   own switch, what iOS allows and the phone's notification address.
/// - A switch only pauses and resumes: the master switch and a computer's switch tell the
///   helper to hold this phone's notifications back, now or when the computer is next
///   connected. Nothing at the gateway changes, and no secret is taken back. The master switch
///   off also takes the app off Apple's remote notifications, and on puts it back.
/// - A secret is taken back only by "Remove Beacon", by "Trust" of a changed Beacon, and when
///   the computer is removed from the app.
/// - On background and foreground: `push_presence`, so the helper skips pushes while the app
///   shows its own toasts.
///
/// Which Beacon version is the latest is the app's to say: `release` reads the signed release
/// list once for every computer, and each row compares its Beacon's version against that one
/// result (`LatestRelease.standing`). A Beacon only supplies its own version, whether it can
/// replace itself, and whether it is doing so.
///
/// For the Notifications screen it is the one source of what to show and the one place its
/// actions go: `master`, `computers` and `status(for:)` are the rows `NotificationStatus.swift`
/// makes from this type's facts, and `setMaster`, `setComputer`, `fix`, `sendTest`, `details`,
/// `removeHelper` and `cancel` are what the rows' controls call.
@MainActor
@Observable
final class PushRegistrar {
    /// What the registrar needs from iOS, so tests can stand in for it.
    @MainActor
    struct System {
        /// What iOS says about notifications for the app, read now.
        var permission: @MainActor () async -> NotificationPermission
        /// Shows the iOS question. Only called while iOS has never asked.
        var ask: @MainActor () async -> Void
        /// Asks iOS for this phone's notification address.
        var registerForNotifications: @MainActor () -> Void
        /// Takes the app off Apple's remote notifications, so nothing arrives.
        var unregisterForNotifications: @MainActor () -> Void
        /// Opens the app's page in iOS Settings.
        var openSettings: @MainActor () -> Void
        var deviceName: @MainActor () -> String

        static let live = System(
            permission: {
                await withCheckedContinuation { (c: CheckedContinuation<NotificationPermission, Never>) in
                    UNUserNotificationCenter.current().getNotificationSettings { s in
                        let permission: NotificationPermission = switch s.authorizationStatus {
                        case .notDetermined: .notAsked
                        case .denied: .denied
                        case .provisional: .quiet
                        default: .allowed(provisional: false, banners: s.alertSetting == .enabled, sounds: s.soundSetting == .enabled)
                        }
                        c.resume(returning: permission)
                    }
                }
            },
            ask: { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) },
            registerForNotifications: { UIApplication.shared.registerForRemoteNotifications() },
            unregisterForNotifications: { UIApplication.shared.unregisterForRemoteNotifications() },
            openSettings: {
                if let url = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(url) }
            },
            deviceName: { UIDevice.current.name })
    }

    /// What sign-up is made of, so tests can stand in for each part.
    @MainActor
    struct Parts {
        var gateway: PushGateway?
        var store: RegistrationStore
        /// The computers' Rex connections. Nil for the app's own servers.
        var channel: HelperChannel?
        var now: @MainActor () -> Date = { Date() }
        var sleep: @MainActor (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
        var random = PushRandom.system
    }

    typealias Helper = PushReconciler.Helper
    typealias SetupReply = PushReconciler.SetupReply

    let deviceID: String
    let environment: String
    /// What iOS says about notifications for the app. Read at start and every time the app
    /// becomes active.
    private(set) var permission: NotificationPermission = .unknown
    private(set) var token: String?
    /// iOS said it can't give this phone a notification address. The app keeps asking.
    private(set) var addressFailed = false
    /// What each helper last said of itself: its version, and how it can be updated.
    private(set) var versions: [UUID: HelperVersion] = [:]
    /// The version each helper gave when it took this phone (`register_push`'s
    /// `helper_version`). It usually arrives before the helper's status does, and the row shows
    /// whichever is there, the status first.
    private(set) var registeredVersions: [UUID: String] = [:]
    /// Servers whose helper is being removed, or whose removal did not finish.
    private(set) var removals: [UUID: ComputerFacts.Removal] = [:]
    /// The result of the last "Send Test Notification", for a few seconds.
    private(set) var tests: [UUID: ComputerFacts.Test] = [:]
    /// Servers whose helper was asked to update itself with "Update" and has not reported the
    /// new version yet.
    private(set) var updating: Set<UUID> = []

    /// What sign-up found on each computer.
    var helpers: [UUID: Helper] { reconciler.helpers }

    /// The servers of the app. AppModel sets it.
    @ObservationIgnored var servers: () -> [ServerConnection] = { [] } {
        didSet { (channel as? ServerHelpers)?.servers = servers }
    }
    /// The installs of the helper. AppModel sets it; without it nothing is installed or removed.
    @ObservationIgnored weak var setup: HelperSetupCenter?
    /// Opens the install sheet for a server, and brings back the sheet of an install that goes
    /// on without it; true as the second value opens that sheet at the installer's output.
    /// AppModel sets both.
    @ObservationIgnored var presentSetup: (UUID, SetupState.Kind) -> Void = { _, _ in }
    @ObservationIgnored var showSetup: (UUID, Bool) -> Void = { _, _ in }
    /// Signs the phone up, computer by computer.
    @ObservationIgnored let reconciler: PushReconciler
    @ObservationIgnored private let channel: HelperChannel
    @ObservationIgnored private let system: System
    /// The app's check for the latest Beacon release. Nil where nothing is checked (tests that
    /// are not about it): rows then show the version and make no claim.
    @ObservationIgnored private let release: ReleaseCheck?
    @ObservationIgnored private let sleep: @MainActor (TimeInterval) async -> Void
    /// Servers where an install of the helper is under way. They sign up whatever iOS says
    /// about notifications, so the install can finish.
    @ObservationIgnored private var settingUp: Set<UUID> = []
    @ObservationIgnored private var addressRetry: Task<Void, Never>?
    #if DEBUG
    /// `-simulateNotifications <name>`: fixed rows for screenshots. Nothing is signed up.
    @ObservationIgnored private let simulation: NotificationSimulation?
    #endif
    @ObservationIgnored private let prefs: Prefs
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private var started = false
    /// The master switch's question to iOS is under way. iOS may take as long as the person does.
    @ObservationIgnored private var asking = false
    /// The app is in front: false until `becameActive()` first says so, so a launch that never
    /// reaches the screen tells no helper that the phone is in use. A connection that resumes
    /// keeps its client id, so the helper still thinks it's in the background until told otherwise.
    @ObservationIgnored private var inFront = false
    /// `-pushToken <hex>` (debug builds): use this token and skip the permission check, to test
    /// sign-up in a simulator.
    @ObservationIgnored private let tokenOverride: String?

    private static let tokenKey = "pushToken.last"

    init(prefs: Prefs, deviceID: String, environment: String = APNsEnvironment.current, defaults: UserDefaults = .standard,
         parts: Parts? = nil, system: System = .live, release: ReleaseCheck? = nil) {
        self.prefs = prefs
        self.system = system
        self.release = release
        self.deviceID = deviceID
        self.environment = environment
        self.defaults = defaults
        var address = PushGateway.defaultURL
        #if DEBUG
        // `-pushGateway <url>` (debug builds): another gateway, to test against a local one.
        if let other = defaults.string(forKey: "pushGateway") { address = other }
        #endif
        let parts = parts ?? Parts(gateway: PushGateway(address: address), store: KeychainRegistrationStore())
        let channel = parts.channel ?? ServerHelpers()
        self.channel = channel
        now = parts.now
        sleep = parts.sleep
        reconciler = PushReconciler(gateway: parts.gateway, store: parts.store, channel: channel, prefs: prefs,
                                    phone: PushReconciler.Phone(deviceID: deviceID, environment: environment, deviceName: system.deviceName),
                                    now: parts.now, sleep: parts.sleep, random: parts.random)
        token = defaults.string(forKey: Self.tokenKey)
        #if DEBUG
        tokenOverride = defaults.string(forKey: "pushToken").map { $0.lowercased() }
        #else
        tokenOverride = nil
        #endif
        if let tokenOverride { token = tokenOverride }
        #if DEBUG
        simulation = defaults.string(forKey: "simulateNotifications").flatMap(NotificationSimulation.init(name:))
        #endif
        reconciler.intent = { [weak self] in self?.intent(for: $0) ?? .waiting }
        reconciler.registered = { [weak self] in self?.helperRegistered($0, version: $1) }
        #if DEBUG
        if let script = defaults.string(forKey: "notificationsScript") {
            Task { [weak self] in await self?.run(script: script) }
        }
        #endif
    }

    /// iOS shows this app's notifications in some form (quiet ones go to Notification Center).
    /// `-pushToken` stands in for the permission.
    private var allowed: Bool { permission == .allowed || permission == .quiet || tokenOverride != nil }

    /// The master switch is on and iOS lets notifications through, or an install is under way.
    private var active: Bool { prefs.pushEnabled && (allowed || !settingUp.isEmpty) }

    /// What the person wants for one computer, with what iOS allows: the reconciler's question.
    func intent(for id: UUID) -> PushIntent {
        if removals[id] != nil { return .leaveAlone }
        if !prefs.pushEnabled || prefs.notificationsOff.contains(id) { return .paused }
        guard allowed || settingUp.contains(id), let token else { return .waiting }
        return .on(token: token)
    }

    // MARK: What the Notifications screen shows

    /// The "Notifications" switch.
    var master: MasterStatus {
        #if DEBUG
        if let simulation { return simulation.master }
        #endif
        return MasterStatus.make(MasterFacts(permission: tokenOverride != nil ? .allowed : permission, choice: prefs.pushEnabled,
                                             addressMissing: addressFailed && token == nil))
    }

    /// One row per computer, in the servers' order. The screen lists them while
    /// `master.showsComputers`.
    var computers: [ComputerRow] {
        #if DEBUG
        if let simulation { return simulation.rows }
        #endif
        return servers().map { ComputerRow(id: $0.id, name: $0.config.name, status: ComputerStatus.make(facts(for: $0))) }
    }

    /// One computer's row. Nil for a server that is not in the app.
    func status(for id: UUID) -> ComputerStatus? {
        #if DEBUG
        if let simulation { return simulation.rows.first { $0.id == id }?.status }
        #endif
        return server(id).map { ComputerStatus.make(facts(for: $0)) }
    }

    /// The facts behind a computer's row, from what this type, the installs and the connection
    /// know.
    func facts(for s: ServerConnection) -> ComputerFacts {
        let id = s.id
        let seen = prefs.helperSeen.contains(id)
        let helper: ComputerFacts.Helper = switch helpers[id] {
        case .missing: seen ? .notRunning : .notInstalled
        // Not looked for: the computer is off, or its first look is still on its way.
        case nil: seen ? .running : .notInstalled
        default: .running
        }
        var install: ComputerFacts.Setup?
        if let setup {
            if let run = setup.run(for: id) {
                install = ComputerFacts.Setup(run.state)
            } else if setup.pending?.server == id {
                install = .working(.downloading)
            } else if let error = setup.failures[id] {
                install = ComputerFacts.Setup(error)
            }
        }
        let registered: Bool = if case .running = helpers[id] { true } else { false }
        // While the gateway asks the phone to wait, the row says so in place of a failed try.
        let limited = reconciler.limit != nil && !registered && !reconciler.stopped.contains(id)
        let link: ComputerFacts.Link
        // The computer is on and was signed up before, and its helper has not confirmed on this
        // connection that it holds the phone's secret and is not paused: the app is on it.
        let confirming: Bool = if case .on = intent(for: id), seen, !s.showsOffline, helpers[id] == nil || registered,
                                  !reconciler.stopped.contains(id), !reconciler.isSettled(id) { true } else { false }
        if limited {
            link = .pending
        } else if reconciler.retrying.contains(id) || reconciler.mending.contains(id) || confirming {
            link = .repairing
        } else if registered {
            link = .connected
        } else if case .failed = helpers[id] {
            link = .failed
        } else if reconciler.stopped.contains(id) {
            link = .failed
        } else {
            link = .pending
        }
        return ComputerFacts(name: s.config.name, choice: !prefs.notificationsOff.contains(id), online: !s.showsOffline,
                             helper: helper, setup: install,
                             // While an install runs there, it decides who the helper is.
                             changed: helpers[id] == .identityChanged && setup?.isRunning(id) != true,
                             // One that refused the registration as too old never says its version.
                             tooOld: helpers[id] == .outdated,
                             link: link, limit: limited ? RateLimit(retryAt: reconciler.limit?.retryAt, now: now()) : nil,
                             pauseWaits: prefs.helpersToTell.contains(id),
                             full: reconciler.full.contains(id),
                             removal: removals[id], test: tests[id], version: shownVersion(id),
                             updating: updating.contains(id) || versions[id]?.updating == true)
            // The app's word on the version, the same release for every computer.
            .judged(against: release?.latest)
    }

    /// The version a computer's helper last gave: its status first, then its answer to the
    /// registration.
    private func shownVersion(_ id: UUID) -> String? { versions[id]?.version ?? registeredVersions[id] }

    private func server(_ id: UUID) -> ServerConnection? { servers().first { $0.id == id } }

    // MARK: Lifecycle

    /// Called once the app is on screen. Reads the permission and asks APNs for a token if push is on.
    func start() {
        guard !started else { return }
        started = true
        if !simulated { reconciler.computersLoaded() }
        Task { await refresh() }
    }

    /// Reads what iOS says about notifications now, and brings everything in line with it.
    func refresh() async {
        await refreshPermission()
        apply()
        checkRelease()
    }

    /// Reads the release list when it is due (`ReleaseCheck`), and only while its result would
    /// show: notifications are on and a computer is listed.
    private func checkRelease() {
        guard let release, !simulated, master.showsComputers, !channel.computers.isEmpty else { return }
        Task { await release.refresh() }
    }

    /// Back in front: the user may have changed the permission in iOS Settings. With
    /// notifications allowed again, every computer comes back as it was chosen.
    func becameActive() {
        inFront = true
        guard started else { return }
        sendPresence(active: true)
        Task {
            await refreshPermission()
            guard !simulated else { return }
            if active, tokenOverride == nil { system.registerForNotifications() }
            // A new stay in front: each computer has its automatic tries again.
            reconciler.cameToFront()
            checkRelease()
            // A Beacon may have replaced itself while the app was away, with nothing to tell
            // the app: each one that holds the phone says which version it is now.
            for id in channel.computers where reconciler.relay(id) != nil {
                Task { await self.lookAgain(id) }
            }
        }
    }

    /// The phone's network changed: a try that failed can work now.
    func networkChanged() {
        guard started, !simulated else { return }
        reconciler.reconcileAll()
    }

    func enteredBackground() {
        inFront = false
        sendPresence(active: false)
    }

    // MARK: What the Notifications screen does

    /// The master switch. On asks iOS at that moment if it never has, and puts the app back on
    /// Apple's remote notifications. Off takes it off them and pauses this phone on every
    /// computer, now or when each is next connected; each computer's choice, its secret and the
    /// phone's registration stay as they are. While iOS has notifications turned off the choice
    /// stays as it is and iOS Settings opens instead.
    func setMaster(on: Bool) {
        guard !simulated else { return }
        guard permission != .denied || tokenOverride != nil else { return system.openSettings() }
        guard on else {
            guard prefs.pushEnabled else { return }
            prefs.pushEnabled = false
            if tokenOverride == nil { system.unregisterForNotifications() }
            // What each helper said of its version stays: it is the same helper when the
            // switch goes on again, and nothing may be left to ask it then.
            if !tests.isEmpty { tests = [:] }
            // A computer that is off by its own switch has been told, or waits to be.
            for id in channel.computers where !prefs.notificationsOff.contains(id) { reconciler.pause(id) }
            return
        }
        prefs.pushEnabled = true
        // Every computer comes back with what is known now: the permission as last read and
        // the address the phone already has. Nothing here waits for iOS.
        apply(by: .person)
        checkRelease()
        // iOS is asked the first time, by one question at a time; its answer, whenever it
        // comes, and an address iOS gives later bring everything in line once more.
        guard !asking else { return }
        asking = true
        Task {
            let before = permission
            await refreshPermission()
            // `-pushToken` (debug builds) stands in for the permission, so it is not asked for.
            if permission == .notAsked, tokenOverride == nil { await system.ask() }
            await refreshPermission()
            asking = false
            if permission != before { apply(by: .person) }
        }
    }

    /// One computer's switch. On resumes this phone there, signing it up first when it never
    /// was, and installing the helper when the computer has none. Off pauses it there, at once
    /// or, while the computer can't be reached, the next time it is connected; an install that
    /// is under way there is stopped.
    func setComputer(_ id: UUID, on: Bool) {
        guard !simulated, removals[id] != .removing else { return }
        if on {
            // The choice changes now, so that a switch moved again right after finds it.
            prefs.notificationsOff.remove(id)
            if prefs.helpersToTell.contains(id) { prefs.helpersToTell.remove(id) }
            removals[id] = nil
            Task { await turnOn(id) }
        } else {
            turnOff(id)
        }
    }

    /// The row's one button. `.how` and `.trust` are the screen's: it shows the steps in
    /// `NotificationCopy.manualSteps`, and the confirm of `NotificationCopy.trustConfirm`, whose
    /// button calls `trust(_:key:)`.
    func fix(_ fix: NotificationFix, for id: UUID) {
        guard !simulated else { return }
        switch fix {
        case .openSettings:
            system.openSettings()
        case .how:
            break
        case .continueSetup:
            showSetup(id, false)
        case .retry:
            if removals[id] == .failed {
                removeHelper(from: id)
            } else if setup?.failures[id] != nil {
                presentSetup(id, .install)
            } else {
                reconciler.trigger(id, by: .person)
            }
        case .update:
            update(id)
        case .repair:
            presentSetup(id, .repair)
        case .trust:
            break
        }
    }

    /// The key the computer's changed helper offers now, for the confirm before `trust`. Nil
    /// when none is offered.
    func offeredKey(for id: UUID) -> String? { reconciler.offeredKey(id) }

    /// "Trust", once the person confirmed: `key` is the helper key that was offered when the
    /// confirm was shown, and only that key is pinned. A helper that offers another by now is
    /// not trusted; the row stays at "Beacon has changed", and its button shows the confirm again.
    func trust(_ id: UUID, key: String) {
        guard !simulated else { return }
        Task { await reconciler.trust(id, key: key) }
    }

    /// The master switch's button: iOS Settings.
    func openSettings() { system.openSettings() }

    /// "Reinstall Beacon" in a row's menu.
    func reinstall(_ id: UUID) {
        guard !simulated else { return }
        presentSetup(id, .reinstall)
    }

    /// "Send Test Notification": the computer's helper sends one notification to this phone. The
    /// row shows how it went for a few seconds; a helper that has lost this phone, or holds it
    /// paused, is put right.
    func sendTest(for id: UUID) {
        guard !simulated, removals[id] == nil else { return }
        Task {
            var code: String? = "not_registered"
            if let relay = reconciler.relay(id) {
                switch await channel.perform(id, relay: relay, action: "send_test", args: [:], timeout: 20_000) {
                case .success(let r): code = r.bool("sent") == false ? "" : nil
                case .failure(let f): code = f.isUnknownAction ? "not_supported" : f.code
                }
            }
            switch TestOutcome.read(code: code) {
            case .sent: showTest(.sent, for: id)
            case .failed(let why): showTest(.failed(why), for: id)
            case .repair(.addressDied): reconciler.addressDied(id)
            case .repair(.lost): reconciler.helperLost(id)
            // The person asked for a test: the helper resumes whatever came before.
            case .repair(.paused): reconciler.helperPaused(id, by: .person)
            }
        }
    }

    /// "Show Details" on a computer whose install is under way or has failed: the install's
    /// sheet comes back, at the installer's output. False for a computer with no such install,
    /// where `details(for:)` is what to show.
    func showSetupDetails(for id: UUID) -> Bool {
        guard !simulated, setup?.run(for: id) != nil else { return false }
        showSetup(id, true)
        return true
    }

    #if DEBUG
    /// `-simulateNotifications confirm-remove|confirm-trust|details|how`: what the screen has up
    /// over its first computer when it opens.
    var simulatedPresentation: NotificationSimulation.Presentation? { simulation?.presents }
    #endif

    /// "Show Details": what the computer's helper says about itself, read now. Nil when no
    /// helper answers.
    func details(for id: UUID) async -> HelperDetails? {
        #if DEBUG
        if simulation != nil { return NotificationSimulation.details }
        #endif
        guard let relay = await relay(on: id),
              case .success(let status) = await channel.perform(id, relay: relay, action: "helper_status", args: [:], timeout: 5000) else { return nil }
        var details = HelperDetails(status: status)
        // The check is the app's own, the same for every computer.
        details.updateCheck = release?.lastFailed == true ? .failed : .ok
        return details
    }

    /// The words of the confirm before `removeHelper`, with the helper's count of other phones
    /// when it says.
    func removeConfirm(for id: UUID) async -> NotificationCopy.Confirm {
        let name = computers.first { $0.id == id }?.name ?? ""
        let details = await details(for: id)
        return NotificationCopy.removeConfirm(name: name, devices: details?.devices, otherPhones: details?.otherPhones)
    }

    /// "Remove Beacon…", once the person confirmed: this phone's secret for the helper is taken
    /// back and the helper is told, then the installer script removes the helper from the
    /// computer, then the phone forgets the helper and the computer's switch goes off
    /// (`HelperRemoval`). A script that fails leaves the row at "Couldn't remove Beacon".
    func removeHelper(from id: UUID) {
        guard !simulated, let s = server(id), removals[id] != .removing, s.control.state == .connected else { return }
        // From here the computer is not signed up again until the removal is over.
        removals[id] = .removing
        setup?.cancel(id)
        forgetShown(id, version: true)
        Task {
            let removed = await HelperRemoval.run(HelperRemoval.Steps(
                revoke: { await self.reconciler.revoke(id, keepPin: true) },
                unregister: { await self.sayGoodbye(id) },
                script: { await self.setup?.remove(on: s) },
                clear: {
                    await self.reconciler.revoke(id, keepPin: false)
                    self.reconciler.clear(id)
                    self.prefs.helperSeen.remove(id)
                    self.prefs.notificationsOff.insert(id)
                }))
            removals[id] = removed ? nil : .failed
        }
    }

    /// "Cancel" in a row's menu: stops the install that is under way on the computer.
    func cancel(for id: UUID) {
        guard !simulated else { return }
        setup?.cancel(id)
    }

    /// An install of the helper on this server starts. It is the person asking for notifications
    /// from this computer: the master switch and the computer's own go on, and iOS asks if it
    /// never has. Whatever iOS answers, the computer signs up while the install runs, so the
    /// helper is installed and checked all the same.
    func prepareForSetup(_ id: UUID) async {
        prefs.pushEnabled = true
        prefs.notificationsOff.remove(id)
        prefs.helpersToTell.remove(id)
        removals[id] = nil
        settingUp.insert(id)
        await refreshPermission()
        // `-pushToken` (debug builds) stands in for the permission, so it is not asked for.
        if permission == .notAsked, tokenOverride == nil {
            await system.ask()
            await refreshPermission()
        }
        apply(by: .person)
    }

    private var simulated: Bool {
        #if DEBUG
        return simulation != nil
        #else
        return false
        #endif
    }

    private func turnOn(_ id: UUID) async {
        await reconciler.run(id, by: .person)
        // A run that was already on its way finishes first: it is the one that looks for the helper.
        for _ in 0..<50 where reconciler.isBusy(id) {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        // No helper there and none ever was: install it, when this phone may. Otherwise the row
        // says to install it on the computer.
        guard case .on = intent(for: id), helpers[id] == .missing, !prefs.helperSeen.contains(id), let s = server(id),
              let setup, !setup.isRunning(id) else { return }
        if setup.offer(for: s) == .install { presentSetup(id, .install) } else { setup.noteManual(id) }
    }

    /// The computer is turned off: its helper holds this phone's notifications back from now
    /// on, or from the next time the computer is connected. Nothing is deleted anywhere.
    private func turnOff(_ id: UUID) {
        prefs.notificationsOff.insert(id)
        setup?.cancel(id)
        forgetShown(id)
        reconciler.pause(id)
    }

    /// What the row showed of the computer's helper is over. Its version stays: it is the
    /// same helper when the computer is turned on again.
    private func forgetShown(_ id: UUID, version: Bool = false) {
        if version {
            versions[id] = nil
            registeredVersions[id] = nil
        }
        tests[id] = nil
    }

    private func showTest(_ result: ComputerFacts.Test, for id: UUID) {
        tests[id] = result
        Task {
            try? await Task.sleep(nanoseconds: UInt64(TestOutcome.shownFor * 1_000_000_000))
            if tests[id] == result { tests[id] = nil }
        }
    }

    // MARK: Token

    func tokenReceived(_ data: Data) {
        guard tokenOverride == nil else { return }
        let hex = PushIdentity.hex(data)
        if hex != token {
            // A new or rotated address goes to the gateway once. The helpers' secrets stay.
            token = hex
            defaults.set(hex, forKey: Self.tokenKey)
        }
        addressFailed = false
        addressRetry?.cancel()
        addressRetry = nil
        if !simulated { reconciler.reconcileAll() }
    }

    /// How long after iOS said it has no notification address the app asks again.
    static let addressRetryAfter: TimeInterval = 30

    func tokenFailed(_ error: Error) {
        print("[push] no APNs token: \(error.localizedDescription)")
        guard tokenOverride == nil else { return }
        addressFailed = true
        addressRetry?.cancel()
        addressRetry = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.addressRetryAfter * 1_000_000_000))
            guard let self, !Task.isCancelled, self.active, self.addressFailed else { return }
            self.system.registerForNotifications()
        }
    }

    // MARK: Servers

    /// A server finished a (re)sync. Signs up on a new connection; otherwise usually does nothing.
    func serverReady(_ s: ServerConnection) {
        guard !simulated else { return }
        reconciler.trigger(s.id)
    }

    /// A helper joined or left this server: look for it again.
    func relayChanged(_ s: ServerConnection) {
        helperClientChanged(s.id)
    }

    /// The computer's helper is another client than before, as after it restarted for an update
    /// or was installed again. The reconciler finds the new one and hands it the secret, and
    /// with that the helper is asked for its status (`helperRegistered`), so the row shows the
    /// version that runs now with no tap.
    func helperClientChanged(_ id: UUID) {
        guard !simulated else { return }
        reconciler.helperChanged(id)
    }

    /// An install on this server has typed its setup code into the installer: from now until
    /// `setupEnded`, the server's helper is signed up only after it showed the proof for `code`.
    func beginSetup(_ id: UUID, code: String) {
        reconciler.beginSetup(id, code: code)
    }

    /// Asks the helper now connected on this server for the proof that the install started it,
    /// once. The run calls this after the installer's `start` step, and counts the replies.
    func proveSetup(_ s: ServerConnection) async -> SetupReply {
        await reconciler.prove(s.id)
    }

    /// Signs the helper that showed the proof up again, when the sign-up that followed the
    /// proof didn't finish. True once that helper holds its secret.
    func syncAfterSetup(_ s: ServerConnection) async -> Bool {
        await reconciler.setupRegistered(s.id)
    }

    /// The install on this server ended without the helper's proof: the helper there gets nothing
    /// until the user trusts it in Settings, as a helper whose key changed.
    func setupUnproven(_ s: ServerConnection) {
        reconciler.setupUnproven(s.id)
    }

    /// The install is over, whichever way: sign-up follows the usual rules again.
    func setupEnded(_ id: UUID) {
        let was = settingUp.remove(id) != nil
        reconciler.setupEnded(id)
        if was { apply(by: .person) }
    }

    /// The server was removed from the app: its helper's secret stops working and its pin is
    /// forgotten.
    func serverRemoved(_ id: UUID) {
        versions[id] = nil
        registeredVersions[id] = nil
        settingUp.remove(id)
        updating.remove(id)
        removals[id] = nil
        tests[id] = nil
        prefs.notificationsOff.remove(id)
        prefs.helperSeen.remove(id)
        reconciler.forget(id)
    }

    func isRelay(_ clientID: String, on s: ServerConnection) -> Bool {
        reconciler.isRelay(clientID, on: s.id)
    }

    // MARK: Helper updates

    /// Asks one server's helper which version it is.
    func refreshVersion(_ s: ServerConnection) {
        guard reconciler.relay(s.id) != nil else { return }
        Task { await readVersion(s.id) }
    }

    /// "Update": one tap brings the helper to the latest version. A helper that says it can
    /// replace itself is asked to (`HelperUpdate.route`); the installer does it for every other
    /// one, and for one that was asked and did not get there.
    private func update(_ id: UUID) {
        guard !updating.contains(id) else { return }
        guard HelperUpdate.route(reported: versions[id]) == .bySelf, let relay = reconciler.relay(id) else {
            return presentSetup(id, .repair)
        }
        let before = shownVersion(id)
        updating.insert(id)
        Task {
            let done = await updateBySelf(id, relay: relay, from: before)
            updating.remove(id)
            // The computer may have left the app, or its Beacon been removed, meanwhile.
            if !done, channel.computers.contains(id), removals[id] == nil { presentSetup(id, .repair) }
        }
    }

    /// Asks the helper to download the new version, check it and restart into it
    /// (`update_helper`; the helper has its own checks and its own pause between two updates),
    /// then waits until it reports that version. True once it does. False when the helper
    /// refused or did not start, and when `HelperUpdate.limit` passed without the new version.
    ///
    /// The restarted helper is a new client on the server, which brings its status by itself
    /// (`helperClientChanged`); the look every few seconds is for a helper that kept its client.
    private func updateBySelf(_ id: UUID, relay: String, from before: String?) async -> Bool {
        let asked = now()
        guard case .success(let reply) = await channel.perform(id, relay: relay, action: "update_helper", args: [:], timeout: 30_000),
              reply.bool("started") == true else { return false }
        var reached: Bool { HelperUpdate.reached(shownVersion(id), from: before, target: release?.latest?.version) }
        while !reached, now().timeIntervalSince(asked) < HelperUpdate.limit {
            await sleep(HelperUpdate.askEvery)
            await readVersion(id)
        }
        return reached
    }

    /// A computer's helper holds its secret: it hears whether the app is in front, and says
    /// which version it is.
    private func helperRegistered(_ id: UUID, version: String?) {
        if let version, !version.isEmpty {
            if registeredVersions[id] != version { registeredVersions[id] = version }
            // A status that names another version is from the helper that ran there before
            // this one: the row shows the registration's until the new status is in.
            if let status = versions[id], status.version != version { versions[id] = nil }
        }
        checkRelease()
        Task {
            if inFront { await presence(id, true) }
            // The helper that registers may not be the one whose status the app holds (it
            // restarts for an update), so it is asked again each time. One that gave no version
            // with the registration is asked a few times, in case the first answer is lost:
            // the row waits at "Connecting…" for it.
            for attempt in 0..<Self.versionTries {
                if attempt > 0 { await sleep(Self.versionRetryAfter) }
                if await readVersion(id) || version?.isEmpty == false { break }
            }
        }
    }

    /// Back in front. Events may have been missed while the app was away, so the computer's
    /// client list is read: with another helper client there than the one the app knows, the
    /// Beacon restarted and is taken as changed; the one known is asked for its status.
    private func lookAgain(_ id: UUID) async {
        guard let known = reconciler.relay(id) else { return }
        if let clients = await channel.clients(id), RelayLookup.relayID(in: clients) != known {
            if reconciler.relay(id) == known { helperClientChanged(id) }
        } else {
            await readVersion(id)
        }
    }

    /// How often a helper that just registered is asked for its status until it has said its
    /// version, and the pause between two tries.
    static let versionTries = 3
    static let versionRetryAfter: TimeInterval = 2

    /// The helper's word on itself; true when it gave one. One that says it holds nothing for
    /// this phone, or holds it paused while the computer is on, is put right by the reconciler.
    @discardableResult
    private func readVersion(_ id: UUID) async -> Bool {
        guard let relay = reconciler.relay(id),
              case .success(let result) = await channel.perform(id, relay: relay, action: "helper_status", args: [:], timeout: 5000),
              let v = HelperVersion(result), reconciler.relay(id) == relay else { return false }
        if versions[id] != v { versions[id] = v }
        if v.registered == false {
            reconciler.helperLost(id)
        } else if v.paused == true {
            reconciler.helperPaused(id)
        }
        return true
    }

    // MARK: Internals

    private func refreshPermission() async {
        let now = await system.permission()
        if permission != now { permission = now }
    }

    /// Brings everything in line with the master switch and what iOS allows.
    private func apply(by who: PushReconciler.Trigger = .automatic) {
        guard !simulated else { return }
        if active, tokenOverride == nil { system.registerForNotifications() }
        reconciler.reconcileAll(by: who)
    }

    /// Tells a computer's helper that this phone is gone from it, before the helper is removed.
    private func sayGoodbye(_ id: UUID) async {
        guard let relay = await relay(on: id) else { return }
        _ = await channel.perform(id, relay: relay, action: "unregister_push", args: ["device_id": deviceID], timeout: 5000)
    }

    /// The helper on the computer's connection, signed up or not: a look at the computer's clients.
    private func relay(on id: UUID) async -> String? {
        guard channel.connection(id) != nil, let clients = await channel.clients(id) else { return nil }
        return RelayLookup.relayID(in: clients)
    }

    private func presence(_ id: UUID, _ active: Bool) async {
        guard let relay = reconciler.relay(id),
              case .success(let r) = await channel.perform(id, relay: relay, action: "push_presence", args: ["active": active],
                                                          timeout: 5000) else { return }
        // Only while in front: on the way to the background iOS is about to suspend the app.
        if active, r.bool("registered") == false, reconciler.relay(id) == relay { reconciler.helperLost(id) }
    }

    /// Tells each helper that holds this phone whether the app is in front. Going to the
    /// background runs inside a background task, since iOS suspends the app right after.
    private func sendPresence(active: Bool) {
        let targets = channel.computers.filter { reconciler.relay($0) != nil }
        guard !targets.isEmpty else { return }
        let bg = active ? nil : BackgroundTask(name: "push_presence") {}
        Task {
            await withTaskGroup(of: Void.self) { g in
                for id in targets {
                    g.addTask { await self.presence(id, active) }
                }
            }
            bg?.end()
        }
    }
}

/// The app's servers, as sign-up reaches their helpers: through each server's control connection.
@MainActor
final class ServerHelpers: HelperChannel {
    var servers: () -> [ServerConnection] = { [] }

    private func server(_ id: UUID) -> ServerConnection? { servers().first { $0.id == id } }

    var computers: [UUID] { servers().map(\.id) }

    func connection(_ computer: UUID) -> Int? {
        guard let s = server(computer), s.control.state == .connected else { return nil }
        return s.connectionSerial
    }

    func clientID(_ computer: UUID) -> String? { server(computer)?.control.clientID }

    func name(_ computer: UUID) -> String { server(computer)?.config.name ?? "" }

    func clients(_ computer: UUID) async -> [JSONObject]? {
        guard let s = server(computer), let list = try? await s.control.call("client.list") else { return nil }
        return list.arr("clients")
    }

    func perform(_ computer: UUID, relay: String, action: String, args: JSONObject, timeout: Int) async -> Result<JSONObject, HelperFailure> {
        guard let s = server(computer) else { return .failure(HelperFailure(code: "", message: "not connected")) }
        do {
            return HelperFailure.read(try await s.control.call(
                "client.perform", ["client_id": relay, "action": action, "args": args, "timeout_ms": timeout]))
        } catch {
            return .failure(HelperFailure(error))
        }
    }
}
