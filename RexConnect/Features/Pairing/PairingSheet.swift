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
    /// The person would rather type the address. Called as the sheet is dismissed.
    let onEnterAddress: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(Prefs.self) private var prefs
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    @State private var pairing: PairingModel?
    @State private var access = CameraAccess.asking
    @State private var torch = false
    @State private var showDetails = false

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
            .navigationTitle("Pair via QR Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
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
        .onChange(of: pairing?.step) { _, _ in
            torch = false
            showDetails = false
        }
    }

    // MARK: Steps

    @ViewBuilder
    private func content(_ pairing: PairingModel, _ theme: TermTheme, _ layout: PairingLayout) -> some View {
        switch pairing.step {
        case .scanning:
            switch access {
            case .asking:
                Color.clear
            case .granted:
                scanner(pairing, theme, layout)
            case .denied:
                PairingCard(theme: theme, glyph: .symbol("camera"), title: "Camera is off",
                            message: "Rex DUO needs the camera to scan a pairing code. Allow it in Settings.") {
                    PrimaryButton(title: "Open Settings", busy: false, theme: theme) {
                        Haptic.tap()
                        if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
                    }
                    SecondaryButton(title: "Enter Address Instead", theme: theme, action: enterAddress)
                }
            case .unavailable:
                PairingCard(theme: theme, glyph: .symbol("camera"), title: "No camera",
                            message: "This device has no camera to scan a pairing code with.") {
                    PrimaryButton(title: "Enter Address Instead", busy: false, theme: theme, action: enterAddress)
                }
            }
        case .checking(let url):
            PairingCard(theme: theme, glyph: .spinner, title: "Looking for that computer",
                        message: url.host() ?? url.absoluteString, monospacedMessage: true) {
                SecondaryButton(title: "Cancel", theme: theme) { pairing.rescan() }
            }
        case .found(let url):
            FoundCard(pairing: pairing, theme: theme, url: url) { dismiss() }
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

    @ViewBuilder
    private func scanner(_ pairing: PairingModel, _ theme: TermTheme, _ layout: PairingLayout) -> some View {
        switch layout {
        case .sideBySide(let width):
            HStack(spacing: 0) {
                camera(pairing, theme).frame(width: width)
                instructions(theme).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .stacked(let height):
            VStack(spacing: 0) {
                if let height {
                    camera(pairing, theme).frame(height: height)
                    instructions(theme).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    camera(pairing, theme)
                    instructions(theme).padding(.top, 8).padding(.bottom, 16)
                }
            }
        }
    }

    private func camera(_ pairing: PairingModel, _ theme: TermTheme) -> some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        return QRCameraView(torch: torch) { code in
            if pairing.scanned(code) { Haptic.success() }
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

    private func enterAddress() {
        dismiss()
        onEnterAddress()
    }

    private func begin() async {
        guard pairing == nil else { return }
        let p = PairingModel(
            servers: { [prefs] in prefs.servers },
            probe: { [model] url in await model.probe(url) },
            onExisting: { [model] saved in
                finish()
                Notice.shared.show("\(saved.name) is already added.")
                model.kick(saved)
            },
            onAdd: { [model] config in
                model.addServer(config)
                Haptic.success()
                finish()
            })
        pairing = p
        access = await CameraAccess.resolve()
        #if DEBUG
        // `-simulateScan <payload>` (testing): the camera reads this once the scanner is up.
        // `-simulateScan open` only opens the scanner.
        if let payload = UserDefaults.standard.string(forKey: "simulateScan"), payload != "open" {
            try? await Task.sleep(nanoseconds: 800_000_000)
            if p.scanned(payload) { Haptic.success() }
        }
        #endif
    }

    /// Done: back to the sidebar, where the server is, closing Settings when the scan started there.
    private func finish() {
        dismiss()
        model.showSettings = false
    }
}

/// The offline screen's card: a glyph, a title, a message and the buttons under it, centred. Every
/// step but the camera.
private struct PairingCard<Actions: View>: View {
    enum Glyph {
        case symbol(String)
        /// The offline screen's glyph, for a computer that can't be reached.
        case glitch(String)
        case spinner
    }

    let theme: TermTheme
    let glyph: Glyph
    let title: String
    let message: String
    var monospacedMessage = false
    @ViewBuilder var actions: Actions

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
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(theme.fg)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 6)
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

/// The server answered: its address, a name to change, Add.
private struct FoundCard: View {
    @Bindable var pairing: PairingModel
    let theme: TermTheme
    let url: URL
    let cancel: () -> Void

    var body: some View {
        PairingCard(theme: theme, glyph: .symbol("checkmark.circle"), title: "Computer found",
                    message: url.host() ?? url.absoluteString, monospacedMessage: true) {
            TextField("Name", text: $pairing.name, prompt: Text(ServerConfig.name(for: url)).foregroundStyle(theme.chrome.tertiary))
                .font(.subheadline)
                .foregroundStyle(theme.fg)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .onSubmit { pairing.add() }
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
                .frame(width: 200, height: 44)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(theme.fg.opacity(theme.isDark ? 0.06 : 0.05)))
                .padding(.bottom, 10)
                .accessibilityLabel("Name")
            PrimaryButton(title: "Add", busy: false, theme: theme) { pairing.add() }
            SecondaryButton(title: "Cancel", theme: theme, action: cancel)
        }
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
