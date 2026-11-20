import SwiftUI

/// The setup guide over the whole root while `AppModel.guide` is set: the first run's welcome, or
/// the checklist from Setup Guide. The rest of the time it is nothing, so it costs nothing.
struct OnboardingCover: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        let start = model.guide
        content
            // VoiceOver reads only the guide while it covers the app.
            .accessibilityHidden(start != nil)
            .overlay {
                ZStack {
                    if let start {
                        OnboardingScreen(start: start, model: model)
                            .transition(.opacity)
                    }
                }
                // Not Now, or a computer added: the guide dissolves into what is under it.
                .animation(.easeInOut(duration: 0.35), value: start)
            }
    }
}

/// The guide: three steps, each its own screen, cross-fading into the next.
///
/// - Welcome: Glide over the offline screen's static, what the app is, Get Started.
/// - Tour: two cards, paged with a spring.
/// - Connect: the checklist, with Scan Code.
///
/// Each screen lays itself out from its size and the fold, as the offline screen does
/// (`OfflineLayout`): one column, or on the unfolded Duo the art on one page and the words and
/// buttons on the other, clear of the crease.
struct OnboardingScreen: View {
    @Environment(Prefs.self) private var prefs
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var flow: OnboardingModel

    init(start: OnboardingStart, model: AppModel) {
        _flow = State(initialValue: OnboardingModel(start: start, effects: .init(
            pair: { [weak model] in
                model?.pairingStart = nil
                model?.showPairing = true
            },
            enterAddress: { [weak model] in model?.openSettings(at: .addServer) },
            getTailscale: { TailscaleApp.showInAppStore() },
            close: { [weak model] in model?.closeGuide() })))
    }

    var body: some View {
        let theme = prefs.theme(for: scheme)
        ZStack {
            theme.bg.ignoresSafeArea()
            // Only behind the welcome, where Glide and its card sit on it as on the offline screen.
            // Off screen it is gone, with its animations.
            if flow.step == .welcome {
                SignalStatic(theme: theme, level: .locked)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .transition(.opacity)
            }
            ZStack {
                switch flow.step {
                case .welcome: WelcomePage(flow: flow, theme: theme).transition(section)
                case .tour: TourPage(flow: flow, theme: theme).transition(section)
                case .connect: ConnectPage(flow: flow, theme: theme).transition(section)
                }
            }
        }
        .animation(.smooth(duration: 0.35), value: flow.step)
        .onChange(of: flow.step) { _, _ in
            // VoiceOver starts again at the top of the new screen.
            UIAccessibility.post(notification: .screenChanged, argument: nil)
        }
        #if DEBUG
        .task { await playDemo() }
        #endif
    }

    #if DEBUG
    /// `-guideDemo YES` (testing): the first run plays itself through, each step as its tap would
    /// make it, for a recording: Get Started, Continue, Continue, Linux, Back, Skip, Not Now.
    private func playDemo() async {
        guard UserDefaults.standard.bool(forKey: "guideDemo") else { return }
        let steps: [(Double, () -> Void)] = [
            (2.5, { flow.getStarted() }),
            (2.2, { withAnimation(TourPage.spring) { flow.next() } }),
            (2.2, { withAnimation(TourPage.spring) { flow.next() } }),
            (2.0, { flow.computer = .linux }),
            (2.0, { flow.back() }),
            (1.8, { flow.skip() }),
            (2.0, { flow.close() }),
        ]
        for (wait, step) in steps {
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            if Task.isCancelled { return }
            step()
        }
    }
    #endif

    /// Between steps: a cross-fade, with a slight settle unless Reduce Motion is on.
    private var section: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.97))
    }
}

// MARK: - Parts every screen uses

/// The size and the layout of the region under the bar, from the fold.
struct GuideRegion<Content: View>: View {
    @Environment(\.division) private var division
    @Environment(\.rootOrigin) private var rootOrigin
    @ViewBuilder var content: (OfflineLayout, CGSize) -> Content

    var body: some View {
        GeometryReader { geo in
            let global = geo.frame(in: .global).origin
            let origin = CGPoint(x: global.x - rootOrigin.x, y: global.y - rootOrigin.y)
            content(OfflineLayout.decide(size: geo.size, origin: origin, division: division), geo.size)
        }
    }
}

extension View {
    /// Puts a view in `rect` of a top-leading `ZStack`.
    func guidePlaced(in rect: CGRect) -> some View {
        frame(width: rect.width, height: rect.height).offset(x: rect.minX, y: rect.minY)
    }
}

/// A column that centers its content in `height` and scrolls when large text makes it taller.
struct GuideColumn<Content: View>: View {
    let height: CGFloat
    var maxWidth: CGFloat = 420
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(spacing: 0) { content }
                // Its own height, never the one the frame below would squeeze it to.
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .frame(maxWidth: maxWidth)
                .frame(maxWidth: .infinity, minHeight: height)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicators(.hidden)
    }
}

/// Back on the leading side, Skip on the trailing one, each only where it applies.
struct GuideBar: View {
    let theme: TermTheme
    var back: (() -> Void)?
    var skip: (() -> Void)?

    var body: some View {
        HStack(spacing: 0) {
            if let back {
                Button(action: back) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.body.weight(.semibold))
                        Text("Back")
                    }
                    .foregroundStyle(theme.accent)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
            }
            Spacer(minLength: 0)
            if let skip {
                Button(action: skip) {
                    Text("Skip")
                        .foregroundStyle(theme.chrome.secondary)
                        .padding(.horizontal, 16)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Goes to the steps to connect a computer.")
            }
        }
        .font(.body)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .padding(.horizontal, 4)
        .frame(height: 44)
    }
}

/// Glide, the launch screen's art. Decoration only: VoiceOver skips it.
struct GlideMark: View {
    let width: CGFloat

    var body: some View {
        Image(LaunchArt.assetName)
            .resizable()
            .interpolation(.high)
            .aspectRatio(LaunchArt.size, contentMode: .fit)
            .frame(width: width)
            .accessibilityHidden(true)
    }
}

/// The offline screen's card: the theme's background, a hairline border, rounded 22 pt.
struct GuideCardBackground: View {
    let theme: TermTheme

    var body: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(theme.bg)
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(theme.chrome.divider, lineWidth: 1))
    }
}

/// The offline screen's second button: accent text, a full-size touch target, wrapping with
/// large text. `quiet` greys it, for a way out.
struct GuideLink: View {
    let title: String
    let theme: TermTheme
    var quiet = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(quiet ? theme.chrome.secondary : theme.accent)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
