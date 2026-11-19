import Foundation
import Testing
import RexKit
@testable import RexDuo

private func alert(_ block: String, at date: Date = Date(timeIntervalSince1970: 1000), title: String = "Claude has a question") -> AgentAlert {
    AgentAlert(serverID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, sessionID: "session:s",
               windowID: "window:w", blockID: block, title: title, body: "api › work", date: date)
}

struct ToastPolicyTests {
    let now = Date(timeIntervalSince1970: 1000)

    private func decide(_ a: AgentAlert, _ ctx: ToastPolicy.Context = .init(), current: AgentToast? = nil,
                        lastShown: [String: Date] = [:]) -> ToastPolicy.Decision {
        ToastPolicy.decide(a, context: ctx, current: current, lastShown: lastShown, now: now)
    }

    @Test func showsForAPaneTheUserIsNotLookingAt() {
        guard case .show(let t) = decide(alert("block:a"), .init(visibleBlocks: ["block:b"])) else {
            Issue.record("expected a toast"); return
        }
        #expect(t.alert.blockID == "block:a")
        #expect(t.others.isEmpty)
    }

    @Test func suppressedWhileLookingAtThatPane() {
        #expect(decide(alert("block:a"), .init(visibleBlocks: ["block:a"])) == .suppress(.looking))
    }

    @Test func suppressedInTheBackground() {
        #expect(decide(alert("block:a"), .init(appActive: false)) == .suppress(.background))
    }

    @Test func suppressedWhileTheAgentBoardShows() {
        #expect(decide(alert("block:a"), .init(boardShowing: true)) == .suppress(.board))
        // Also under a sheet: it is not held to show over the board later.
        #expect(decide(alert("block:a"), .init(modalPresented: true, boardShowing: true)) == .suppress(.board))
        // In the background the helper pushes, board or not.
        #expect(decide(alert("block:a"), .init(appActive: false, boardShowing: true)) == .suppress(.background))
    }

    @Test func heldWhileASheetCoversTheScreen() {
        #expect(decide(alert("block:a"), .init(modalPresented: true)) == .hold)
        // Looking at the pane wins: a sheet can't hide a pane the user is reading.
        #expect(decide(alert("block:a"), .init(visibleBlocks: ["block:a"], modalPresented: true)) == .suppress(.looking))
    }

    @Test func aSecondAlertUpdatesTheToastInsteadOfStacking() {
        let first = AgentToast(id: UUID(), alert: alert("block:a"), others: [])
        guard case .update(let t) = decide(alert("block:b", title: "Codex needs permission"), current: first) else {
            Issue.record("expected an update"); return
        }
        #expect(t.id == first.id)
        #expect(t.alert.blockID == "block:b")
        #expect(t.others == ["block:a"])
        // The first pane alerts again: it becomes the main one and leaves the count.
        guard case .update(let t2) = decide(alert("block:a"), current: t) else { Issue.record("expected an update"); return }
        #expect(t2.alert.blockID == "block:a")
        #expect(t2.others == ["block:b"])
    }

    @Test func samePaneUpdatesInPlace() {
        let first = AgentToast(id: UUID(), alert: alert("block:a"), others: [])
        guard case .update(let t) = decide(alert("block:a", title: "Claude needs permission"), current: first) else {
            Issue.record("expected an update"); return
        }
        #expect(t.others.isEmpty)
        #expect(t.alert.title == "Claude needs permission")
    }

    @Test func aFlappingPaneDoesNotToastAgainWithinTheCooldown() {
        let recent = now.addingTimeInterval(-(ToastPolicy.cooldown - 1))
        #expect(decide(alert("block:a"), lastShown: ["block:a": recent]) == .suppress(.recentlyShown))
        let old = now.addingTimeInterval(-(ToastPolicy.cooldown + 1))
        if case .show = decide(alert("block:a"), lastShown: ["block:a": old]) {} else { Issue.record("expected a toast") }
        // Other panes aren't held back.
        if case .show = decide(alert("block:b"), lastShown: ["block:a": recent]) {} else { Issue.record("expected a toast") }
    }

    @Test func heldAlertsKeepTheNewestPerPaneAndExpire() {
        var held: [AgentAlert] = []
        held = ToastPolicy.hold(alert("block:a", title: "old"), in: held)
        held = ToastPolicy.hold(alert("block:b"), in: held)
        held = ToastPolicy.hold(alert("block:a", title: "new"), in: held)
        #expect(held.map(\.blockID) == ["block:b", "block:a"])
        #expect(held.last?.title == "new")

        let a = alert("block:a", at: now)
        #expect(ToastPolicy.worthOfferingAgain(a, stillWaiting: true, now: now.addingTimeInterval(10)))
        #expect(!ToastPolicy.worthOfferingAgain(a, stillWaiting: false, now: now.addingTimeInterval(10)))
        #expect(!ToastPolicy.worthOfferingAgain(a, stillWaiting: true, now: now.addingTimeInterval(ToastPolicy.holdLimit + 1)))
    }
}

struct PushRouteTests {
    @Test func parsesTheHelpersPayload() {
        let info: [AnyHashable: Any] = [
            "aps": ["alert": ["title": "Claude · api"], "category": "AGENT_BLOCKED", "thread-id": "block:b"],
            "server": "https://office-mac-rex.tail1234.ts.net",
            "session_id": "session:s", "window_id": "window:w", "block_id": "block:b",
        ]
        #expect(PushRoute(userInfo: info) == PushRoute(server: "https://office-mac-rex.tail1234.ts.net",
                                                       sessionID: "session:s", windowID: "window:w", blockID: "block:b"))
    }

    @Test func windowIsOptional() {
        let r = PushRoute(userInfo: ["server": "https://a.ts.net", "session_id": "session:s", "block_id": "block:b"])
        #expect(r?.windowID == nil)
        #expect(r?.blockID == "block:b")
    }

    @Test func rejectsPushesWithoutServerOrSession() {
        #expect(PushRoute(userInfo: ["session_id": "session:s"]) == nil)
        #expect(PushRoute(userInfo: ["server": "https://a.ts.net"]) == nil)
        #expect(PushRoute(userInfo: ["server": "", "session_id": "session:s"]) == nil)
        #expect(PushRoute(userInfo: ["server": 3, "session_id": "session:s"]) == nil)
    }

    @Test func matchesTheServerByHost() {
        let r = PushRoute(server: "https://Office-Mac-Rex.tail1234.ts.net", sessionID: "session:s")
        #expect(r.matches(serverURL: "https://office-mac-rex.tail1234.ts.net/", hostName: nil))
        #expect(r.matches(serverURL: "office-mac-rex.tail1234.ts.net", hostName: nil))
        #expect(r.matches(serverURL: "https://typo", hostName: "office-mac-rex.tail1234.ts.net."))
        #expect(!r.matches(serverURL: "https://devbox.tail1234.ts.net", hostName: "devbox.tail1234.ts.net"))
    }
}

struct PushSupportTests {
    @Test func deviceIDIsEightLowercaseHex() {
        let id = PushIdentity.deviceID(vendorID: UUID(uuidString: "A1B2C3D4-0000-0000-0000-000000000000"))
        #expect(id == "a1b2c3d4")
        #expect(PushIdentity.deviceID(vendorID: nil).count == 8)
    }

    @Test func labelEndsWithTheDeviceIDAndFitsRex() {
        #expect(PushIdentity.clientLabel(deviceName: "Alex's iPhone", deviceID: "a1b2c3d4") == "Alex's iPhone #a1b2c3d4")
        let long = PushIdentity.clientLabel(deviceName: String(repeating: "ñ", count: 60), deviceID: "a1b2c3d4")
        #expect(long.utf8.count <= PushIdentity.maxLabelBytes)
        #expect(long.hasSuffix(" #a1b2c3d4"))
        #expect(PushIdentity.clientLabel(deviceName: "  ", deviceID: "a1b2c3d4") == "iPhone #a1b2c3d4")
    }

    @Test func tokenIsHex() {
        #expect(PushIdentity.hex(Data([0x00, 0xab, 0x10, 0xff])) == "00ab10ff")
    }

    private func profile(_ entitlements: String) -> Data {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict><key>Entitlements</key><dict>\(entitlements)</dict></dict></plist>
        """
        // The real file wraps the plist in binary CMS data.
        return Data([0x30, 0x82, 0x01, 0x00]) + Data(plist.utf8) + Data([0xa0, 0x82, 0x00])
    }

    @Test func apnsEnvironmentFollowsTheProfile() {
        let dev = profile("<key>aps-environment</key><string>development</string>")
        let prod = profile("<key>aps-environment</key><string>production</string>")
        #expect(APNsEnvironment.detect(profile: dev, isSimulator: false) == "sandbox")
        #expect(APNsEnvironment.detect(profile: prod, isSimulator: false) == "production")
        // TestFlight and App Store builds carry no profile.
        #expect(APNsEnvironment.detect(profile: nil, isSimulator: false) == "production")
        #expect(APNsEnvironment.detect(profile: nil, isSimulator: true) == "sandbox")
        #expect(APNsEnvironment.detect(profile: profile("<key>get-task-allow</key><true/>"), isSimulator: false) == "sandbox")
        #expect(APNsEnvironment.detect(profile: Data("garbage".utf8), isSimulator: false) == "production")
    }

    @Test func findsTheLastLiveRelayOnTheServersOwnMachine() {
        let peer: JSONObject = ["kind": "peer", "uid": 501]
        let clients: [JSONObject] = [
            ["client_id": "client:old", "info": ["name": "rex-push-relay"], "principal": peer, "connection_state": "connected"],
            ["client_id": "client:phone", "info": ["name": "Rex DUO"], "principal": ["kind": "tailscale"]],
            ["client_id": "client:new", "info": ["name": "rex-push-relay"], "principal": peer],
            ["client_id": "client:lost", "info": ["name": "rex-push-relay"], "principal": peer, "connection_state": "lost"],
        ]
        #expect(RelayLookup.relayID(in: clients) == "client:new")
        #expect(RelayLookup.relayID(in: [clients[1]]) == nil)
        let windows: JSONObject = ["client_id": "client:win", "info": ["name": "rex-push-relay"], "principal": ["kind": "windows_peer", "sid": "S-1-5-21"]]
        #expect(RelayLookup.relayID(in: [windows]) == "client:win")
    }

    @Test func aClientOfThatNameFromTheTailnetIsNotTheHelper() {
        let peer: JSONObject = ["client_id": "client:real", "info": ["name": "rex-push-relay"], "principal": ["kind": "peer", "uid": 501]]
        let remote: JSONObject = ["client_id": "client:fake", "info": ["name": "rex-push-relay"],
                                  "principal": ["kind": "tailscale", "user_id": "1234"]]
        let anonymous: JSONObject = ["client_id": "client:anon", "info": ["name": "rex-push-relay"], "principal": ["kind": "anonymous"]]
        let unsaid: JSONObject = ["client_id": "client:bare", "info": ["name": "rex-push-relay"]]
        // Connected last, so it would win on order alone.
        #expect(RelayLookup.relayID(in: [peer, remote, anonymous, unsaid]) == "client:real")
        #expect(RelayLookup.relayID(in: [remote, anonymous, unsaid]) == nil)
    }
}
