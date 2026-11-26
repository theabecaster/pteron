import Foundation
import GlanceModel
import Testing
import RexKit
@testable import Pteron

/// The Notifications screen's rows: one test per row of the two tables in docs/notifications.md,
/// then the order when two things are true and the words of the confirms and details.
struct NotificationStatusTests {
    private func line(_ text: String, _ tint: NotificationTint, spinner: Bool = false) -> NotificationLine {
        NotificationLine(text: text, tint: tint, spinner: spinner)
    }

    /// A computer where all is well, its add-on's version known.
    private func facts(_ change: (inout ComputerFacts) -> Void = { _ in }) -> ComputerFacts {
        var f = ComputerFacts(name: "Studio", version: "0.3.1")
        change(&f)
        return f
    }

    private func row(_ change: (inout ComputerFacts) -> Void = { _ in }) -> ComputerStatus {
        ComputerStatus.make(facts(change))
    }

    // MARK: The master switch

    @Test func masterOffByTheUser() {
        let s = MasterStatus.make(MasterFacts(permission: .allowed, choice: false))
        #expect(s == MasterStatus(switchOn: false, switchEnabled: true, line: nil, fix: nil, showsComputers: false))
        #expect(MasterStatus.footer == "Get notified when an agent finishes or needs you. Each computer needs \(Brand.beaconName) to send notifications.")
        #expect(MasterStatus.title == "Notifications")
    }

    @Test func masterBeforeIOSHasAsked() {
        for choice in [false, true] {
            let s = MasterStatus.make(MasterFacts(permission: .notAsked, choice: choice))
            #expect(s == MasterStatus(switchOn: false, showsComputers: false))
            #expect(!s.tapOpensSettings)
        }
    }

    @Test func masterOnWhileIOSAllows() {
        let s = MasterStatus.make(MasterFacts(permission: .allowed, choice: true))
        #expect(s == MasterStatus(switchOn: true, switchEnabled: true, line: nil, fix: nil, showsComputers: true))
    }

    @Test func masterOnWhileIOSDeliversQuietly() {
        let s = MasterStatus.make(MasterFacts(permission: .quiet, choice: true))
        #expect(s.switchOn && s.switchEnabled && s.showsComputers)
        #expect(s.line == line("Notifications arrive quietly", .secondary))
        #expect(s.fix == .openSettings)
        // Provisional, or banners and sounds both off.
        #expect(NotificationPermission.allowed(provisional: true, banners: true, sounds: true) == .quiet)
        #expect(NotificationPermission.allowed(provisional: false, banners: false, sounds: false) == .quiet)
        #expect(NotificationPermission.allowed(provisional: false, banners: true, sounds: false) == .allowed)
        #expect(NotificationPermission.allowed(provisional: false, banners: false, sounds: true) == .allowed)
    }

    @Test func masterWhileIOSHasNotificationsTurnedOff() {
        for choice in [false, true] {
            let s = MasterStatus.make(MasterFacts(permission: .denied, choice: choice))
            #expect(!s.switchOn && !s.showsComputers)
            #expect(s.line == line("Turned off in iOS Settings", .warning))
            #expect(s.fix == .openSettings)
        }
    }

    @Test func masterWithoutANotificationAddress() {
        let s = MasterStatus.make(MasterFacts(permission: .allowed, choice: true, addressMissing: true))
        #expect(s.switchOn && s.showsComputers && s.fix == nil)
        #expect(s.line == line("Can't reach Apple's notification service", .none, spinner: true))
        // Nothing to say about it while the switch is off.
        #expect(MasterStatus.make(MasterFacts(permission: .allowed, choice: false, addressMissing: true)).line == nil)
    }

    @Test func masterKeepsTheChoiceUntilIOSHasAnswered() {
        #expect(MasterStatus.make(MasterFacts(permission: .unknown, choice: true)) == MasterStatus(switchOn: true, showsComputers: true))
        #expect(MasterStatus.make(MasterFacts(permission: .unknown, choice: false)) == MasterStatus(switchOn: false, showsComputers: false))
    }

    // MARK: A computer's row

    @Test func healthy() {
        #expect(row() == ComputerStatus(switchOn: true, switchEnabled: true, line: line("Beacon 0.3.1", .secondary), fix: nil,
                                        menu: [.sendTest, .showDetails, .reinstall, .remove]))
    }

    @Test func offByTheUser() {
        #expect(row { $0.choice = false } == ComputerStatus(switchOn: false, switchEnabled: true, line: nil, fix: nil,
                                                            menu: [.showDetails, .remove]))
    }

    @Test func offline() {
        for choice in [true, false] {
            let s = row { $0.online = false; $0.choice = choice }
            #expect(s == ComputerStatus(switchOn: choice, switchEnabled: true, line: line("Offline", .secondary), fix: nil, menu: []))
        }
    }

    @Test func helperNotInstalledWithTheSwitchOff() {
        // The stored choice is on for a new computer; with no helper there the switch shows off,
        // and the line says what turning it on does, so the switch isn't a bare one.
        for choice in [true, false] {
            #expect(row { $0.helper = .notInstalled; $0.choice = choice }
                == ComputerStatus(switchOn: false, line: line("Turn on to install Beacon", .secondary), menu: []))
        }
    }

    @Test func helperNotInstalledAndTheComputerCannotRunTheInstaller() {
        let s = row { $0.helper = .notInstalled; $0.setup = .manual }
        #expect(s == ComputerStatus(switchOn: true, line: line("Install Beacon by hand", .warning), fix: .how,
                                    menu: [.showDetails]))
        #expect(NotificationFix.how.title == "How")
    }

    @Test func settingUp() {
        let steps: [(ComputerFacts.Step, String)] = [(.downloading, "Downloading…"), (.checking, "Checking…"),
                                                     (.installing, "Installing…"), (.starting, "Starting…"),
                                                     (.connecting, "Connecting…")]
        for (step, text) in steps {
            let s = row { $0.helper = .notInstalled; $0.setup = .working(step) }
            #expect(s == ComputerStatus(switchOn: true, line: line(text, .none, spinner: true), fix: nil, menu: [.showDetails, .cancel]))
        }
    }

    @Test func settingUpAndWaitingForThePerson() {
        let s = row { $0.helper = .notInstalled; $0.setup = .waitingForPerson }
        #expect(s == ComputerStatus(switchOn: true, line: line("Waiting for you", .warning), fix: .continueSetup,
                                    menu: [.showDetails, .cancel]))
        #expect(NotificationFix.continueSetup.title == "Continue")
    }

    @Test func setupFailed() {
        let reasons: [(ComputerFacts.Failure, String)] = [
            (.download, "Couldn't download Beacon"), (.check, "The download didn't pass its check"),
            (.noRoom, "No room for Beacon"), (.notAllowed, "Didn't let Beacon install"),
            (.notStarted, "Beacon didn't start"), (.notLoggedIn, "Log in on the computer"),
            (.busy, "Another install is running"),
        ]
        for (reason, text) in reasons {
            let s = row { $0.helper = .notInstalled; $0.setup = .failed(reason) }
            #expect(s == ComputerStatus(switchOn: true, line: line(text, .warning), fix: .retry, menu: [.showDetails, .remove]))
        }
        #expect(NotificationFix.retry.title == "Try Again")
        // Where Beacon can't run, Try Again can't help: the row has no button.
        let cantRun = row { $0.helper = .notInstalled; $0.setup = .failed(.cantRun) }
        #expect(cantRun == ComputerStatus(switchOn: true, line: line("Beacon can't run here", .warning), fix: nil,
                                          menu: [.showDetails, .remove]))
        // Each install error lands on the line that says it.
        #expect(ComputerFacts.Setup(SetupError.unsupportedComputer) == .failed(.cantRun))
        #expect(ComputerFacts.Setup(SetupError.oldMacOS) == .failed(.cantRun))
        #expect(ComputerFacts.Setup(SetupError.noGUI) == .failed(.notLoggedIn))
        #expect(ComputerFacts.Setup(SetupError.busy) == .failed(.busy))
        #expect(ComputerFacts.Setup(SetupError.appManagement) == .failed(.notAllowed))
    }

    @Test func helperTooOld() {
        #expect(row { $0.tooOld = true } == ComputerStatus(switchOn: true, line: line("Beacon needs an update", .warning), fix: .update,
                                                           menu: [.reinstall, .remove]))
    }

    @Test func helperInstalledButNotRunning() {
        let s = row { $0.helper = .notRunning; $0.link = .pending }
        #expect(s == ComputerStatus(switchOn: true, line: line("Beacon isn't running", .warning), fix: .repair, menu: [.reinstall, .remove]))
    }

    @Test func reconnecting() {
        #expect(row { $0.link = .repairing } == ComputerStatus(switchOn: true, line: line("Reconnecting…", .none, spinner: true), fix: nil,
                                                               menu: [.reinstall, .remove]))
    }

    @Test func couldNotReconnect() {
        #expect(row { $0.link = .failed } == ComputerStatus(switchOn: true, line: line("Couldn't reconnect", .warning), fix: .retry,
                                                            menu: [.reinstall, .remove]))
    }

    @Test func helperChanged() {
        let s = row { $0.changed = true; $0.link = .pending }
        #expect(s == ComputerStatus(switchOn: true, line: line("Beacon has changed", .warning), fix: .trust,
                                    menu: [.reinstall, .remove]))
        #expect(NotificationFix.trust.title == "Trust…")
        let confirm = NotificationCopy.trustConfirm(name: "Studio")
        #expect(confirm.confirm == "Trust" && confirm.cancel == "Cancel" && confirm.title == "Trust Beacon on Studio?"
                && confirm.message == "Did you reinstall or remove Beacon on Studio? If you did, trust it. If you didn't, don't: something else is answering for it. Cancel, then choose Reinstall Beacon.")
    }

    @Test func noRoomForAnotherComputerAtTheNotificationService() {
        let s = row { $0.full = true; $0.link = .pending }
        #expect(s == ComputerStatus(switchOn: true, line: line("Too many computers for this \(DeviceWord.current)", .warning), fix: .retry,
                                    menu: [.reinstall, .remove]))
    }

    @Test func macNeedsAClick() {
        let s = row { $0.setup = .clickAllow }
        #expect(s == ComputerStatus(switchOn: true, line: line("Click Allow for \(Brand.beaconName)", .none, spinner: true), fix: nil,
                                    menu: [.showDetails, .cancel]))
    }

    /// Noon in UTC, so the next UTC midnight is twelve hours on.
    private static let noon = Date(timeIntervalSince1970: 1_800_000_000 - 1_800_000_000.truncatingRemainder(dividingBy: 86400) + 12 * 3600)

    private func limit(_ wait: TimeInterval?) -> RateLimit {
        RateLimit(retryAt: wait.map { Self.noon.addingTimeInterval($0) }, now: Self.noon)
    }

    @Test func tooManyTries() {
        let s = row { $0.limit = limit(3600); $0.link = .pending }
        #expect(s == ComputerStatus(switchOn: true, line: line("Too many tries. Try again in an hour.", .warning), fix: nil, menu: [.remove]))
    }

    @Test func theWaitAfterTooManyTriesIsSaidInPlainWords() {
        func text(_ wait: TimeInterval?) -> String { limit(wait).text }
        // Under an hour: whole minutes, rounded up.
        #expect(text(0) == "Too many tries. Try again in 1 minute.")
        #expect(text(59) == "Too many tries. Try again in 1 minute.")
        #expect(text(60) == "Too many tries. Try again in 1 minute.")
        #expect(text(61) == "Too many tries. Try again in 2 minutes.")
        #expect(text(59 * 60) == "Too many tries. Try again in 59 minutes.")
        // From an hour on: hours, to the nearest.
        #expect(text(59 * 60 + 1) == "Too many tries. Try again in an hour.")
        #expect(text(60 * 60) == "Too many tries. Try again in an hour.")
        #expect(text(89 * 60) == "Too many tries. Try again in an hour.")
        #expect(text(3 * 3600) == "Too many tries. Try again in 3 hours.")
        #expect(text(11 * 3600) == "Too many tries. Try again in 11 hours.")
        // A wait that reaches the next midnight in UTC is a day's allowance starting over.
        #expect(text(12 * 3600 - 61) == "Too many tries. Try again in 12 hours.")
        #expect(text(12 * 3600) == "Too many tries. Try again tomorrow.")
        #expect(text(12 * 3600 + 1) == "Too many tries. Try again tomorrow.")
        #expect(text(30 * 3600) == "Too many tries. Try again tomorrow.")
        // Close to midnight a short wait is still said in minutes.
        let late = Self.noon.addingTimeInterval(12 * 3600 - 600)
        #expect(RateLimit.text(wait: 600, now: late) == "Too many tries. Try again in 10 minutes.")
        #expect(RateLimit.text(wait: 2 * 3600, now: late) == "Too many tries. Try again tomorrow.")
        // The service did not say how long.
        #expect(text(nil) == "Too many tries. Try again later.")
        #expect(RateLimit.text(wait: -5, now: Self.noon) == "Too many tries. Try again in 1 minute.")
    }

    @Test func turnedOffWhileItCouldNotBeReached() {
        // The switch shows the choice, and the line says when the add-on hears of it.
        let s = row { $0.online = false; $0.choice = false; $0.pauseWaits = true }
        #expect(s == ComputerStatus(switchOn: false, switchEnabled: true, line: line("Turns off when it's back", .secondary),
                                    fix: nil, menu: []))
        // Once it is back, or once it was told, the row is the usual one.
        #expect(row { $0.choice = false; $0.pauseWaits = true } == row { $0.choice = false })
        #expect(row { $0.online = false; $0.choice = false }.line?.text == "Offline")
        // Turned on again before it was told: nothing is left to say.
        #expect(row { $0.online = false; $0.pauseWaits = true }.line?.text == "Offline")
        // Only a removal comes before it.
        #expect(row { $0.online = false; $0.choice = false; $0.pauseWaits = true; $0.removal = .removing }.line?.text == "Removing…")
        #expect(row { $0.online = false; $0.choice = false; $0.pauseWaits = true; $0.removal = .failed }.line?.text
                == "Turns off when it's back")
    }

    @Test func removing() {
        for choice in [true, false] {
            let s = row { $0.removal = .removing; $0.choice = choice }
            #expect(s == ComputerStatus(switchOn: false, switchEnabled: false, line: line("Removing…", .none, spinner: true), fix: nil,
                                        menu: []))
        }
    }

    @Test func removeFailed() {
        for choice in [true, false] {
            let s = row { $0.removal = .failed; $0.choice = choice }
            #expect(s == ComputerStatus(switchOn: choice, line: line("Couldn't remove Beacon", .warning), fix: .retry,
                                        menu: [.showDetails]))
        }
    }

    // MARK: The order when two things are true

    @Test func theFirstStateThatAppliesDecidesTheRow() {
        // Each entry adds one more thing that is true; the row is the earliest in the order.
        let order: [(String, (inout ComputerFacts) -> Void)] = [
            ("Too many tries. Try again in an hour.", { $0.limit = RateLimit(retryAt: Self.noon.addingTimeInterval(3600), now: Self.noon) }),
            ("Couldn't reconnect", { $0.link = .failed }),
            ("Too many computers for this \(DeviceWord.current)", { $0.full = true }),
            ("Beacon isn't running", { $0.helper = .notRunning }),
            ("Beacon needs an update", { $0.tooOld = true }),
            ("Installing…", { $0.setup = .working(.installing) }),
            ("Beacon has changed", { $0.changed = true }),
            ("Offline", { $0.online = false }),
            ("Turns off when it's back", { $0.choice = false; $0.pauseWaits = true }),
            ("Removing…", { $0.removal = .removing }),
        ]
        var f = facts { $0.link = .pending }
        for (text, add) in order {
            add(&f)
            #expect(ComputerStatus.make(f).line?.text == text)
        }
    }

    @Test func eachPairFollowsTheOrder() {
        #expect(row { $0.link = .repairing; $0.limit = limit(60) }.line?.text == "Reconnecting…")
        #expect(row { $0.setup = .waitingForPerson; $0.tooOld = true }.line?.text == "Waiting for you")
        #expect(row { $0.setup = .failed(.download); $0.helper = .notRunning }.line?.text == "Couldn't download Beacon")
        #expect(row { $0.changed = true; $0.tooOld = true }.fix == .trust)
        #expect(row { $0.tooOld = true; $0.link = .repairing }.fix == .update)
        // A failed removal comes after Offline, since Retry has nowhere to run, and before the rest.
        #expect(row { $0.removal = .failed; $0.online = false }.line?.text == "Offline")
        #expect(row { $0.removal = .failed; $0.changed = true }.line?.text == "Couldn't remove Beacon")
        // A computer that is off has nothing to report but Offline and a removal.
        #expect(row { $0.choice = false; $0.changed = true; $0.tooOld = true; $0.link = .failed }.line == nil)
        #expect(row { $0.choice = false; $0.online = false }.line?.text == "Offline")
    }

    // MARK: The four approved changes

    @Test func aTapOnTheMasterSwitchOpensIOSSettingsWhileIOSHasNotificationsOff() {
        let denied = MasterStatus.make(MasterFacts(permission: .denied, choice: true))
        #expect(!denied.switchOn && denied.switchEnabled && denied.tapOpensSettings)
        for permission in [NotificationPermission.unknown, .notAsked, .allowed, .quiet] {
            #expect(!MasterStatus.make(MasterFacts(permission: permission, choice: true)).tapOpensSettings)
        }
    }

    @Test func aHealthyRowSendsATestAndShowsHowItWent() {
        #expect(row().menu.first == .sendTest)
        #expect(NotificationMenuItem.sendTest.title == "Send Test Notification")
        let sent = row { $0.test = .sent }
        #expect(sent.line == line("Test notification sent", .secondary) && sent.fix == nil && sent.menu == row().menu)
        #expect(row { $0.test = .failed("Wait a few seconds") }.line == line("Wait a few seconds", .warning))
        #expect(TestOutcome.shownFor == 3)
        // Only a row that is connected offers it, and a problem's line is never replaced by it.
        for change: (inout ComputerFacts) -> Void in [{ $0.choice = false }, { $0.link = .pending }, { $0.link = .failed },
                                                      { $0.tooOld = true }, { $0.online = false }, { $0.helper = .notRunning }] {
            #expect(!row(change).menu.contains(.sendTest))
        }
        #expect(row { $0.test = .sent; $0.tooOld = true }.line?.text == "Beacon needs an update")
    }

    @Test func healthyAndOffRowsShowDetails() {
        #expect(row().menu.contains(.showDetails))
        #expect(row { $0.choice = false }.menu.contains(.showDetails))
        #expect(NotificationMenuItem.showDetails.title == "Show Details")
        #expect(NotificationMenuItem.reinstall.title == "Reinstall Beacon")
        #expect(NotificationMenuItem.remove.title == "Remove Beacon…" && NotificationMenuItem.remove.isDestructive)
    }

    @Test func anOfflineRowHasNoMenuAndItsSwitchStillWorks() {
        let s = row { $0.online = false }
        #expect(s.menu.isEmpty && s.switchEnabled && s.fix == nil)
        // A computer with no helper has nothing to switch while it can't be reached.
        #expect(!row { $0.online = false; $0.helper = .notInstalled }.switchEnabled)
    }

    // MARK: An install, as its row

    @Test func aRowFollowsTheInstallsState() {
        var state = SetupState(kind: .install, computer: .linux)
        func record(_ token: String, state s: String = "working", kind: String? = nil) {
            state.handle(.record(SetupRecord(state: s, token: token, kind: kind, updatedAt: "1")))
        }
        #expect(ComputerFacts.Setup(state) == .working(.downloading))
        state.handle(.started)
        record("download")
        #expect(ComputerFacts.Setup(state) == .working(.downloading))
        record("verify")
        #expect(ComputerFacts.Setup(state) == .working(.checking))
        record("install")
        #expect(ComputerFacts.Setup(state) == .working(.installing))
        record("start")
        #expect(ComputerFacts.Setup(state) == .working(.starting))
        record("linger", state: "blocked", kind: "auth")
        #expect(ComputerFacts.Setup(state) == .waitingForPerson)
        state.handle(.passwordSkipped)
        state.handle(.exited(code: 0))
        #expect(ComputerFacts.Setup(state) == .working(.connecting))
        state.handle(.proof(.valid))
        state.handle(.helperRegistered)
        #expect(state.phase == .connected && ComputerFacts.Setup(state) == nil)
    }

    @Test func aMacsOpenQuestionIsClickAllow() {
        var state = SetupState(kind: .install, computer: .mac)
        state.handle(.started)
        state.handle(.record(SetupRecord(state: "working", token: "notify")))
        state.handle(.exited(code: 0))
        state.handle(.notices("undetermined"))
        #expect(ComputerFacts.Setup(state) == .clickAllow)
        state.handle(.proof(.valid))
        state.handle(.helperRegistered)
        // Connected, and the Mac still asks.
        #expect(state.phase == .connected && ComputerFacts.Setup(state) == .clickAllow)
        state.handle(.notices("allowed"))
        #expect(ComputerFacts.Setup(state) == nil)
    }

    @Test func everyWayAnInstallEndsHasARow() {
        let rows: [(SetupError, ComputerFacts.Setup?)] = [
            (.network, .failed(.download)), (.noDownloader, .failed(.download)), (.release, .failed(.download)),
            (.verify, .failed(.check)), (.write, .failed(.noRoom)),
            (.appManagement, .failed(.notAllowed)), (.noGUI, .failed(.notLoggedIn)), (.busy, .failed(.busy)),
            (.unsupportedComputer, .failed(.cantRun)), (.oldMacOS, .failed(.cantRun)),
            (.notStarted, .failed(.notStarted)), (.noSystemd, .failed(.notStarted)), (.interrupted, .failed(.notStarted)),
            (.manual, .manual),
            // A helper that has to be trusted is the row's "changed" state, not an install's.
            (.identityChanged, nil), (.notificationsOff, nil),
        ]
        for (error, fact) in rows {
            #expect(ComputerFacts.Setup(error) == fact)
            var state = SetupState(kind: .install, computer: .mac)
            state.handle(.fail(error))
            #expect(ComputerFacts.Setup(state) == fact)
        }
        var stopped = SetupState(kind: .install, computer: .mac)
        stopped.handle(.cancel)
        #expect(ComputerFacts.Setup(stopped) == nil)
    }

    @Test func theInstallSheetSaysWhereToTurnNotificationsOn() {
        #expect(SetupState.connectedMessage(name: "Studio", notificationsAllowed: false)
                == "Studio will notify this \(DeviceWord.current) when an agent finishes or needs you. Turn on notifications in iOS Settings to be notified.")
        #expect(SetupState.connectedMessage(name: "Studio") == "Studio will notify this \(DeviceWord.current) when an agent finishes or needs you.")
    }

    // MARK: Send Test Notification

    @Test func aTestsAnswerBecomesTheRowsLine() {
        #expect(TestOutcome.read(code: nil) == .sent)
        #expect(TestOutcome.read(code: "test_too_soon") == .failed("Wait a few seconds"))
        // What the app can put right, it does: each has its own way.
        #expect(TestOutcome.read(code: "phone_gone") == .repair(.addressDied))
        #expect(TestOutcome.read(code: "not_registered") == .repair(.lost))
        #expect(TestOutcome.read(code: "paused") == .repair(.paused))
        // The helper does not say how long the service asked it to wait.
        #expect(TestOutcome.read(code: "limit_reached") == .failed("Too many tries. Try again later."))
        #expect(TestOutcome.read(code: "no_connection") == .failed("Couldn't reach the notification service"))
        // A helper without the action.
        #expect(TestOutcome.read(code: "not_supported") == .failed("Beacon needs an update"))
        #expect(HelperFailure(code: "not_supported", message: "unknown action send_test").isUnknownAction)
        // Anything else, such as no answer in time.
        #expect(TestOutcome.read(code: "") == .failed("Couldn't send the test notification"))
        #expect(TestOutcome.read(code: "timeout") == .failed("Couldn't send the test notification"))
    }

    @Test func aTestNotificationShowsWhileTheAppIsInFront() {
        #expect(PushTest.isTest(threadID: "rexduo-test"))
        #expect(!PushTest.isTest(threadID: ""))
        #expect(!PushTest.isTest(threadID: "session-1"))
    }

    // MARK: Show Details

    private func status(_ json: String) throws -> JSONObject {
        try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? JSONObject)
    }

    @Test func detailsListWhatTheHelperSays() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let d = HelperDetails(status: try status(#"{"version":"0.3.0","os":"macOS 15.5","devices":3,"last_push_at":1799999880}"#))
        #expect(d.devices == 3)
        #expect(d.rows(now: now) == [.init(label: "Beacon version", value: "0.3.0"), .init(label: "System", value: "macOS 15.5"),
                                     .init(label: "Last notification", value: "2 minutes ago")])
    }

    @Test func aMissingFieldHasNoRowAndNullIsNever() throws {
        // A helper from before these fields.
        let old = HelperDetails(status: try status(#"{"version":"0.2.0"}"#))
        #expect(old.rows() == [.init(label: "Beacon version", value: "0.2.0")])
        #expect(old.devices == nil && old.lastNotification == nil)
        let never = HelperDetails(status: try status(#"{"version":"0.3.0","os":"Ubuntu 24.04.1 LTS","last_push_at":null}"#))
        #expect(never.rows().last == .init(label: "Last notification", value: "Never"))
        #expect(HelperDetails(status: [:]).rows() == [])
    }

    @Test func fieldsOfTheWrongKindAreLeftOut() throws {
        let long = String(repeating: "x", count: 65)
        let odd = HelperDetails(status: try status(
            #"{"version":7,"os":"mac\u0007OS","devices":true,"last_push_at":"yesterday"}"#))
        #expect(odd == HelperDetails())
        #expect(HelperDetails(status: ["os": long, "devices": -1, "last_push_at": false]) == HelperDetails())
        #expect(HelperDetails(status: ["os": "Linux é"]).system == nil)
        #expect(HelperDetails(status: try status(#"{"devices":1}"#)).devices == 1)
    }

    @Test func theLastNotificationIsRelative() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func ago(_ seconds: TimeInterval) -> String { HelperDetails.ago(now.addingTimeInterval(-seconds), now: now) }
        #expect(ago(5) == "Just now")
        #expect(ago(60) == "1 minute ago")
        #expect(ago(59 * 60) == "59 minutes ago")
        #expect(ago(3600) == "1 hour ago")
        #expect(ago(5 * 3600) == "5 hours ago")
        #expect(ago(86400) == "1 day ago")
        #expect(ago(3 * 86400) == "3 days ago")
        // A clock that is ahead on the computer.
        #expect(ago(-30) == "Just now")
    }

    // MARK: Remove Helper

    @Test func theConfirmCountsTheOtherPhones() {
        let one = NotificationCopy.removeConfirm(name: "Studio", devices: 1)
        #expect(one.title == "Remove \(Brand.beaconName) from Studio?")
        #expect(one.message == "Studio will stop sending notifications to this \(DeviceWord.current).")
        #expect(one.confirm == "Remove" && one.cancel == "Cancel")
        #expect(NotificationCopy.removeConfirm(name: "Studio", devices: 2).message
                == "Studio will stop sending notifications to this \(DeviceWord.current) and to 1 other \(DeviceWord.current).")
        #expect(NotificationCopy.removeConfirm(name: "Studio", devices: 4).message
                == "Studio will stop sending notifications to this \(DeviceWord.current) and to 3 other iPhones.")
        #expect(NotificationCopy.removeConfirm(name: "Studio", devices: 0).message
                == "Studio will stop sending notifications to this \(DeviceWord.current).")
        #expect(NotificationCopy.removeConfirm(name: "Studio", devices: nil).message
                == "Studio will stop sending notifications to this \(DeviceWord.current) and to any other \(DeviceWord.current) that uses Beacon.")
    }

    @Test func theConfirmUsesTheHelpersCountOfOtherPhonesWhenItGivesOne() throws {
        func message(_ json: String) throws -> String {
            let d = HelperDetails(status: try status(json))
            return NotificationCopy.removeConfirm(name: "Studio", devices: d.devices, otherPhones: d.otherPhones).message
        }
        // Four phones, three of them this user's own: one other iPhone.
        #expect(try message(#"{"devices":4,"other_phones":1}"#) == "Studio will stop sending notifications to this \(DeviceWord.current) and to 1 other \(DeviceWord.current).")
        #expect(try message(#"{"devices":4,"other_phones":2}"#) == "Studio will stop sending notifications to this \(DeviceWord.current) and to 2 other iPhones.")
        #expect(try message(#"{"devices":4,"other_phones":0}"#) == "Studio will stop sending notifications to this \(DeviceWord.current).")
        #expect(try message(#"{"other_phones":3}"#) == "Studio will stop sending notifications to this \(DeviceWord.current) and to 3 other iPhones.")
        // A helper that does not give the count: one fewer than its phones, as before.
        #expect(try message(#"{"devices":4}"#) == "Studio will stop sending notifications to this \(DeviceWord.current) and to 3 other iPhones.")
        #expect(try message(#"{"devices":4,"other_phones":true}"#) == "Studio will stop sending notifications to this \(DeviceWord.current) and to 3 other iPhones.")
        #expect(try message(#"{"devices":4,"other_phones":-1}"#) == "Studio will stop sending notifications to this \(DeviceWord.current) and to 3 other iPhones.")
        #expect(try message("{}") == "Studio will stop sending notifications to this \(DeviceWord.current) and to any other \(DeviceWord.current) that uses Beacon.")
        #expect(HelperDetails(status: try status(#"{"other_phones":2}"#)).otherPhones == 2)
    }

    // MARK: The program's name

    /// Every sentence the Notifications screen, the install sheet, the offer and the pairing
    /// card can show for a computer called "Studio".
    @MainActor
    private func everySentence() -> [String] {
        let name = "Studio"
        var out = [MasterStatus.title, MasterStatus.computersHeader, MasterStatus.footer, ComputerStatus.fullLine,
                   ComputerStatus.connectingLine.text, NotificationCopy.manualTitle, NotificationCopy.turnOnInSettings,
                   NotificationCopy.noDetails(name: name)] + NotificationCopy.manualSteps
        for confirm in [NotificationCopy.removeConfirm(name: name, devices: nil), NotificationCopy.removeConfirm(name: name, devices: 3),
                        NotificationCopy.removeConfirm(name: name, devices: 3, otherPhones: 1), NotificationCopy.trustConfirm(name: name)] {
            out += [confirm.title, confirm.message, confirm.confirm, confirm.cancel]
        }
        out += [NotificationMenuItem.sendTest, .showDetails, .reinstall, .remove, .cancel].map(\.title)
        out += [NotificationFix.openSettings, .how, .continueSetup, .retry, .update, .repair, .trust].map(\.title)
        // The model's lines: every state of the master switch and of a computer's row.
        let permissions: [NotificationPermission] = [.unknown, .notAsked, .denied, .allowed, .quiet]
        for permission in permissions {
            for missing in [false, true] {
                out.append(MasterStatus.make(MasterFacts(permission: permission, choice: true, addressMissing: missing)).line?.text ?? "")
            }
        }
        let steps: [ComputerFacts.Step] = [.downloading, .checking, .installing, .starting, .connecting]
        let failures: [ComputerFacts.Failure] = [.download, .check, .noRoom, .notAllowed, .notStarted, .cantRun, .notLoggedIn, .busy]
        var states: [(inout ComputerFacts) -> Void] = [
            { _ in }, { $0.updateAvailable = true }, { $0.version = nil }, { $0.choice = false }, { $0.online = false },
            { $0.online = false; $0.choice = false; $0.pauseWaits = true }, { $0.helper = .notInstalled },
            { $0.setup = .waitingForPerson }, { $0.setup = .clickAllow }, { $0.setup = .manual }, { $0.changed = true },
            { $0.updating = true }, { $0.tooOld = true }, { $0.helper = .notRunning }, { $0.full = true }, { $0.link = .repairing },
            { $0.link = .failed }, { $0.limit = RateLimit(retryAt: nil, now: Self.noon) },
            { $0.limit = RateLimit(retryAt: Self.noon.addingTimeInterval(120), now: Self.noon) }, { $0.removal = .removing },
            { $0.removal = .failed }, { $0.test = .sent },
        ]
        states += steps.map { step in { $0.setup = .working(step) } }
        states += failures.map { failure in { $0.setup = .failed(failure) } }
        out += states.map { row($0).line?.text ?? "" }
        for code in ["test_too_soon", "limit_reached", "no_connection", "not_supported", "anything_else"] {
            if case .failed(let why) = TestOutcome.read(code: code) { out.append(why) }
        }
        out += HelperDetails(version: "0.3.1", system: "macOS 26.1", lastNotification: .never, updateCheck: .failed).rows().map(\.label)
        // The install sheet.
        let errors: [SetupError] = [.network, .noDownloader, .verify, .release, .unsupportedComputer, .oldMacOS, .write, .busy,
                                    .notStarted, .noGUI, .noSystemd, .appManagement, .interrupted, .notificationsOff,
                                    .identityChanged, .manual]
        out += errors.map { $0.message(name: name) } + [SetupError.connectionLost(name: name)]
        for kind in [SetupState.Kind.install, .repair, .reinstall] {
            var state = SetupState(kind: kind, computer: .linux)
            out.append(state.title(name: name))
            out += SetupState.Step.allCases.map(\.title)
            out += SetupState.Step.allCases.compactMap { state.detail($0, name: name) }
            state.handle(.release(version: "0.3.1"))
            state.handle(.started)
            for token in ["download", "verify", SetupCode.token, "install", "start", "linger", "notify", "done"] {
                state.handle(.record(SetupRecord(state: "working", token: token)))
                out += SetupState.Step.allCases.compactMap { state.detail($0, name: name) }
            }
            state.handle(.exited(code: 0))
            out += SetupState.Step.allCases.compactMap { state.detail($0, name: name) }
        }
        out += [SetupState.connectedMessage(name: name), SetupState.connectedMessage(name: name, notificationsAllowed: false)]
        let allow = HumanStepCard.allowCopy(name: name)
        out += [allow.title, allow.message, allow.aside]
        out += [PasswordCard.message(name: name, account: "sam"), PasswordCard.message(name: name, account: nil)]
        // The offer after a computer is added, and the pairing card's line.
        out += [HelperOfferCard.title(name), HelperOfferCard.message(name), HelperOfferCard.footnote(name), HelperOfferCard.skippedLine(name)]
        out.append(IdentityCopy.of(ServerIdentity(hasHelper: false)).helper ?? "")
        return out
    }

    @MainActor
    @Test func noSentenceCallsTheProgramAnAddOnOrAHelper() {
        let sentences = everySentence()
        #expect(sentences.count > 100)
        for sentence in sentences {
            // The command-line program keeps its file name, shown only inside the command to run.
            let words = sentence.replacingOccurrences(of: NotificationCopy.linuxInstall, with: "")
            for old in ["add-on", "Add-on", "add\u{2011}on", "helper", "Helper"] {
                #expect(!words.contains(old), "\(sentence)")
            }
        }
        // The program is named in full where a screen first says it.
        #expect(MasterStatus.footer.contains(Brand.beaconName) && NotificationCopy.manualSteps[0].contains(Brand.beaconName))
        #expect(sentences.filter { $0.contains("Beacon") }.count > 30)
    }

    @Test func theRemoveCommandIsTheModeAndTheReservedArgument() {
        let scripts = ["exit 0", "", "$(reboot); `id` \"$1\" 'x' \n; rm -rf ~", String(repeating: "a", count: 4096)]
        for script in scripts {
            let command = SetupArgs.removeCommand(script: script)
            #expect(command == ["/bin/sh", "-c", script, "rexduo-setup", "3", "-"])
            // After the name the script runs under come exactly two arguments.
            #expect(Array(command.dropFirst(4)) == ["3", "-"])
        }
        // The command takes nothing but the script: no server name, address, version or key can
        // reach it, whatever those strings are.
        let layout = SetupBlock.session(command: SetupArgs.removeCommand(script: "exit 0"), theme: ThemeStore.fallback)
        let options = ((layout["initial_windows"] as? [JSONObject])?.first?.obj("layout")?.obj("block")?.obj("options"))
        #expect(options?.str("shell") == "none")
        #expect(options?["command"] as? [String] == ["/bin/sh", "-c", "exit 0", "rexduo-setup", "3", "-"])
        #expect(SetupArgs.removeMode == "3" && SetupArgs.mode == "2")
    }

    @MainActor @Test func aRemovalRevokesAndUnregistersThenRunsTheScriptThenForgets() async {
        var order: [String] = []
        let removed = await HelperRemoval.run(HelperRemoval.Steps(
            revoke: { order.append("revoke") },
            unregister: { order.append("unregister") },
            script: { order.append("script"); return 0 },
            clear: { order.append("clear") }))
        #expect(removed)
        #expect(order == ["revoke", "unregister", "script", "clear"])
    }

    @MainActor @Test func aFailedScriptLeavesThePhoneUnregisteredAndForgetsNothing() async {
        for code in [10, 15, 16, 1, nil] as [Int?] {
            var order: [String] = []
            let removed = await HelperRemoval.run(HelperRemoval.Steps(
                revoke: { order.append("revoke") },
                unregister: { order.append("unregister") },
                script: { order.append("script"); return code },
                clear: { order.append("clear") }))
            #expect(!removed)
            #expect(order == ["revoke", "unregister", "script"])
        }
        // The row then says so, with Retry.
        let s = row { $0.removal = .failed }
        #expect(s.line?.text == "Couldn't remove Beacon" && s.fix == .retry)
        #expect(HelperRemoval.succeeded(exitCode: 0) && !HelperRemoval.succeeded(exitCode: nil))
    }

    // MARK: Where the installer can run

    /// Every state a row of a computer with Beacon can be in.
    private var everyState: [ComputerFacts] {
        [facts(), facts { $0.version = "" }, facts { $0.choice = false }, facts { $0.online = false },
         facts { $0.setup = .failed(.download) }, facts { $0.setup = .working(.installing) }, facts { $0.setup = .manual },
         facts { $0.changed = true }, facts { $0.updating = true }, facts { $0.tooOld = true }, facts { $0.updateAvailable = true },
         facts { $0.helper = .notRunning }, facts { $0.full = true }, facts { $0.link = .repairing }, facts { $0.link = .failed },
         facts { $0.link = .pending; $0.limit = RateLimit(retryAt: nil, now: Date()) }, facts { $0.test = .sent },
         facts { $0.removal = .failed }, facts { $0.removal = .removing }]
    }

    @Test func onlyMacAndLinuxComputersCanRunTheInstaller() {
        #expect(HelperOffer.installable(platform: "darwin_arm64") && HelperOffer.installable(platform: "linux_amd64"))
        #expect(HelperOffer.installable(platform: "Linux_arm64"))
        for other in ["windows_amd64", "windows_arm64", "freebsd_amd64", "darwin", "", nil] {
            #expect(!HelperOffer.installable(platform: other))
            // The same rule as the install offer.
            #expect(HelperOffer.decide(platform: other, hasHelper: false, owner: nil, viewer: nil, running: false) == .none)
        }
    }

    @Test func aMacOrLinuxRowOffersReinstallAndRemove() {
        for platform in ["darwin_arm64", "linux_amd64"] {
            let installable = HelperOffer.installable(platform: platform)
            #expect(ComputerStatus.make(facts { $0.installable = installable }).menu == [.sendTest, .showDetails, .reinstall, .remove])
            #expect(ComputerStatus.make(facts { $0.installable = installable; $0.helper = .notRunning }).fix == .repair)
            #expect(ComputerStatus.make(facts { $0.installable = installable; $0.tooOld = true }).fix == .update)
            for f in everyState {
                var g = f
                g.installable = installable
                #expect(ComputerStatus.make(g) == ComputerStatus.make(f))
            }
        }
    }

    @Test func anotherSystemsRowShowsBeaconButOffersNothingThatRunsTheInstaller() {
        for platform in ["windows_amd64", "plan9_386", nil] {
            let installable = HelperOffer.installable(platform: platform)
            #expect(!installable)
            for f in everyState {
                var g = f
                g.installable = installable
                let shown = ComputerStatus.make(g), mac = ComputerStatus.make(f)
                // The same state, said the same way.
                #expect(shown.line == mac.line && shown.switchOn == mac.switchOn && shown.switchEnabled == mac.switchEnabled)
                // Nothing that would type the installer there: no Reinstall or Remove, no Repair
                // or Update, no Retry of an install or a removal.
                #expect(shown.menu.allSatisfy { !ComputerStatus.installerItems.contains($0) })
                #expect(shown.menu == mac.menu.filter { $0 != .reinstall && $0 != .remove })
                if let fix = shown.fix { #expect(![.repair, .update].contains(fix)) }
                if f.removal == .failed || f.setup == .failed(.download) { #expect(shown.fix == nil) }
            }
            let healthy = ComputerStatus.make(facts { $0.installable = installable })
            #expect(healthy.line == line("Beacon 0.3.1", .secondary) && healthy.menu == [.sendTest, .showDetails])
            // Retry of the link to the notification service is the phone's own, and stays.
            #expect(ComputerStatus.make(facts { $0.installable = installable; $0.link = .failed }).fix == .retry)
            #expect(ComputerStatus.make(facts { $0.installable = installable; $0.helper = .notRunning }).fix == nil)
            #expect(ComputerStatus.make(facts { $0.installable = installable; $0.choice = false }).menu == [.showDetails])
        }
    }

    #if DEBUG
    // MARK: Screenshots

    @Test func everySimulatedStateHasAName() throws {
        #expect(NotificationSimulation.names.count == 6 + 24 + 2 + 4)
        #expect(Set(NotificationSimulation.names).count == NotificationSimulation.names.count)
        for name in NotificationSimulation.names {
            let s = try #require(NotificationSimulation(name: name))
            #expect(!s.rows.isEmpty)
        }
        #expect(NotificationSimulation(name: "nope") == nil)
        let all = try #require(NotificationSimulation(name: "all"))
        #expect(all.rows.count == NotificationSimulation.computerStates.count)
        #expect(all.rows.prefix(3).map(\.name) == ["Studio", "Laptop", "Mini"])
        #expect(Set(all.rows.map(\.id)).count == all.rows.count && Set(all.rows.map(\.name)).count == all.rows.count)
        #expect(try #require(NotificationSimulation(name: "master-denied")).master.tapOpensSettings)
        #expect(try #require(NotificationSimulation(name: "removing")).rows.first?.status.line?.text == "Removing…")
    }

    @Test func aSimulatedConfirmOrSheetSitsOverTheRowItBelongsTo() throws {
        // Each is opened from the first computer's row, so that row has the button or the menu item for it.
        let remove = try #require(NotificationSimulation(name: "confirm-remove"))
        #expect(remove.presents == .confirmRemove && remove.rows.first?.status.menu.last == .remove)
        let details = try #require(NotificationSimulation(name: "details"))
        #expect(details.presents == .details && details.rows.first?.status.menu.contains(.showDetails) == true)
        let trust = try #require(NotificationSimulation(name: "confirm-trust"))
        #expect(trust.presents == .confirmTrust && trust.rows.first?.status.fix == .trust)
        let how = try #require(NotificationSimulation(name: "how"))
        #expect(how.presents == .how && how.rows.first?.status.fix == .how)
        #expect(try #require(NotificationSimulation(name: "all")).presents == nil)
    }

    @Test func theLongNamesStateCarriesTheLongestLines() throws {
        let long = try #require(NotificationSimulation(name: "long-names"))
        let lines = long.rows.compactMap(\.status.line?.text)
        #expect(lines.contains("Didn't let Beacon install"))
        #expect(lines.contains("The download didn't pass its check"))
        #expect(lines.contains("Couldn't reach the notification service"))
        #expect(long.rows.allSatisfy { $0.name == NotificationSimulation.longName })
        // The last one is healthy: a long name over the version.
        #expect(long.rows.last?.status.line?.text == "Beacon 0.3.1")
    }
    #endif

    // MARK: Update

    @Test func updateGoesThroughTheInstallerUnlessTheHelperCanReplaceItself() throws {
        // A helper too old to register says nothing about itself.
        #expect(HelperUpdate.route(reported: nil) == .byInstaller)
        let able = try #require(HelperVersion(["version": "0.3.0", "can_update": true]))
        #expect(HelperUpdate.route(reported: able) == .bySelf)
        let unable = try #require(HelperVersion(["version": "0.3.0", "can_update": false]))
        #expect(HelperUpdate.route(reported: unable) == .byInstaller)
        let silent = try #require(HelperVersion(["version": "0.3.0"]))
        #expect(HelperUpdate.route(reported: silent) == .byInstaller)
        // One that is already updating is not asked again.
        let busy = try #require(HelperVersion(["version": "0.3.0", "can_update": true, "updating": true]))
        #expect(HelperUpdate.route(reported: busy) == .byInstaller)
        // Whether an update is due is the app's to say. A helper that thinks there is none, or
        // knows of no newer version, is asked all the same when it can replace itself.
        for opinion in [["update_available": false, "latest_version": "0.3.0"], ["update_available": true, "update_required": true],
                        ["last_error": "The release list could not be downloaded."]] as [[String: Any]] {
            var status: [String: Any] = ["version": "0.3.0", "can_update": true]
            status.merge(opinion) { $1 }
            let can = try #require(HelperVersion(status))
            #expect(HelperUpdate.route(reported: can) == .bySelf)
            status["can_update"] = false
            let cannot = try #require(HelperVersion(status))
            #expect(HelperUpdate.route(reported: cannot) == .byInstaller)
        }
    }

    @Test func aHelperThatUpdatesItselfIsDoneAtTheVersionTheUpdateWasFor() {
        let target = ReleaseVersion("0.3.2")
        #expect(!HelperUpdate.reached("0.3.1", from: "0.3.1", target: target))
        #expect(HelperUpdate.reached("0.3.2", from: "0.3.1", target: target))
        #expect(HelperUpdate.reached("0.4.0", from: "0.3.1", target: target))
        // Nothing reported is not done.
        #expect(!HelperUpdate.reached(nil, from: "0.3.1", target: target))
        #expect(!HelperUpdate.reached("", from: "0.3.1", target: target))
        // With no release to compare against, or a version that is not three numbers, another
        // version than before counts.
        #expect(HelperUpdate.reached("0.3.2", from: "0.3.1", target: nil))
        #expect(!HelperUpdate.reached("0.3.1", from: "0.3.1", target: nil))
        #expect(HelperUpdate.reached("0.3.2-dev", from: "0.3.1", target: target))
        #expect(!HelperUpdate.reached("0.3.1-dev", from: "0.3.1-dev", target: target))
        #expect(HelperUpdate.limit == 90)
    }

    @Test func aVersionStandsAgainstTheOneRelease() {
        let release = LatestRelease(version: ReleaseVersion("0.4.0")!, minVersion: ReleaseVersion("0.3.1")!)
        #expect(LatestRelease.standing(of: "0.4.0", against: release) == .current)
        // A build ahead of the release list is current too.
        #expect(LatestRelease.standing(of: "0.4.1", against: release) == .current)
        #expect(LatestRelease.standing(of: "1.0.0", against: release) == .current)
        #expect(LatestRelease.standing(of: "0.3.9", against: release) == .behind)
        #expect(LatestRelease.standing(of: "0.3.1", against: release) == .behind)
        #expect(LatestRelease.standing(of: "0.3.0", against: release) == .belowMinimum)
        #expect(LatestRelease.standing(of: "0.2.14", against: release) == .belowMinimum)
        // Numbers, not text: 0.10.0 is newer than 0.4.0.
        #expect(LatestRelease.standing(of: "0.10.0", against: release) == .current)
        // No release list, no version, or a version that is not three numbers: nothing is said.
        #expect(LatestRelease.standing(of: "0.3.0", against: nil) == .unknown)
        for odd in [nil, "", "0.4", "0.4.0-beta.2", "v0.3.0"] as [String?] {
            #expect(LatestRelease.standing(of: odd, against: release) == .unknown)
        }
        // The standing becomes the row's facts, and the rest is left alone.
        let facts = ComputerFacts(name: "Studio", version: "0.3.5")
        #expect(facts.judged(against: release).updateAvailable)
        #expect(!facts.judged(against: release).tooOld)
        var old = facts
        old.version = "0.3.0"
        #expect(old.judged(against: release).tooOld && !old.judged(against: release).updateAvailable)
        #expect(facts.judged(against: nil) == facts)
        var current = facts
        current.version = "0.4.0"
        #expect(current.judged(against: release) == current)
        // An add-on that refused the registration as too old stays so, whatever the list says.
        var refused = ComputerFacts(name: "Studio", tooOld: true, link: .pending)
        #expect(refused.judged(against: nil).tooOld)
        refused.version = "0.4.0"
        #expect(refused.judged(against: release).tooOld)
    }

    @Test func aHelperTooOldToRegisterIsUpdatedAndThenHealthy() {
        // It refused the registration and reported nothing: no status, nothing registered yet.
        var facts = ComputerFacts(name: "Studio", helper: .running, tooOld: true, link: .pending)
        #expect(ComputerStatus.make(facts) == ComputerStatus(switchOn: true, line: line("Beacon needs an update", .warning), fix: .update,
                                                             menu: [.reinstall, .remove]))
        #expect(NotificationMenuItem.reinstall.title == "Reinstall Beacon" && NotificationMenuItem.remove.title == "Remove Beacon…")
        // The same on a phone that never registered there: the helper that answers counts as installed.
        #expect(ComputerStatus.make(ComputerFacts(name: "Studio", helper: .running, tooOld: true, link: .pending)).switchOn)

        // Update runs the installer; while it does, the row follows the install.
        var state = SetupState(kind: .repair, computer: .mac)
        state.handle(.release(version: "0.4.0"))
        state.handle(.started)
        facts.setup = ComputerFacts.Setup(state)
        #expect(ComputerStatus.make(facts).line == line("Downloading…", .none, spinner: true))

        // The new helper showed the install's proof and registered: nothing is left for the row.
        state.handle(.record(SetupRecord(state: "done", token: "done", progress: nil, kind: nil, updatedAt: "1")))
        state.handle(.exited(code: 0))
        state.handle(.proof(.valid))
        state.handle(.helperRegistered)
        #expect(state.phase == .connected && ComputerFacts.Setup(state) == nil)
        let after = ComputerFacts(name: "Studio", helper: .running, setup: ComputerFacts.Setup(state), tooOld: false, link: .connected)
        // Until it has said which version it is, the row is still connecting.
        #expect(ComputerStatus.make(after) == ComputerStatus(switchOn: true, line: ComputerStatus.connectingLine,
                                                             menu: [.showDetails, .reinstall, .remove]))
    }

    @Test func aHealthyRowShowsTheVersionAndNothingAfterIt() {
        let healthy = row { $0.version = "0.3.1" }
        #expect(healthy == ComputerStatus(switchOn: true, line: line("Beacon 0.3.1", .secondary), fix: nil,
                                          menu: [.sendTest, .showDetails, .reinstall, .remove]))
        // Only what a version looks like is shown.
        #expect(ComputerStatus.versionLine("0.4.0-beta.2")?.text == "Beacon 0.4.0-beta.2")
        #expect(ComputerStatus.versionLine("0.3.1, up to date") == nil)
        #expect(ComputerStatus.versionLine(String(repeating: "1", count: 25)) == nil)
        // Every other state has its own line in the version's place.
        #expect(row { $0.version = "0.3.1"; $0.test = .sent }.line?.text == "Test notification sent")
        #expect(row { $0.version = "0.3.1"; $0.updateAvailable = true }.line?.text == "Update available")
        #expect(row { $0.version = "0.3.1"; $0.tooOld = true }.line?.text == "Beacon needs an update")
        #expect(row { $0.version = "0.3.1"; $0.link = .repairing }.line?.text == "Reconnecting…")
        #expect(row { $0.version = "0.3.1"; $0.choice = false }.line == nil)
        #expect(row { $0.version = "0.3.1"; $0.online = false }.line?.text == "Offline")
    }

    @Test func aRowIsNotHealthyUntilItsVersionIsKnown() {
        // On, reachable and registered, and the add-on has not said which version it is: the
        // row is still working, with no button, and a test waits.
        let connecting = ComputerStatus(switchOn: true, line: line("Connecting…", .none, spinner: true), fix: nil,
                                        menu: [.showDetails, .reinstall, .remove])
        for version in [nil, ""] as [String?] {
            #expect(row { $0.version = version } == connecting)
        }
        // The same before the add-on has taken this phone on this connection, whatever is
        // known of its version from before.
        #expect(row { $0.link = .pending } == connecting)
        #expect(row { $0.link = .pending; $0.version = nil } == connecting)
        // The version arrives: healthy.
        #expect(row { $0.version = "0.3.0" }.line == line("Beacon 0.3.0", .secondary))
        // The result of a test has a line of its own without it.
        #expect(row { $0.version = nil; $0.test = .sent }.line?.text == "Test notification sent")
    }

    @Test func aRowThatOffersATestAlwaysHasALine() {
        // Every mix of the facts: a row that is on and offers Send Test Notification is never blank.
        let helpers: [ComputerFacts.Helper] = [.notInstalled, .notRunning, .running]
        let setups: [ComputerFacts.Setup?] = [nil, .working(.installing), .waitingForPerson, .clickAllow, .failed(.download), .manual]
        let links: [ComputerFacts.Link] = [.pending, .connected, .repairing, .failed]
        let tests: [ComputerFacts.Test?] = [nil, .sent, .failed("Wait a few seconds")]
        var seen = 0
        for helper in helpers { for setup in setups { for link in links { for test in tests {
            for version in [nil, "", "0.3.1", "not a version"] as [String?] {
                for flags in 0..<32 {
                    var f = ComputerFacts(name: "Studio", choice: flags & 1 == 0, online: flags & 2 == 0, helper: helper, setup: setup,
                                          changed: flags & 4 != 0, tooOld: flags & 8 != 0, link: link, test: test, version: version)
                    f.updateAvailable = flags & 16 != 0
                    let s = ComputerStatus.make(f)
                    seen += 1
                    if s.switchOn { #expect(s.line != nil, "\(f)") }
                    if s.menu.contains(.sendTest) { #expect(s.switchOn && s.line?.spinner == false, "\(f)") }
                }
            }
        } } } }
        #expect(seen == 3 * 6 * 4 * 3 * 4 * 32)
    }

    #if DEBUG
    @Test func noLineOfTheScreenSaysUpToDate() throws {
        // The version stands alone: nothing in any state of the screen says more about it.
        var words = [MasterStatus.footer, NotificationCopy.manualTitle, NotificationCopy.turnOnInSettings] + NotificationCopy.manualSteps
        for name in NotificationSimulation.names {
            let s = try #require(NotificationSimulation(name: name))
            words += [s.master.line?.text ?? ""] + s.rows.compactMap(\.status.line?.text)
            words += s.rows.flatMap { $0.status.menu.map(\.title) + [$0.status.fix?.title ?? ""] }
        }
        words += NotificationSimulation.details.rows().flatMap { [$0.label, $0.value] }
        #expect(words.allSatisfy { !$0.localizedCaseInsensitiveContains("up to date") })
        let healthy = try #require(NotificationSimulation(name: "healthy")).rows[0].status.line
        #expect(healthy == line("Beacon 0.3.1", .secondary))
        let older = try #require(NotificationSimulation(name: "update-available")).rows[0].status
        #expect(older.line == line("Update available", .secondary) && older.fix == .update)
        #expect(NotificationSimulation(name: "healthy-older") == nil && NotificationSimulation(name: "cannot-check") == nil)
        #expect(try #require(NotificationSimulation(name: "connecting")).rows[0].status.line == ComputerStatus.connectingLine)
        // In the list of every state, no row that is on is blank, and one row is connecting.
        let all = try #require(NotificationSimulation(name: "all"))
        #expect(all.rows.allSatisfy { !$0.status.switchOn || $0.status.line != nil })
        #expect(all.rows.filter { $0.status.line == ComputerStatus.connectingLine }.map(\.name) == ["Cellar"])
        // One row is behind the simulated release, and no row speaks of the check itself.
        #expect(all.rows[1].name == "Laptop" && all.rows[1].status == older)
        #expect(all.rows.filter { $0.status.line?.text == "Update available" }.count == 1)
        #expect(!all.rows.contains { $0.status.line?.text == "Can't check for updates" })
    }
    #endif

    @Test func anUpdateThePersonStartedShowsHowItGoes() {
        // Asked to update itself: a spinner and no button while it does.
        let updating = ComputerStatus(switchOn: true, line: line("Updating…", .none, spinner: true), fix: nil, menu: [.reinstall, .remove])
        #expect(row { $0.tooOld = true; $0.updating = true } == updating)
        #expect(row { $0.updateAvailable = true; $0.updating = true } == updating)
        // A helper that changed, or an install, still comes first.
        #expect(row { $0.updating = true; $0.changed = true }.fix == .trust)
    }

    @Test func anUpdateThatIsAvailableIsInformationWithOneButton() {
        // Not a problem: the secondary tint, Update beside it, and the healthy row's menu.
        let available = row { $0.version = "0.3.0"; $0.updateAvailable = true }
        #expect(available == ComputerStatus(switchOn: true, line: line("Update available", .secondary), fix: .update,
                                            menu: [.sendTest, .showDetails, .reinstall, .remove]))
        #expect(row { $0.updateAvailable = false } == row())
        // Below the oldest version the release list allows it is a problem.
        #expect(row { $0.tooOld = true }
                == ComputerStatus(switchOn: true, line: line("Beacon needs an update", .warning), fix: .update, menu: [.reinstall, .remove]))
        // It sits just above the version: every problem and everything under way wins over it.
        func text(_ change: @escaping (inout ComputerFacts) -> Void) -> String? {
            row { $0.updateAvailable = true; change(&$0) }.line?.text
        }
        #expect(text { $0.tooOld = true } == "Beacon needs an update")
        #expect(text { $0.updating = true } == "Updating…")
        #expect(text { $0.changed = true } == "Beacon has changed")
        #expect(text { $0.helper = .notRunning } == "Beacon isn't running")
        #expect(text { $0.link = .repairing } == "Reconnecting…")
        #expect(text { $0.link = .failed } == "Couldn't reconnect")
        #expect(text { $0.limit = self.limit(nil); $0.link = .pending } == "Too many tries. Try again later.")
        #expect(text { $0.link = .pending } == "Connecting…")
        #expect(text { $0.test = .sent } == "Test notification sent")
        #expect(text { $0.test = .failed("Wait a few seconds") } == "Wait a few seconds")
        #expect(text { $0.setup = .working(.installing) } == "Installing…")
        #expect(text { $0.removal = .removing } == "Removing…")
        #expect(text { $0.online = false } == "Offline")
        #expect(row { $0.updateAvailable = true; $0.choice = false }.line == nil)
        // A result of a test has no button while it shows.
        #expect(row { $0.updateAvailable = true; $0.test = .sent }.fix == nil)
    }

    @Test func detailsSayHowTheAppsOwnUpdateCheckWent() throws {
        // Nothing to say until the app's read of the release list has failed.
        #expect(HelperDetails(status: ["version": "0.3.0"]).rows().last == .init(label: "Beacon version", value: "0.3.0"))
        var details = HelperDetails(status: ["version": "0.3.0"])
        details.updateCheck = .failed
        #expect(details.rows().last == .init(label: "Update check", value: "Couldn't check"))
        // The add-on's own failed checks are not the screen's: its reason is not shown.
        let own = HelperDetails(status: ["version": "0.3.0", "last_error": "The release list could not be downloaded.",
                                         "failing_since": 1_799_990_000])
        #expect(own.updateCheck == .ok && own.rows().last == .init(label: "Beacon version", value: "0.3.0"))
        #expect(HelperDetails(status: ["last_error": "x"]).rows() == [])
    }

    // MARK: What the screen adds

    @Test func eachTintIsOneColourOfTheTheme() {
        for theme in [ThemeStore.fallback, ThemeStore.all.first { !$0.isDark } ?? ThemeStore.fallback] {
            // A problem has the colour of an agent that needs the person; information is
            // secondary text; what the app does by itself is plain text.
            #expect(NotificationTint.warning.color(in: theme) == theme.chrome.blocked)
            #expect(NotificationTint.secondary.color(in: theme) == theme.chrome.secondary)
            #expect(NotificationTint.none.color(in: theme) == theme.fg)
        }
    }

    @Test func theSheetsHaveTheirWords() {
        // The row says "Install Beacon by hand", its button "How", and the sheet is those steps:
        // where to get the program, under its real name, for each system; Linux's line is the
        // install command of docs/helper.md, to copy.
        #expect(NotificationCopy.manualTitle == "Install by Hand")
        #expect(NotificationCopy.manualSteps == [
            "Mac: download \(Brand.beaconName) from github.com/theabecaster/pteron/releases, drag it to Applications and open it once.",
            "Linux: run this command, which downloads and installs \(Brand.beaconName):",
        ])
        #expect(NotificationCopy.linuxInstall
            == "curl -fsSL https://github.com/theabecaster/pteron/releases/download/helper-latest/install.sh | sh")
        #expect(SetupError.manual.message(name: "Studio").hasSuffix("Linux: run the command below."))
        #expect(NotificationCopy.noDetails(name: "Studio") == "\(Brand.beaconName) on Studio isn't answering.")
    }
}

/// What the phone keeps about notifications, and what turning things off and on does to it:
/// the switches through `PushRegistrar`, with stand-ins for iOS, the gateway and the helpers.
@MainActor
struct NotificationChoiceTests {
    private let server = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let other = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    /// iOS, as the registrar sees it.
    @MainActor
    final class Phone {
        var permission = NotificationPermission.allowed
        /// What iOS answers when it asks the person.
        var answer = NotificationPermission.allowed
        var asked = 0
        var openedSettings = 0
        var addressRequests = 0
        var addressReleases = 0
        /// How long the person takes to answer iOS's question, in seconds.
        var answersAfter: TimeInterval = 0

        var system: PushRegistrar.System {
            PushRegistrar.System(permission: { self.permission },
                                 ask: {
                                     self.asked += 1
                                     if self.answersAfter > 0 { try? await Task.sleep(nanoseconds: UInt64(self.answersAfter * 1_000_000_000)) }
                                     self.permission = self.answer
                                 },
                                 registerForNotifications: { self.addressRequests += 1 },
                                 unregisterForNotifications: { self.addressReleases += 1 },
                                 openSettings: { self.openedSettings += 1 },
                                 deviceName: { "Test iPhone" })
        }
    }

    private struct Setup {
        var world: PushWorld
        var phone: Phone
        var push: PushRegistrar

        var prefs: Prefs { world.prefs }
        var gateway: GatewayStandIn { world.gateway }
        var helpers: HelperStandIn { world.helpers }
    }

    /// A phone with the master switch on, an address from iOS, and a helper on each of `servers`.
    private func make(_ servers: [UUID] = [], configure: (PushWorld) -> Void = { _ in }) -> Setup {
        let world = PushWorld()
        for (index, id) in servers.enumerated() { world.helpers.add(id, name: index == 0 ? "Studio" : "Laptop") }
        world.defaults.set(PushWorld.token, forKey: "pushToken.last")
        world.prefs.pushEnabled = true
        configure(world)
        let phone = Phone()
        let push = PushRegistrar(prefs: world.prefs, deviceID: "abcd1234", environment: "sandbox", defaults: world.defaults,
                                 parts: world.parts, system: phone.system)
        return Setup(world: world, phone: phone, push: push)
    }

    /// The same, once every computer's helper holds its secret.
    private func signedUp(_ servers: [UUID]) async -> Setup {
        let s = make(servers)
        await s.push.refresh()
        await s.world.eventually { servers.allSatisfy { s.helpers[$0].secret != nil } }
        await s.world.quiet()
        return s
    }

    // MARK: In front

    /// A launch that never reaches the screen registers (a helper's push arrived, say) and must
    /// not tell the helper that the phone is in use: it would hold the pushes back.
    @Test func aRegistrationBeforeTheAppIsActiveSaysNothingAboutBeingInFront() async {
        let s = make([server])
        s.push.start()
        await s.world.eventually { s.helpers[server].secret != nil }
        await s.world.quiet()
        #expect(s.helpers[server].presence.isEmpty)
        // The app reaches the screen: now the helper hears it.
        s.push.becameActive()
        await s.world.eventually { !s.helpers[server].presence.isEmpty }
        await s.world.quiet()
        #expect(s.helpers[server].presence == [true])
    }

    /// The app is active before the registrar has started (the connection opens first, the
    /// sign-up later): nothing is sent then, and the registration that follows says "in front".
    @Test func becomingActiveBeforeTheRegistrarStartsStillSaysInFrontOnceItRegisters() async {
        let s = make([server])
        s.push.becameActive()
        await s.world.quiet()
        #expect(s.helpers[server].presence.isEmpty)
        s.push.start()
        await s.world.eventually { !s.helpers[server].presence.isEmpty }
        await s.world.quiet()
        #expect(s.helpers[server].secret != nil && s.helpers[server].presence == [true])
    }

    @Test func aRegistrationAfterTheAppIsActiveSaysItIsInFront() async {
        let s = make([server])
        s.push.start()
        // Active before the helper holds the phone: nobody to tell yet.
        s.push.becameActive()
        #expect(s.helpers[server].presence.isEmpty)
        await s.world.eventually { !s.helpers[server].presence.isEmpty }
        await s.world.quiet()
        #expect(s.helpers[server].secret != nil && s.helpers[server].presence == [true])
    }

    @Test func goingToTheBackgroundSaysSo() async {
        let s = make([server])
        s.push.start()
        s.push.becameActive()
        await s.world.eventually { !s.helpers[server].presence.isEmpty }
        await s.world.quiet()
        s.push.enteredBackground()
        await s.world.eventually { s.helpers[server].presence.count == 2 }
        #expect(s.helpers[server].presence == [true, false])
    }

    @Test func aNewServerIsOnAndTheChoicesPersist() {
        let s = make()
        #expect(s.prefs.notificationsOff.isEmpty && s.prefs.helperSeen.isEmpty && s.prefs.helpersToTell.isEmpty)
        // A server nobody turned off is on.
        #expect(!s.prefs.notificationsOff.contains(UUID()))
        s.prefs.notificationsOff = [server]
        s.prefs.helperSeen = [server, other]
        s.prefs.helpersToTell = [other]
        let again = Prefs(defaults: s.world.defaults)
        #expect(again.notificationsOff == [server] && again.helperSeen == [server, other] && again.helpersToTell == [other])
    }

    @Test func theVersionComesFromTheRegistrationOrTheStatusWhicheverArrives() async {
        // The registration's answer carries the version, and the add-on's status does not come.
        let s = make([server, other]) {
            $0.helpers[self.server].answersStatus = false
            // An add-on 0.3.0, whose registration says nothing of its version: its status does.
            $0.helpers[self.other].version = "0.3.0"
            $0.helpers[self.other].registrationSaysVersion = false
        }
        await s.push.refresh()
        await s.world.eventually { s.push.registeredVersions[self.server] != nil && s.push.versions[self.other] != nil }
        #expect(s.push.registeredVersions[server] == "0.3.1" && s.push.versions[server] == nil)
        #expect(s.push.versions[other]?.version == "0.3.0" && s.push.registeredVersions[other] == nil)
        // Asked once where it answered; asked again where it did not, and no more than the tries allow.
        #expect(s.helpers[other].count("helper_status") == 1)
        #expect((1...PushRegistrar.versionTries).contains(s.helpers[server].count("helper_status")))
    }

    /// Going to the background tells each helper once, inside the shared `BackgroundTask` (it
    /// replaced PushRegistrar's own copy).
    @Test func goingToTheBackgroundTellsEachHelperOnce() async {
        let s = await signedUp([server, other])
        let before = (s.helpers[server].count("push_presence"), s.helpers[other].count("push_presence"))
        s.push.enteredBackground()
        await s.world.eventually {
            s.helpers[self.server].count("push_presence") == before.0 + 1 && s.helpers[self.other].count("push_presence") == before.1 + 1
        }
        await s.world.quiet()
        #expect(s.helpers[server].count("push_presence") == before.0 + 1)
        #expect(s.helpers[other].count("push_presence") == before.1 + 1)
    }

    @Test func turningNotificationsOnSignsEachComputerUpOnce() async {
        let s = await signedUp([server, other])
        // One device, and one secret for each computer.
        #expect(s.gateway.seen.count == 3 && s.gateway.made == 1 && s.gateway.devices.values.first?.secrets.count == 2)
        #expect(s.push.helpers[server] == .running(pushEnabled: true) && s.push.versions[server]?.version == "0.3.1")
        #expect(s.phone.addressRequests == 1 && s.phone.addressReleases == 0)
        #expect(s.push.intent(for: server) == .on(token: PushWorld.token))
    }

    @Test func aHundredFlipsOfEitherSwitchMakeNoGatewayRequest() async {
        let s = await signedUp([server, other])
        let requests = s.gateway.seen.count, writes = s.gateway.writes, saves = s.world.store.saves
        let secrets = [server, other].map { s.helpers[$0].secret }

        // One computer's switch.
        for flip in 0..<100 {
            let on = flip % 2 == 1
            s.push.setComputer(server, on: on)
            await s.world.eventually { s.helpers[server].paused == !on && !s.push.reconciler.isBusy(server) }
        }
        await s.world.quiet()
        #expect(s.gateway.seen.count == requests && s.gateway.writes == writes && s.world.store.saves == saves)
        #expect(s.helpers[server].pauseCalls == (0..<100).map { "set_push_paused \($0 % 2 == 0)" })
        // The other computer heard nothing of it.
        #expect(s.helpers[other].pauseCalls.isEmpty && !s.helpers[other].paused)
        #expect(s.prefs.notificationsOff.isEmpty && s.prefs.helpersToTell.isEmpty)

        // The master switch.
        for flip in 0..<100 {
            let on = flip % 2 == 1
            s.push.setMaster(on: on)
            await s.world.eventually {
                s.helpers[server].paused == !on && s.helpers[other].paused == !on
                    && !s.push.reconciler.isBusy(server) && !s.push.reconciler.isBusy(other)
            }
        }
        await s.world.quiet()
        #expect(s.gateway.seen.count == requests && s.gateway.writes == writes && s.world.store.saves == saves)
        #expect(s.helpers[other].pauseCalls == (0..<100).map { "set_push_paused \($0 % 2 == 0)" })
        #expect(s.helpers[server].pauseCalls.count == 200)
        // Each helper holds the secret it was given, and was given it once.
        #expect([server, other].map { s.helpers[$0].secret } == secrets)
        #expect(s.helpers[server].count("register_push") == 1 && s.helpers[other].count("register_push") == 1)
        #expect(s.helpers[server].count("unregister_push") == 0)
        // Off takes the app off Apple's notifications each time, and on puts it back.
        #expect(s.phone.addressReleases == 50 && s.phone.addressRequests == 51)
        #expect(s.prefs.pushEnabled && s.prefs.helpersToTell.isEmpty)
    }

    /// Every computer that is on has resumed, says its version, and has nothing under way.
    private func healthy(_ s: Setup, _ ids: [UUID]) -> Bool {
        ids.allSatisfy { id in
            !s.helpers[id].paused && s.helpers[id].pauseCalls.last != "set_push_paused true"
                && s.push.reconciler.isSettled(id) && s.push.helpers[id] == .running(pushEnabled: true)
                && s.push.versions[id]?.version == "0.3.1" && !s.push.reconciler.isBusy(id)
        } && s.push.reconciler.mending.isEmpty && s.push.reconciler.retrying.isEmpty && s.push.reconciler.stopped.isEmpty
    }

    @Test func masterFlipsFasterThanAHelperAnswersEndOnTheLastChoice() async {
        for (flips, endsOn) in [(20, true), (100, true), (21, false), (101, false)] {
            let s = await signedUp([server, other])
            let requests = s.gateway.seen.count, saves = s.world.store.saves
            for id in [server, other] { s.helpers[id].latency = 2_000_000 }
            // Off first, then on, and so on; a flip every millisecond.
            for flip in 0..<flips {
                s.push.setMaster(on: flip % 2 == 1)
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
            #expect(s.prefs.pushEnabled == endsOn)
            if endsOn {
                await s.world.eventually { healthy(s, [server, other]) }
                await s.world.quiet()
                #expect(healthy(s, [server, other]))
            } else {
                await s.world.eventually { [server, other].allSatisfy { s.helpers[$0].paused && !s.push.reconciler.isBusy($0) } }
                await s.world.quiet()
                for id in [server, other] {
                    #expect(s.helpers[id].paused && s.helpers[id].pauseCalls.last == "set_push_paused true")
                }
                #expect(s.prefs.helpersToTell.isEmpty)
            }
            // Each helper kept its secret, and the gateway and the Keychain heard nothing.
            #expect(s.helpers[server].count("register_push") == 1 && s.helpers[other].count("register_push") == 1)
            #expect(s.gateway.seen.count == requests && s.world.store.saves == saves)
        }
    }

    @Test func masterAndComputerFlipsTogetherEndOnTheLastChoices() async {
        let s = await signedUp([server, other])
        let requests = s.gateway.seen.count
        for id in [server, other] { s.helpers[id].latency = 2_000_000 }
        for flip in 0..<60 {
            switch flip % 4 {
            case 0: s.push.setMaster(on: false)
            case 1: s.push.setComputer(server, on: flip % 8 == 1)
            case 2: s.push.setMaster(on: true)
            default: s.push.setComputer(other, on: flip % 8 == 3)
            }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        // Left with the master switch on, one computer off and the other on.
        s.push.setComputer(server, on: false)
        s.push.setComputer(other, on: true)
        s.push.setMaster(on: true)
        await s.world.eventually { s.helpers[server].paused && healthy(s, [other]) && !s.push.reconciler.isBusy(server) }
        await s.world.quiet()
        #expect(s.helpers[server].paused && s.helpers[server].pauseCalls.last == "set_push_paused true")
        #expect(healthy(s, [other]) && s.prefs.notificationsOff == [server] && s.prefs.helpersToTell.isEmpty)
        #expect(s.gateway.seen.count == requests)
    }

    @Test func aTestThatFindsTheHelperPausedResumesIt() async {
        let s = await signedUp([server])
        let requests = s.gateway.seen.count
        // Paused behind the app's back.
        s.helpers[server].paused = true
        s.push.sendTest(for: server)
        await s.world.eventually { healthy(s, [server]) }
        #expect(s.helpers[server].count("send_test") == 1 && s.helpers[server].pauseCalls == ["set_push_paused false"])
        #expect(s.gateway.seen.count == requests)
        // The next test goes out.
        s.push.sendTest(for: server)
        await s.world.eventually { s.push.tests[server] == .sent }
        #expect(s.push.tests[server] == .sent)
    }

    #if DEBUG
    @Test func theMasterSwitchDoesNotWaitForIOS() async {
        // iOS was never asked and its question stays unanswered; `-pushToken` gives the address.
        let s = make([server]) { $0.defaults.set(PushWorld.token, forKey: "pushToken") }
        s.phone.permission = .notAsked
        s.phone.answersAfter = 30
        await s.push.refresh()
        await s.world.eventually { healthy(s, [server]) }
        let requests = s.gateway.seen.count
        for flip in 0..<40 {
            s.push.setMaster(on: flip % 2 == 1)
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        await s.world.eventually { healthy(s, [server]) }
        await s.world.quiet()
        #expect(healthy(s, [server]) && s.prefs.pushEnabled)
        // The stand-in address needs no question and no word to Apple.
        #expect(s.phone.asked == 0 && s.phone.addressRequests == 0 && s.phone.addressReleases == 0)
        #expect(s.gateway.seen.count == requests)
    }
    #endif

    @Test func aQuestionIOSHasNotAnsweredHoldsNothingUp() async {
        let s = await signedUp([server])
        // The permission reads as never asked, and the question takes the person a while.
        s.phone.answersAfter = 30
        s.push.setMaster(on: false)
        await s.world.eventually { s.helpers[server].paused }
        s.phone.permission = .notAsked
        s.push.setMaster(on: true)
        s.push.setMaster(on: false)
        s.push.setMaster(on: true)
        await s.world.eventually { s.phone.asked == 1 }
        await s.world.quiet()
        // One question, and the app is not held by it.
        #expect(s.phone.asked == 1 && s.prefs.pushEnabled)
        s.push.setMaster(on: false)
        await s.world.quiet()
        #expect(s.helpers[server].paused && s.helpers[server].pauseCalls.last == "set_push_paused true")
    }

    @Test func masterOffThenOnBringsEachComputerBackAsItWas() async {
        let s = await signedUp([server, other])
        let requests = s.gateway.seen.count
        let stored = s.world.store.value
        s.push.setComputer(other, on: false)
        await s.world.eventually { s.helpers[other].paused }
        #expect(s.prefs.notificationsOff == [other])

        s.push.setMaster(on: false)
        #expect(!s.prefs.pushEnabled && !s.push.master.switchOn && !s.push.master.showsComputers)
        await s.world.eventually { s.helpers[server].paused }
        // Every helper holds the phone's notifications back. The other one had been told already.
        #expect(s.helpers[other].pauseCalls == ["set_push_paused true"] && s.phone.addressReleases == 1)
        #expect(s.prefs.notificationsOff == [other] && s.push.intent(for: server) == .paused)

        s.push.setMaster(on: true)
        await s.world.eventually { s.push.master.switchOn && !s.helpers[server].paused }
        await s.world.quiet()
        #expect(s.prefs.pushEnabled && s.push.master.showsComputers)
        // The computer that was off by its own switch stays off.
        #expect(s.prefs.notificationsOff == [other] && s.helpers[other].paused)
        // iOS had been asked before, so it is not asked again.
        #expect(s.phone.asked == 0)
        // Nothing at the gateway or in the Keychain changed: the device, the secrets, each helper's key.
        #expect(s.gateway.seen.count == requests && s.world.store.value == stored)
    }

    @Test func masterOnAgainSendsTheAddressOnlyWhenItChanged() async {
        let s = await signedUp([server])
        let requests = s.gateway.seen.count
        s.push.setMaster(on: false)
        await s.world.eventually { s.helpers[server].paused }
        s.push.setMaster(on: true)
        await s.world.eventually { s.phone.addressRequests == 2 }
        // iOS gives the address it gave before: nothing to send.
        s.push.tokenReceived(Data(repeating: 0xab, count: 32))
        await s.world.eventually { !s.helpers[server].paused }
        await s.world.quiet()
        #expect(s.gateway.seen.count == requests)

        // Off and on again, and this time iOS gives another: one request, and the secret stays.
        s.push.setMaster(on: false)
        await s.world.eventually { s.helpers[server].paused }
        s.push.setMaster(on: true)
        s.push.tokenReceived(Data(repeating: 0xcd, count: 32))
        await s.world.eventually { !s.helpers[server].paused && s.world.store.value?.token == String(repeating: "cd", count: 32) }
        await s.world.quiet()
        #expect(s.gateway.seen.count == requests + 1 && s.gateway.seen.last?.method == "PUT")
        #expect(s.gateway.seen.last?.body["apns_token"] == String(repeating: "cd", count: 32))
        #expect(s.helpers[server].count("register_push") == 1)
    }

    @Test func turningTheMasterSwitchOnAsksIOSTheFirstTime() async {
        let s = make()
        s.prefs.pushEnabled = false
        s.phone.permission = .notAsked
        await s.push.refresh()
        #expect(!s.push.master.switchOn)
        s.push.setMaster(on: true)
        await s.world.eventually { s.phone.asked == 1 && s.push.master.switchOn }
        #expect(s.phone.asked == 1 && s.prefs.pushEnabled && s.push.master.switchOn)

        // Don't Allow: the choice is kept and the switch shows off.
        let no = make()
        no.prefs.pushEnabled = false
        no.phone.permission = .notAsked
        no.phone.answer = .denied
        await no.push.refresh()
        no.push.setMaster(on: true)
        await no.world.eventually { no.push.permission == .denied }
        #expect(no.prefs.pushEnabled && !no.push.master.switchOn && no.push.master.line?.text == "Turned off in iOS Settings")
    }

    @Test func iOSTurnedOffKeepsEverythingAndComingBackTurnsItOnAgain() async {
        let s = await signedUp([server])
        let requests = s.gateway.seen.count, calls = s.helpers[server].calls.count
        let stored = s.world.store.value
        s.prefs.notificationsOff = [other]
        s.phone.permission = .denied
        await s.push.refresh()
        await s.world.quiet()
        #expect(!s.push.master.switchOn && !s.push.master.showsComputers && s.push.master.tapOpensSettings)
        #expect(s.prefs.pushEnabled && s.prefs.notificationsOff == [other])
        // Nothing is taken back and nobody is told: iOS shows nothing meanwhile.
        #expect(s.push.intent(for: server) == .waiting)
        #expect(s.gateway.seen.count == requests && s.helpers[server].calls.count == calls && s.world.store.value == stored)

        // A tap on the switch opens iOS Settings and changes nothing.
        s.push.setMaster(on: true)
        s.push.setMaster(on: false)
        #expect(s.phone.openedSettings == 2 && s.prefs.pushEnabled && s.phone.asked == 0 && s.phone.addressReleases == 0)

        // Back in the app with notifications allowed: on again, with no tap and no request.
        s.phone.permission = .allowed
        await s.push.refresh()
        await s.world.quiet()
        #expect(s.push.master.switchOn && s.push.master.showsComputers)
        #expect(s.prefs.notificationsOff == [other])
        #expect(s.phone.addressRequests == 2 && s.gateway.seen.count == requests)
    }

    @Test func quietDeliveryKeepsThePhoneSignedUp() async {
        let s = await signedUp([server])
        let requests = s.gateway.seen.count
        s.phone.permission = .quiet
        await s.push.refresh()
        await s.world.quiet()
        #expect(s.push.master.switchOn && s.push.master.fix == .openSettings)
        #expect(s.push.intent(for: server) == .on(token: PushWorld.token) && s.gateway.seen.count == requests)
    }

    @Test func aMissingNotificationAddressShowsUntilIOSGivesOne() async {
        let s = make([server]) { $0.defaults.removeObject(forKey: "pushToken.last") }
        await s.push.refresh()
        #expect(s.push.master.line == nil && s.push.intent(for: server) == .waiting)
        s.push.tokenFailed(URLError(.notConnectedToInternet))
        #expect(s.push.master.line == NotificationLine(text: "Can't reach Apple's notification service", tint: .none, spinner: true))
        await s.world.quiet()
        #expect(s.gateway.seen.isEmpty && s.helpers[server].calls.isEmpty)
        // The address arrives: the line goes, and the computer signs up.
        s.push.tokenReceived(Data([0xab, 0xcd]))
        #expect(s.push.master.line == nil && s.push.token == "abcd")
        await s.world.eventually { s.helpers[server].secret != nil }
        #expect(s.gateway.seen.first?.body["apns_token"] == "abcd")
    }

    @Test func turningAComputerOffWhileItCannotBeReachedWaitsOnThePhone() async {
        let s = await signedUp([server, other])
        let requests = s.gateway.seen.count
        let stored = s.world.store.value
        s.helpers[server].serial = nil
        s.push.setComputer(server, on: false)
        await s.world.quiet()
        // The choice is on the phone, and the row says the add-on hears of it later.
        #expect(s.prefs.notificationsOff == [server] && s.prefs.helpersToTell == [server] && s.prefs.pushEnabled)
        #expect(s.push.intent(for: server) == .paused && s.helpers[server].pauseCalls.isEmpty)
        // Nothing was taken back: not at the gateway, not on the phone.
        #expect(s.gateway.seen.count == requests && s.world.store.value == stored)

        // The computer is back: its helper is told, once.
        s.helpers[server].serial = 2
        s.push.reconciler.trigger(server)
        await s.world.eventually { s.helpers[server].paused }
        s.push.reconciler.reconcileAll()
        await s.world.quiet()
        #expect(s.prefs.helpersToTell.isEmpty && s.helpers[server].pauseCalls == ["set_push_paused true"])
        #expect(s.gateway.seen.count == requests && !s.helpers[other].paused)
    }

    #if DEBUG
    @Test func theLaunchArgumentPublishesFixedRowsAndItsControlsDoNothing() async {
        let s = make([server]) { $0.defaults.set("all", forKey: "simulateNotifications") }
        let push = s.push
        #expect(push.master.switchOn && push.computers.count == NotificationSimulation.computerStates.count)
        let first = push.computers[0]
        #expect(first.name == "Studio" && push.status(for: first.id) == first.status)
        push.setMaster(on: false)
        push.setComputer(first.id, on: false)
        push.setComputer(server, on: false)
        push.removeHelper(from: first.id)
        await push.refresh()
        push.tokenReceived(Data([0xab]))
        push.becameActive()
        await s.world.quiet()
        #expect(s.prefs.pushEnabled && s.prefs.notificationsOff.isEmpty && s.prefs.helpersToTell.isEmpty)
        #expect(s.gateway.seen.isEmpty && s.helpers[server].calls.isEmpty)
        #expect(s.phone.addressRequests == 0 && s.phone.addressReleases == 0)
        #expect(await push.details(for: first.id)?.rows().count == 3)
        // Every name of the launch argument makes a screen, and the new lines are among them.
        for name in NotificationSimulation.names { #expect(NotificationSimulation(name: name) != nil) }
        #expect(NotificationSimulation(name: "turns-off")?.rows[0].status.line == NotificationLine(text: "Turns off when it's back", tint: .secondary))
        // No line of any state repeats the computer's name: the row's title is the name.
        for name in ["all", "long-names"] {
            for row in NotificationSimulation(name: name)?.rows ?? [] {
                #expect(row.status.line?.text.contains(row.name) != true)
            }
        }
        #expect(NotificationSimulation(name: "limit")?.rows[0].status.line?.text == "Too many tries. Try again in an hour.")
        #expect(NotificationSimulation.computers.count >= NotificationSimulation.computerStates.count)
    }
    #endif

    @Test func removingAServerFromTheAppForgetsItsChoicesAndTakesItsSecretBack() async throws {
        let s = await signedUp([server, other])
        let device = try #require(s.world.store.value?.device)
        let secret = try #require(s.world.store.value?.servers[server.uuidString]?.secretID)
        s.prefs.notificationsOff = [server, other]
        s.prefs.helperSeen = [server]
        s.prefs.helpersToTell = [server]
        s.push.serverRemoved(server)
        #expect(s.prefs.notificationsOff == [other] && s.prefs.helperSeen.isEmpty)
        await s.world.eventually { s.world.store.value?.servers[server.uuidString] == nil }
        #expect(s.prefs.helpersToTell.isEmpty)
        // The secret is taken back after the store has let it go.
        await s.world.eventually { s.gateway.lines.last == "DELETE /v1/devices/\(device)/secrets/\(secret)" }
        #expect(s.gateway.lines.last == "DELETE /v1/devices/\(device)/secrets/\(secret)")
        // The other computer's secret and the device stay.
        #expect(s.gateway.devices[device]?.secrets.count == 1 && s.world.store.value?.servers[other.uuidString]?.pushSecret != nil)
    }

    /// Reinstall, Repair and Remove type the installer into a tab on the computer, and Remove
    /// takes the secret back first. On a computer of another system none of them is offered,
    /// and a call from elsewhere (a script, a stale menu) runs nothing and takes nothing back.
    @Test func theInstallerIsAskedForOnlyOnAMacOrLinuxComputer() async {
        let cases: [(platform: String?, runs: Bool)] = [("darwin_arm64", true), ("linux_amd64", true),
                                                        ("windows_amd64", false), ("haiku_x86", false), (nil, false)]
        for (platform, runs) in cases {
            let s = await signedUp([server])
            let computer = ServerConnection(config: ServerConfig(id: server, name: "Studio", url: "http://127.0.0.1:1"),
                                            prefs: s.prefs, notifier: AgentNotifier(), deviceID: "a1b2c3d4")
            computer.platform = platform
            s.push.servers = { [computer] }
            final class Asked { var kinds: [SetupState.Kind] = [] }
            let asked = Asked()
            s.push.presentSetup = { _, kind in asked.kinds.append(kind) }
            let requests = s.gateway.seen.count
            let menu = s.push.status(for: server)?.menu ?? []
            #expect(menu.contains(.reinstall) == runs && menu.contains(.remove) == runs)

            s.push.reinstall(server)
            s.push.fix(.repair, for: server)
            s.push.removeHelper(from: server)
            await s.world.quiet()
            #expect(asked.kinds == (runs ? [.reinstall, .repair] : []))
            // The secret stays where it was, at the gateway and with Beacon.
            #expect(s.push.removals[server] == nil && s.gateway.seen.count == requests && s.helpers[server].secret != nil)
        }
    }
}
