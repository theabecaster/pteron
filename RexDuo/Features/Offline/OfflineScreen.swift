import GlanceModel
import SwiftUI
import UIKit

/// What the offline screen says, in the app's voice. It describes what the app can see, never what
/// it guesses the person did.
struct OfflineCopy: Equatable {
    var symbol: String
    var title: String
    var message: String
    /// The one thing to check, when there is one.
    var hint: String?

    static func of(_ kind: ConnectionProblem.Kind, server name: String, address: String) -> OfflineCopy {
        // "This Mac" is the default name; mid-sentence it reads as "your Mac".
        let server = name == "This Mac" ? "your Mac" : name
        let Server = server.prefix(1).uppercased() + server.dropFirst()
        switch kind {
        case .noInternet:
            return OfflineCopy(symbol: "wifi.slash", title: "No connection",
                               message: "This iPhone is offline right now. \(Brand.appName) reconnects as soon as a network is back.")
        case .offPrivateNetwork where TailscaleApp.isTailnetAddress(address):
            // A Tailscale address and no Tailscale here: the one thing to fix is on this iPhone.
            return OfflineCopy(symbol: "antenna.radiowaves.left.and.right.slash", title: "Out of range",
                               message: "Tailscale isn't connected on this iPhone.",
                               hint: "Turn it on in the Tailscale app, signed in as on the computer.")
        case .offPrivateNetwork:
            return OfflineCopy(symbol: "antenna.radiowaves.left.and.right.slash", title: "Out of range",
                               message: "Can't reach \(server) from this network.",
                               hint: "Make sure this iPhone is on the same network or VPN as the Mac.")
        case .hostNotFound:
            return OfflineCopy(symbol: "network.slash", title: "Can't find \(server)",
                               message: "This iPhone is on a private network, but \(server) isn't on it.",
                               hint: "Check that the Mac is on the same network, and that its address in Settings is right.")
        case .notAnswering:
            return OfflineCopy(symbol: "moon.zzz", title: "\(Server) isn't answering",
                               message: "The Mac may be asleep, or Rex isn't open there.",
                               hint: "Check that the Mac is awake and Rex is open.")
        case .notAllowed:
            return OfflineCopy(symbol: "lock", title: "\(Server) didn't let this iPhone in",
                               message: "Rex only accepts devices signed in to the same account as the Mac.",
                               hint: "Sign this iPhone in to that account, then try again.")
        case .insecure:
            return OfflineCopy(symbol: "lock.trianglebadge.exclamationmark", title: "Can't verify \(server)",
                               message: "The secure connection failed, so \(Brand.appName) stopped there.",
                               hint: "Use the Mac's full https:// address in Settings.")
        case .updateServer:
            return OfflineCopy(symbol: "arrow.down.circle", title: "Update Rex on \(server)",
                               message: "Rex there is too old for this version of \(Brand.appName).",
                               hint: "Update Rex on the Mac, then try again.")
        case .updateApp:
            return OfflineCopy(symbol: "arrow.down.circle", title: "Update \(Brand.appName)",
                               message: "\(Server) runs a newer Rex than this version of \(Brand.appName) works with.",
                               hint: "Update \(Brand.appName), then try again.")
        case .badAddress:
            return OfflineCopy(symbol: "link", title: "That address won't work",
                               message: "“\(address)” isn't a server address.",
                               hint: "Use the full https:// address of the Mac in Settings.")
        case .unknown:
            return OfflineCopy(symbol: "antenna.radiowaves.left.and.right.slash", title: "Can't reach \(server)",
                               message: "Something interrupted the connection. \(Brand.appName) keeps trying.")
        case .tunnelDown:
            // Every computer at once: the words are about all of them, and name no server.
            return OfflineCopy(symbol: "antenna.radiowaves.left.and.right.slash", title: "Can't reach your computers",
                               message: "If Tailscale shows a warning, turn it off and on.")
        }
    }

    /// A few words for the sidebar's host row and Settings.
    static func short(_ kind: ConnectionProblem.Kind) -> String {
        switch kind {
        case .noInternet: return "No internet connection"
        case .offPrivateNetwork: return "Off the private network"
        case .hostNotFound: return "Not on this network"
        case .notAnswering: return "Not answering"
        case .notAllowed: return "Not allowed in"
        case .insecure: return "Can't verify"
        case .updateServer: return "Needs a Rex update"
        case .updateApp: return "Needs an app update"
        case .badAddress: return "Address won't work"
        case .unknown: return "Can't connect"
        // The row is one computer's: it says what that computer does.
        case .tunnelDown: return "Not answering"
        }
    }

    /// VoiceOver's hint for a row whose tap asks a computer that is down to try again: a tab or
    /// a session of a computer other than the one on screen (`AppModel.isTap`). Nil for every
    /// other row: there a tap only shows what is there.
    static func tapHint(down: Bool, otherComputer: Bool) -> String? {
        down && otherComputer ? "Tries again." : nil
    }

    static let restoring = OfflineCopy(symbol: "antenna.radiowaves.left.and.right", title: "Back in range",
                                       message: "Loading your sessions…")
}

/// The second button, when the problem has one.
enum OfflineAction: Equatable {
    /// iOS Settings, where Wi-Fi, cellular and VPNs live; or the app's server list; or the
    /// Tailscale app's App Store page, in the app.
    case openSettings, serverSettings, getTailscale

    var title: String {
        switch self {
        case .openSettings: return "Open Settings"
        case .serverSettings: return "Server Settings"
        case .getTailscale: return "Get Tailscale"
        }
    }

    /// `address`: the server's, as saved.
    static func secondary(for kind: ConnectionProblem.Kind, address: String = "") -> OfflineAction? {
        switch kind {
        case .offPrivateNetwork where TailscaleApp.isTailnetAddress(address): return .getTailscale
        case .noInternet, .offPrivateNetwork: return .openSettings
        case .hostNotFound, .insecure: return .serverSettings
        case .badAddress, .notAllowed, .notAnswering, .updateServer, .updateApp, .unknown, .tunnelDown: return nil
        }
    }
}

/// "Signal lost": the static backdrop with a solid card on top that says what's wrong and what to do.
/// The card never moves or flickers; only the backdrop and the glyph's color ghosts animate. Retries
/// run in the background and don't touch it, Try Again shows "Trying…" while its attempt runs, and
/// once the server is back the static settles and the card says so until the sessions are in.
///
/// Unfolded, it is two pages (`OfflineLayout`): the static spans both, the glyph sits large on the
/// leading or top page and the card on the other, each centered in its page and clear of the crease.
/// Elsewhere it is one card, centered, tighter in short windows. It fills the tab, so with the sidebar
/// inline it sits beside it.
struct OfflineScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    @Environment(Prefs.self) private var prefs
    @Environment(\.division) private var division
    @Environment(\.rootOrigin) private var rootOrigin
    let server: ServerConnection
    /// Over a tab whose server dropped: the stale tab shows through, dimmed, and takes no touches.
    var overTab = false
    @Binding var sidebarVisible: Bool

    @State private var showDetails = false

    var body: some View {
        let theme = prefs.theme(for: scheme)
        let problem = server.phase.problem
        let level: SignalStatic.Level = problem == nil ? .locked : server.retrying ? .searching : .idle
        ZStack {
            (overTab ? theme.bg.opacity(0.78) : theme.bg)
                .ignoresSafeArea()
            SignalStatic(theme: theme, level: level)
                .opacity(overTab ? 0.75 : 1)
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            GeometryReader { geo in
                let global = geo.frame(in: .global).origin
                let origin = CGPoint(x: global.x - rootOrigin.x, y: global.y - rootOrigin.y)
                let layout = OfflineLayout.decide(size: geo.size, origin: origin, division: division)
                ZStack(alignment: .topLeading) {
                    if let art = layout.art {
                        illustration(problem, theme, fits: art.size)
                            .frame(width: art.width, height: art.height)
                            .transaction { $0.animation = nil }
                            .offset(x: art.minX, y: art.minY)
                            .transition(.opacity)
                    }
                    // A short window (iPhone on its side, the keyboard up) gets the tighter card, so it
                    // fits without scrolling.
                    let compact = !layout.isPaged && layout.card.height < 480
                    ScrollView {
                        card(problem, theme, withGlyph: !layout.isPaged, compact: compact)
                            .padding(.horizontal, 20)
                            .padding(.vertical, compact ? 12 : 24)
                            .frame(maxWidth: .infinity, minHeight: layout.card.height)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(width: layout.card.width, height: layout.card.height)
                    // Only the position animates. An animated resize leaves the scroll view's content
                    // where it was, off the new page.
                    .transaction { $0.animation = nil }
                    .offset(x: layout.card.minX, y: layout.card.minY)
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                // A fold, an unfold or the sidebar moves the parts to their new pages.
                .animation(.smooth(duration: 0.35), value: layout)
            }
        }
        .contentShape(Rectangle())
        .onChange(of: server.retrying) { was, now in
            // The attempt the person asked for failed: a soft bump, the card stays as it was.
            if was, !now, server.phase.problem != nil { Haptic.bump() }
        }
        .onChange(of: problem == nil) { _, back in if back { Haptic.selection() } }
    }

    private func copy(_ problem: ConnectionProblem?) -> OfflineCopy {
        problem.map { OfflineCopy.of($0.kind, server: server.config.name, address: server.config.url) } ?? .restoring
    }

    private func signalLabel(_ problem: ConnectionProblem?, _ theme: TermTheme, size: CGFloat) -> some View {
        Text(problem == nil ? "SIGNAL FOUND" : "SIGNAL LOST")
            .font(.system(size: size, weight: .semibold, design: .monospaced))
            .tracking(size * 0.22)
            .foregroundStyle(problem == nil ? theme.chrome.done : theme.accent)
            .accessibilityHidden(true)
    }

    /// Two pages: the page opposite the card. The glyph large in a solid disc, like a dial that lost
    /// its station, with the status and the server's name under it.
    private func illustration(_ problem: ConnectionProblem?, _ theme: TermTheme, fits size: CGSize) -> some View {
        let d = max(96, min(208, size.width - 64, size.height - 150))
        return VStack(spacing: 18) {
            ZStack {
                Circle().fill(theme.bg)
                Circle().stroke(theme.chrome.divider, lineWidth: 1)
                Circle()
                    .inset(by: d * 0.12)
                    .stroke(theme.chrome.divider, style: StrokeStyle(lineWidth: 1, dash: [2, 5]))
                GlitchGlyph(symbol: copy(problem).symbol, theme: theme, size: d * 0.34)
                    .frame(width: d * 0.56, height: d * 0.44)
            }
            .frame(width: d, height: d)
            VStack(spacing: 6) {
                signalLabel(problem, theme, size: 13)
                Text(server.config.name)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(theme.chrome.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                Capsule().fill(theme.bg)
                    .overlay(Capsule().stroke(theme.chrome.divider, lineWidth: 1))
            )
            .frame(maxWidth: size.width - 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityHidden(true)
    }

    /// The message and what to do. `withGlyph`: the glyph and status sit on top (one page); with two
    /// pages they are the illustration instead. `compact`: tighter, wider, with the buttons in rows.
    private func card(_ problem: ConnectionProblem?, _ theme: TermTheme, withGlyph: Bool, compact: Bool) -> some View {
        let copy = copy(problem)
        return VStack(spacing: 0) {
            if withGlyph {
                GlitchGlyph(symbol: copy.symbol, theme: theme, size: compact ? 26 : 34)
                    .frame(width: compact ? 44 : 56, height: compact ? 34 : 44)
                    .padding(.bottom, compact ? 8 : 14)
                    .accessibilityHidden(true)
                signalLabel(problem, theme, size: 11)
                    .padding(.bottom, compact ? 6 : 8)
            }
            Text(copy.title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(theme.fg)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 6)
            Text(copy.message)
                .font(.subheadline)
                .foregroundStyle(theme.chrome.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let hint = copy.hint {
                Text(hint)
                    .font(.footnote)
                    .foregroundStyle(theme.chrome.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
            }
            if let problem {
                actions(problem, theme, compact: compact)
                    .padding(.top, compact ? 16 : 20)
                details(problem, theme, compact: compact)
                    .padding(.top, compact ? 4 : 8)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .tint(theme.chrome.secondary)
                    .padding(.top, 18)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, compact ? 16 : 24)
        .padding(.bottom, compact ? 8 : 14)
        .frame(maxWidth: compact ? 440 : 360)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(theme.bg)
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(theme.chrome.divider, lineWidth: 1))
        )
        .accessibilityElement(children: .contain)
    }

    /// The main button and the second one: stacked, or side by side in the compact card.
    @ViewBuilder
    private func actions(_ problem: ConnectionProblem, _ theme: TermTheme, compact: Bool) -> some View {
        let layout = compact ? AnyLayout(HStackLayout(spacing: 8)) : AnyLayout(VStackLayout(spacing: 4))
        layout {
            if problem.kind == .badAddress {
                PrimaryButton(title: "Server Settings", busy: false, theme: theme) { model.openSettings(at: .servers) }
            } else {
                PrimaryButton(title: "Try Again", busyTitle: "Trying…", busy: server.retrying, theme: theme) {
                    Haptic.tap()
                    server.retryNow()
                }
                if let a = OfflineAction.secondary(for: problem.kind, address: server.config.url) {
                    Button(a.title) { perform(a) }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(theme.accent)
                        .padding(.horizontal, compact ? 12 : 0)
                        .frame(minWidth: compact ? 0 : 200, minHeight: 44)
                        .contentShape(Rectangle())
                }
            }
            if !compact { showSidebar(theme, height: 44) }
        }
    }

    /// The tab's title bar, with the sidebar toggle, is under this screen.
    @ViewBuilder
    private func showSidebar(_ theme: TermTheme, height: CGFloat) -> some View {
        if prefs.navigation == .tabs {
            // No sidebar to show: the Change Session palette lists every machine's sessions.
            Button("Change Session") { model.perform(.goTo(.sessions)) }
                .font(.footnote)
                .foregroundStyle(theme.chrome.secondary)
                .frame(minHeight: height)
        } else if !sidebarVisible {
            Button("Show Sidebar") { sidebarVisible = true }
                .font(.footnote)
                .foregroundStyle(theme.chrome.secondary)
                .frame(minHeight: height)
        }
    }

    /// Details, and in the compact card Show Sidebar beside it.
    private func details(_ problem: ConnectionProblem, _ theme: TermTheme, compact: Bool) -> some View {
        VStack(spacing: 2) {
            HStack(spacing: 20) {
                if compact { showSidebar(theme, height: 36) }
                detailsToggle(theme)
            }
            if showDetails {
                Text("\(server.config.url)\n\(problem.detail)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.chrome.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func detailsToggle(_ theme: TermTheme) -> some View {
        Button {
            showDetails.toggle()
        } label: {
            HStack(spacing: 4) {
                Text("Details")
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(showDetails ? 90 : 0))
            }
            .font(.caption)
            .foregroundStyle(theme.chrome.tertiary)
            .frame(minWidth: 88, minHeight: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(showDetails ? "Hide Details" : "Show Details")
    }

    private func perform(_ a: OfflineAction) {
        Haptic.tap()
        switch a {
        case .openSettings:
            if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
        case .serverSettings: model.openSettings(at: .servers)
        case .getTailscale: TailscaleApp.showInAppStore()
        }
    }
}

/// The filled capsule button. Busy swaps the title for a spinner and `busyTitle` in the same frame,
/// so nothing around it moves. 200 × 46 pt; large text makes it taller and wider, wrapping.
struct PrimaryButton: View {
    let title: String
    var busyTitle: String = ""
    let busy: Bool
    let theme: TermTheme
    let action: () -> Void
    /// Room around the title, growing with it.
    @ScaledMetric(relativeTo: .body) private var inset: CGFloat = 10

    var body: some View {
        // Taps while busy do nothing. Not `.disabled`, which would fade "Trying…" past legibility.
        Button { if !busy { action() } } label: {
            ZStack {
                Text(title).opacity(busy ? 0 : 1)
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).tint(theme.bg)
                    Text(busyTitle)
                }
                .opacity(busy ? 1 : 0)
            }
            .font(.body.weight(.semibold))
            .foregroundStyle(theme.bg)
            .multilineTextAlignment(.center)
            .padding(.horizontal, inset).padding(.vertical, inset * 0.8)
            .frame(minWidth: 200, minHeight: 46)
            .background(Capsule().fill(theme.accent.opacity(busy ? 0.85 : 1)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: busy)
        .accessibilityLabel(busy ? busyTitle : title)
    }
}
