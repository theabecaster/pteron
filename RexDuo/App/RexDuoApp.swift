import SwiftUI
import UserNotifications

@main
struct RexDuoApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            // Offline replay of a capture file (development): `-ghosttyDemo <path>`.
            if let demo = GhosttyDemo.path {
                GhosttyDemoScreen(path: demo).ignoresSafeArea()
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
