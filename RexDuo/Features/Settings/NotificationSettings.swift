import SwiftUI
import UIKit

/// Settings → Notifications: one toggle for push, and a quiet line when something stands in the way
/// (iOS permission, the Rex DUO Helper on each computer). In-app banners for waiting agents are always on.
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
            ForEach(push.missingHelpers) { server in missingHelper(server) }
            if push.wantsPush, model.servers.contains(where: { push.helpers[$0.id] == .running(pushEnabled: false) }) {
                quiet("Rex DUO Helper is in test mode and won't send notifications.")
            }
            let outdated = push.wantsPush ? model.servers.filter { push.helpers[$0.id] == .outdated } : []
            if !outdated.isEmpty {
                quiet("Rex DUO Helper on \(outdated.map(\.config.name).joined(separator: ", ")) is too old for this version of Rex DUO. Install the latest helper there.")
            }
            if push.wantsPush {
                ForEach(model.servers) { server in
                    switch push.helpers[server.id] {
                    case .identityChanged: changedHelper(server)
                    case .failed(let why): failedHelper(server, why)
                    default: EmptyView()
                    }
                }
            }
            if push.wantsPush, let problem = push.gatewayProblem {
                quiet(Self.text(for: problem))
            }
            if push.wantsPush {
                ForEach(model.servers.filter { push.versions[$0.id] != nil }) { server in
                    if let version = push.versions[server.id] { helperRow(server, version) }
                }
            }
            #if DEBUG
            // For whoever publishes helper releases, not for users: only debug builds show it.
            if let line = renewalLine { quiet(line) }
            #endif
        } header: {
            SettingsHeader("Notifications", theme)
        } footer: {
            SettingsFooter("Rex DUO Helper on each computer sends them while this app is closed: when an agent needs you, finishes, or a terminal asks for attention.", theme)
        }
        .settingsRows(theme)
    }

    private func quiet(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(theme.chrome.secondary)
    }

    /// Why this phone has no registration to hand to a helper.
    static func text(for problem: GatewayError) -> String {
        switch problem {
        case .rateLimited: "Too many tries to set up notifications. Rex DUO will try again later."
        case .unavailable: "Couldn't reach the Rex DUO notification service. Rex DUO will try again."
        case .storeFailed: "Rex DUO couldn't save its notification setup on this iPhone. It will try again."
        default: "The Rex DUO notification service refused this phone. Update Rex DUO and try again."
        }
    }

    /// The helper on this computer isn't the one the phone first met there. It gets nothing until
    /// the user says it is theirs.
    private func changedHelper(_ server: ServerConnection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Self.changedText(server.config.name))
                .font(.footnote)
                .foregroundStyle(theme.chrome.secondary)
            HStack(spacing: 20) {
                Button("Trust") { model.push.trustHelper(server) }
                Button("Reinstall") { install(server, .reinstall) }
            }
            .font(.footnote.weight(.semibold))
            .buttonStyle(.borderless)
            .tint(theme.accent)
            .frame(minHeight: 32)
        }
    }

    /// A helper that is there but not working: what it said, and Repair, which runs the install
    /// again over it.
    private func failedHelper(_ server: ServerConnection, _ why: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            quiet(why)
            if model.helperSetup.offer(for: server, repairing: true) == .install {
                Button("Repair") { install(server, .repair) }
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.borderless)
                    .tint(theme.accent)
                    .frame(minHeight: 32)
            }
        }
    }

    /// Notifications are on but a connected server has no helper: Install, when the computer is
    /// the person's own and one the helper runs on.
    private func missingHelper(_ server: ServerConnection) -> some View {
        let name = server.config.name
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Rex DUO Helper isn't running on \(name)")
                    .foregroundStyle(theme.fg)
                Text(Self.missingText(model.helperSetup.offer(for: server), name: name, installing: model.helperSetup.isRunning(server.id)))
                    .font(.footnote)
                    .foregroundStyle(theme.chrome.secondary)
            }
            Spacer(minLength: 0)
            if model.helperSetup.offer(for: server) == .install {
                Button("Install") { install(server, .install) }
                    .font(.body.weight(.semibold))
                    .buttonStyle(.borderless)
                    .tint(theme.accent)
            }
        }
        .padding(.vertical, 2)
    }

    static func missingText(_ offer: HelperOffer, name: String, installing: Bool) -> String {
        if installing { return "Installing it now." }
        switch offer {
        case .install: return "It sends notifications while Rex DUO is closed."
        case .askOwner: return "Ask the owner of \(name) to install Rex DUO Helper."
        case .none: return "Rex DUO Helper isn't available for this computer yet."
        }
    }

    /// The install sheet takes the screen once Settings has closed.
    private func install(_ server: ServerConnection, _ kind: SetupState.Kind) {
        model.helperSetup.request(server.id, kind: kind)
        model.showSettings = false
    }

    #if DEBUG
    /// The earliest date a helper's release list needs renewing by, when that is within 30 days.
    private var renewalLine: String? {
        let dates = model.servers.compactMap { model.push.versions[$0.id]?.manifestExpiresAt }
        return dates.min().flatMap { HelperRelease.renewalNotice(expiresAt: $0, now: Date()) }
    }
    #endif

    static func changedText(_ name: String) -> String {
        "Rex DUO Helper on \(name) changed. Only trust it if you reinstalled the helper there."
    }

    /// One computer's helper: its version, and "Update" when a newer one is out.
    private func helperRow(_ server: ServerConnection, _ version: HelperVersion) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.servers.count > 1 ? "Rex DUO Helper on \(server.config.name)" : "Rex DUO Helper")
                    .foregroundStyle(theme.fg)
                Text(version.lastError ?? version.summary)
                    .font(.footnote)
                    .foregroundStyle(theme.chrome.secondary)
            }
            Spacer(minLength: 0)
            if version.updating {
                ProgressView()
            } else if version.offersUpdate {
                Button("Update") { model.push.updateHelper(server) }
                    .font(.body.weight(.semibold))
                    .buttonStyle(.borderless)
                    .tint(theme.accent)
            } else if version.updateRequired, !version.canUpdate {
                // It can't replace itself: the install does it.
                Button("Repair") { install(server, .repair) }
                    .font(.body.weight(.semibold))
                    .buttonStyle(.borderless)
                    .tint(theme.accent)
            }
        }
        .task(id: server.id) { model.push.refreshVersion(server) }
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
            .tint(theme.accent)
            .frame(minHeight: 32)
        }
    }
}
