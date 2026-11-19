import GlanceModel
import SwiftUI
import UIKit

/// "Get notifications from <Name>?": the page after a computer is added, when it has no helper.
/// Install hands over to the install sheet. Skip says what that means for three seconds, then
/// leaves; Settings → Notifications keeps Install.
struct HelperOfferCard: View {
    let name: String
    let theme: TermTheme
    let onInstall: () -> Void
    /// Skip was tapped: remember it.
    let onSkip: () -> Void
    /// The line after Skip has been up long enough.
    let onLeave: () -> Void

    @State private var skipped = false

    static func title(_ name: String) -> String { "Get notifications from \(name)?" }
    static func message(_ name: String) -> String {
        "\(Brand.beaconName) runs on \(name) and notifies this iPhone when an agent finishes or needs you, even while \(Brand.appName) is closed."
    }
    static func footnote(_ name: String) -> String {
        "\(Brand.appName) opens a tab on \(name) to install Beacon. Nothing runs as an administrator."
    }
    static func skippedLine(_ name: String) -> String {
        "You won't get notifications from \(name) while \(Brand.appName) is closed. You can install \(Brand.beaconName) anytime in Settings → Notifications."
    }
    /// How long the line after Skip stays before the page leaves.
    static let skipHold: TimeInterval = 3

    var body: some View {
        SetupCard(theme: theme) {
            if skipped {
                Text(Self.skippedLine(name))
                    .font(.subheadline)
                    .foregroundStyle(theme.chrome.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 10)
                    .transition(.opacity)
            } else {
                Image(systemName: "bell.badge")
                    .font(.system(size: 34))
                    .foregroundStyle(theme.fg.opacity(0.85))
                    .frame(width: 56, height: 44)
                    .padding(.bottom, 14)
                    .accessibilityHidden(true)
                Text(Self.title(name))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(theme.fg)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 6)
                    .accessibilityAddTraits(.isHeader)
                Text(Self.message(name))
                    .font(.subheadline)
                    .foregroundStyle(theme.chrome.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 4) {
                    PrimaryButton(title: "Install", busy: false, theme: theme) {
                        Haptic.tap()
                        onInstall()
                    }
                    SetupTextButton(title: "Skip", theme: theme) {
                        onSkip()
                        withAnimation(.easeInOut(duration: 0.2)) { skipped = true }
                        UIAccessibility.post(notification: .announcement, argument: Self.skippedLine(name))
                    }
                }
                .padding(.top, 20)
                Text(Self.footnote(name))
                    .font(.caption.italic())
                    .foregroundStyle(theme.chrome.tertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
                    .padding(.bottom, 8)
            }
        }
        .task(id: skipped) {
            guard skipped else { return }
            try? await Task.sleep(nanoseconds: UInt64(Self.skipHold * 1_000_000_000))
            guard !Task.isCancelled else { return }
            onLeave()
        }
    }
}

/// The pairing sheet's card: the theme's background, one hairline border, content centred.
struct SetupCard<Content: View>: View {
    let theme: TermTheme
    var alignment = HorizontalAlignment.center
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: alignment, spacing: 0) { content }
            .padding(.horizontal, 22)
            .padding(.top, 22)
            .padding(.bottom, 14)
            .frame(maxWidth: 380)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(theme.bg)
                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(theme.chrome.divider, lineWidth: 1))
            )
            .accessibilityElement(children: .contain)
    }
}

/// The second button everywhere in the install flow: accent text, a full-size touch target.
struct SetupTextButton: View {
    let title: String
    let theme: TermTheme
    var minWidth: CGFloat = 200
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(theme.accent)
            .multilineTextAlignment(.center)
            .frame(minWidth: minWidth, minHeight: 44)
            .contentShape(Rectangle())
    }
}
