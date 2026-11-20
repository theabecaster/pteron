import Foundation
import Testing
@testable import GlanceModel

/// The widgets never ask for attention. They are passive: no Live Activity, no sound, haptic or
/// notification, no motion of their own, and no reload beyond the one the throttle allows. These
/// tests read the sources of the widget path, so a line that breaks the rule fails here.
@Suite struct CalmRuleTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    /// Everything that draws a widget, builds the snapshot or writes it.
    private static let path = [
        "RexDuoWidgets", "Packages/RexGlance/Sources", "RexDuo/Features/Board/GlanceWatcher.swift",
        "RexDuo/State/GlanceWriter.swift", "RexDuo/State/GlanceReload.swift", "RexDuo/State/OpenPaneLink.swift",
    ]

    private static func sources(_ paths: [String], ext: Set<String> = ["swift"]) throws -> [(name: String, text: String)] {
        var out: [(String, String)] = []
        for p in paths {
            let url = root.appendingPathComponent(p)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
                Issue.record("missing \(p)")
                continue
            }
            let files = isDir.boolValue
                ? (FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? [])
                : [url]
            for f in files where ext.contains(f.pathExtension) {
                out.append((f.path.replacingOccurrences(of: root.path + "/", with: ""), try String(contentsOf: f, encoding: .utf8)))
            }
        }
        return out
    }

    @Test func theWidgetPathMakesNoSoundHapticNotificationOrLiveActivity() throws {
        let banned = [
            "ActivityKit", "ActivityConfiguration", "UNUserNotificationCenter", "UNMutableNotificationContent",
            "FeedbackGenerator", "AVFoundation", "AudioToolbox", "AudioServices", "CoreHaptics",
            "BGTaskScheduler", "TipKit",
        ]
        let files = try Self.sources(Self.path)
        #expect(files.count > 20)
        for f in files {
            for word in banned { #expect(!f.text.contains(word), "\(f.name) uses \(word)") }
        }
    }

    @Test func theWidgetsHaveNoMotionOfTheirOwn() throws {
        // The ring is still, and nothing repeats, pulses or animates: the only motion is the
        // system's own when a timeline entry replaces another.
        let banned = [
            "withAnimation", ".animation(", "repeatForever", "symbolEffect", "contentTransition", "TimelineView",
            "phaseAnimator", "keyframeAnimator", "Animation.",
        ]
        for f in try Self.sources(["RexDuoWidgets", "Packages/RexGlance/Sources/GlanceUI"]) {
            for word in banned { #expect(!f.text.contains(word), "\(f.name) uses \(word)") }
        }
    }

    @Test func noTargetDeclaresLiveActivities() throws {
        for f in try Self.sources(["RexDuo/Info.plist", "RexDuoWidgets/Info.plist", "project.yml"], ext: ["plist", "yml"]) {
            #expect(!f.text.contains("NSSupportsLiveActivities"), "\(f.name)")
        }
    }

    @Test func oneCallReloadsTheWidgetsAndOnlyTheirOwnKind() throws {
        // `GlanceReload`, which only `GlanceWriter` is given, and `WriteThrottle` says when.
        let files = try Self.sources(["RexDuo", "RexDuoWidgets", "Packages/RexGlance/Sources"])
        #expect(files.allSatisfy { !$0.text.contains("reloadAllTimelines") })
        let callers = files.filter { $0.text.contains("reloadTimelines(") }.map(\.name)
        #expect(callers == ["RexDuo/State/GlanceReload.swift"])
    }

    @Test func nothingInTheAppAsksForAWidgetToBeAdded() throws {
        // The app only writes the file and answers the links: no banner, tip, sheet or Settings row.
        for f in try Self.sources(["RexDuo/Features", "RexDuo/App", "RexDuo/DesignSystem"]) {
            let text = f.text.lowercased()
            for phrase in ["add widget", "add a widget", "add the widget", "widget gallery"] {
                #expect(!text.contains(phrase), "\(f.name) says \(phrase)")
            }
        }
    }

    @Test func theReloadRateIsBounded() {
        // A picture that changes on every tick, for an hour in front: one reload each 10 s at most.
        var throttle = WriteThrottle<Int>()
        var reloads = 0, now = Date(timeIntervalSince1970: 0), key = 0
        let end = now.addingTimeInterval(3600)
        while now < end {
            key += 1
            throttle.changed(newWaiting: true, now: now)
            if throttle.fire(now: now, key: key, active: true, anyLive: true).reload { reloads += 1 }
            now.addTimeInterval(0.25)
        }
        #expect(reloads <= 360)
        #expect(WriteThrottle<Int>.reloadEvery == 10)
    }

    @Test func theStaleLinesAreQuietAndNameTheAppFromBrand() throws {
        #expect(GlanceDigest.refreshText == "Open \(Brand.appName) to refresh")
        // An old snapshot dims and glows no color, whoever waits in it.
        let now = Date(timeIntervalSince1970: 1_000_000)
        let old = GlanceDigest(try #require(GlanceDemo.snapshot("old", now: now)), now: now)
        #expect(old.dimmed && old.glow == nil && old.age == GlanceDigest.Age.refresh)
    }
}
