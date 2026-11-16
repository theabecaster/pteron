import SwiftUI
import UserNotifications

@main
struct RexDuoApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var phase
    static let underTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    var body: some Scene {
        WindowGroup {
            // Offline replay of a capture file (development): `-ghosttyDemo <path>`.
            if let demo = GhosttyDemo.path {
                GhosttyDemoScreen(path: demo).ignoresSafeArea()
            } else if Self.underTest {
                // Unit tests host in the app. Show nothing, so no real pane is ever opened.
                Color.clear
            } else {
            RootView()
                .launchTransition()
                .environment(model)
                .onAppear {
                    UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
                }
            }
        }
        .onChange(of: phase) { _, p in
            if p == .active { model.foregroundResumed() }
        }
    }
}

final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationDelegate()
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }
}
