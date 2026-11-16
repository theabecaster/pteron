import SwiftUI
import UserNotifications

@main
struct RexConnectApp: App {
    @State private var prefs: Prefs
    @State private var model: AppModel
    @Environment(\.scenePhase) private var phase

    init() {
        let prefs = Prefs.shared
        _prefs = State(initialValue: prefs)
        _model = State(initialValue: AppModel(prefs: prefs))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .launchTransition()
                .environment(model)
                .environment(prefs)
                .onAppear {
                    UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
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
