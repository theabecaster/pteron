import Foundation
import SwiftUI
import Testing
@testable import RexDuo

/// A launch opens no connection until a scene shows: the servers are built at `init` and
/// started at the first `.inactive` or `.active` scene phase, once. A launch iOS makes in the
/// background gets no scene phase, so it starts none.
@MainActor
@Suite struct LaunchTests {
    /// A model as the app builds it (`connect: true`) over two saved servers, with every start
    /// recorded instead of made.
    private func model() throws -> (AppModel, started: () -> [String]) {
        let suite = "launch-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let prefs = Prefs(defaults: defaults)
        prefs.servers = [ServerConfig(name: "desk", url: "https://desk-rex.tail1234.ts.net"),
                         ServerConfig(name: "laptop", url: "https://laptop-rex.tail1234.ts.net")]
        let m = AppModel(prefs: prefs, connect: true)
        final class Record { var names: [String] = [] }
        let record = Record()
        m.startServer = { record.names.append($0.config.name) }
        return (m, { record.names })
    }

    @Test func eachPhaseAsksForItsSteps() {
        #expect(ScenePhases.steps(for: .inactive) == [.sceneVisible])
        #expect(ScenePhases.steps(for: .active) == [.sceneVisible, .foreground])
        #expect(ScenePhases.steps(for: .background) == [.background])
    }

    /// The scene's first phase, with no change event before or after it, is enough.
    @Test func thePhaseASceneStartsInStartsTheServersWithNoChangeEvent() throws {
        #expect(ScenePhases.steps(for: .inactive, initial: true) == [.sceneVisible])
        #expect(ScenePhases.steps(for: .active, initial: true) == [.sceneVisible, .foreground])
        // Starting in the background is no move to the background: nothing is flushed or told.
        #expect(ScenePhases.steps(for: .background, initial: true).isEmpty)
        let (m, started) = try model()
        for step in ScenePhases.steps(for: .inactive, initial: true) where step == .sceneVisible { m.sceneVisible() }
        #expect(m.mayConnect && started() == ["desk", "laptop"])
        // The root view appearing asks again: nothing starts twice.
        m.sceneVisible()
        #expect(started() == ["desk", "laptop"])
    }

    @Test func buildingTheModelStartsNoServer() throws {
        let (m, started) = try model()
        #expect(m.servers.map(\.config.name) == ["desk", "laptop"])
        #expect(!m.mayConnect && started().isEmpty)
        // Nothing has been asked of either connection.
        #expect(m.servers.allSatisfy { $0.phase == .idle && $0.connectionSerial == 0 })
    }

    /// iOS prewarms the app, or wakes it for a message: no scene, so no phase but perhaps
    /// `.background`. Nothing connects, however long it lasts.
    @Test func aBackgroundLaunchStartsNoServer() throws {
        let (m, started) = try model()
        for step in ScenePhases.steps(for: .background) where step == .sceneVisible { m.sceneVisible() }
        #expect(!m.mayConnect && started().isEmpty)
        // A server list that changes meanwhile starts nothing either.
        m.rebuildServers()
        #expect(m.addServer(ServerConfig(name: "mini", url: "https://mini-rex.tail1234.ts.net")))
        #expect(m.servers.count == 3 && started().isEmpty)
    }

    /// The system builds the scene of an app it launched in the background too (to hand it an
    /// action from the watch): the root view appears, and that alone starts nothing.
    @Test func theRootViewAppearingInTheBackgroundStartsNoServer() throws {
        #expect(!ScenePhases.appearedCounts(inBackground: true))
        #expect(ScenePhases.appearedCounts(inBackground: false))
        let (m, started) = try model()
        if ScenePhases.appearedCounts(inBackground: true) { m.sceneVisible() }
        #expect(!m.mayConnect && started().isEmpty)
        // Brought to the front later, its first visible phase starts them.
        for step in ScenePhases.steps(for: .inactive) where step == .sceneVisible { m.sceneVisible() }
        #expect(started() == ["desk", "laptop"])
    }

    @Test func theFirstVisiblePhaseStartsEveryServerOnce() throws {
        let (m, started) = try model()
        for phase in [ScenePhase.background, .inactive, .active, .inactive, .active] {
            for step in ScenePhases.steps(for: phase) where step == .sceneVisible { m.sceneVisible() }
        }
        #expect(m.mayConnect && started() == ["desk", "laptop"])
    }

    @Test func activeAloneStartsThemToo() throws {
        let (m, started) = try model()
        #expect(ScenePhases.steps(for: .active).first == .sceneVisible)
        m.sceneVisible()
        m.sceneVisible()
        #expect(started() == ["desk", "laptop"])
    }

    @Test func onceASceneHasShownANewServerStartsAtOnce() throws {
        let (m, started) = try model()
        m.sceneVisible()
        #expect(m.addServer(ServerConfig(name: "mini", url: "https://mini-rex.tail1234.ts.net")))
        // As before the change: a rebuild asks every server, and one that runs only retries.
        #expect(started() == ["desk", "laptop", "desk", "laptop", "mini"])
    }

    @Test func aModelForTestsBuildsNoServersAndWritesNoSnapshot() throws {
        let suite = "launch-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let prefs = Prefs(defaults: defaults)
        prefs.servers = [ServerConfig(name: "desk", url: "https://desk-rex.tail1234.ts.net")]
        let m = AppModel(prefs: prefs, connect: false)
        m.sceneVisible()
        #expect(m.servers.isEmpty && m.glance.mode == .off)
    }
}
