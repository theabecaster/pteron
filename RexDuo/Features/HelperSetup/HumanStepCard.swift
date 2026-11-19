import GlanceModel
import SwiftUI

/// Something a person does on the computer while the install goes on: a title, what to do, a
/// quieter aside, and Done for when the app can't see that it happened.
struct HumanStepCard: View {
    let title: String
    let message: String
    var aside: String?
    let theme: TermTheme
    let onDone: () -> Void

    /// The words of the Mac's card. They name the program as the Mac's own question does.
    static func allowCopy(name: String) -> (title: String, message: String, aside: String) {
        ("Click Allow for \(Brand.beaconName) on \(name)",
         "\(name) asks whether \(Brand.beaconName) may show notifications. Beacon only shows a short notice on \(name) when a phone connects. This iPhone gets notifications either way.",
         "\(name) may also say \(Brand.beaconName) added a background item. That message is expected.")
    }

    /// Mac: the system asks whether the helper may show notifications.
    static func allow(name: String, theme: TermTheme, onDone: @escaping () -> Void) -> HumanStepCard {
        let copy = allowCopy(name: name)
        return HumanStepCard(title: copy.title, message: copy.message, aside: copy.aside, theme: theme, onDone: onDone)
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
