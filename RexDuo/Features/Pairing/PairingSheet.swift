import SwiftUI
import UIKit

/// Where the camera and the instructions go. Pure, so it is tested.
enum PairingLayout: Equatable {
    /// Camera on the leading page, instructions on the trailing one. `camera` is the camera's width.
    case sideBySide(camera: CGFloat)
    /// Camera above the instructions. `camera` is its height when a horizontal crease sets it;
    /// nil lets the camera take what the instructions leave.
    case stacked(camera: CGFloat?)

    /// Narrowest window worth two pages.
    static let minSideBySide: CGFloat = 600
    /// Smallest page either side of a crease that the layout follows the crease for.
    static let minPage: CGFloat = 240

    static func decide(size: CGSize, division: Division?) -> PairingLayout {
        if let d = division {
            if d.isVertical, d.frame.minX >= minPage, size.width - d.frame.maxX >= minPage {
                return .sideBySide(camera: d.frame.minX)
            }
            if !d.isVertical, d.frame.minY >= minPage, size.height - d.frame.maxY >= minPage {
                return .stacked(camera: d.frame.minY)
            }
        }
        if size.width >= minSideBySide, size.width > size.height {
            return .sideBySide(camera: (size.width / 2).rounded())
        }
        return .stacked(camera: nil)
    }
}

/// "Pair via QR Code": scan the code a computer shows for `rex server tailscale pair`, check that
/// this iPhone can reach it, name it, add it. Full screen, in the offline screen's look: the
/// theme's background, one bordered card, the capsule button.
struct PairingSheet: View {
    /// The person would rather type the address. The presenter acts on it once the sheet is gone
    /// (`pairingCover`).
    let onEnterAddress: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(Prefs.self) private var prefs
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pairing: PairingModel?
    @State private var access = CameraAccess.asking
    @State private var torch = false
    @State private var showDetails = false
    /// Opened for a computer picked from a list: there is no camera to go back to.
    @State private var picked = false
    /// The pause that shows the checkmark before the sheet leaves.
    @State private var leaving: Task<Void, Never>?
    /// The computer just added has no helper: the page that offers to install it.
    @State private var offer: ServerConfig?

    var body: some View {
        let theme = prefs.theme(for: scheme)
        NavigationStack {
            GeometryReader { geo in
                if let pairing {
                    content(pairing, theme, PairingLayout.decide(size: geo.size, division: RootView.division(geo)))
                        .frame(width: geo.size.width, height: geo.size.height)
                }
            }
            .background(theme.bg.ignoresSafeArea())
            .navigationTitle(picked ? "Add Computer" : "Pair via QR Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Once the server is added there is nothing left to cancel.
                if pairing?.isFinished != true {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                }
                if pairing?.step == .scanning, access == .granted, CameraAccess.hasTorch {
                    ToolbarItem(placement: .primaryAction) {
                        Button { torch.toggle() } label: {
                            Label(torch ? "Turn Light Off" : "Turn Light On",
                                  systemImage: torch ? "flashlight.on.fill" : "flashlight.off.fill")
                        }
                    }
                }
            }
        }
        .tint(theme.accent)
        .preferredColorScheme(theme.isDark ? .dark : .light)
        .task { await begin() }
        .onDisappear {
            pairing?.cancel()
            leaving?.cancel()
        }
        .onChange(of: pairing?.step) { _, _ in
            torch = false
            showDetails = false
            // VoiceOver moves to the new step's card.
            UIAccessibility.post(notification: .screenChanged, argument: nil)
        }
        .onChange(of: pairing?.rejection) { _, text in
            if let text { UIAccessibility.post(notification: .announcement, argument: text) }
        }
        .onChange(of: scenePhase) { _, phase in
            // Back from Settings, where the person may have allowed the camera.
            guard phase == .active, access == .denied else { return }
            Task { access = await CameraAccess.resolve() }
        }
    }

    // MARK: Steps

    /// The camera stays where it is for the whole run. Once a code is read its picture freezes
    /// under a dim, and the card for that step sits on top.
    @ViewBuilder
    private func content(_ pairing: PairingModel, _ theme: TermTheme, _ layout: PairingLayout) -> some View {
        let scanning = pairing.step == .scanning
        ZStack {
            if access == .granted {
                scanner(pairing, theme, layout, frozen: !scanning)
                    .disabled(!scanning)
                    .accessibilityHidden(!scanning)
                theme.bg.opacity(scanning ? 0 : 0.78)
                    .ignoresSafeArea()
                    .allowsHitTesting(!scanning)
            }
            if let offer {
                offerPage(offer, theme)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96)))
            } else {
                card(pairing, theme)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .animation(.smooth(duration: 0.3), value: pairing.step)
        .animation(.smooth(duration: 0.3), value: offer)
        .animation(.smooth(duration: 0.3), value: access)
    }

    @ViewBuilder
    private func card(_ pairing: PairingModel, _ theme: TermTheme) -> some View {
        switch pairing.step {
        case .scanning:
            switch access {
            case .asking, .granted:
                EmptyView()
            case .denied:
                PairingCard(theme: theme, glyph: .symbol("camera"), title: "Camera is off",
                            message: "Rex DUO needs the camera to scan a pairing code. Allow it in Settings.") {
                    PrimaryButton(title: "Open Settings", busy: false, theme: theme) {
                        Haptic.tap()
                        if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
                    }
                    SecondaryButton(title: "Enter Address Instead", theme: theme, action: enterAddress)
                }
            case .restricted:
                PairingCard(theme: theme, glyph: .symbol("camera"), title: "Camera is restricted",
                            message: "This iPhone doesn't allow apps to use the camera, so Rex DUO can't scan a pairing code.") {
                    PrimaryButton(title: "Enter Address Instead", busy: false, theme: theme, action: enterAddress)
                }
            case .unavailable:
                PairingCard(theme: theme, glyph: .symbol("camera"), title: "Camera isn't available",
                            message: "Rex DUO can't use the camera right now to scan a pairing code.") {
                    PrimaryButton(title: "Enter Address Instead", busy: false, theme: theme, action: enterAddress)
                }
            }
        case .checking(let url):
            PairingCard(theme: theme, glyph: .spinner, title: "Looking for that computer",
                        message: url.host() ?? url.absoluteString, monospacedMessage: true) {
                SecondaryButton(title: "Cancel", theme: theme) { back(pairing) }
            }
        case .found(let url, let identity):
            IdentityCard(pairing: pairing, theme: theme, url: url, copy: .of(identity), added: false) { back(pairing) }
        case .added(let url, let identity):
            IdentityCard(pairing: pairing, theme: theme, url: url, copy: .of(identity), added: true) {}
        case .done:
            EmptyView()
        case .problem(let url, let problem):
            PairingCard(theme: theme, glyph: .glitch(problem.symbol), title: problem.title, message: problem.message) {
                if problem.actions.contains(.tryAgain) {
                    PrimaryButton(title: "Try Again", busy: false, theme: theme) {
                        Haptic.tap()
                        pairing.tryAgain()
                    }
                }
                if problem.actions.contains(.addAnyway) {
                    SecondaryButton(title: "Add Anyway", theme: theme) { pairing.addAnyway() }
                }
                SecondaryButton(title: "Cancel", theme: theme) { dismiss() }
                if let detail = problem.detail { details("\(url.absoluteString)\n\(detail)", theme) }
            }
        }
    }

    /// After "added", for a computer of the person's own with no helper: offer to install it.
    /// Install closes this sheet and opens the install sheet; Skip is remembered, so pairing
    /// never asks about this computer again.
    private func offerPage(_ config: ServerConfig, _ theme: TermTheme) -> some View {
        GeometryReader { geo in
            ScrollView {
                HelperOfferCard(name: config.name, theme: theme) {
                    model.helperSetup.request(config.id, kind: .install)
                    leave(config)
                } onSkip: {
                    prefs.helperOfferSkipped.insert(config.id)
                } onLeave: {
                    leave(config)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity, minHeight: geo.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private func leave(_ config: ServerConfig) {
        finish()
        model.land(on: config)
    }

    /// One camera and one set of instructions in one stack, whichever way it runs, so a fold, a
    /// rotation or a resize moves the camera instead of rebuilding it and restarting its session.
    private func scanner(_ pairing: PairingModel, _ theme: TermTheme, _ layout: PairingLayout, frozen: Bool) -> some View {
        let stack: AnyLayout
        var width: CGFloat?, height: CGFloat?
        var paged = true
        switch layout {
        case .sideBySide(let camera):
            stack = AnyLayout(HStackLayout(spacing: 0))
            width = camera
        case .stacked(let camera):
            stack = AnyLayout(VStackLayout(spacing: 0))
            height = camera
            paged = camera != nil
        }
        return stack {
            camera(pairing, theme, frozen: frozen)
                .frame(width: width, height: height)
            instructions(theme)
                .padding(.top, paged ? 0 : 8)
                .padding(.bottom, paged ? 0 : 16)
                .frame(maxWidth: .infinity, maxHeight: paged ? .infinity : nil)
        }
    }

    private func camera(_ pairing: PairingModel, _ theme: TermTheme, frozen: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        return QRCameraView(torch: $torch, frozen: frozen) { code in
            // A light tap for "read". The success haptic waits for the server to be added.
            if pairing.scanned(code) { Haptic.tap() }
        } onFailure: {
            access = .unavailable
        }
        .overlay { Viewfinder(color: theme.accent).padding(36) }
        .overlay(alignment: .bottom) {
            if let text = pairing.rejection {
                Text(text)
                    .font(.footnote)
                    .foregroundStyle(theme.fg)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(Capsule().fill(theme.chrome.sidebar))
                    .overlay(Capsule().stroke(theme.chrome.divider, lineWidth: 1))
                    .padding(.bottom, 16)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: pairing.rejection)
        .clipShape(shape)
        .overlay(shape.stroke(theme.chrome.divider, lineWidth: 1))
        .padding(12)
        .accessibilityElement()
        .accessibilityLabel("Camera")
        .accessibilityValue(pairing.rejection ?? "Looking for a pairing code")
    }

    private func instructions(_ theme: TermTheme) -> some View {
        VStack(spacing: 6) {
            Text("On your computer, run\n`rex server tailscale pair`\nthen point the camera at the code it shows.")
                .font(.subheadline)
                .foregroundStyle(theme.chrome.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 340)
                .padding(.horizontal, 24)
            SecondaryButton(title: "Enter Address Instead", theme: theme, action: enterAddress)
        }
    }

    /// The offline screen's collapsed technical line.
    private func details(_ text: String, _ theme: TermTheme) -> some View {
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
                Text(text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.chrome.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Wiring

    /// Not this computer: back to the camera, or out when there was none.
    private func back(_ pairing: PairingModel) {
        if picked { dismiss() } else { pairing.rescan() }
    }

    private func enterAddress() {
        onEnterAddress()
        dismiss()
    }

    private func begin() async {
        guard pairing == nil else { return }
        let p = PairingModel(
            servers: { [prefs] in prefs.servers },
            probe: { [model] url in await model.check(url) },
            onExisting: { [model] saved in
                finish()
                Notice.shared.show("\(saved.name) is already added.", style: .neutral)
                model.show(saved)
            },
            onAdd: { [model] config in
                model.addServer(config)
                Haptic.success()
                UIAccessibility.post(notification: .announcement, argument: "\(config.name) added")
                // What the computer said about itself decides the offer, before the card goes.
                var offers = false
                if case .added(_, let identity) = pairing?.step {
                    offers = HelperOffer.decide(identity) == .install && !prefs.helperOfferSkipped.contains(config.id)
                }
                leaving = Task {
                    // Long enough to see the button turn into its checkmark.
                    try? await Task.sleep(nanoseconds: 450_000_000)
                    guard !Task.isCancelled else { return }
                    if offers {
                        offer = config
                    } else {
                        leave(config)
                    }
                }
            })
        pairing = p
        if let start = model.pairingStart {
            // No camera, so no permission question: the card stands on the plain background.
            model.pairingStart = nil
            picked = true
            p.start(start.candidate, name: start.name)
            return
        }
        access = await CameraAccess.resolve()
        #if DEBUG
        // `-simulateScan <payload>` (testing): the camera reads this once the scanner is up.
        // `-simulateScan open` only opens the scanner.
        if let payload = UserDefaults.standard.string(forKey: "simulateScan"), payload != "open" {
            try? await Task.sleep(nanoseconds: 800_000_000)
            if p.scanned(payload) { Haptic.tap() }
        }
        #endif
    }

    /// Done: back to the sidebar, where the server is, closing Settings when the scan started there.
    private func finish() {
        dismiss()
        model.showSettings = false
    }
}

extension View {
    /// Presents "Pair via QR Code" full screen. `enterAddress` runs after the cover is gone when the
    /// person chose to type the address, so what it presents or focuses next sticks.
    func pairingCover(isPresented: Binding<Bool>, model: AppModel, enterAddress: @escaping () -> Void) -> some View {
        modifier(PairingCover(isPresented: isPresented, model: model, enterAddress: enterAddress))
    }
}

private struct PairingCover: ViewModifier {
    @Binding var isPresented: Bool
    let model: AppModel
    let enterAddress: () -> Void
    @State private var wantsAddress = false

    func body(content: Content) -> some View {
        content.fullScreenCover(isPresented: $isPresented, onDismiss: {
            // A picked computer the sheet never got to must not start the next scan.
            model.pairingStart = nil
            // An install asked for on the offer page starts once this sheet is gone.
            model.helperSetup.presentPending()
            guard wantsAddress else { return }
            wantsAddress = false
            enterAddress()
        }, content: {
            PairingSheet { wantsAddress = true }.environment(model)
        })
    }
}

/// The offline screen's card: a glyph, a title, a message and the buttons under it, centred. Every
/// step but the camera.
private struct PairingCard<Actions: View, Header: View>: View {
    enum Glyph {
        case symbol(String)
        /// The offline screen's glyph, for a computer that can't be reached.
        case glitch(String)
        case spinner
    }

    let theme: TermTheme
    let glyph: Glyph
    /// Nil when `header` stands in for it.
    let title: String?
    let message: String
    var monospacedMessage = false
    @ViewBuilder var actions: Actions
    @ViewBuilder var header: Header

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                card
                    .padding(.horizontal, 20)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity, minHeight: geo.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private var card: some View {
        VStack(spacing: 0) {
            Group {
                switch glyph {
                case .symbol(let name):
                    Image(systemName: name)
                        .font(.system(size: 34))
                        .foregroundStyle(theme.fg.opacity(0.85))
                case .glitch(let name):
                    GlitchGlyph(symbol: name, theme: theme, size: 34)
                case .spinner:
                    ProgressView().controlSize(.regular).tint(theme.chrome.secondary)
                }
            }
            .frame(width: 56, height: 44)
            .padding(.bottom, 14)
            .accessibilityHidden(true)
            if let title {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(theme.fg)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 6)
                    .accessibilityAddTraits(.isHeader)
            }
            header
            Text(message)
                .font(monospacedMessage ? .system(.footnote, design: .monospaced) : .subheadline)
                .foregroundStyle(theme.chrome.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 4) { actions }
                .padding(.top, 20)
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
}

extension PairingCard where Header == EmptyView {
    init(theme: TermTheme, glyph: Glyph, title: String, message: String, monospacedMessage: Bool = false,
         @ViewBuilder actions: () -> Actions) {
        self.init(theme: theme, glyph: glyph, title: title, message: message, monospacedMessage: monospacedMessage,
                  actions: actions, header: { EmptyView() })
    }
}

/// Who the computer is, before it is added: its name (tap to change it), its address, its account,
/// system and sessions, then Add & Open. Two lines show only when they matter: the computer is
/// someone else's, or it has no helper for notifications.
private struct IdentityCard: View {
    @Bindable var pairing: PairingModel
    let theme: TermTheme
    let url: URL
    let copy: IdentityCopy
    /// Added: the button shows its checkmark and nothing responds any more.
    let added: Bool
    let decline: () -> Void

    var body: some View {
        PairingCard(theme: theme, glyph: .symbol(copy.symbol), title: nil,
                    message: url.host() ?? url.absoluteString, monospacedMessage: true) {
            VStack(spacing: 10) {
                if let summary = copy.summary {
                    Text(summary)
                        .font(.subheadline)
                        .foregroundStyle(theme.chrome.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !copy.sessions.isEmpty { sessions }
                if let owner = copy.owner {
                    Label(owner, systemImage: "person.crop.circle.badge.exclamationmark")
                        .font(.footnote)
                        .foregroundStyle(theme.fg)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                }
            }
            .padding(.bottom, 12)
            AddButton(done: added, theme: theme) { pairing.add() }
            SecondaryButton(title: "Not This One", theme: theme, action: decline)
                .opacity(added ? 0 : 1)
                .accessibilityHidden(added)
            if let helper = copy.helper {
                Text(helper)
                    .font(.caption)
                    .foregroundStyle(theme.chrome.tertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 6)
            }
        } header: {
            TextField("Name", text: $pairing.name, prompt: Text(ServerConfig.name(for: url)).foregroundStyle(theme.chrome.tertiary))
                .font(.title3.weight(.semibold))
                .foregroundStyle(theme.fg)
                .multilineTextAlignment(.center)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .padding(.bottom, 6)
                .accessibilityLabel("Name")
                .accessibilityHint("Edit to rename this computer")
        }
        .disabled(added)
    }

    /// The first few session names as chips, then how many more.
    private var sessions: some View {
        HStack(spacing: 6) {
            ForEach(Array(copy.sessions.enumerated()), id: \.offset) { _, name in chip(name) }
            if copy.more > 0 { chip("+\(copy.more)") }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sessions: " + (copy.sessions + (copy.more > 0 ? ["and \(copy.more) more"] : [])).joined(separator: ", "))
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(theme.chrome.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(theme.fg.opacity(theme.isDark ? 0.06 : 0.05)))
    }
}

/// The capsule button for Add & Open: once added, its label turns into a checkmark in place.
private struct AddButton: View {
    let done: Bool
    let theme: TermTheme
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button { if !done { action() } } label: {
            ZStack {
                Text("Add & Open").opacity(done ? 0 : 1)
                Image(systemName: "checkmark")
                    .font(.body.weight(.bold))
                    .opacity(done ? 1 : 0)
                    .scaleEffect(done || reduceMotion ? 1 : 0.5)
            }
            .font(.body.weight(.semibold))
            .foregroundStyle(theme.bg)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 18).padding(.vertical, 8)
            // At least the offline screen's button; taller and wider for large text.
            .frame(minWidth: 200, minHeight: 46)
            .background(Capsule().fill(done ? theme.chrome.done : theme.accent))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(duration: 0.3, bounce: 0.35), value: done)
        .accessibilityLabel(done ? "Added" : "Add and Open")
    }
}

/// The offline screen's second button: accent text, a full-size touch target.
private struct SecondaryButton: View {
    let title: String
    let theme: TermTheme
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(theme.accent)
            .frame(minWidth: 200, minHeight: 44)
            .contentShape(Rectangle())
    }
}

/// Four corner marks: where to hold the code.
private struct Viewfinder: View {
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height, 260)
            let arm = side * 0.16
            Path { p in
                let r = CGRect(x: (geo.size.width - side) / 2, y: (geo.size.height - side) / 2, width: side, height: side)
                for (x, y, dx, dy) in [(r.minX, r.minY, 1.0, 1.0), (r.maxX, r.minY, -1.0, 1.0),
                                       (r.maxX, r.maxY, -1.0, -1.0), (r.minX, r.maxY, 1.0, -1.0)] {
                    p.move(to: CGPoint(x: x + dx * arm, y: y))
                    p.addLine(to: CGPoint(x: x, y: y))
                    p.addLine(to: CGPoint(x: x, y: y + dy * arm))
                }
            }
            .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
