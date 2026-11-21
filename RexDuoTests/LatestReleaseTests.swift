import Foundation
import Testing
import RexKit
@testable import RexDuo

/// The release list, as the app's one check reads it: it answers what the test says and counts
/// how often it was read.
@MainActor
final class ReleaseListStandIn {
    var answer: Result<VerifiedRelease, ReleaseFault>
    private(set) var fetches = 0

    init(latest: String = "0.3.2", min: String = "0.3.0") {
        answer = .success(Self.release(latest, min: min))
    }

    static func release(_ latest: String, min: String = "0.3.0") -> VerifiedRelease {
        VerifiedRelease(version: ReleaseVersion(latest)!, minVersion: ReleaseVersion(min)!, assets: [:], expiresAt: .distantFuture, keys: [])
    }

    func fetch() async -> Result<VerifiedRelease, ReleaseFault> {
        fetches += 1
        // A read takes a moment, so triggers that come together meet it under way.
        await Task.yield()
        return answer
    }
}

/// The one check for the latest release by itself: when it reads the list and what it keeps.
@MainActor
struct ReleaseCheckTests {
    @Test func theListIsReadOnceAnHourAndAFailureKeepsWhatWasRead() async {
        let clock = TestClock()
        let list = ReleaseListStandIn(latest: "0.3.2", min: "0.3.0")
        let check = ReleaseCheck(fetch: { await list.fetch() }, now: { clock.now })
        #expect(check.latest == nil && !check.lastFailed)

        // Three triggers at once, then more within the hour: one read.
        async let first: Void = check.refresh()
        async let second: Void = check.refresh()
        async let third: Void = check.refresh()
        _ = await (first, second, third)
        #expect(list.fetches == 1)
        #expect(check.latest == LatestRelease(version: ReleaseVersion("0.3.2")!, minVersion: ReleaseVersion("0.3.0")!))
        clock.advance(by: ReleaseCheck.goodFor - 1)
        await check.refresh()
        #expect(list.fetches == 1)

        // After the hour it is read again, and a newer release replaces the result.
        clock.advance(by: 1)
        list.answer = .success(ReleaseListStandIn.release("0.4.0", min: "0.3.1"))
        await check.refresh()
        #expect(list.fetches == 2 && check.latest?.version == ReleaseVersion("0.4.0") && check.latest?.minVersion == ReleaseVersion("0.3.1"))

        // A failed read keeps the result, and the next one waits a few minutes.
        clock.advance(by: ReleaseCheck.goodFor)
        for fault in [ReleaseFault.unreachable, .expired, .untrusted] {
            list.answer = .failure(fault)
            let before = list.fetches
            await check.refresh()
            #expect(list.fetches == before + 1 && check.lastFailed && check.latest?.version == ReleaseVersion("0.4.0"))
            await check.refresh()
            clock.advance(by: ReleaseCheck.retryAfter - 1)
            await check.refresh()
            #expect(list.fetches == before + 1)
            clock.advance(by: 1)
        }
        list.answer = .success(ReleaseListStandIn.release("0.4.1"))
        let before = list.fetches
        await check.refresh()
        #expect(list.fetches == before + 1 && !check.lastFailed && check.latest?.version == ReleaseVersion("0.4.1"))
        // A good read starts the hour again.
        clock.advance(by: ReleaseCheck.retryAfter)
        await check.refresh()
        #expect(list.fetches == before + 1)
    }

    @Test func aReadIsDueByTheLastGoodOneAndTheLastFailedOne() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func due(good: TimeInterval?, failed: TimeInterval?) -> Bool {
            ReleaseCheck.isDue(now: now, fetchedAt: good.map { now.addingTimeInterval(-$0) }, failedAt: failed.map { now.addingTimeInterval(-$0) })
        }
        #expect(due(good: nil, failed: nil))
        #expect(!due(good: 0, failed: nil) && !due(good: 3599, failed: nil) && due(good: 3600, failed: nil))
        #expect(!due(good: nil, failed: 0) && !due(good: nil, failed: 299) && due(good: nil, failed: 300))
        // An old result and a fresh failure: not yet. A fresh result: not for an hour.
        #expect(!due(good: 7200, failed: 60) && due(good: 7200, failed: 600) && !due(good: 60, failed: 600))
        // A clock that was set back does not hold the next read off.
        #expect(due(good: -86_400, failed: nil) && due(good: nil, failed: -86_400))
        #expect(ReleaseCheck.goodFor == 3600 && ReleaseCheck.retryAfter == 300)
    }
}

/// The rows of Settings → Notifications against the app's one release result: `PushRegistrar`
/// with stand-ins for iOS, the gateway, the helpers and the release list.
@MainActor
struct LatestReleaseTests {
    private let a = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let b = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    /// The install sheets the registrar asked for.
    @MainActor
    final class Sheets {
        var shown: [(id: UUID, kind: SetupState.Kind)] = []
    }

    @MainActor
    private struct Setup {
        var world: PushWorld
        var phone: NotificationChoiceTests.Phone
        var list: ReleaseListStandIn
        var check: ReleaseCheck
        var push: PushRegistrar
        var sheets: Sheets
        /// Kept alive for the registrar, which only holds a closure over them.
        var servers: [ServerConnection]

        var helpers: HelperStandIn { world.helpers }
        var clock: TestClock { world.clock }

        func row(_ id: UUID) -> ComputerStatus? { push.status(for: id) }
    }

    private func line(_ text: String, _ tint: NotificationTint, spinner: Bool = false) -> NotificationLine {
        NotificationLine(text: text, tint: tint, spinner: spinner)
    }

    private let healthyMenu: [NotificationMenuItem] = [.sendTest, .showDetails, .reinstall, .remove]

    /// A phone with notifications on and one computer per version, in the order a, b.
    private func make(_ versions: [String], latest: String = "0.3.2", min: String = "0.3.0",
                      configure: (PushWorld) -> Void = { _ in }) -> Setup {
        let world = PushWorld()
        let ids = [a, b]
        let model = AppModel(prefs: world.prefs, connect: false)
        var servers: [ServerConnection] = []
        for (index, version) in versions.enumerated() {
            let name = index == 0 ? "Studio" : "Laptop"
            world.helpers.add(ids[index], name: name).version = version
            let server = ServerConnection(config: ServerConfig(id: ids[index], name: name, url: "https://\(name.lowercased())-rex.tail1.ts.net"),
                                          prefs: world.prefs, notifier: model.notifier, deviceID: "abcd1234")
            // A Mac and a Linux computer, where the installer can run.
            server.platform = index == 0 ? "darwin_arm64" : "linux_amd64"
            servers.append(server)
        }
        world.defaults.set(PushWorld.token, forKey: "pushToken.last")
        world.prefs.pushEnabled = true
        configure(world)
        let phone = NotificationChoiceTests.Phone()
        let list = ReleaseListStandIn(latest: latest, min: min)
        let check = ReleaseCheck(fetch: { await list.fetch() }, now: { [clock = world.clock] in clock.now })
        let push = PushRegistrar(prefs: world.prefs, deviceID: "abcd1234", environment: "sandbox", defaults: world.defaults,
                                 parts: world.parts, system: phone.system, release: check)
        let sheets = Sheets()
        push.servers = { servers }
        push.presentSetup = { id, kind in sheets.shown.append((id, kind)) }
        return Setup(world: world, phone: phone, list: list, check: check, push: push, sheets: sheets, servers: servers)
    }

    /// The same, once every add-on holds the phone and has said its version, and the release
    /// list was read.
    private func signedUp(_ versions: [String], latest: String = "0.3.2", min: String = "0.3.0",
                          configure: (PushWorld) -> Void = { _ in }) async -> Setup {
        let s = make(versions, latest: latest, min: min, configure: configure)
        await s.push.refresh()
        await s.world.eventually {
            s.list.fetches > 0 && s.servers.allSatisfy { s.push.versions[$0.id] != nil && s.push.reconciler.isSettled($0.id) }
        }
        await s.world.quiet()
        return s
    }

    // MARK: Rows

    @Test func twoComputersAreJudgedByTheOneReleaseList() async {
        // Each add-on has its own idea of the latest version, and both are wrong.
        let s = await signedUp(["0.3.1", "0.3.2"]) {
            $0.helpers[self.a].statusSays = ["update_available": false, "update_required": false, "latest_version": "0.3.1"]
            $0.helpers[self.b].statusSays = ["update_available": true, "update_required": true, "latest_version": "0.4.0",
                                             "last_error": "The release list could not be downloaded.", "failing_since": 1_700_000_000]
        }
        #expect(s.row(a) == ComputerStatus(switchOn: true, line: line("Update available", .secondary), fix: .update, menu: healthyMenu))
        #expect(s.row(b) == ComputerStatus(switchOn: true, line: line("Beacon 0.3.2", .secondary), fix: nil, menu: healthyMenu))
        #expect(s.push.computers.map(\.status) == [s.row(a), s.row(b)])
        // One read of the list for both.
        #expect(s.list.fetches == 1)

        // The same two add-ons without their opinions: the same rows.
        let plain = await signedUp(["0.3.1", "0.3.2"])
        #expect(plain.row(a) == s.row(a) && plain.row(b) == s.row(b))
    }

    @Test func belowTheOldestAllowedVersionTheAddOnNeedsAnUpdate() async {
        let s = await signedUp(["0.3.0", "0.3.1"], latest: "0.4.0", min: "0.3.1") {
            // It thinks it is fine.
            $0.helpers[self.a].statusSays = ["update_available": false, "update_required": false, "latest_version": "0.3.0"]
        }
        #expect(s.row(a) == ComputerStatus(switchOn: true, line: line("Beacon needs an update", .warning), fix: .update,
                                           menu: [.reinstall, .remove]))
        // At the oldest allowed version an update is only available.
        #expect(s.row(b)?.line == line("Update available", .secondary) && s.row(b)?.fix == .update)
    }

    @Test func aNewerAddOnThanTheListIsHealthy() async {
        let s = await signedUp(["0.3.3", "0.4.0-dev"])
        #expect(s.row(a) == ComputerStatus(switchOn: true, line: line("Beacon 0.3.3", .secondary), fix: nil, menu: healthyMenu))
        // A version that is not three numbers can't be compared: no claim.
        #expect(s.row(b)?.line == line("Beacon 0.4.0-dev", .secondary) && s.row(b)?.fix == nil)
    }

    @Test func withNoReleaseListTheRowsShowTheVersionOnly() async {
        let s = make(["0.3.0", "0.3.1"])
        s.list.answer = .failure(.unreachable)
        await s.push.refresh()
        await s.world.eventually { s.check.lastFailed && s.push.versions[self.a] != nil && s.push.versions[self.b] != nil }
        await s.world.quiet()
        #expect(s.list.fetches == 1 && s.check.latest == nil)
        // No claim about an update and no error line.
        #expect(s.row(a) == ComputerStatus(switchOn: true, line: line("Beacon 0.3.0", .secondary), fix: nil, menu: healthyMenu))
        #expect(s.row(b) == ComputerStatus(switchOn: true, line: line("Beacon 0.3.1", .secondary), fix: nil, menu: healthyMenu))
        #expect(s.push.master.line == nil)
    }

    @Test func aFailedReadKeepsTheRowsAsTheLastGoodOneLeftThem() async {
        let s = await signedUp(["0.3.1", "0.3.2"])
        let rows = [s.row(a), s.row(b)]
        s.push.start()
        await s.world.quiet()
        s.clock.advance(by: ReleaseCheck.goodFor)
        s.list.answer = .failure(.unreachable)
        s.push.becameActive()
        await s.world.eventually { s.check.lastFailed }
        #expect(s.list.fetches == 2 && [s.row(a), s.row(b)] == rows)
        #expect(s.row(a)?.line?.text == "Update available")
    }

    // MARK: When the list is read

    @Test func theListIsReadOnceForSeveralComputersAndTriggers() async {
        let s = await signedUp(["0.3.1", "0.3.2"])
        #expect(s.list.fetches == 1)
        // Launch, returns to the front, the master switch, a computer's switch, an add-on that
        // registers again: all within the hour.
        s.push.start()
        await s.world.quiet()
        for _ in 0..<3 {
            s.push.becameActive()
            await s.world.quiet()
        }
        s.push.setMaster(on: false)
        s.push.setMaster(on: true)
        s.push.setComputer(a, on: false)
        s.push.setComputer(a, on: true)
        s.push.helperClientChanged(b)
        await s.world.eventually { !s.helpers[self.a].paused && s.push.reconciler.isSettled(self.a) && s.push.reconciler.isSettled(self.b) }
        await s.world.quiet()
        #expect(s.list.fetches == 1)

        // After the hour, the next return to the front reads it again, once.
        s.clock.advance(by: ReleaseCheck.goodFor)
        s.list.answer = .success(ReleaseListStandIn.release("0.3.3"))
        s.push.becameActive()
        s.push.becameActive()
        await s.world.eventually { s.check.latest?.version == ReleaseVersion("0.3.3") }
        await s.world.quiet()
        #expect(s.list.fetches == 2)
        // Both rows follow the new result.
        #expect(s.row(a)?.line?.text == "Update available" && s.row(b)?.line?.text == "Update available")
    }

    @Test func nothingIsReadWhileNotificationsAreOffOrNoComputerIsListed() async {
        // The master switch is off.
        let off = make(["0.3.1"]) { $0.prefs.pushEnabled = false }
        await off.push.refresh()
        off.push.start()
        await off.world.quiet()
        off.push.becameActive()
        await off.world.quiet()
        #expect(off.list.fetches == 0 && off.check.latest == nil)
        // Turned on: now it is read.
        off.push.setMaster(on: true)
        await off.world.eventually { off.list.fetches == 1 }
        await off.world.quiet()
        #expect(off.list.fetches == 1)

        // iOS has notifications turned off: the computers are not listed.
        let denied = make(["0.3.1"])
        denied.phone.permission = .denied
        await denied.push.refresh()
        denied.push.start()
        await denied.world.quiet()
        denied.push.becameActive()
        await denied.world.quiet()
        #expect(denied.list.fetches == 0)

        // On, with no computer in the app.
        let empty = make([])
        await empty.push.refresh()
        empty.push.start()
        await empty.world.quiet()
        empty.push.becameActive()
        await empty.world.quiet()
        #expect(empty.list.fetches == 0)
    }

    #if DEBUG
    @Test func theSimulatedScreenReadsNothing() async {
        let s = make(["0.3.1"]) { $0.defaults.set("all", forKey: "simulateNotifications") }
        await s.push.refresh()
        s.push.start()
        await s.world.quiet()
        s.push.becameActive()
        s.push.setMaster(on: true)
        await s.world.quiet()
        #expect(s.list.fetches == 0 && s.helpers[a].calls.isEmpty && s.world.gateway.seen.isEmpty)
        #expect(s.push.computers[1].status.line?.text == "Update available")
    }
    #endif

    // MARK: Update

    @Test func updateAsksAnAddOnThatCanReplaceItselfOnce() async {
        let s = await signedUp(["0.3.1", "0.3.2"]) {
            $0.helpers[self.a].statusSays = ["can_update": true]
            $0.helpers[self.a].update = .starts(reaching: "0.3.2")
        }
        #expect(s.row(a)?.fix == .update)
        // The waits between two looks are the test's to end.
        s.clock.passes = false
        let statuses = s.helpers[a].count("helper_status")
        s.push.fix(.update, for: a)
        s.push.fix(.update, for: a)
        await s.world.eventually { s.helpers[self.a].count("update_helper") == 1 && s.clock.sleeps.last == HelperUpdate.askEvery }
        await s.world.quiet()
        // Working, with no button, until the add-on reports the new version.
        #expect(s.row(a) == ComputerStatus(switchOn: true, line: line("Updating…", .none, spinner: true), fix: nil, menu: [.reinstall, .remove]))
        #expect(s.helpers[a].count("helper_status") == statuses)
        s.push.fix(.update, for: a)

        s.clock.advance(by: HelperUpdate.askEvery)
        await s.world.eventually { s.push.updating.isEmpty }
        await s.world.quiet()
        // The next status says the new version, and that is the row.
        #expect(s.helpers[a].count("helper_status") == statuses + 1)
        #expect(s.row(a) == ComputerStatus(switchOn: true, line: line("Beacon 0.3.2", .secondary), fix: nil, menu: healthyMenu))
        #expect(s.helpers[a].count("update_helper") == 1 && s.sheets.shown.isEmpty)
        // The other computer was not asked for anything.
        #expect(s.helpers[b].count("update_helper") == 0)
        s.clock.release()
    }

    @Test func updateFallsBackToTheInstaller() async {
        // The add-on can't replace itself: the installer at once, and the add-on is not asked.
        let unable = await signedUp(["0.3.1"]) { $0.helpers[self.a].update = .starts(reaching: "0.3.2") }
        unable.push.fix(.update, for: a)
        await unable.world.quiet()
        #expect(unable.sheets.shown.map(\.id) == [a] && unable.sheets.shown.first?.kind == .repair)
        #expect(unable.helpers[a].count("update_helper") == 0 && unable.push.updating.isEmpty)

        // It can, and refuses, finds nothing to do, or does not know the question: one call,
        // then the installer.
        for answer in [HelperStandIn.Computer.Update.refuses, .nothingToDo, .unknown] {
            let s = await signedUp(["0.3.1"]) {
                $0.helpers[self.a].statusSays = ["can_update": true]
                $0.helpers[self.a].update = answer
            }
            s.push.fix(.update, for: a)
            await s.world.eventually { !s.sheets.shown.isEmpty }
            await s.world.quiet()
            #expect(s.helpers[a].count("update_helper") == 1, "\(answer)")
            #expect(s.sheets.shown.count == 1 && s.sheets.shown.first?.id == a && s.sheets.shown.first?.kind == .repair, "\(answer)")
            // The row is back at what the release list says of it.
            #expect(s.push.updating.isEmpty && s.row(a)?.line?.text == "Update available" && s.row(a)?.fix == .update, "\(answer)")
        }
    }

    @Test func anUpdateThatDoesNotArriveInTimeFallsBackToTheInstaller() async {
        // It says it started and stays at its version.
        let s = await signedUp(["0.3.1"]) {
            $0.helpers[self.a].statusSays = ["can_update": true]
            $0.helpers[self.a].update = .starts(reaching: nil)
        }
        let asked = s.clock.now
        s.push.fix(.update, for: a)
        await s.world.eventually { !s.sheets.shown.isEmpty }
        await s.world.quiet()
        #expect(s.helpers[a].count("update_helper") == 1)
        #expect(s.sheets.shown.count == 1 && s.sheets.shown.first?.id == a && s.sheets.shown.first?.kind == .repair)
        // Not before the limit, and not long after it.
        let waited = s.clock.now.timeIntervalSince(asked)
        #expect(waited >= HelperUpdate.limit && waited < HelperUpdate.limit + 2 * HelperUpdate.askEvery)
        #expect(s.push.updating.isEmpty && s.row(a)?.line?.text == "Update available")
    }

    @Test func aTooOldAddOnIsUpdatedBySelfOrByTheInstallerTheSameWay() async {
        // Below the oldest allowed version, and able to replace itself: asked, like any other.
        let s = await signedUp(["0.3.0"], latest: "0.4.0", min: "0.3.1") {
            $0.helpers[self.a].statusSays = ["can_update": true]
            $0.helpers[self.a].update = .starts(reaching: "0.4.0")
        }
        #expect(s.row(a)?.line == line("Beacon needs an update", .warning))
        s.push.fix(.update, for: a)
        await s.world.eventually { s.push.updating.isEmpty && s.push.versions[self.a]?.version == "0.4.0" }
        #expect(s.helpers[a].count("update_helper") == 1 && s.sheets.shown.isEmpty)
        #expect(s.row(a)?.line == line("Beacon 0.4.0", .secondary))
    }

    // MARK: An add-on that restarted

    @Test func aReplacedHelperClientBringsItsNewVersionWithoutATap() async {
        let s = await signedUp(["0.3.1", "0.3.2"])
        #expect(s.row(a)?.line?.text == "Update available")
        let statuses = s.helpers[a].count("helper_status"), fetches = s.list.fetches
        // The add-on updated itself and restarted: another client, the same secret, a new version.
        s.helpers[a].relay = "relay-2"
        s.helpers[a].version = "0.3.2"
        s.push.helperClientChanged(a)
        await s.world.eventually { s.push.versions[self.a]?.version == "0.3.2" && s.push.reconciler.isSettled(self.a) }
        await s.world.quiet()
        #expect(s.helpers[a].count("helper_status") == statuses + 1)
        #expect(s.row(a) == ComputerStatus(switchOn: true, line: line("Beacon 0.3.2", .secondary), fix: nil, menu: healthyMenu))
        // The release list was not read for it, and the other computer was left alone.
        #expect(s.list.fetches == fetches && s.sheets.shown.isEmpty)
        #expect(s.helpers[b].count("register_push") == 1)
    }

    @Test func aRestartTheAppMissedIsFoundOnTheReturnToTheFront() async {
        let s = await signedUp(["0.3.1", "0.3.2"])
        s.push.start()
        await s.world.quiet()
        let statusesA = s.helpers[a].count("helper_status"), statusesB = s.helpers[b].count("helper_status")
        // No event told the app.
        s.helpers[a].relay = "relay-2"
        s.helpers[a].version = "0.3.2"
        s.push.becameActive()
        await s.world.eventually { s.push.versions[self.a]?.version == "0.3.2" && s.push.reconciler.isSettled(self.a) }
        await s.world.quiet()
        #expect(s.helpers[a].count("helper_status") == statusesA + 1 && s.row(a)?.line?.text == "Beacon 0.3.2")
        // The add-on that did not restart says its version again, and keeps its registration.
        #expect(s.helpers[b].count("helper_status") == statusesB + 1 && s.helpers[b].count("register_push") == 1)
    }

    @Test func aStatusFromTheAddOnBeforeDoesNotOutliveARegistration() async {
        // The new add-on registers with its version, and its status does not come at first.
        let s = await signedUp(["0.3.1"])
        s.helpers[a].relay = "relay-2"
        s.helpers[a].version = "0.3.2"
        s.helpers[a].answersStatus = false
        s.push.helperClientChanged(a)
        await s.world.eventually { s.push.registeredVersions[self.a] == "0.3.2" }
        await s.world.quiet()
        #expect(s.push.versions[a] == nil && s.row(a)?.line?.text == "Beacon 0.3.2")
    }

    // MARK: Show Details

    @Test func detailsSayHowTheAppsCheckWent() async throws {
        let s = await signedUp(["0.3.1"]) {
            // The add-on's own check failed; that is not what the row is about.
            $0.helpers[self.a].statusSays = ["last_error": "The release list could not be downloaded.", "failing_since": 1_700_000_000]
        }
        let good = try #require(await s.push.details(for: a))
        #expect(good.rows() == [.init(label: "Beacon version", value: "0.3.1")])

        // The app's own read fails: the row says so, and the list's last good result stands.
        s.push.start()
        await s.world.quiet()
        s.clock.advance(by: ReleaseCheck.goodFor)
        s.list.answer = .failure(.unreachable)
        s.push.becameActive()
        await s.world.eventually { s.check.lastFailed }
        let failed = try #require(await s.push.details(for: a))
        #expect(failed.rows().last == .init(label: "Update check", value: "Couldn't check"))
        #expect(s.row(a)?.line?.text == "Update available")

        // It works again.
        s.clock.advance(by: ReleaseCheck.retryAfter)
        s.list.answer = .success(ReleaseListStandIn.release("0.3.2"))
        s.push.becameActive()
        await s.world.eventually { !s.check.lastFailed }
        let again = try #require(await s.push.details(for: a))
        #expect(again.rows().last == .init(label: "Beacon version", value: "0.3.1"))
    }
}
