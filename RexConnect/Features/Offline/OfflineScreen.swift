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
                               message: "This iPhone is offline right now. Rex DUO reconnects as soon as a network is back.")
        case .offPrivateNetwork:
            return OfflineCopy(symbol: "antenna.radiowaves.left.and.right.slash", title: "Out of range",
                               message: "This iPhone can't see your Mac's private network right now.",
                               hint: "Connect it to the same private network as the Mac, and Rex DUO picks up from there.")
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
                               message: "The secure connection failed, so Rex DUO stopped there.",
                               hint: "Use the Mac's full https://….ts.net address in Settings.")
        case .badAddress:
            return OfflineCopy(symbol: "link", title: "That address won't work",
                               message: "“\(address)” isn't a server address.",
                               hint: "Use https://<name>.<tailnet>.ts.net in Settings.")
        case .unknown:
            return OfflineCopy(symbol: "antenna.radiowaves.left.and.right.slash", title: "Can't reach \(server)",
                               message: "Something interrupted the connection. Rex DUO keeps trying.")
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
        case .badAddress: return "Address won't work"
        case .unknown: return "Can't connect"
        }
    }

    static let restoring = OfflineCopy(symbol: "antenna.radiowaves.left.and.right", title: "Back in range",
                                       message: "Loading your sessions…")
}

/// The second button, when the problem has one.
enum OfflineAction: Equatable {
    case openTailscale, openSettings, serverSettings

    var title: String {
        switch self {
        case .openTailscale: return "Open Tailscale"
        case .openSettings: return "Open Settings"
        case .serverSettings: return "Server Settings"
        }
    }

    static let tailscaleURL = URL(string: "tailscale://")!

    /// `tailscaleInstalled`: `canOpenURL` for Tailscale's scheme (listed in LSApplicationQueriesSchemes).
    static func secondary(for kind: ConnectionProblem.Kind, tailscaleInstalled: Bool) -> OfflineAction? {
        switch kind {
        case .noInternet: return .openSettings
        case .offPrivateNetwork, .notAllowed: return tailscaleInstalled ? .openTailscale : nil
        case .hostNotFound, .insecure: return .serverSettings
        case .badAddress, .notAnswering, .unknown: return nil
        }
    }
}

/// "Signal lost": the static backdrop with a solid card on top that says what's wrong and what to do.
/// The card never moves or flickers; only the backdrop and the glyph's color ghosts animate. Retries
/// run in the background and don't touch it, Try Again shows "Trying…" while its attempt runs, and
/// once the server is back the static settles and the card says so until the sessions are in.
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
    @State private var tailscaleInstalled = false

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
                let page = Self.page(size: geo.size, origin: origin, division)
                ScrollView {
                    card(problem, theme)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 24)
                        .frame(maxWidth: .infinity, minHeight: geo.size.height - page.top - page.bottom)
                        .padding(EdgeInsets(top: page.top, leading: page.leading, bottom: page.bottom, trailing: page.trailing))
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .contentShape(Rectangle())
        .onAppear { tailscaleInstalled = UIApplication.shared.canOpenURL(OfflineAction.tailscaleURL) }
        .onChange(of: server.retrying) { was, now in
            // The attempt the person asked for failed: a soft bump, the card stays as it was.
            if was, !now, server.phase.problem != nil { Haptic.bump() }
        }
        .onChange(of: problem == nil) { _, back in if back { Haptic.selection() } }
    }

    /// Insets that keep the card on one page of an unfolded Duo, the larger one, instead of across the
    /// crease. No insets when there's no crease here, or the larger page is too small for the card.
    static func page(size: CGSize, origin: CGPoint, _ division: Division?) -> EdgeInsets {
        guard let d = division else { return EdgeInsets() }
        if d.isVertical {
            let lo = d.frame.minX - origin.x, hi = d.frame.maxX - origin.x
            guard lo > 0, hi < size.width else { return EdgeInsets() }
            let left = lo, right = size.width - hi
            guard max(left, right) >= 300 else { return EdgeInsets() }
            return right >= left ? EdgeInsets(top: 0, leading: hi, bottom: 0, trailing: 0)
                                 : EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: size.width - lo)
        }
        let lo = d.frame.minY - origin.y, hi = d.frame.maxY - origin.y
        guard lo > 0, hi < size.height else { return EdgeInsets() }
        let above = lo, below = size.height - hi
        guard max(above, below) >= 420 else { return EdgeInsets() }
        return above >= below ? EdgeInsets(top: 0, leading: 0, bottom: size.height - lo, trailing: 0)
                              : EdgeInsets(top: hi, leading: 0, bottom: 0, trailing: 0)
    }

    private func card(_ problem: ConnectionProblem?, _ theme: TermTheme) -> some View {
        let copy = problem.map { OfflineCopy.of($0.kind, server: server.config.name, address: server.config.url) } ?? .restoring
        return VStack(spacing: 0) {
            GlitchGlyph(symbol: copy.symbol, theme: theme, size: 34)
                .frame(width: 56, height: 44)
                .padding(.bottom, 14)
                .accessibilityHidden(true)
            Text(problem == nil ? "SIGNAL FOUND" : "SIGNAL LOST")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .tracking(2.4)
                .foregroundStyle(problem == nil ? theme.chrome.done : theme.accent)
                .padding(.bottom, 8)
                .accessibilityHidden(true)
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
                actions(problem, theme)
                    .padding(.top, 20)
                details(problem, theme)
                    .padding(.top, 8)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .tint(theme.chrome.secondary)
                    .padding(.top, 18)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 14)
        .frame(maxWidth: 360)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(theme.bg)
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(theme.chrome.divider, lineWidth: 1))
        )
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func actions(_ problem: ConnectionProblem, _ theme: TermTheme) -> some View {
        VStack(spacing: 4) {
            if problem.kind == .badAddress {
                PrimaryButton(title: "Server Settings", busy: false, theme: theme) { model.showSettings = true }
            } else {
                PrimaryButton(title: "Try Again", busyTitle: "Trying…", busy: server.retrying, theme: theme) {
                    Haptic.tap()
                    server.retryNow()
                }
                if let a = OfflineAction.secondary(for: problem.kind, tailscaleInstalled: tailscaleInstalled) {
                    Button(a.title) { perform(a) }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(theme.accent)
                        .frame(minWidth: 200, minHeight: 44)
                        .contentShape(Rectangle())
                }
            }
            // The tab's title bar, with the sidebar toggle, is under this screen.
            if !sidebarVisible {
                Button("Show Sidebar") { sidebarVisible = true }
                    .font(.footnote)
                    .foregroundStyle(theme.chrome.secondary)
                    .frame(minHeight: 44)
            }
        }
    }

    private func details(_ problem: ConnectionProblem, _ theme: TermTheme) -> some View {
        VStack(spacing: 2) {
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

    private func perform(_ a: OfflineAction) {
        Haptic.tap()
        switch a {
        case .openTailscale: UIApplication.shared.open(OfflineAction.tailscaleURL)
        case .openSettings:
            if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
        case .serverSettings: model.showSettings = true
        }
    }
}

/// The filled capsule button. Busy swaps the title for a spinner and `busyTitle` in the same frame,
/// so nothing around it moves.
private struct PrimaryButton: View {
    let title: String
    var busyTitle: String = ""
    let busy: Bool
    let theme: TermTheme
    let action: () -> Void

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
            .frame(width: 200, height: 46)
            .background(Capsule().fill(theme.accent.opacity(busy ? 0.85 : 1)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: busy)
        .accessibilityLabel(busy ? busyTitle : title)
    }
}
