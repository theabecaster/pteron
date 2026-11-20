import Foundation
import Testing
@testable import GlanceModel

/// What the watch shows for each state of the snapshot.
@Suite struct WatchScreenTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func screen(_ name: String) -> WatchScreen {
        WatchScreen(GlanceDemo.snapshot(name, now: now).map(GlanceReading.snapshot) ?? .missing, now: now)
    }

    @Test func noSnapshotAsksForTheAppOnThePhone() {
        let s = WatchScreen(.missing, now: now)
        #expect(s.kind == .message("Open \(Brand.appName) on iPhone"))
        #expect(s.rows.isEmpty && s.machines.isEmpty && s.age == nil && !s.dimmed)
        #expect(s.palette == .standardDark)
    }

    @Test func aNewerSnapshotShowsThePlaceholder() {
        #expect(WatchScreen(GlanceReading(GlanceDemo.newerFile), now: now).kind == .message(WatchText.open))
    }

    @Test func noServersSaysSo() {
        #expect(screen("unpaired").kind == .message("No machines paired"))
    }

    @Test func aMachineNeverReachedIsThePlaceholder() {
        let s = GlanceSnapshot(seq: 1, asOf: now, palette: .standard, machines: [
            .init(id: "m", name: "Mini", link: .never, counts: .init(), waiting: [], seen: nil)])
        #expect(WatchScreen(.snapshot(s), now: now).kind == .message(WatchText.open))
    }

    @Test func waitingAgentsAreListedLongestWaitFirstWithTheAppsWords() {
        let s = screen("several")
        #expect(s.kind == .agents)
        #expect(s.headline == .text("2 need you") && s.urgency == .waiting)
        #expect(s.rows.map(\.name) == ["Claude", "Aider"])
        #expect(s.rows.map(\.words) == ["Needs permission", "Has a question"])
        #expect(s.rows[0].place == "api › tests" && s.rows[0].machine == "Studio" && s.rows[0].listedMachine == nil)
        #expect(s.rows[0].since == now.addingTimeInterval(-12 * 60))
        #expect(s.rows.allSatisfy { !$0.lastKnown })
        #expect(s.machineLine == nil && s.age == nil && !s.dimmed && s.more == 0)
        #expect(s.machines.map(\.words) == ["2 waiting · 1 error · 3 working · 1 done · 4 idle"])
    }

    @Test func theWordsForEveryReason() {
        #expect(WatchScreen.words(why: "permission") == "Needs permission")
        #expect(WatchScreen.words(why: "question") == "Has a question")
        #expect(WatchScreen.words(why: "auth") == "Needs password")
        #expect(WatchScreen.words(why: nil) == "Waiting for you")
        #expect(WatchScreen.words(why: "something new") == "Waiting for you")
    }

    @Test func quietAndWorkingListNoAgentsAndOneCountsRow() {
        let q = screen("quiet")
        #expect(q.headline == .text("All quiet") && q.rows.isEmpty && q.machines.map(\.words) == ["4 idle"])
        let w = screen("working")
        #expect(w.headline == .text("3 working") && w.urgency == .working && w.rows.isEmpty)
    }

    @Test func severalMachinesNameEachRowAndGetALine() {
        let s = screen("machines")
        #expect(s.machineLine == "2 of 3 machines connected")
        #expect(s.rows.map(\.listedMachine) == ["Studio", "Laptop"])
        // The machine never reached has no counts row.
        #expect(s.machines.map(\.name) == ["Studio", "Laptop"])
    }

    @Test func everyListedAgentShowsAndTheRestAreCounted() {
        let s = screen("many")
        #expect(s.rows.count == 8 && s.more == 3)
        #expect(s.rows.map(\.since) == s.rows.map(\.since).sorted())
    }

    @Test func aDownMachinesAgentsAreLastKnown() {
        let s = screen("stale")
        #expect(s.headline == .lastSeen(now.addingTimeInterval(-25 * 60)) && s.urgency == .offline)
        #expect(s.rows.count == 1 && s.rows[0].lastKnown && s.rows[0].machine == "Laptop")
        #expect(s.machines.map(\.dimmed) == [false, false, true])
        let off = screen("offline")
        #expect(off.dimmed && off.rows[0].lastKnown && off.machines[0].dimmed)
    }

    @Test func anAgingSnapshotIsDatedAndAnOldOneDimsAndAsksForThePhone() {
        let aging = screen("aging")
        #expect(aging.age == .asOf(now.addingTimeInterval(-600)) && !aging.dimmed && !aging.rows[0].lastKnown)
        let old = screen("old")
        #expect(old.age == .refresh && old.dimmed)
        #expect(old.rows.allSatisfy(\.lastKnown) && old.machines.allSatisfy(\.dimmed))
        #expect(WatchText.refresh == "Open \(Brand.appName) on iPhone to refresh")
    }

    @Test func theScreenIsWorkedOutAgainWhenTheAgeChangesWhatShows() throws {
        let fresh = GlanceReading.snapshot(try #require(GlanceDemo.snapshot("one", now: now)))
        #expect(WatchScreen.nextChange(fresh, after: now) == now.addingTimeInterval(GlanceFreshness.agingAfter))
        #expect(WatchScreen.nextChange(fresh, after: now.addingTimeInterval(200)) == now.addingTimeInterval(GlanceFreshness.staleAfter))
        #expect(WatchScreen.nextChange(fresh, after: now.addingTimeInterval(4000)) == nil)
        #expect(WatchScreen.nextChange(.missing, after: now) == nil)
        #expect(WatchScreen.nextChange(.newer, after: now) == nil)
    }

    // MARK: Privacy

    @Test func theMessageIsHiddenWithTheWristDown() {
        let row = screen("one").rows[0]
        #expect(row.message(wristDown: false) == "Run `npm test` in api?")
        #expect(row.message(wristDown: true) == nil)
    }

    @Test func anAgentThatSaidNothingHasNoMessage() {
        var s = GlanceDemo.snapshot("one", now: now)!
        s.machines[0].waiting[0].msg = nil
        #expect(WatchScreen(.snapshot(s), now: now).rows[0].message(wristDown: false) == nil)
        s.machines[0].waiting[0].msg = ""
        #expect(WatchScreen(.snapshot(s), now: now).rows[0].message(wristDown: false) == nil)
    }

    // MARK: Colors

    @Test func theWatchTakesTheDarkSlotOnlyWhenItIsADarkTheme() {
        var custom = GlancePalette.standardDark
        custom.bg = "#101010"
        #expect(WatchScreen.palette(.init(dark: custom, light: .standardLight)) == custom)
        // A light theme chosen for Dark Mode can't be read on the watch's black.
        #expect(WatchScreen.palette(.init(dark: .standardLight, light: .standardLight)) == .standardDark)
        #expect(WatchScreen.palette(nil) == .standardDark)
        #expect(screen("light-in-dark").palette == .standardDark)
    }

    // MARK: Smart Stack

    @Test func onlyACurrentWaitRaisesTheWidget() {
        func relevance(_ name: String) -> Float {
            GlanceDigest(GlanceDemo.snapshot(name, now: now).map(GlanceReading.snapshot) ?? .missing, now: now).relevance
        }
        #expect(relevance("one") == 1 && relevance("several") == 2 && relevance("many") == 10)
        for quiet in ["quiet", "working", "old", "offline", "stale", "unpaired", "none"] { #expect(relevance(quiet) == 0, "\(quiet)") }
    }
}
