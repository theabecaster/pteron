import GlanceModel
import SwiftUI
import UIKit

/// "Installing on <Name>": the steps of an install of Beacon, the cards for what a person
/// has to do meanwhile, and how it ended. Full screen, in the pairing sheet's look. Where the
/// window is wide or the fold splits it (`SetupLayout`), the installer's output sits beside the
/// steps; elsewhere "Show details" pushes it. "Hide" closes the sheet and lets the install go
/// on; the computer's row in Settings → Notifications follows it and brings the sheet back.
struct HelperSetupSheet: View {
    let run: HelperSetupRun

    @Environment(AppModel.self) private var model
    @Environment(Prefs.self) private var prefs
    @Environment(\.colorScheme) private var scheme
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showDetails = false
    @State private var confirmStop = false

    var body: some View {
        let theme = prefs.theme(for: scheme)
        let state = run.state
        NavigationStack {
            GeometryReader { geo in
                let layout = SetupLayout.decide(size: geo.size, division: RootView.division(geo))
                Group {
                    switch layout {
                    case .sideBySide(let steps):
                        HStack(spacing: 0) {
                            stepsPage(state, theme, details: false)
                                .frame(width: steps)
                            SetupDetailsTerminal(run: run, theme: theme)
                                .padding(12)
                                // A failed run whose output was on screen closes its tab with the sheet.
                                .onAppear { run.showedDetails() }
                        }
                    case .single:
                        stepsPage(state, theme, details: true)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .navigationDestination(isPresented: Binding(get: { showDetails && layout == .single }, set: { showDetails = $0 })) {
                    SetupDetailsTerminal(run: run, theme: theme)
                        .padding(12)
                        .onAppear { run.showedDetails() }
                        .background(theme.bg.ignoresSafeArea())
                        .navigationTitle("Details")
                        .navigationBarTitleDisplayMode(.inline)
                }
            }
            .background(theme.bg.ignoresSafeArea())
            .navigationTitle(state.title(name: run.name))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if run.server != nil, !state.isFinished {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Hide") { model.helperSetup.hide(run) }
                    }
                }
            }
        }
        .tint(theme.accent)
        .preferredColorScheme(theme.isDark ? .dark : .light)
        .interactiveDismissDisabled()
        .alert("Stop installing \(Brand.beaconName)?", isPresented: $confirmStop) {
            Button("Stop Install", role: .destructive) { model.helperSetup.close(run, cancelled: true) }
            Button("Keep Going", role: .cancel) {}
        } message: {
            Text("\(run.name) keeps the \(Brand.beaconName) it had before, if any.")
        }
        // "Show Details" in the computer's row opens the sheet at the installer's output.
        .onAppear { if model.helperSetup.takeDetailsRequest(for: run) { showDetails = true } }
        .onChange(of: state.phase) { _, phase in
            if phase == .connected { Haptic.success() }
            // VoiceOver moves to what the sheet shows now.
            UIAccessibility.post(notification: .screenChanged, argument: nil)
        }
    }

    // MARK: Steps

    private func stepsPage(_ state: SetupState, _ theme: TermTheme, details: Bool) -> some View {
        GeometryReader { geo in
            ScrollView {
                VStack(spacing: 14) {
                    if state.phase == .connected {
                        connected(theme)
                    } else if let error = state.error {
                        failure(error, state, theme, details: details)
                    } else {
                        progress(state, theme, details: details)
                    }
                    human(state, theme)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity, minHeight: geo.size.height)
                .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: state.phase)
                .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: state.human)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
        }
    }

    private func progress(_ state: SetupState, _ theme: TermTheme, details: Bool) -> some View {
        SetupCard(theme: theme, alignment: .leading) {
            SetupStepList(state: state, name: run.name, theme: theme)
            if state.connectionLost {
                Text(SetupError.connectionLost(name: run.name))
                    .font(.footnote)
                    .foregroundStyle(theme.chrome.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 14)
            }
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                if details, state.hasTab {
                    SetupTextButton(title: "Show Details", theme: theme, minWidth: 110) { showDetails = true }
                }
                SetupTextButton(title: "Stop Install", theme: theme, minWidth: 80) {
                    if state.hasTab { confirmStop = true } else { model.helperSetup.close(run, cancelled: true) }
                }
            }
            .padding(.top, 8)
        }
    }

    @ViewBuilder
    private func human(_ state: SetupState, _ theme: TermTheme) -> some View {
        switch state.human {
        case .allowNotifications:
            HumanStepCard.allow(name: run.name, theme: theme) { run.humanDone() }
                .transition(.opacity)
        case .password(let wrong):
            passwordCard(wrong: wrong, onComputer: false, theme)
        case .passwordOnComputer:
            passwordCard(wrong: false, onComputer: true, theme)
        case nil:
            EmptyView()
        }
    }

    private func passwordCard(wrong: Bool, onComputer: Bool, _ theme: TermTheme) -> some View {
        PasswordCard(name: run.name, account: run.account, wrong: wrong, onComputer: onComputer, sending: run.sendingPassword, theme: theme,
                     onContinue: { password in Task { await run.sendPassword(password) } },
                     onTypeThere: { run.typeOnComputer() },
                     onNotNow: { Task { await run.skipPassword() } })
            .transition(.opacity)
    }

    // MARK: Endings

    private func connected(_ theme: TermTheme) -> some View {
        SetupCard(theme: theme) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(theme.chrome.done)
                .frame(height: 48)
                .padding(.bottom, 12)
                .accessibilityHidden(true)
            Text("Connected")
                .font(.title3.weight(.semibold))
                .foregroundStyle(theme.fg)
                .padding(.bottom, 6)
                .accessibilityAddTraits(.isHeader)
            Text(run.connectedMessage)
                .font(.subheadline)
                .foregroundStyle(theme.chrome.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            PrimaryButton(title: "Done", busy: false, theme: theme) {
                Haptic.tap()
                model.helperSetup.close(run, cancelled: false)
            }
            .padding(.top, 20)
            .padding(.bottom, 8)
        }
    }

    private func failure(_ error: SetupError, _ state: SetupState, _ theme: TermTheme, details: Bool) -> some View {
        SetupCard(theme: theme) {
            Image(systemName: error == .notificationsOff ? "bell.slash" : "exclamationmark.triangle")
                .font(.system(size: 34))
                .foregroundStyle(error == .notificationsOff ? theme.fg.opacity(0.85) : theme.chrome.error)
                .frame(width: 56, height: 44)
                .padding(.bottom, 14)
                .accessibilityHidden(true)
            Text(error.message(name: run.name))
                .font(.subheadline)
                .foregroundStyle(theme.fg)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 4) {
                ForEach(Array(error.actions(hasTab: state.hasTab && details).enumerated()), id: \.offset) { index, action in
                    button(action, filled: index == 0 && action != .close && action != .showDetails, state, theme)
                }
            }
            .padding(.top, 20)
        }
    }

    @ViewBuilder
    private func button(_ action: SetupError.Action, filled: Bool, _ state: SetupState, _ theme: TermTheme) -> some View {
        let (title, run): (String, () -> Void) = switch action {
        case .tryAgain: ("Try Again", { model.helperSetup.retry(self.run, kind: state.kind) })
        case .repair: ("Repair", { model.helperSetup.retry(self.run, kind: .repair) })
        case .openSettings: ("Open Settings", {
            if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
        })
        case .showDetails: ("Show Details", { showDetails = true })
        case .close: ("Close", { model.helperSetup.close(self.run, cancelled: false) })
        }
        if filled {
            PrimaryButton(title: title, busy: false, theme: theme) {
                Haptic.tap()
                run()
            }
        } else {
            SetupTextButton(title: title, theme: theme, action: run)
        }
    }
}

extension View {
    /// Presents the install sheet for the run `AppModel.helperSetup` has on screen.
    func helperSetupCover(model: AppModel) -> some View {
        modifier(HelperSetupCover(model: model))
    }
}

private struct HelperSetupCover: ViewModifier {
    let model: AppModel
    @Environment(Prefs.self) private var prefs

    func body(content: Content) -> some View {
        let center = model.helperSetup
        content
            .fullScreenCover(item: Binding(get: { center.active }, set: { if $0 == nil { center.active = nil } })) { run in
                HelperSetupSheet(run: run).environment(model).environment(prefs)
            }
            #if DEBUG
            .fullScreenCover(isPresented: Binding(get: { center.simulatedOffer != nil }, set: { if !$0 { center.simulatedOffer = nil } })) {
                HelperOfferPage(name: center.simulatedOffer ?? "", onInstall: { center.simulatedOffer = nil },
                                onSkip: {}, onLeave: { center.simulatedOffer = nil })
                    .environment(prefs)
            }
            #endif
    }
}

/// The offer card on the theme's background, centred: the page pairing shows after a computer is
/// added.
struct HelperOfferPage: View {
    let name: String
    let onInstall: () -> Void
    let onSkip: () -> Void
    let onLeave: () -> Void

    @Environment(Prefs.self) private var prefs
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = prefs.theme(for: scheme)
        GeometryReader { geo in
            ScrollView {
                HelperOfferCard(name: name, theme: theme, onInstall: onInstall, onSkip: onSkip, onLeave: onLeave)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity, minHeight: geo.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(theme.bg.ignoresSafeArea())
        .tint(theme.accent)
        .preferredColorScheme(theme.isDark ? .dark : .light)
    }
}

#if DEBUG
extension HelperSetupCenter {
    /// `-simulateHelperSetup <state>` (testing): show the install sheet in that state, with no
    /// server and nothing running. States: `offer`, `preparing`, `download`, `verify`, `install`,
    /// `connecting`, `allow`, `password`, `password-wrong`, `password-computer`, `lost`,
    /// `connected`, `connected-allow`, `denied`, `manual`, `changed`, `error-release`,
    /// `error-timeout` and `error-<exit code>`. `-simulateHelperSetupOS linux` makes the computer
    /// a Linux one, `-simulateHelperSetupKind repair` titles the sheet "Repairing".
    func simulateFromLaunchArguments() {
        let defaults = UserDefaults.standard
        guard let raw = defaults.string(forKey: "simulateHelperSetup") else { return }
        let name = "studio"
        if raw == "offer" {
            simulatedOffer = name
            return
        }
        let linux = defaults.string(forKey: "simulateHelperSetupOS") == "linux" || raw.hasPrefix("password")
        let kind: SetupState.Kind = defaults.string(forKey: "simulateHelperSetupKind") == "repair" ? .repair : .install
        var state = SetupState(kind: kind, computer: linux ? .linux : .mac)
        func record(_ token: String, state s: String = "working", progress: Int? = nil, kind: String? = nil, at: String = "1") {
            state.handle(.record(SetupRecord(state: s, token: token, progress: progress, kind: kind, updatedAt: at)))
        }
        func start() {
            state.handle(.release(version: "0.4.0"))
            state.handle(.started)
        }
        switch raw {
        case "preparing":
            break
        case "download":
            start(); record("download", progress: 40)
        case "verify":
            start(); record("verify")
        case "install":
            start(); record("install")
        case "connecting":
            start(); record("done", state: "done"); state.handle(.exited(code: 0))
        case "allow":
            start(); record("notify"); state.handle(.exited(code: 0)); state.handle(.notices("undetermined"))
        case "password":
            start(); record("linger", state: "blocked", kind: "auth")
        case "password-wrong":
            start(); record("linger", state: "blocked", kind: "auth")
            state.handle(.passwordSent); record("linger", state: "blocked", kind: "auth", at: "2")
        case "password-computer":
            start(); record("linger", state: "blocked", kind: "auth"); state.handle(.passwordOnComputer)
        case "lost":
            start(); record("install"); state.handle(.connectionLost)
        case "connected", "connected-allow":
            start(); record("done", state: "done"); state.handle(.exited(code: 0))
            state.handle(.proof(.valid)); state.handle(.helperRegistered)
            if raw == "connected-allow" { state.handle(.notices("undetermined")) }
        case "denied":
            state.handle(.fail(.notificationsOff))
        case "manual":
            state.handle(.fail(.manual))
        case "changed":
            start(); state.handle(.exited(code: 0)); state.handle(.proof(.wrong))
        case "error-release":
            state.handle(.fail(.release))
        case "error-timeout":
            start(); state.handle(.exited(code: 0)); state.handle(.connectTimeout)
        default:
            guard raw.hasPrefix("error-"), let code = Int(raw.dropFirst("error-".count)) else { return }
            start(); record("verify"); state.handle(.exited(code: code))
        }
        let run = HelperSetupRun(name: name, account: "sam", state: state)
        run.simulatedDetails = """
        \(Brand.beaconName) setup
        computer: \(linux ? "Linux x86_64" : "macOS, Apple silicon")
        downloading \(Brand.beaconName) 0.4.0
        checking the download
        """
        active = run
    }
}
#endif
