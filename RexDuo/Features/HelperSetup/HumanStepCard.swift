import SwiftUI

/// Something a person does on the computer while the install goes on: a title, what to do, a
/// quieter aside, and Done for when the app can't see that it happened.
struct HumanStepCard: View {
    let title: String
    let message: String
    var aside: String?
    let theme: TermTheme
    let onDone: () -> Void

    /// Mac: the system asks whether the helper may show notifications.
    static func allow(name: String, theme: TermTheme, onDone: @escaping () -> Void) -> HumanStepCard {
        HumanStepCard(
            title: "On \(name): click Allow",
            message: "Your Mac asks whether Rex DUO Helper may show notifications. That's only for a short notice when a phone connects. This iPhone gets its notifications either way.",
            aside: "Your Mac may also say Rex DUO Helper added a background item. That's expected.",
            theme: theme, onDone: onDone)
    }

    var body: some View {
        SetupCard(theme: theme, alignment: .leading) {
            Text(title)
                .font(.headline)
                .foregroundStyle(theme.fg)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 6)
                .accessibilityAddTraits(.isHeader)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(theme.chrome.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let aside {
                Text(aside)
                    .font(.caption.italic())
                    .foregroundStyle(theme.chrome.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }
            SetupTextButton(title: "Done", theme: theme, minWidth: 88, action: onDone)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.top, 2)
        }
    }
}
