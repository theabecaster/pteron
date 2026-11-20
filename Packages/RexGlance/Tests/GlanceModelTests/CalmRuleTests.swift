import Foundation
import Testing
@testable import GlanceModel

/// The widgets and the watch app never ask for attention. They are passive: no Live Activity, no
/// sound, haptic or notification, no reload beyond the one the throttle allows, and no delivery
/// to the watch beyond what `WatchDelivery` allows. The watch acts only when the person taps an
/// action and confirms it, and the phone then types once. A widget moves only once, when a new
/// entry changes a value, and only through `GlanceMotion`; complications don't move; the watch
/// app moves softly, and only as Reduce Motion and the wrist allow. These
/// tests read the sources of the widget path and the watch path, so a line that breaks the rule
/// fails here.
@Suite struct CalmRuleTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    /// Everything that draws a widget, builds the snapshot or writes it.
    private static let path = [
        "RexDuoWidgets", "Packages/RexGlance/Sources", "RexDuo/Features/Board/GlanceWatcher.swift",
        "RexDuo/State/GlanceWriter.swift", "RexDuo/State/GlanceReload.swift", "RexDuo/State/OpenPaneLink.swift",
        "RexDuo/State/GlanceBridge.swift", "RexDuo/State/GlanceActions.swift", "RexDuoWatch", "RexDuoWatchWidgets",
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

    /// What makes a view move. A file that holds none of these doesn't animate.
    private static let motion = [
        "withAnimation", ".animation(", "repeatForever", "symbolEffect", "contentTransition", "TimelineView",
        "phaseAnimator", "PhaseAnimator", "keyframeAnimator", "KeyframeAnimator", "Animation.", ".transition(",
        "matchedGeometryEffect", "navigationTransition", "Transaction", ".spring(", ".snappy(", ".bouncy(", ".smooth(",
        ".easeIn", ".easeOut", ".linear(", "interpolatingSpring",
    ]

    /// The watch app's one file that moves anything (docs/glance.md, The watch, Motion).
    private static let watchMotion = "RexDuoWatch/Views/WatchMotion.swift"

    /// What moves by itself or without end, or counts on screen: never in a widget, a
    /// complication or what they share, not even in `GlanceMotion`.
    private static let restless = [
        "repeatForever", ".repeating", "symbolEffect", "TimelineView", "phaseAnimator", "PhaseAnimator", "keyframeAnimator",
        "KeyframeAnimator", "withAnimation", "matchedGeometryEffect", "navigationTransition", "Transaction", "interpolatingSpring",
        ".spring(", ".bouncy(", ".snappy(", "Timer", "style: .timer", "style: .relative", ".timer", ".relative",
    ]

    /// The iPhone widget's one file that moves anything (docs/glance.md, The agents widget, Calm).
    private static let widgetMotion = "RexDuoWidgets/Views/GlanceMotion.swift"

    @Test func theWidgetsMoveOnlyOnceOnAChangeAndOnlyThroughGlanceMotion() throws {
        // The ring is still, and nothing repeats, pulses or counts by itself. What moves is the
        // system's change from one timeline entry to the next, and `GlanceMotion`'s three
        // motions tied to it. The watch's complications and the shared packages have none.
        let files = try Self.sources(["RexDuoWidgets", "RexDuoWatchWidgets", "Packages/RexGlance/Sources"])
        #expect(files.count > 15)
        #expect(files.contains { $0.name == Self.widgetMotion })
        for f in files {
            for word in Self.restless { #expect(!f.text.contains(word), "\(f.name) uses \(word)") }
            guard f.name != Self.widgetMotion else { continue }
            for word in Self.motion { #expect(!f.text.contains(word), "\(f.name) uses \(word)") }
        }
    }

    @Test func glanceMotionIsShortTiedToAValueAndStillWhenDimmed() throws {
        let text = try #require(try Self.sources([Self.widgetMotion]).first).text
        let lines = text.split(separator: "\n").map(String.init)
        // Every animation is tied to a value: it runs when that value changes, never by itself.
        let animations = lines.filter { $0.contains(".animation(") }
        #expect(!animations.isEmpty)
        for line in animations { #expect(line.contains(", value:"), "\(line)") }
        // At most 0.4 s.
        let durations = lines.compactMap { line -> Double? in
            guard let r = line.range(of: "duration: ") else { return nil }
            return Double(line[r.upperBound...].prefix { $0.isNumber || $0 == "." })
        }
        #expect(!durations.isEmpty && durations.allSatisfy { $0 <= 0.4 }, "\(durations)")
        // Only these motions: digits that roll, a push from below, and a fade for Reduce Motion.
        for word in [".push(", ".numericText(", ".opacity", ".identity"] { #expect(text.contains(word)) }
        for word in [".scale", ".move(", ".slide", ".offset(", "rotation", ".blurReplace", "symbolEffect"] {
            #expect(!text.contains(word), "GlanceMotion uses \(word)")
        }
        // Still with the screen dimmed (Always On) and where the system draws vibrant (StandBy
        // at night), and every modifier that moves asks the same value.
        #expect(text.contains("if luminanceReduced || mode == .vibrant {\n            self = .still"))
        let modifiers = text.components(separatedBy: ": ViewModifier").count - 1
        #expect(modifiers == 2)
        for read in ["@Environment(\\.accessibilityReduceMotion)", "@Environment(\\.isLuminanceReduced)", "@Environment(\\.widgetRenderingMode)",
                     "GlanceMotion(reduceMotion: reduceMotion, luminanceReduced: luminanceReduced, mode: mode)"] {
            #expect(text.components(separatedBy: read).count - 1 == modifiers, "\(read)")
        }
    }

    @Test func theWatchAppMovesOnlyThroughWatchMotion() throws {
        // Its views ask `WatchMotion`'s modifiers for every movement, so no animation can skip
        // Reduce Motion or the wrist.
        let files = try Self.sources(["RexDuoWatch"])
        #expect(files.contains { $0.name == Self.watchMotion })
        for f in files where f.name != Self.watchMotion {
            for word in Self.motion { #expect(!f.text.contains(word), "\(f.name) uses \(word)") }
        }
    }

    @Test func everyWatchAnimationChecksReduceMotionAndTheWrist() throws {
        let text = try #require(try Self.sources([Self.watchMotion]).first).text
        // The file in its declarations: each starts at a line that opens a type.
        var blocks: [[Substring]] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if ["struct ", "enum ", "extension ", "final class ", "private struct "].contains(where: line.hasPrefix) || blocks.isEmpty {
                blocks.append([])
            }
            blocks[blocks.count - 1].append(line)
        }
        var moving = 0
        for block in blocks {
            let body = block.joined(separator: "\n")
            guard Self.motion.contains(where: body.contains) else { continue }
            moving += 1
            let name = String(block.first { !$0.hasPrefix("///") && !$0.hasPrefix("import") && !$0.isEmpty } ?? "")
            if name.hasPrefix("enum WatchMotion") {
                // The values: one for each of full motion, Reduce Motion and the wrist down,
                // made only from the two settings.
                #expect(body.contains("init(reduceMotion: Bool, wristDown: Bool)"))
                for c in ["case full", "case fade", "case still"] { #expect(body.contains(c), "WatchMotion lacks \(c)") }
            } else {
                // A modifier that moves reads both settings and works its motion out from them.
                #expect(body.contains("@Environment(\\.accessibilityReduceMotion)"), "\(name) doesn't read Reduce Motion")
                #expect(body.contains("@Environment(\\.isLuminanceReduced)"), "\(name) doesn't read the wrist")
                #expect(body.contains("WatchMotion(reduceMotion: reduceMotion, wristDown: wristDown)"), "\(name) doesn't ask WatchMotion")
            }
        }
        #expect(moving >= 5)
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

    @Test func theWatchSendsThePhoneOnlyAConfirmedAction() throws {
        // One message goes from the watch: an action the person confirmed (`WatchSession.send`).
        // Nothing else is sent, nothing asks for a refresh, and no connection is opened.
        let never = ["transferUserInfo", "updateApplicationContext", "transferFile", "transferCurrentComplicationUserInfo",
                     "URLSession", "NWConnection", "openSystemURL"]
        let files = try Self.sources(Self.watch)
        #expect(files.count >= 8)
        for f in files {
            for word in never { #expect(!f.text.contains(word), "\(f.name) uses \(word)") }
        }
        let senders = files.filter { $0.text.contains("sendMessage") }
        #expect(senders.map(\.name) == ["RexDuoWatch/WatchSession.swift"])
        // One call, with a reply handler, and nothing sent as data.
        let session = try #require(senders.first).text
        #expect(session.components(separatedBy: "sendMessage(").count == 2)
        #expect(session.contains("sendMessage(WatchActionWire.message(action), replyHandler:"))
        #expect(!session.contains("sendMessageData"))
        // Only the model calls it, and only from `confirmed`.
        let callers = files.filter { $0.text.contains(".send($0)") || $0.text.contains("session.send(") }.map(\.name)
        #expect(callers == ["RexDuoWatch/RexDuoWatchApp.swift"])
    }

    @Test func nothingOnTheWatchSendsWithoutAConfirmation() throws {
        // The two buttons only ask. The question's own button is the one place that confirms,
        // and the model sends nothing a second time or by itself: no loop, no timer, no retry.
        let files = try Self.sources(Self.watch)
        let views = "RexDuoWatch/Views/WatchDetailView.swift"
        let pressers = files.filter { $0.text.contains("Button(") }.map(\.name)
        #expect(pressers == [views])
        #expect(files.filter { $0.text.contains("confirmationDialog") }.map(\.name) == [views])
        let text = try #require(files.first { $0.name == views }).text
        // Every button of the detail screen: the two that ask (one `ForEach`), the one that
        // confirms, Cancel.
        #expect(text.components(separatedBy: " Button(").count == 4)
        #expect(text.contains("ForEach(WatchAction.Kind.allCases") && text.contains("asking = kind") && text.contains("{ confirmed(kind) }") && text.contains("Button(\"Cancel\", role: .cancel) {}"))
        #expect(text.components(separatedBy: "confirmed(kind").count == 3)
        let model = try #require(files.first { $0.name == "RexDuoWatch/WatchActions.swift" }).text
        #expect(model.components(separatedBy: "await send(").count == 2)
        for word in ["while ", "for _", "for await", "repeat", "Timer", "Task.sleep", "retry"] { #expect(!model.contains(word), "WatchActions uses \(word)") }
        // No other control, and no shortcut that would fire an action without a look.
        let controls = ["TextField", "SecureField", "Toggle(", "Picker(", "Slider(", "Stepper(", "onTapGesture",
                        "digitalCrownRotation", "handGestureShortcut", "AppIntent", ".alert(", ".sheet(", "swipeActions", "onLongPressGesture"]
        for f in files {
            for word in controls { #expect(!f.text.contains(word), "\(f.name) uses \(word)") }
        }
    }

    @Test func thePhoneTakesOnlyAnActionFromTheWatchAndOnlyThroughTheBridge() throws {
        let files = try Self.sources(["RexDuo", "RexDuoWidgets"])
        let users = files.filter { $0.text.contains("WCSession.") || $0.text.contains("import WatchConnectivity") }.map(\.name)
        #expect(users == ["RexDuo/State/GlanceBridge.swift"])
        let bridge = try #require(files.first { $0.name == "RexDuo/State/GlanceBridge.swift" }).text
        // One message is handled, with a reply. No other is, and none is sent that would open the watch app.
        #expect(bridge.components(separatedBy: "didReceiveMessage").count == 2)
        #expect(bridge.contains("didReceiveMessage message: [String: Any], replyHandler:"))
        for word in ["didReceiveMessageData", "didReceiveUserInfo", "didReceiveApplicationContext", "didReceive file", "sendMessage", "AppModel("] {
            #expect(!bridge.contains(word), "the bridge uses \(word)")
        }
    }

    @Test func anActionThatWakesThePhoneStartsNoServerAndTypesOnce() throws {
        // The glance-widgets rule: a launch without a scene opens no full connection. What
        // answers the watch can't start a server, show a scene, ask for the server's events or
        // open a pane, and it has one place that types, called once. Its short connection
        // attaches to the one session of the pane, which Rex asks for, and to nothing else.
        let text = try #require(try Self.sources(["RexDuo/State/GlanceActions.swift"]).first).text
        #expect(text.components(separatedBy: "control.call(\"session.attach\", [\"session_id\": session])").count == 2)
        for word in ["sceneVisible", "startServer", ".start()", "rebuildServers", "session.bootstrap", "attach_all", "event_scope", "own_block", "data.connect",
                     "focus_block", "openPane", "clientLabel", "deviceID", "AppModel(", "model.", "UNUserNotificationCenter", "Notice."] {
            #expect(!text.contains(word), "GlanceActions uses \(word)")
        }
        #expect(text.components(separatedBy: "terminal.write\"").count == 2)
        #expect(text.components(separatedBy: "channel.write(").count == 2)
        #expect(text.components(separatedBy: ".sendOnce(").count == 2)
        // Nothing loops over a write.
        for word in ["while !", "while true", "for _", "repeat {", "retry("] { #expect(!text.contains(word), "GlanceActions uses \(word)") }
        // The connection made for a wake is labelled without the device id.
        let model = try #require(try Self.sources(["RexDuo/State/AppModel.swift"]).first).text
        let made = try #require(model.range(of: "OneShotActionChannel("))
        #expect(model[made.upperBound...].prefix(400).contains("PushIdentity.previewLabel("))
        // The root view of a launch made in the background starts no server either.
        let app = try #require(try Self.sources(["RexDuo/App/RexDuoApp.swift"]).first).text
        #expect(app.contains("if ScenePhases.appearedCounts(inBackground: UIApplication.shared.applicationState == .background) {\n                            model.sceneVisible()"))
        #expect(app.components(separatedBy: "model.sceneVisible()").count == 3)
        // Nor does it write a snapshot: nothing new is known.
        let watcher = try #require(try Self.sources(["RexDuo/Features/Board/GlanceWatcher.swift"]).first).text
        #expect(watcher.contains("guard model.mayConnect else { return }"))
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
