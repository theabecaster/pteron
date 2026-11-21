import SwiftUI
import UIKit

@main
struct RexDuoApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var prefs: Prefs
    @State private var model: AppModel
    /// Takes the system's crash and hang reports for as long as the app runs.
    private let diagnosticReports: DiagnosticReportsSubscriber?
    @Environment(\.scenePhase) private var phase

    /// Unit tests run inside this app. The test host must not connect: fit mode would claim and
    /// resize real panes on the owner's servers.
    static let isTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    init() {
        #if DEBUG || BENCH
        PerfProbe.cleanUpIfAsked()
        PortsLoop.runIfAsked()
        #endif
        // Copies of files a crash or a kill left on their way to or from a pane.
        FileStaging.clearAll()
        let prefs = Prefs.shared
        _prefs = State(initialValue: prefs)
        // An offline replay or demo has no server either.
        let connect = !Self.isTestHost && !Self.runsOffline
        let log = connect ? ConnectionDiagnostics.launchLog() : nil
        // Crash and hang reports are taken from the first moment; the system hands over the
        // ones of earlier launches then.
        diagnosticReports = connect ? DiagnosticReportsSubscriber(reports: .standard) : nil
        diagnosticReports?.start()
        // A shared diagnostics file a kill left behind, off the launch path.
        Task.detached(priority: .utility) { ConnectionDiagnostics.clearShareFile() }
        let model = AppModel(prefs: prefs, connect: connect, log: log)
        _model = State(initialValue: model)
        // For an action on a notification in a launch that never shows a view.
        AppDelegate.launching(with: model)
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
                RootView(launchHold: model.launchHold)
                    .launchTransition()
                    .agentToasts()
                    .environment(model)
                    .environment(prefs)
                    // A view that appears is a scene on screen: the servers start here too, in
                    // case no change of phase ever arrives (`sceneVisible` acts once). Not in a
                    // launch the system made in the background, which builds the scene as well.
                    .onAppear {
                        if ScenePhases.appearedCounts(inBackground: UIApplication.shared.applicationState == .background) {
                            model.sceneVisible()
                        }
                        appDelegate.attach(model)
                    }
                    // Links from the controls (`rexduo:`, navigation only). The test host and
                    // the offline screens take none.
                    .onOpenURL { model.openLink($0) }
            }
        }
        .commands {
            if !Self.isTestHost { AppShortcutCommands(model: model) }
        }
        // `initial`: the phase the scene starts in counts too (old and new are then the same).
        .onChange(of: phase, initial: true) { old, p in
            guard !Self.isTestHost else { return }
            ConnectionDiagnostics.phaseChanged(p, log: model.connectionLog)
            for step in ScenePhases.steps(for: p, initial: old == p) {
                switch step {
                case .sceneVisible:
                    model.sceneVisible()
                case .foreground:
                    readSystemScheme()
                    model.foregroundResumed()
                case .background:
                    model.enteredBackground()
                    model.push.enteredBackground()
                }
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
