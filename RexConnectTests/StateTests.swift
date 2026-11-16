import Foundation
import SwiftUI
import Testing
import RexKit
@testable import RexConnect

@MainActor
struct PrefsTests {
    private func fresh() -> (Prefs, UserDefaults) {
        let name = "RexConnectTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return (Prefs(defaults: d), d)
    }

    @Test func defaults() {
        let (p, _) = fresh()
        #expect(p.sizing == .fit)
        #expect(p.fontSize == 11)
        #expect(p.keyBar == KeyBarPreset.agents.keys)
        #expect(p.haptics)
    }

    @Test func persistsToItsOwnDefaults() {
        let (p, d) = fresh()
        p.fontSize = 14
        p.sizing = .mirror
        p.servers = [ServerConfig(name: "Mac", url: "https://mac.tail.ts.net")]
        let again = Prefs(defaults: d)
        #expect(again.fontSize == 14)
        #expect(again.sizing == .mirror)
        #expect(again.servers.map(\.url) == ["https://mac.tail.ts.net"])
    }

    @Test func lightThemeOnlyWhenFollowingTheSystem() {
        let (p, _) = fresh()
        p.themeID = "github-dark-dimmed"
        p.lightThemeID = "github-light-default"
        #expect(p.theme(for: .light).id == "github-dark-dimmed")
        p.followSystemAppearance = true
        #expect(p.theme(for: .light).id == "github-light-default")
        #expect(p.theme(for: .dark).id == "github-dark-dimmed")
    }
}

@MainActor
struct AppModelTests {
    @Test func stableIDIsDeterministicAndDistinct() {
        #expect(AppModel.stableID("studio") == AppModel.stableID("studio"))
        #expect(AppModel.stableID("studio") != AppModel.stableID("studoi"))
        #expect(AppModel.stableID("ab") != AppModel.stableID("ba"))
    }

    @Test func doesNotConnectWhenAskedNotTo() {
        let model = AppModel(prefs: Prefs(defaults: UserDefaults(suiteName: "RexConnectTests.model")!), connect: false)
        #expect(model.servers.isEmpty)
    }
}

@MainActor
struct AgentNotifierTests {
    @Test func hapticIsThrottled() {
        var now = Date(timeIntervalSince1970: 1000)
        let n = AgentNotifier(now: { now })
        #expect(n.shouldBuzz())
        now += 1
        #expect(!n.shouldBuzz())
        now += AgentNotifier.hapticInterval
        #expect(n.shouldBuzz())
        #expect(!n.shouldBuzz())
    }
}

struct ProcessLabelTests {
    @Test func scriptThenArgv0ThenName() {
        #expect(ServerConnection.processLabel(["script": "/usr/local/bin/claude", "name": "node"]) == "claude")
        #expect(ServerConnection.processLabel(["argv0": "-zsh", "name": "zsh"]) == "zsh")
        #expect(ServerConnection.processLabel(["invoked_path": "/opt/bin/codex"]) == "codex")
        #expect(ServerConnection.processLabel(["name": "vim"]) == "vim")
        #expect(ServerConnection.processLabel([:]) == "")
    }
}
