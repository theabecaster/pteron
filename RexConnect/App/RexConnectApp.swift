import SwiftUI

@main
struct RexConnectApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var prefs: Prefs
    @State private var model: AppModel
    @Environment(\.scenePhase) private var phase

    /// Unit tests run inside this app. The test host must not connect: fit mode would claim and
    /// resize real panes on the owner's servers.
    static let isTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    init() {
        let prefs = Prefs.shared
        _prefs = State(initialValue: prefs)
        // An offline replay (`-replay <file>`) has no server either.
        _model = State(initialValue: AppModel(prefs: prefs, connect: !Self.isTestHost && ReplayConfig.current == nil))
    }

    var body: some Scene {
        WindowGroup {
            // Offline replay of a capture file (development): `-ghosttyDemo <path>`.
            if let replay = ReplayConfig.current {
                // Offline replay through a real TerminalHost, either engine: `-replay <file>`.
                ReplayScreen(config: replay).ignoresSafeArea()
            } else if let demo = GhosttyDemo.path {
                GhosttyDemoScreen(path: demo).ignoresSafeArea()
            } else if Self.isTestHost {
                // Show nothing, so no real pane is ever opened.
                Color.clear
            } else {
                RootView()
                    .launchTransition()
                    .agentToasts()
                    .environment(model)
                    .environment(prefs)
                    .onAppear { appDelegate.attach(model) }
            }
        }
        .onChange(of: phase) { _, p in
            guard !Self.isTestHost else { return }
            switch p {
            case .active: model.foregroundResumed()
            case .background: model.push.enteredBackground()
            default: break
            }
        }
    }
}
