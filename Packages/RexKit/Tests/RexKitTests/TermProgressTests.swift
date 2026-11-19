import Foundation
import Testing
@testable import RexKit

/// `progress_report` payloads as Rex preview.21 sends them for OSC 9;4 (checked live in a zz
/// session: `9;4;1;300` arrives as 100, `9;4;1` as `set` with 0, `9;4;2` as `error` alone).
struct TermProgressTests {
    private func report(_ state: String?, _ progress: Any? = nil) -> TermProgress.Report? {
        var p: JSONObject = [:]
        if let state { p["state"] = state }
        if let progress { p["progress"] = progress }
        return TermProgress.Report(p)
    }

    @Test func aPercentIsClampedTo0Through100() throws {
        #expect(try #require(report("set", 255)).applied(to: nil) == TermProgress(state: .set, percent: 100))
        #expect(try #require(report("set", -4)).applied(to: nil) == TermProgress(state: .set, percent: 0))
        #expect(try #require(report("set", 42)).applied(to: nil)?.percent == 42)
    }

    @Test func setWithoutAPercentIsIndeterminate() throws {
        #expect(try #require(report("set")).applied(to: nil) == TermProgress(state: .indeterminate))
        #expect(try #require(report("set", NSNull())).applied(to: TermProgress(state: .set, percent: 30))
            == TermProgress(state: .indeterminate))
        #expect(try #require(report("indeterminate")).applied(to: TermProgress(state: .set, percent: 30))
            == TermProgress(state: .indeterminate))
    }

    @Test func pauseAndErrorKeepTheLastPercentWhenTheyGiveNone() throws {
        let at40 = TermProgress(state: .set, percent: 40)
        #expect(try #require(report("error")).applied(to: at40) == TermProgress(state: .error, percent: 40))
        #expect(try #require(report("pause")).applied(to: at40) == TermProgress(state: .pause, percent: 40))
        #expect(try #require(report("pause", 20)).applied(to: at40) == TermProgress(state: .pause, percent: 20))
        #expect(try #require(report("error")).applied(to: nil) == TermProgress(state: .error))
    }

    @Test func removeClears() throws {
        #expect(try #require(report("remove")).applied(to: TermProgress(state: .set, percent: 9)) == nil)
    }

    @Test func anUnknownOrMissingStateIsIgnored() {
        #expect(report("sparkle", 50) == nil)
        #expect(report(nil, 50) == nil)
    }
}
