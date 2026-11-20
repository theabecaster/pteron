import RexKit
import SwiftUI
import Testing
import UIKit
@testable import RexDuo

/// The Agents sheet: one way to open it, when it stays shut, and rows that are the sidebar's
/// Agents mode's own, read and tapped as VoiceOver would.
@MainActor
@Suite(.serialized) struct AgentsSheetTests {
    private func model() throws -> AppModel {
        let suite = "agents-sheet-\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: suite))
        d.removePersistentDomain(forName: suite)
        let m = AppModel(prefs: Prefs(defaults: d), connect: false)
        m.firstSeenWaiting = { [:] }
        return m
    }

    /// A server with one session: tab w1 holds b1 (waiting) and b2 (working), tab w2 holds b3
    /// (waiting). Each pane has a title of its own, so every row reads differently.
    private func server(_ m: AppModel) -> ServerConnection {
        let s = ServerConnection(config: ServerConfig(name: "desk", url: "https://desk-rex.tail1234.ts.net"),
                                 prefs: m.prefs, notifier: m.notifier, deviceID: "a1b2c3d4")
        m.servers.append(s)
        let tabs = ["w1": ["b1", "b2"], "w2": ["b3"]]
        let windows = tabs.keys.sorted().map { w -> JSONObject in
            ["window_id": w, "layers": [["kind": "tiled", "blocks": (tabs[w] ?? []).map {
                ["block_id": $0, "creator_name": "com.superlogical.terminal"] as JSONObject
            }] as JSONObject]]
        }
        s.sessions = [SessionEntry(id: "s1", label: "s1")]
        s.views = ["s1": SessionView(["revision": 1, "session_id": "s1", "active_window_id": "w1", "windows": windows])]
        for b in ["b1", "b2", "b3"] {
            var meta = BlockMeta()
            meta.title = "task \(b)"
            meta.statuses = ["claude": ProgramStatus(["id": "claude", "app": "claude", "state": b == "b2" ? "working" : "blocked"])]
            s.meta[b] = meta
        }
        s.phase = .online
        s.synced = true
        s.agentsWereRead()
        return s
    }

    @Test func showAgentsOpensTheSheet() throws {
        let m = try model()
        #expect(!m.agentsShown)
        m.showAgents()
        #expect(m.agentsShown)
        AgentsSheet.picked(m)
        #expect(!m.agentsShown, "an agent picked closes it")
    }

    @Test func itStaysShutUnderSettingsOrTheScanner() throws {
        let m = try model()
        m.showSettings = true
        m.showAgents()
        #expect(!m.agentsShown)
        m.showSettings = false
        m.showPairing = true
        m.showAgents()
        #expect(!m.agentsShown)
    }

    @Test func aHelperInstallWaitsForTheSheet() throws {
        let m = try model()
        m.showAgents()
        #expect(m.helperSetup.sheetIsUp())
        m.agentsShown = false
        #expect(!m.helperSetup.sheetIsUp())
    }

    /// The agents' rows as VoiceOver reads them, once each, in order.
    private func rows(in window: UIWindow) -> [String] {
        var seen = Set<String>()
        return Hosted.accessibilityElements(in: window).compactMap(\.accessibilityLabel)
            .filter { $0.contains("task b") && seen.insert($0).inserted }
    }

    /// The sheet shows the sidebar's Agents mode: the same rows in the same order. Then a tap on
    /// a row opens its pane and closes the sheet.
    @Test func theSheetsRowsAreTheSidebars() async throws {
        try #require(Hosted.setAccessibility(on: true), "the simulator's accessibility runtime")
        defer { _ = Hosted.setAccessibility(on: false) }
        let m = try model()
        let s = server(m)
        #expect(s.agentKeys.count == 3)

        let sidebar = Hosted.window(SidebarView(mode: .constant(.agents), onSelect: { _ in })
            .environment(m).environment(m.prefs))
        _ = await Hosted.settle { rows(in: sidebar).count == 3 }
        let sidebarRows = rows(in: sidebar)
        sidebar.isHidden = true

        m.showAgents()
        let sheet = Hosted.window(AgentsSheet().environment(m).environment(m.prefs))
        defer { sheet.isHidden = true }
        _ = await Hosted.settle { rows(in: sheet).count == 3 }
        let sheetRows = rows(in: sheet)
        #expect(sidebarRows.count == 3)
        #expect(sheetRows == sidebarRows)
        // Waiting first, then working.
        #expect(sheetRows.first?.contains("Waiting") == true && sheetRows.last?.contains("Working") == true)

        // A tap on the working agent's row, as VoiceOver's double-tap gives it.
        let working = try #require(Hosted.accessibilityElements(in: sheet).first {
            $0.accessibilityLabel?.contains("task b2") == true && $0.accessibilityTraits.contains(.button)
        })
        #expect(working.accessibilityActivate())
        _ = await Hosted.settle { !m.agentsShown }
        #expect(m.selection == Selection(serverID: s.id, sessionID: "s1", windowID: "w1"))
        #expect(m.focusedPane["w1"] == "b2")
        #expect(!m.agentsShown, "the sheet closed")
    }

    @Test func theEmptySheetSaysWhatTheSidebarSays() async throws {
        try #require(Hosted.setAccessibility(on: true), "the simulator's accessibility runtime")
        defer { _ = Hosted.setAccessibility(on: false) }
        let m = try model()
        let sheet = Hosted.window(AgentsSheet().environment(m).environment(m.prefs))
        defer { sheet.isHidden = true }
        let empty = await Hosted.settle {
            Hosted.accessibilityElements(in: sheet).contains { $0.accessibilityLabel?.hasPrefix("No agents are running.") == true }
        }
        #expect(empty)
        let title = await Hosted.settle {
            Hosted.navigationController(in: sheet.rootViewController)?.topViewController?.navigationItem.title == "Agents"
        }
        #expect(title)
    }
}
