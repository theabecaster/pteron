import SwiftUI
import UIKit

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
        // An offline replay or demo has no server either.
        _model = State(initialValue: AppModel(prefs: prefs, connect: !Self.isTestHost && !Self.runsOffline))
    }

    /// A launch argument asked for an offline screen instead of the app: `-replay <file>` (Debug
    /// and benchmark builds) or `-ghosttyDemo <path>` (Debug builds). Never in a shipped app.
    private static var runsOffline: Bool {
        #if DEBUG || BENCH
        if ReplayConfig.current != nil { return true }
        #endif
        #if DEBUG
        if GhosttyDemo.path != nil { return true }
        #endif
        return false
    }

    /// The offline screen a launch argument asked for, if any.
    @ViewBuilder private var offlineScreen: some View {
        #if DEBUG || BENCH
        if let replay = ReplayConfig.current {
            // Offline replay through a real TerminalHost: `-replay <file>`.
            ReplayScreen(config: replay).ignoresSafeArea()
        }
        #endif
        #if DEBUG
        if ReplayConfig.current == nil, let demo = GhosttyDemo.path {
            // Offline replay of a capture file (development): `-ghosttyDemo <path>`.
            GhosttyDemoScreen(path: demo).ignoresSafeArea()
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            if Self.runsOffline {
                offlineScreen
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
        .commands {
            if !Self.isTestHost { AppShortcutCommands(model: model) }
        }
        .onChange(of: phase) { _, p in
            guard !Self.isTestHost else { return }
            switch p {
            case .active:
                readSystemScheme()
                model.foregroundResumed()
            case .background: model.push.enteredBackground()
            default: break
            }
        }
    }

    /// Picks up Light or Dark Mode from the screen: SwiftUI puts the root's forced color scheme on
    /// the window scene, so the scene and every view report the theme's mode, not the system's, and
    /// get no trait change when the system's flips. Changing it means leaving the app (Control
    /// Center or Settings), so reading it each time the app becomes active is enough.
    private func readSystemScheme() {
        let screens = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }
        guard let style = screens.first?.traitCollection.userInterfaceStyle, style != .unspecified else { return }
        let scheme: ColorScheme = style == .light ? .light : .dark
        if prefs.systemScheme != scheme { prefs.systemScheme = scheme }
    }
}
