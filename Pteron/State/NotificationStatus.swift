import Foundation
import GlanceModel

// What Settings → Notifications shows, as a function of plain facts. The master switch and each
// computer's row are value types; `MasterStatus.make` and `ComputerStatus.make` build them, and
// every word the screen shows is in this file. `PushRegistrar` gathers the facts and performs
// the actions; the screen only renders. The design is in docs/notifications.md, "The screen".

// MARK: - What a row is made of

/// The colour of a status line. Words carry the meaning; the tint only supports them.
enum NotificationTint: Equatable, Sendable {
    /// The row's own text colour: something the app is doing by itself.
    case none
    /// Information that needs nothing from the person.
    case secondary
    /// A problem.
    case warning
}

/// The one line under a switch.
struct NotificationLine: Equatable, Sendable {
    var text: String
    var tint: NotificationTint
    /// The app is working on it: a spinner sits beside the text, and the row has no button.
    var spinner = false
}

/// The one button beside a status line.
enum NotificationFix: Equatable, Sendable {
    case openSettings, how, continueSetup, retry, update, repair, trust

    var title: String {
        switch self {
        case .openSettings: "Open Settings"
        case .how: "How"
        case .continueSetup: "Continue"
        case .retry: "Try Again"
        case .update: "Update"
        case .repair: "Repair"
        case .trust: "Trust…"
        }
    }
}

/// An entry of a row's menu. A row lists only the ones that can work in its state.
enum NotificationMenuItem: Equatable, Sendable {
    case sendTest, showDetails, reinstall, remove, cancel

    var title: String {
        switch self {
        case .sendTest: "Send Test Notification"
        case .showDetails: "Show Details"
        case .reinstall: "Reinstall Beacon"
        case .remove: "Remove Beacon…"
        case .cancel: "Stop Install"
        }
    }

    var isDestructive: Bool { self == .remove }
}

// MARK: - The master switch

/// What iOS says about notifications for this app.
enum NotificationPermission: Equatable, Sendable {
    /// Not read yet, right after launch.
    case unknown
    /// iOS has never asked the person.
    case notAsked
    case denied
    case allowed
    /// Allowed, but nothing shows or sounds: provisional, or banners and sounds both off.
    case quiet

    /// The quiet case of an allowed permission. `banners` and `sounds` are the person's choices
    /// in iOS Settings.
    static func allowed(provisional: Bool, banners: Bool, sounds: Bool) -> NotificationPermission {
        provisional || (!banners && !sounds) ? .quiet : .allowed
    }
}

struct MasterFacts: Equatable, Sendable {
    var permission: NotificationPermission
    /// The person's choice in the app. It is kept while iOS has notifications turned off.
    var choice: Bool
    /// iOS has not given this phone a notification address, and said why not.
    var addressMissing = false
}

/// The "Notifications" switch at the top of the screen.
struct MasterStatus: Equatable, Sendable {
    static let title = "Notifications"
    /// The header over the computers, which have a group of their own under the switch's.
    static let computersHeader = "Computers"
    static let footer = "Get notified when an agent finishes or needs you. Each computer needs \(Brand.beaconName) to send notifications."

    var switchOn: Bool
    var switchEnabled = true
    var line: NotificationLine?
    var fix: NotificationFix?
    /// The computer rows are listed under the switch.
    var showsComputers: Bool
    /// A tap on the switch opens iOS Settings and leaves the switch as it is: no choice in the
    /// app can turn notifications on while iOS has them off.
    var tapOpensSettings = false

    static func make(_ f: MasterFacts) -> MasterStatus {
        switch f.permission {
        case .denied:
            return MasterStatus(switchOn: false, line: NotificationLine(text: "Turned off in iOS Settings", tint: .warning),
                                fix: .openSettings, showsComputers: false, tapOpensSettings: true)
        case .notAsked:
            return MasterStatus(switchOn: false, showsComputers: false)
        case .unknown:
            // Until iOS has answered, the choice stands, so the screen does not change under the
            // person a moment after it opens.
            return MasterStatus(switchOn: f.choice, showsComputers: f.choice)
        case .allowed, .quiet:
            guard f.choice else { return MasterStatus(switchOn: false, showsComputers: false) }
            if f.addressMissing {
                return MasterStatus(switchOn: true, line: NotificationLine(text: "Can't reach Apple's notification service",
                                                                          tint: .none, spinner: true),
                                    showsComputers: true)
            }
            if f.permission == .quiet {
                return MasterStatus(switchOn: true,
                                    line: NotificationLine(text: "Notifications arrive quietly", tint: .secondary),
                                    fix: .openSettings, showsComputers: true)
            }
            return MasterStatus(switchOn: true, showsComputers: true)
        }
    }
}

// MARK: - A computer's row

struct ComputerFacts: Equatable, Sendable {
    enum Helper: Equatable, Sendable {
        /// No helper answers and this phone never registered with one there.
        case notInstalled
        /// This phone registered with a helper there before, and none answers now.
        case notRunning
        case running
    }

    /// Where an install of the helper on this computer stands.
    enum Setup: Equatable, Sendable {
        case working(Step)
        /// The install waits for something only the person can give, such as a password.
        case waitingForPerson
        /// The Mac shows a question that has to be answered there.
        case clickAllow
        case failed(Failure)
        /// This computer's Rex can't run the installer, so the helper is installed by hand.
        case manual
    }

    enum Step: Equatable, Sendable {
        case downloading, checking, installing, starting, connecting

        var text: String {
            switch self {
            case .downloading: "Downloading…"
            case .checking: "Checking…"
            case .installing: "Installing…"
            case .starting: "Starting…"
            case .connecting: "Connecting…"
            }
        }
    }

    enum Failure: Equatable, Sendable {
        case download, check, noRoom, notAllowed, notStarted
        /// The computer or its macOS is one Beacon doesn't run on: trying again can't help.
        case cantRun
        /// Nobody is logged in on the computer's screen.
        case notLoggedIn
        /// Another install was running there.
        case busy

        var text: String {
            switch self {
            case .download: "Couldn't download Beacon"
            case .check: "The download didn't pass its check"
            case .noRoom: "No room for Beacon"
            case .notAllowed: "Didn't let Beacon install"
            case .notStarted: "Beacon didn't start"
            case .cantRun: "Beacon can't run here"
            case .notLoggedIn: "Log in on the computer"
            case .busy: "Another install is running"
            }
        }

        /// Try Again can work: not where Beacon can't run at all.
        var canRetry: Bool { self != .cantRun }
    }

    /// This phone's connection to the notification service for this computer.
    enum Link: Equatable, Sendable {
        /// Not set up yet on this connection; the app is doing it.
        case pending
        case connected
        /// It stopped working and the app is setting it up again.
        case repairing
        /// The app's own tries did not bring it back.
        case failed
    }

    enum Removal: Equatable, Sendable { case removing, failed }

    enum Test: Equatable, Sendable {
        case sent
        case failed(String)
    }

    /// The row's title. No status line repeats it: the title stands beside every line.
    var name: String
    /// The person's choice for this computer. A computer is on until it is turned off.
    var choice = true
    var online = true
    /// The app can run Beacon's installer there (`HelperOffer.installable`). Where it can't, the
    /// row says how Beacon is doing all the same, and offers nothing that would run the installer.
    var installable = true
    var helper = Helper.running
    var setup: Setup?
    /// Another helper answers than the one this phone trusted.
    var changed = false
    var tooOld = false
    var link = Link.connected
    /// The notification service asked this phone to wait before it tries again.
    var limit: RateLimit?
    /// The computer was turned off while it could not be reached, and its Beacon has not heard
    /// of it yet.
    var pauseWaits = false
    /// The notification service holds as many computers for this phone as it takes, and this
    /// one is not among them.
    var full = false
    var removal: Removal?
    /// The result of "Send Test Notification", shown for a few seconds.
    var test: Test?
    /// The version the helper reports: from its answer to the registration or from its status,
    /// whichever came first. Nil until one has arrived.
    var version: String?
    /// The helper is replacing itself with a newer version: after "Update", or by itself.
    var updating = false
    /// The app's release list names a newer version than this helper's, and this one may still
    /// run (`LatestRelease.standing`). One that may not is `tooOld`.
    var updateAvailable = false
}

extension ComputerFacts {
    /// These facts with the app's word on Beacon's version: below the oldest version the
    /// release list allows it needs an update, older than the latest one is available, and with
    /// no release list nothing is claimed.
    func judged(against release: LatestRelease?) -> ComputerFacts {
        var f = self
        switch LatestRelease.standing(of: version, against: release) {
        case .belowMinimum: f.tooOld = true
        case .behind: f.updateAvailable = true
        case .current, .unknown: break
        }
        return f
    }
}

/// One computer's row: its switch, the line under its name, the one button and the menu.
struct ComputerStatus: Equatable, Sendable {
    var switchOn: Bool
    var switchEnabled = true
    var line: NotificationLine?
    var fix: NotificationFix?
    var menu: [NotificationMenuItem] = []

    /// The line of a computer where all is well: the helper's version and nothing after it. Nil
    /// for a version that is not known yet, or that is not a short run of letters, digits, dots
    /// and dashes, as a version is.
    static func versionLine(_ version: String?) -> NotificationLine? {
        guard let version, (1...24).contains(version.count),
              version.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || ".-+".unicodeScalars.contains($0)) })
        else { return nil }
        return NotificationLine(text: "Beacon \(version)", tint: .secondary)
    }

    /// The line of a computer that is on while the app does not yet know all is well there: its
    /// Beacon has not taken this phone on this connection, or has not said which version it is.
    /// A row that is on always has a line, so this stands where the version will.
    static let connectingLine = NotificationLine(text: "Connecting…", tint: .none, spinner: true)

    /// The line of a computer without Beacon, beside its off switch.
    static let installLine = NotificationLine(text: "Turn on to install Beacon", tint: .secondary)

    /// The line of a computer the notification service took no secret for, because the phone
    /// has as many computers there as the service holds for one phone.
    static let fullLine = "Too many computers for this \(DeviceWord.current)"

    /// The first state that applies decides the row: Removing, Turns off when the computer is
    /// back, Offline, a failed removal, off, Helper changed, an install, Helper too old, Helper
    /// isn't running, Too many computers, Reconnecting or Couldn't reconnect, Too many tries,
    /// Connecting, the result
    /// of a test, Update available, healthy, which shows the helper's version. No line holds
    /// the computer's name: the row's title is the name.
    ///
    /// On a computer the app can't run the installer on, the row is the same less what would run
    /// it there: Reinstall, Remove (which takes the secret back and then needs the installer to
    /// stop Beacon), Repair, Update (whose fallback is the installer) and a Retry of an install
    /// or a removal.
    static func make(_ f: ComputerFacts) -> ComputerStatus {
        let status = rowState(f)
        guard !f.installable else { return status }
        return status.withoutInstaller(retriesInstaller: f.removal == .failed || f.setup?.isFailure == true)
    }

    /// The menu entries that run the installer on the computer.
    static let installerItems: Set<NotificationMenuItem> = [.reinstall, .remove]
    /// The buttons that may run the installer on the computer. Retry does when it repeats an
    /// install or a removal.
    static let installerFixes: Set<NotificationFix> = [.repair, .update]

    private func withoutInstaller(retriesInstaller: Bool) -> ComputerStatus {
        var s = self
        s.menu.removeAll { Self.installerItems.contains($0) }
        if let fix, Self.installerFixes.contains(fix) || (fix == .retry && retriesInstaller) { s.fix = nil }
        return s
    }

    private static func rowState(_ f: ComputerFacts) -> ComputerStatus {
        func problem(_ text: String) -> NotificationLine { NotificationLine(text: text, tint: .warning) }
        func working(_ text: String) -> NotificationLine { NotificationLine(text: text, tint: .none, spinner: true) }
        let installed = f.helper != .notInstalled
        // With no helper there and no install under way there is nothing to be on: the switch
        // shows off, and turning it on starts the install.
        let on = f.choice && (installed || f.setup != nil)
        let standard: [NotificationMenuItem] = [.reinstall, .remove]

        if f.removal == .removing {
            return ComputerStatus(switchOn: false, switchEnabled: false, line: working("Removing…"))
        }
        if !f.online {
            // Nothing can run there, so the menu is empty. The switch still works for a computer
            // that has a helper: the choice is kept on the phone, and the helper hears of it
            // when the computer is back. Until then the row says so.
            let text = f.pauseWaits && !f.choice ? "Turns off when it's back" : "Offline"
            return ComputerStatus(switchOn: on, switchEnabled: installed, line: NotificationLine(text: text, tint: .secondary))
        }
        if f.removal == .failed {
            return ComputerStatus(switchOn: on, line: problem("Couldn't remove Beacon"), fix: .retry, menu: [.showDetails])
        }
        if let setup = f.setup, f.choice, !f.changed {
            switch setup {
            case .working(let step):
                return ComputerStatus(switchOn: true, line: working(step.text), menu: [.showDetails, .cancel])
            case .waitingForPerson:
                return ComputerStatus(switchOn: true, line: problem("Waiting for you"), fix: .continueSetup,
                                      menu: [.showDetails, .cancel])
            case .clickAllow:
                return ComputerStatus(switchOn: true, line: working("Click Allow for \(Brand.beaconName)"), menu: [.showDetails, .cancel])
            case .failed(let why):
                return ComputerStatus(switchOn: true, line: problem(why.text), fix: why.canRetry ? .retry : nil,
                                      menu: [.showDetails, .remove])
            case .manual:
                return ComputerStatus(switchOn: true, line: problem("Install Beacon by hand"), fix: .how,
                                      menu: [.showDetails])
            }
        }
        // Off with no Beacon: the line says what turning it on does.
        if !installed { return ComputerStatus(switchOn: false, line: Self.installLine) }
        if !f.choice { return ComputerStatus(switchOn: false, menu: [.showDetails, .remove]) }
        if f.changed {
            return ComputerStatus(switchOn: true, line: problem("Beacon has changed"), fix: .trust, menu: standard)
        }
        if f.updating {
            return ComputerStatus(switchOn: true, line: working("Updating…"), menu: standard)
        }
        if f.tooOld {
            return ComputerStatus(switchOn: true, line: problem("Beacon needs an update"), fix: .update, menu: standard)
        }
        if f.helper == .notRunning {
            return ComputerStatus(switchOn: true, line: problem("Beacon isn't running"), fix: .repair, menu: standard)
        }
        if f.full {
            // The app does not try again by itself: Retry is for once a computer was removed.
            return ComputerStatus(switchOn: true, line: problem(Self.fullLine), fix: .retry, menu: standard)
        }
        switch f.link {
        case .repairing:
            return ComputerStatus(switchOn: true, line: working("Reconnecting…"), menu: standard)
        case .failed:
            return ComputerStatus(switchOn: true, line: problem("Couldn't reconnect"), fix: .retry, menu: standard)
        case .pending, .connected:
            break
        }
        if let limit = f.limit {
            return ComputerStatus(switchOn: true, line: problem(limit.text), menu: [.remove])
        }
        // Not connected yet, or connected and the version still on its way: the row is not
        // shown as healthy before the app knows it is, and a test waits until then.
        let connecting = ComputerStatus(switchOn: true, line: connectingLine, menu: [.showDetails] + standard)
        guard f.link == .connected else { return connecting }
        let line: NotificationLine
        var fix: NotificationFix?
        switch f.test {
        case .sent: line = NotificationLine(text: "Test notification sent", tint: .secondary)
        case .failed(let why): line = problem(why)
        case nil:
            if f.updateAvailable {
                // Not a problem: notifications arrive as they are, so the line is information
                // and the row keeps the healthy menu.
                line = NotificationLine(text: "Update available", tint: .secondary)
                fix = .update
            } else if let version = versionLine(f.version) {
                line = version
            } else {
                return connecting
            }
        }
        return ComputerStatus(switchOn: true, line: line, fix: fix, menu: [.sendTest, .showDetails] + standard)
    }
}

/// A computer and its row, for the list under the master switch.
struct ComputerRow: Identifiable, Equatable, Sendable {
    var id: UUID
    var name: String
    var status: ComputerStatus
}

extension ComputerFacts.Setup {
    /// What a row says for an install in this state. Nil when the install has nothing for the
    /// row: it finished, it was stopped, or it ended with a helper that has to be trusted, which
    /// is the row's "changed" state.
    init?(_ state: SetupState) {
        switch state.phase {
        case .preparing, .running, .connecting:
            switch state.human {
            case .password, .passwordOnComputer: self = .waitingForPerson
            case .allowNotifications: self = .clickAllow
            case nil: self = .working(Self.step(state))
            }
        case .connected:
            guard state.human == .allowNotifications else { return nil }
            self = .clickAllow
        case .failed(let error):
            guard let fact = Self(error) else { return nil }
            self = fact
        case .cancelled:
            return nil
        }
    }

    /// The same for an install that ended with `error` and whose sheet is closed.
    init?(_ error: SetupError) {
        switch error {
        case .network, .noDownloader, .release: self = .failed(.download)
        case .verify: self = .failed(.check)
        case .write: self = .failed(.noRoom)
        case .appManagement: self = .failed(.notAllowed)
        case .unsupportedComputer, .oldMacOS: self = .failed(.cantRun)
        case .noGUI: self = .failed(.notLoggedIn)
        case .busy: self = .failed(.busy)
        case .notStarted, .noSystemd, .interrupted: self = .failed(.notStarted)
        case .manual: self = .manual
        case .identityChanged, .notificationsOff: return nil
        }
    }

    private static func step(_ state: SetupState) -> ComputerFacts.Step {
        if state.phase == .connecting { return .connecting }
        switch state.step {
        case .downloading: return .downloading
        case .verifying: return .checking
        case .installing: return state.isStarting ? .starting : .installing
        case .connected: return .connecting
        }
    }
}

extension ComputerFacts.Setup {
    var isFailure: Bool { if case .failed = self { true } else { false } }
}

// MARK: - Too many tries

/// The notification service turned a request away and said how long to wait (`Retry-After`).
/// `text` is the row's line for it.
struct RateLimit: Equatable, Sendable {
    /// When the service takes requests again. Nil when it did not say.
    var retryAt: Date?
    var now: Date

    var text: String { Self.text(wait: retryAt.map { $0.timeIntervalSince(now) }, now: now) }

    /// A wait that ends this close to the next day counts as ending in it: the phone's clock
    /// and the service's are not the same clock.
    static let slack: TimeInterval = 60

    /// Under an hour: whole minutes, rounded up. From an hour on: "tomorrow" when the wait
    /// ends at or after the next midnight in UTC, which is when a day's allowance starts over;
    /// otherwise whole hours. Without a time: "later".
    static func text(wait: TimeInterval?, now: Date) -> String {
        let start = "Too many tries. Try again "
        guard let wait else { return start + "later." }
        let seconds = max(wait, 0)
        let minutes = max(Int((seconds / 60).rounded(.up)), 1)
        if minutes < 60 { return start + "in \(minutes) minute\(minutes == 1 ? "" : "s")." }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0) ?? utc.timeZone
        let midnight = utc.startOfDay(for: now).addingTimeInterval(24 * 3600)
        if now.addingTimeInterval(seconds + slack) >= midnight { return start + "tomorrow." }
        let hours = Int((seconds / 3600).rounded())
        return start + (hours <= 1 ? "in an hour." : "in \(hours) hours.")
    }
}

// MARK: - Update

/// How "Update" brings a computer's helper to the latest version.
enum HelperUpdate: Equatable, Sendable {
    /// The helper downloads the new version and restarts into it.
    case bySelf
    /// The installer replaces the helper, as a repair does. It needs nothing from the helper
    /// that is there: the one it installs proves itself to the phone.
    case byInstaller

    /// How long a helper that was asked to update itself has to report the new version. After
    /// that the installer takes over.
    static let limit: TimeInterval = 90
    /// The pause between two looks at the helper's version while it updates.
    static let askEvery: TimeInterval = 3

    /// `reported` is what the helper said about itself, or nil when it said nothing: a helper
    /// too old to register doesn't know the question. Only a helper that says it can replace
    /// itself, and is not doing so already, is asked to. Whether an update is due is the app's
    /// to say (`LatestRelease.standing`), so the helper's own view of that is not read here.
    static func route(reported: HelperVersion?) -> HelperUpdate {
        reported?.canUpdate == true && reported?.updating != true ? .bySelf : .byInstaller
    }

    /// A helper that was asked to update itself is done once it reports the version the update
    /// was for. `before` is what it reported when it was asked and `target` the latest release
    /// the app knows; without one of them to compare, any other version than before counts.
    static func reached(_ reported: String?, from before: String?, target: ReleaseVersion?) -> Bool {
        guard let reported, !reported.isEmpty else { return false }
        if let target, let version = ReleaseVersion(reported) { return version >= target }
        return reported != before
    }
}

// MARK: - Send Test Notification

/// What the helper's answer to `send_test` means for the row.
enum TestOutcome: Equatable, Sendable {
    case sent
    /// A line for the row.
    case failed(String)
    /// The helper can't send to this phone as things stand, and the app can put that right.
    case repair(Repair)

    enum Repair: Equatable, Sendable {
        /// The helper holds nothing for this phone: it gets the phone's secret again.
        case lost
        /// The helper holds this phone paused although the computer is on: it resumes.
        case paused
        /// The notification service said the phone's address is dead: the phone and each
        /// computer's secret go to the service again.
        case addressDied
    }

    /// How long a result stays in the row.
    static let shownFor: TimeInterval = 3

    /// `code` is the helper's error code, or nil when it answered that the test was sent. A
    /// helper that does not know the action answers `not_supported`.
    static func read(code: String?) -> TestOutcome {
        switch code {
        case nil: .sent
        case "test_too_soon": .failed("Wait a few seconds")
        case "phone_gone": .repair(.addressDied)
        case "not_registered": .repair(.lost)
        case "paused": .repair(.paused)
        // The helper does not pass on how long the service asked it to wait.
        case "limit_reached": .failed(RateLimit.text(wait: nil, now: Date()))
        case "no_connection": .failed("Couldn't reach the notification service")
        case "not_supported": .failed("Beacon needs an update")
        default: .failed("Couldn't send the test notification")
        }
    }
}

// MARK: - Show Details

/// What "Show Details" lists for a computer's helper: what it says in its `helper_status`, and
/// how the app's own check for the latest release went.
struct HelperDetails: Equatable, Sendable {
    enum LastNotification: Equatable, Sendable {
        case never
        case at(Date)
    }

    /// How the app's last read of the release list went (`ReleaseCheck`). The helper's own
    /// checks are not shown: the app decides which version is the latest.
    enum UpdateCheck: Equatable, Sendable {
        case ok
        case failed
    }

    struct Row: Equatable, Sendable {
        var label: String
        var value: String
    }

    var version: String?
    var system: String?
    /// Nil from a helper that doesn't say.
    var lastNotification: LastNotification?
    /// How many phones are registered on the helper. Nil from a helper that doesn't say.
    var devices: Int?
    /// How many of them were registered by others than this phone's Rex user (`other_phones`).
    /// Nil from a helper that doesn't say.
    var otherPhones: Int?
    /// Set by `PushRegistrar.details` from the app's check; fine until a read has failed.
    var updateCheck = UpdateCheck.ok

    /// A field that is missing, or not of the kind expected, is left out.
    init(status: [String: Any]) {
        version = (status["version"] as? String).flatMap(Self.plain)
        system = (status["os"] as? String).flatMap(Self.plain)
        if let seconds = Self.number(status["last_push_at"]), seconds > 0 {
            lastNotification = .at(Date(timeIntervalSince1970: seconds))
        } else if status["last_push_at"] is NSNull {
            lastNotification = .never
        }
        if let count = Self.number(status["devices"]), count >= 0, count < 1_000_000 { devices = Int(count) }
        if let count = Self.number(status["other_phones"]), count >= 0, count < 1_000_000 { otherPhones = Int(count) }
    }

    /// A JSON number. A JSON true or false is not one, though Foundation hands both over as
    /// `NSNumber`.
    private static func number(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n.doubleValue
    }

    init(version: String? = nil, system: String? = nil, lastNotification: LastNotification? = nil, devices: Int? = nil,
         otherPhones: Int? = nil, updateCheck: UpdateCheck = .ok) {
        self.version = version
        self.system = system
        self.lastNotification = lastNotification
        self.devices = devices
        self.otherPhones = otherPhones
        self.updateCheck = updateCheck
    }

    /// The rows to show, in order. A value the helper did not give has no row.
    func rows(now: Date = Date()) -> [Row] {
        var out: [Row] = []
        if let version { out.append(Row(label: "Beacon version", value: version)) }
        if let system { out.append(Row(label: "System", value: system)) }
        switch lastNotification {
        case .never: out.append(Row(label: "Last notification", value: "Never"))
        case .at(let date): out.append(Row(label: "Last notification", value: Self.ago(date, now: now)))
        case nil: break
        }
        // Only a failed check says anything: "OK" told nothing the version row doesn't.
        if updateCheck == .failed { out.append(Row(label: "Update check", value: "Couldn't check")) }
        return out
    }

    /// Up to 64 printable ASCII characters, as the helper sends them; anything else is not shown.
    private static func plain(_ text: String) -> String? {
        guard (1...64).contains(text.utf8.count), text.utf8.allSatisfy({ (0x20...0x7E).contains($0) }) else { return nil }
        return text
    }

    /// "2 minutes ago". Whole units, the largest that fits.
    static func ago(_ date: Date, now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        func some(_ n: Int, _ unit: String) -> String { "\(n) \(unit)\(n == 1 ? "" : "s") ago" }
        switch seconds {
        case ..<60: return "Just now"
        case ..<3600: return some(seconds / 60, "minute")
        case ..<86400: return some(seconds / 3600, "hour")
        default: return some(seconds / 86400, "day")
        }
    }
}

// MARK: - Confirms and the manual steps

/// The words of the screen's two confirms and of "How", and of a question's notification
/// after an action on it typed nothing.
enum NotificationCopy {
    /// Enter or Interrupt on a notification, and the agent no longer waits for that.
    static let actionChanged = "The question changed. Open \(Brand.appName) to see it."
    /// The same, and the computer couldn't be reached or didn't answer.
    static let actionFailed = "The connection to the computer dropped. Open \(Brand.appName) to check."
    /// The same, and another action answered this wait a moment ago, so nothing was typed.
    static let actionAnswered = "Already answered a moment ago. Open \(Brand.appName) if it's still waiting."

    struct Confirm: Equatable, Sendable {
        var title: String
        var message: String
        /// The button that goes ahead. Remove is destructive.
        var confirm: String
        var cancel = "Cancel"
    }

    /// "Remove Beacon…". `otherPhones` is the helper's count of phones on that computer that
    /// others registered, and the count the confirm names. A helper that doesn't give it gives
    /// `devices`, its count of registered phones with this one among them, and the confirm
    /// names one fewer; with neither it names no number.
    static func removeConfirm(name: String, devices: Int?, otherPhones: Int? = nil) -> Confirm {
        let others: String
        if let n = otherPhones ?? devices.map({ $0 - 1 }) {
            others = n > 0 ? " and to \(n) other \(DeviceWord.current)\(n == 1 ? "" : "s")" : ""
        } else {
            others = " and to any other \(DeviceWord.current) that uses Beacon"
        }
        return Confirm(title: "Remove \(Brand.beaconName) from \(name)?",
                       message: "\(name) will stop sending notifications to this \(DeviceWord.current)\(others).", confirm: "Remove")
    }

    /// "Trust…" on a helper that has changed.
    static func trustConfirm(name: String) -> Confirm {
        Confirm(title: "Trust Beacon on \(name)?",
                message: "Did you reinstall or remove Beacon on \(name)? If you did, trust it. If you didn't, don't: something else is answering for it. Cancel, then choose Reinstall Beacon.",
                confirm: "Trust")
    }

    /// The title over the steps of "How", the button beside "Install Beacon by hand".
    static let manualTitle = "Install by Hand"

    /// "Show Details" on a computer where no helper answers.
    static func noDetails(name: String) -> String { "\(Brand.beaconName) on \(name) isn't answering." }

    /// "How": installing the helper by hand, one step per line; `linuxInstall` follows the last.
    static let manualSteps = [
        "Mac: download \(Brand.beaconName) from github.com/theabecaster/pteron/releases, drag it to Applications and open it once.",
        "Linux: run this command, which downloads and installs \(Brand.beaconName):",
    ]

    /// The Linux install line (docs/helper.md, Linux), shown as a command to copy.
    static let linuxInstall = "curl -fsSL https://github.com/theabecaster/pteron/releases/download/helper-latest/install.sh | sh"

    /// Added to the install sheet's last screen while iOS has notifications turned off.
    static let turnOnInSettings = "Turn on notifications in iOS Settings to be notified."
}

// MARK: - The order of a removal

/// Remove Beacon, step by step. The phone's side goes first, so the computer stops reaching this
/// phone even when the rest does not finish; what the phone remembers of the helper is cleared
/// only once the helper is gone. This is one of the three things that take a secret back; a
/// switch never does.
enum HelperRemoval {
    struct Steps {
        /// This phone's link with the computer's helper stops working at the notification service.
        var revoke: @MainActor () async -> Void
        /// The helper is told this phone is gone.
        var unregister: @MainActor () async -> Void
        /// The installer script in remove mode; its exit code, or nil when it could not run.
        var script: @MainActor () async -> Int?
        /// The helper's key, this phone's link and "a helper was here" are forgotten, and the
        /// computer's switch goes off.
        var clear: @MainActor () async -> Void
    }

    /// True when the helper was removed. False leaves the phone unregistered and everything it
    /// remembers of the helper in place, for another try.
    @MainActor
    static func run(_ steps: Steps) async -> Bool {
        await steps.revoke()
        await steps.unregister()
        guard succeeded(exitCode: await steps.script()) else { return false }
        await steps.clear()
        return true
    }

    /// The script's exit codes: 0 removed (also when no helper was there), 10 wrong arguments,
    /// 15 something could not be stopped or deleted, 16 another install or update is running.
    static func succeeded(exitCode: Int?) -> Bool { exitCode == 0 }
}
