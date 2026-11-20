import Foundation
import Testing
@testable import GlanceModel

/// The widgets and the watch app never ask for attention. They are passive: no Live Activity, no
/// sound, haptic or notification, no motion of their own, no reload beyond the one the throttle
/// allows, and no delivery to the watch beyond what `WatchDelivery` allows. These tests read the
/// sources of the widget path and the watch path, so a line that breaks the rule fails here.
@Suite struct CalmRuleTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    /// Everything that draws a widget, builds the snapshot or writes it.
    private static let path = [
        "RexDuoWidgets", "Packages/RexGlance/Sources", "RexDuo/Features/Board/GlanceWatcher.swift",
        "RexDuo/State/GlanceWriter.swift", "RexDuo/State/GlanceReload.swift", "RexDuo/State/OpenPaneLink.swift",
        "RexDuo/State/GlanceBridge.swift", "RexDuoWatch", "RexDuoWatchWidgets",
    ]

    /// Everything that runs on the watch.
    private static let watch = ["RexDuoWatch", "RexDuoWatchWidgets"]

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
            // The watch's haptics and sounds, and the ways a watch app keeps itself running.
            "WKInterfaceDevice", "WKHapticType", ".play(", "sensoryFeedback", "WKExtendedRuntimeSession",
            "scheduleBackgroundRefresh", "scheduleSnapshotRefresh", "WKBackgroundModes", "HKWorkoutSession",
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
        for f in try Self.sources(["RexDuoWidgets", "Packages/RexGlance/Sources/GlanceUI"] + Self.watch) {
            for word in banned { #expect(!f.text.contains(word), "\(f.name) uses \(word)") }
        }
    }

    @Test func noTargetDeclaresLiveActivities() throws {
        let lists = ["RexDuo/Info.plist", "RexDuoWidgets/Info.plist", "RexDuoWatch/Info.plist", "RexDuoWatchWidgets/Info.plist", "project.yml"]
        for f in try Self.sources(lists, ext: ["plist", "yml"]) {
            #expect(!f.text.contains("NSSupportsLiveActivities"), "\(f.name)")
            // Nor a background mode: nothing of ours runs unless the system starts it for a delivery.
            #expect(!f.text.contains("WKBackgroundModes"), "\(f.name)")
        }
    }

    @Test func oneCallReloadsTheWidgetsAndOnlyTheirOwnKind() throws {
        // `GlanceReload`, which only `GlanceWriter` is given, and `WriteThrottle` says when.
        // On the watch: `WatchReload`, called only after a delivery replaced the file.
        let files = try Self.sources(["RexDuo", "RexDuoWidgets", "Packages/RexGlance/Sources"] + Self.watch)
        #expect(files.allSatisfy { !$0.text.contains("reloadAllTimelines") })
        let callers = files.filter { $0.text.contains("reloadTimelines(") }.map(\.name).sorted()
        #expect(callers == ["RexDuo/State/GlanceReload.swift", "RexDuoWatch/WatchReload.swift"])
    }

    @Test func theWatchNeverSendsToThePhone() throws {
        // v1 only shows. With nothing sent from the watch, it can't wake the phone or act on a session.
        let sends = ["sendMessage", "transferUserInfo", "updateApplicationContext", "transferFile", "transferCurrentComplicationUserInfo",
                     "URLSession", "NWConnection", "openSystemURL"]
        let files = try Self.sources(Self.watch)
        #expect(files.count >= 8)
        for f in files {
            for word in sends { #expect(!f.text.contains(word), "\(f.name) uses \(word)") }
        }
    }

    @Test func theWatchAppHasNoControlAndNoInput() throws {
        // A view of the agents: nothing to press but a row, which opens its detail screen.
        let controls = ["Button(", "TextField", "SecureField", "Toggle(", "Picker(", "Slider(", "Stepper(", "onTapGesture",
                        "digitalCrownRotation", "handGestureShortcut", "AppIntent", "confirmationDialog", ".alert(", ".sheet("]
        for f in try Self.sources(Self.watch) {
            for word in controls { #expect(!f.text.contains(word), "\(f.name) uses \(word)") }
        }
    }

    @Test func thePhoneOnlySendsThroughTheBridgeAndTakesNothingBack() throws {
        let files = try Self.sources(["RexDuo", "RexDuoWidgets"])
        let users = files.filter { $0.text.contains("WCSession.") || $0.text.contains("import WatchConnectivity") }.map(\.name)
        #expect(users == ["RexDuo/State/GlanceBridge.swift"])
        let bridge = try #require(files.first { $0.name == "RexDuo/State/GlanceBridge.swift" }).text
        // No message from the watch is handled, and none is sent that would open the watch app.
        for word in ["didReceiveMessage", "didReceiveUserInfo", "didReceiveApplicationContext", "sendMessage", "AppModel("] {
            #expect(!bridge.contains(word), "the bridge uses \(word)")
        }
    }

    @Test func nothingInTheAppMentionsTheWatch() throws {
        // No prompt to install or open the watch app, and no Settings row: the iPhone app looks the same.
        for f in try Self.sources(["RexDuo/Features", "RexDuo/App", "RexDuo/DesignSystem"]) {
            let text = f.text.lowercased()
            for phrase in ["apple watch", "watch app", "your watch", "on the watch", "complication"] {
                #expect(!text.contains(phrase), "\(f.name) says \(phrase)")
            }
        }
    }

    @Test func theWatchsStaleLinesAreQuietAndNameTheAppFromBrand() throws {
        #expect(WatchText.open == "Open \(Brand.appName) on iPhone")
        #expect(WatchText.refresh == "Open \(Brand.appName) on iPhone to refresh")
        let now = Date(timeIntervalSince1970: 1_000_000)
        let old = WatchScreen(.snapshot(try #require(GlanceDemo.snapshot("old", now: now))), now: now)
        // Dimmed, dated, no running clock, and nothing raised in the Smart Stack.
        #expect(old.dimmed && old.age == .refresh && old.rows.allSatisfy(\.lastKnown))
        #expect(GlanceDigest(try #require(GlanceDemo.snapshot("old", now: now)), now: now).relevance == 0)
    }

    @Test func theDeliveryRateToTheWatchIsBounded() {
        // The same bound as `WatchDeliveryTests`, held here with the other calm rules: who waits
        // changes on every write for an hour with the app in front, and at most 120 deliveries go.
        var delivery = WatchDelivery()
        var sends = 0, now = Date(timeIntervalSince1970: 0), flip = false
        let end = now.addingTimeInterval(3600)
        while now < end {
            flip.toggle()
            var s = GlanceDemo.snapshot(flip ? "one" : "several", now: Date(timeIntervalSince1970: 0))!
            s.asOf = now
            if delivery.offer(s, reason: .wrote, link: .init(ready: true), now: now).context { sends += 1 }
            now.addTimeInterval(0.5)
        }
        #expect(sends <= 120)
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
