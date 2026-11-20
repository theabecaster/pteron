import GlanceModel
import SwiftUI
import UIKit

/// The checklist: the three things that connect a computer, in order, then Scan Code.
///
/// 1. Tailscale on this iPhone. Its tick comes from `NetworkWatch` (a Tailscale address on this
///    iPhone) and changes as Tailscale comes and goes. It only tells; nothing waits for it.
/// 2. Rex serving over Tailscale on the computer, for Rex's Mac app or its command line.
/// 3. Pairing: where the computer shows its code. Scan Code opens the scanner; Enter Address and
///    Not Now are always there.
struct ConnectPage: View {
    @Bindable var flow: OnboardingModel
    let theme: TermTheme
    @Environment(AppModel.self) private var model
    /// Scan Code and the links under it, measured: the steps get the room above.
    @State private var actionsHeight: CGFloat = 110
    @Environment(\.dynamicTypeSize) private var typeSize

    /// Never claimed without a Tailscale address on this iPhone. Unknown (tests) reads as no.
    private var tailscaleOn: Bool { model.network?.snapshot.onPrivateNetwork == true }

    var body: some View {
        VStack(spacing: 0) {
            GuideBar(theme: theme, back: flow.canGoBack ? { flow.back() } : nil)
            GuideRegion { layout, size in
                // The buttons stay in sight at the bottom; the steps scroll above them when they
                // need more room (a short window, large text).
                let steps = max(layout.card.height - actionsHeight, 0)
                ZStack(alignment: .topLeading) {
                    if let art = layout.art {
                        GuideColumn(height: art.height) { header(glide: min(art.width - 96, 150)) }
                            .guidePlaced(in: art)
                    }
                    VStack(spacing: 0) {
                        GuideColumn(height: steps) {
                            if layout.art == nil {
                                // A short window or large text: the steps get Glide's room.
                                header(glide: size.height < 700 || typeSize.isAccessibilitySize ? 0 : 64)
                                    .padding(.bottom, 20)
                            }
                            checklist
                        }
                        .frame(height: steps)
                        actions
                            // Its own height: the measure below then gives the steps the rest.
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 8)
                            .padding(.bottom, 8)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { actionsHeight = $0 }
                    }
                    .guidePlaced(in: layout.card)
                }
                .frame(width: size.width, height: size.height, alignment: .topLeading)
            }
        }
        .onChange(of: tailscaleOn) { _, on in
            if on { UIAccessibility.post(notification: .announcement, argument: "Tailscale is connected on this iPhone.") }
        }
    }

    /// `glide`: Glide's width, 0 for none (a short window).
    private func header(glide: CGFloat) -> some View {
        VStack(spacing: 8) {
            if glide > 0 {
                GlideMark(width: glide).padding(.bottom, 10)
            }
            Text("Connect your computer")
                .font(.title2.weight(.semibold))
                .foregroundStyle(theme.fg)
                .accessibilityAddTraits(.isHeader)
            Text("\(Brand.appName) connects to your computer privately, through Tailscale.")
                .font(.subheadline)
                .foregroundStyle(theme.chrome.secondary)
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 360)
    }

    private var checklist: some View {
        VStack(spacing: 0) {
            row(1, "Tailscale on this iPhone", done: tailscaleOn) {
                if tailscaleOn {
                    detail("Connected.", color: theme.chrome.done)
                } else {
                    Button(action: flow.getTailscale) {
                        Label("Get Tailscale", systemImage: "arrow.down.circle")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(theme.accent)
                            .frame(minHeight: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens Tailscale in the App Store.")
                    detail("Then sign in and turn it on.")
                }
            }
            separator
            row(2, "Turn on Tailscale in Rex") {
                Picker("Computer", selection: $flow.computer) {
                    ForEach(OnboardingModel.Computer.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 220)
                .padding(.vertical, 2)
                switch flow.computer {
                case .mac:
                    path("In Rex: Settings → Server → Tailscale → Serve over Tailscale.")
                case .linux:
                    CommandChip(command: "rex server tailscale on", theme: theme)
                    detail("If it asks you to sign in, \(code("rex server status")) shows the link.")
                }
                detail("Sign in with the same account as on this iPhone.")
            }
            separator
            row(3, "Show the pairing code") {
                switch flow.computer {
                case .mac:
                    path("In Rex: Settings → Server → Remote Address → Pair.")
                case .linux:
                    CommandChip(command: "rex server tailscale pair", theme: theme)
                }
                detail("Then tap Scan Code.")
            }
        }
        .frame(maxWidth: 420)
        .background(GuideCardBackground(theme: theme))
        // The steps follow the computer picked, in place.
        .animation(.smooth(duration: 0.25), value: flow.computer)
    }

    private var actions: some View {
        VStack(spacing: 4) {
            PrimaryButton(title: "Scan Code", busy: false, theme: theme) {
                Haptic.tap()
                flow.pair()
            }
            .accessibilityHint("Opens the camera, to scan the code the computer shows.")
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { secondary }
                VStack(spacing: 0) { secondary }
            }
        }
    }

    @ViewBuilder
    private var secondary: some View {
        GuideLink(title: "Enter Address", theme: theme) { flow.enterAddress() }
        GuideLink(title: flow.closeTitle, theme: theme, quiet: true) { flow.close() }
    }

    // MARK: Parts

    private func row<Content: View>(_ n: Int, _ title: String, done: Bool = false,
                                    @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            StepBadge(number: n, done: done, theme: theme)
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.fg)
                    .fixedSize(horizontal: false, vertical: true)
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .accessibilityElement(children: .contain)
    }

    private var separator: some View {
        Rectangle().fill(theme.chrome.divider).frame(height: 1).padding(.leading, 52)
    }

    private func detail(_ text: LocalizedStringKey, color: Color? = nil) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(color ?? theme.chrome.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Where a setting is in Rex's Mac app. VoiceOver reads the steps with pauses, not arrows.
    private func path(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(theme.fg)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(text.replacingOccurrences(of: " → ", with: ", "))
    }

    private func code(_ command: String) -> Text {
        Text(command).font(Font(RexFont.ui(UIFontMetrics(forTextStyle: .footnote).scaledValue(for: 12))))
    }
}

/// A step's number in a ring, or a tick once the app can see it is done.
private struct StepBadge: View {
    let number: Int
    let done: Bool
    let theme: TermTheme
    @ScaledMetric(relativeTo: .subheadline) private var side: CGFloat = 24
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if done {
                Circle().fill(theme.chrome.done)
                Image(systemName: "checkmark")
                    .font(.system(size: side * 0.46, weight: .bold))
                    .foregroundStyle(theme.bg)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.4).combined(with: .opacity))
            } else {
                Circle().stroke(theme.chrome.divider, lineWidth: 1.5)
                Text("\(number)")
                    .font(.system(size: side * 0.5, weight: .semibold))
                    .foregroundStyle(theme.chrome.secondary)
            }
        }
        .frame(width: side, height: side)
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.35, dampingFraction: 0.7), value: done)
        .accessibilityHidden(true)
    }
}

/// A command to run on the computer, in Rex's terminal font. A tap copies it.
private struct CommandChip: View {
    let command: String
    let theme: TermTheme
    @ScaledMetric(relativeTo: .footnote) private var size: CGFloat = 12
    @State private var copied = false

    var body: some View {
        Button {
            UIPasteboard.general.string = command
            Haptic.selection()
            copied = true
            UIAccessibility.post(notification: .announcement, argument: "Copied")
        } label: {
            HStack(spacing: 10) {
                Text(command)
                    .font(Font(RexFont.ui(size)))
                    .foregroundStyle(theme.fg)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(copied ? theme.chrome.done : theme.chrome.tertiary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(minHeight: 36)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.fg.opacity(theme.isDark ? 0.06 : 0.05)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Copy \(command)")
        // The tick goes back to the copy glyph after a moment.
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if !Task.isCancelled { copied = false }
        }
    }
}
