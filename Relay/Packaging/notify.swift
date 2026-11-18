// rex-duo-notify: posts a desktop notification as Rex DUO Beacon. It sits next to the helper in
// the app bundle (Contents/MacOS), so macOS attributes what it posts to the app: its name, its
// icon, its row in System Settings > Notifications. The helper decides when and what to post
// (Relay/src/notice.rs); this only talks to the system.
//
//   rex-duo-notify authorize              ask for permission if it hasn't been decided yet
//   rex-duo-notify post -- <title> <body>  post one notification
//   rex-duo-notify status                  print allowed, denied or undetermined; never asks
//
// Exit status: 0 done, 1 not allowed or failed, 2 bad usage or not inside an app bundle.

import Foundation
import UserNotifications

@main
enum Notify {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())

        // UNUserNotificationCenter raises an exception in a process that has no app bundle.
        guard Bundle.main.bundleIdentifier != nil, Bundle.main.bundleURL.pathExtension == "app" else { exit(2) }

        // The permission question waits for the person. Don't wait for ever.
        DispatchQueue.global().asyncAfter(deadline: .now() + 300) { exit(1) }

        let center = UNUserNotificationCenter.current()
        switch arguments.first {
        case "authorize":
            exit(await allowed(center) ? 0 : 1)
        case "status":
            // Only reads the setting. The helper reports it to the phone (helper_status).
            switch await status(center) {
            case .authorized, .provisional: print("allowed")
            case .denied: print("denied")
            case .notDetermined: print("undetermined")
            default: exit(1)
            }
            exit(0)
        case "post":
            let texts = Array(arguments.dropFirst().drop { $0 != "--" }.dropFirst())
            guard texts.count == 2 else { exit(2) }
            guard await allowed(center) else { exit(1) }
            let content = UNMutableNotificationContent()
            content.title = texts[0]
            content.body = texts[1]
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            let posted: Bool = await withCheckedContinuation { done in
                center.add(request) { error in done.resume(returning: error == nil) }
            }
            exit(posted ? 0 : 1)
        default:
            exit(2)
        }
    }

    /// What the person has decided about notifications from Rex DUO Beacon, without asking.
    static func status(_ center: UNUserNotificationCenter) async -> UNAuthorizationStatus {
        await withCheckedContinuation { done in
            center.getNotificationSettings { done.resume(returning: $0.authorizationStatus) }
        }
    }

    /// True when notifications are allowed, asking first if the person hasn't decided.
    static func allowed(_ center: UNUserNotificationCenter) async -> Bool {
        switch await status(center) {
        case .authorized, .provisional:
            return true
        case .notDetermined:
            return await withCheckedContinuation { done in
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in done.resume(returning: granted) }
            }
        default:
            return false
        }
    }
}
