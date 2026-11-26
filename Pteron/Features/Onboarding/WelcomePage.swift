import SwiftUI

/// The first screen: Glide over the static, and a card that says what the app is, with Get
/// Started and, for someone whose computer already shows a code, a way straight to the scanner
/// (by the Tailscale step when this iPhone isn't on a tailnet yet).
struct WelcomePage: View {
    let flow: OnboardingModel
    let theme: TermTheme
    @Environment(AppModel.self) private var model

    private var onTailnet: Bool { model.network?.snapshot.onPrivateNetwork == true }

    var body: some View {
        VStack(spacing: 0) {
            GuideRegion { layout, size in
                ZStack(alignment: .topLeading) {
                    if let art = layout.art {
                        GlideMark(width: min(art.width - 64, art.height - 64, 220))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .guidePlaced(in: art)
                        GuideColumn(height: layout.card.height) { card }
                            .guidePlaced(in: layout.card)
                    } else {
                        GuideColumn(height: size.height) {
                            GlideMark(width: size.height < 560 ? 72 : 110)
                                .padding(.bottom, 28)
                            card
                        }
                        .guidePlaced(in: layout.card)
                    }
                }
                .frame(width: size.width, height: size.height, alignment: .topLeading)
            }
        }
    }

    private var card: some View {
        VStack(spacing: 0) {
            Text("Your Rex sessions, on your \(DeviceWord.current).")
                .font(.title2.weight(.semibold))
                .foregroundStyle(theme.fg)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .padding(.bottom, 8)
            Text("Run and answer your coding agents from anywhere.")
                .font(.subheadline)
                .foregroundStyle(theme.chrome.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 4) {
                PrimaryButton(title: "Get Started", busy: false, theme: theme) {
                    Haptic.tap()
                    flow.getStarted()
                }
                GuideLink(title: "I Have a Pairing Code", theme: theme) { flow.havePairingCode() }
                    .accessibilityHint(onTailnet ? "Opens the camera, to scan the code Rex shows on your computer."
                                                 : "Shows how to connect this \(DeviceWord.current) with Tailscale, then opens the camera.")
            }
            .padding(.top, 24)
        }
        .padding(.horizontal, 24)
        .padding(.top, 26)
        .padding(.bottom, 12)
        .frame(maxWidth: 360)
        .background(GuideCardBackground(theme: theme))
        .accessibilityElement(children: .contain)
    }
}
