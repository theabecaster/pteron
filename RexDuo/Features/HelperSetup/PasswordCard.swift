import SwiftUI

/// Linux, when the helper would stop at logout: asks for the computer account's password, which
/// allows that one setting. The field's text goes to `onContinue` once and is cleared here at the
/// same moment; the card keeps nothing.
struct PasswordCard: View {
    let name: String
    let account: String?
    /// The last password wasn't taken.
    let wrong: Bool
    /// The person types it on the computer: no field, only the way out.
    let onComputer: Bool
    let sending: Bool
    let theme: TermTheme
    let onContinue: (String) -> Void
    let onTypeThere: () -> Void
    let onNotNow: () -> Void

    @State private var password = ""
    @FocusState private var focused: Bool

    static let title = "Keep notifications coming after you log out?"
    static func message(name: String, account: String?) -> String {
        "\(name) stops Rex DUO Beacon when you log out, unless you allow Beacon to keep running. Allowing that takes the password for \(account ?? "your account") on \(name)."
    }
    static let wrongLine = "That password didn't work. Try again, or choose Not now."
    static func aside(_ name: String) -> String {
        "Your password goes straight to \(name) and isn't saved on this iPhone."
    }
    static func onComputerLine(_ name: String) -> String {
        "Type the password on \(name). Rex DUO continues once \(name) accepts the password."
    }

    var body: some View {
        SetupCard(theme: theme, alignment: .leading) {
            Text(Self.title)
                .font(.headline)
                .foregroundStyle(theme.fg)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 6)
                .accessibilityAddTraits(.isHeader)
            Text(Self.message(name: name, account: account))
                .font(.subheadline)
                .foregroundStyle(theme.chrome.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if onComputer {
                Text(Self.onComputerLine(name))
                    .font(.subheadline)
                    .foregroundStyle(theme.fg)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
                SetupTextButton(title: "Not now", theme: theme, minWidth: 88, action: onNotNow)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                field
                if wrong {
                    Text(Self.wrongLine)
                        .font(.footnote)
                        .foregroundStyle(theme.chrome.error)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8)
                }
                VStack(spacing: 2) {
                    PrimaryButton(title: "Continue", busyTitle: "Sending…", busy: sending, theme: theme, action: submit)
                        .opacity(password.isEmpty && !sending ? 0.5 : 1)
                    SetupTextButton(title: "Type the password on \(name) instead", theme: theme, action: onTypeThere)
                    SetupTextButton(title: "Not now", theme: theme, action: onNotNow)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 14)
                Text(Self.aside(name))
                    .font(.caption.italic())
                    .foregroundStyle(theme.chrome.tertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 6)
            }
        }
    }

    private var field: some View {
        SecureField("Password", text: $password, prompt: Text("Password").foregroundStyle(theme.chrome.tertiary))
            .textContentType(.password)
            .submitLabel(.continue)
            .focused($focused)
            .onSubmit(submit)
            .font(.body)
            .foregroundStyle(theme.fg)
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.fg.opacity(theme.isDark ? 0.06 : 0.05)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(focused ? theme.accent : theme.chrome.divider, lineWidth: 1))
            .padding(.top, 14)
            .accessibilityLabel("Password for \(account ?? "your account") on \(name)")
    }

    private func submit() {
        guard !password.isEmpty, !sending else { return }
        let typed = password
        password = ""
        onContinue(typed)
    }
}
