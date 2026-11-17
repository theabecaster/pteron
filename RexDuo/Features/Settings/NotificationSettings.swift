import SwiftUI
import UIKit

/// Settings → Notifications: one toggle for push, and a quiet line when something stands in the way
/// (iOS permission, the Rex Connect Helper on each computer). In-app banners for waiting agents are always on.
struct NotificationSettingsSection: View {
    @Environment(AppModel.self) private var model
    @Environment(Prefs.self) private var prefs
    @Environment(\.openURL) private var openURL
    let theme: TermTheme

    var body: some View {
        let push = model.push
        let denied = push.authorization == .denied
        Section {
            Toggle("Allow Notifications", isOn: Binding(
                get: { prefs.pushEnabled && !denied },
                set: { $0 ? push.enable() : push.disable() }))
                .disabled(denied)
            if denied {
                note("Notifications are off for Rex DUO in iOS Settings.", button: "Open Settings")
            } else if prefs.pushEnabled && push.authorization == .provisional {
                note("Notifications arrive quietly in Notification Center. Allow banners in iOS Settings to see them right away.",
                     button: "Open Settings")
            }
            let missing = push.missingHelpers
            if !missing.isEmpty { helperSteps(missing) }
            if push.wantsPush, model.servers.contains(where: { push.helpers[$0.id] == .running(pushEnabled: false) }) {
                Text("Rex Connect Helper is in test mode and won't send notifications.")
                    .font(.footnote)
                    .foregroundStyle(theme.chrome.secondary)
            }
        } header: {
            SettingsHeader("Notifications", theme)
        } footer: {
            SettingsFooter("Rex Connect Helper on each computer sends them while this app is closed: when an agent needs you, finishes, or a terminal asks for attention.", theme)
        }
        .settingsRows(theme)
    }

    private func note(_ text: String, button: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text)
                .font(.footnote)
                .foregroundStyle(theme.chrome.secondary)
            Button(button) {
                if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
            }
            .font(.footnote.weight(.semibold))
            .buttonStyle(.borderless)
            .frame(minHeight: 32)
        }
    }

    /// Notifications are on but a connected server has no helper.
    private func helperSteps(_ servers: [ServerConnection]) -> some View {
        let title = model.servers.count > 1
            ? "Rex Connect Helper isn't running on " + servers.map(\.config.name).joined(separator: ", ")
            : "Rex Connect Helper isn't running on your computer"
        return VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(theme.fg)
            Text("Mac: drag Rex Connect Helper to Applications and open it once.\nLinux: run rex-connect-helper install.")
                .font(.footnote)
                .foregroundStyle(theme.chrome.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
