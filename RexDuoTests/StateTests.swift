import Foundation
import SwiftUI
import Testing
import RexKit
@testable import RexDuo

@MainActor
struct PrefsTests {
    private func fresh() -> (Prefs, UserDefaults) {
        let name = "RexDuoTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return (Prefs(defaults: d), d)
    }

    @Test func defaults() {
        let (p, _) = fresh()
        #expect(p.sizing == .fit)
        #expect(p.fontSize == 11)
        #expect(p.keyBarLayout == .agents)
        #expect(p.darkThemeID == "github-dark-dimmed")
        #expect(p.lightThemeID == "github-light-default")
        #expect(!p.pushEnabled)
        // A fresh install starts with no servers, in every build.
        #expect(p.servers.isEmpty)
    }

    @Test func keepsSavedServersAndAnEmptyList() {
        let (p, d) = fresh()
        p.servers = [ServerConfig(name: "Studio", url: "https://studio-rex.tail1234.ts.net")]
        #expect(Prefs(defaults: d).servers.map(\.url) == ["https://studio-rex.tail1234.ts.net"])
        p.servers = []
        #expect(Prefs(defaults: d).servers.isEmpty)
    }

    @Test func persistsToItsOwnDefaults() {
        let (p, d) = fresh()
        p.fontSize = 14
        p.keyBarLayout = .vim
        p.servers = [ServerConfig(name: "Mac", url: "https://mac.tail.ts.net")]
        let again = Prefs(defaults: d)
        #expect(again.fontSize == 14)
        #expect(again.keyBar == KeyBarLayout.vim.keys)
        #expect(again.servers.map(\.url) == ["https://mac.tail.ts.net"])
    }

    @Test func themeFollowsTheSystemNotTheViewsScheme() {
        let (p, _) = fresh()
        p.darkThemeID = "github-dark-dimmed"
        p.lightThemeID = "github-light-default"
        p.systemScheme = .light
        #expect(p.theme.id == "github-light-default")
        // The root forces views to the theme's scheme; that must not flip the theme back.
        #expect(p.theme(for: .dark).id == "github-light-default")
        p.systemScheme = .dark
        #expect(p.theme(for: .light).id == "github-dark-dimmed")
    }

    @Test func migratesRemovedSettings() {
        let (_, d) = fresh()
        d.set("whitby-bay", forKey: "themeID")
        d.set(false, forKey: "followSystem")
        d.set(KeyBarLayout.shell.keys, forKey: "keyBar")
        d.set(["studio": "https://studio.tail.ts.net"], forKey: "hostURLs")
        for key in ["sizing", "wideLayout", "haptics", "showAgentStatus", "notifyOnBlocked", "sidebarTextSize"] {
            d.set("x", forKey: key)
        }
        let p = Prefs(defaults: d)
        // One theme everywhere stays one theme everywhere.
        #expect(p.lightThemeID == "whitby-bay")
        #expect(p.keyBarLayout == .shell)
        #expect(p.servers.contains { $0.name == "studio" && $0.id == AppModel.stableID("studio") })
        #expect(p.sizing == .fit)
        for key in ["followSystem", "keyBar", "hostURLs", "sizing", "wideLayout", "haptics", "showAgentStatus",
                    "notifyOnBlocked", "sidebarTextSize"] {
            #expect(d.object(forKey: key) == nil, "\(key)")
        }
    }

    @Test func editedKeyBarFallsBackToTheDefaultLayout() {
        let (_, d) = fresh()
        d.set(["esc", "f1"], forKey: "keyBar")
        #expect(Prefs(defaults: d).keyBarLayout == .agents)
    }

    @Test func serverAddresses() {
        #expect(ServerConfig.url(from: " studio.tail1.ts.net ")?.absoluteString == "https://studio.tail1.ts.net")
        #expect(ServerConfig.url(from: "http://127.0.0.1:8765")?.absoluteString == "http://127.0.0.1:8765")
        #expect(ServerConfig.url(from: "") == nil)
        #expect(ServerConfig.url(from: "ftp://studio") == nil)
        #expect(ServerConfig.url(from: "two words") == nil)
        #expect(ServerConfig.name(for: URL(string: "https://studio.tail1.ts.net")!) == "studio")
        #expect(ServerConfig.name(for: URL(string: "http://127.0.0.1:8765")!) == "127.0.0.1")
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
        let model = AppModel(prefs: Prefs(defaults: UserDefaults(suiteName: "RexDuoTests.model")!), connect: false)
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
