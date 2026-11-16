import SwiftUI

/// "Get notified when an agent needs you", offered once. Turn On shows the iOS permission prompt
/// (only the first time); Not now hides the card for good. Settings → Notifications keeps the toggle.
struct NotificationPromptCard: View {
    @Environment(AppModel.self) private var model
    let theme: TermTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "bell.badge")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(theme.accent)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Get notified when an agent needs you")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(theme.fg)
                    Text("While Rex Connect is closed, your Mac lets you know when an agent asks something or finishes.")
                        .font(.caption)
                        .foregroundStyle(theme.chrome.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Not now") { model.push.declinePrompt() }
                    .buttonStyle(.bordered)
                    .tint(theme.chrome.secondary)
                Button("Turn On") { model.push.enable() }
                    .buttonStyle(.borderedProminent)
                    .tint(theme.accent)
            }
        }
    }
}
