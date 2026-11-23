import RexKit
import SwiftUI

/// The tour: two cards, each a small picture drawn from the app's own parts and two lines under
/// it. A swipe or Continue goes on, with a spring; Back and Skip are in the bar.
///
/// With Reduce Motion the cards cross-fade in place and their pictures hold still.
struct TourPage: View {
    let flow: OnboardingModel
    let theme: TermTheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The dots and Continue, measured: the cards' words center in the room above them.
    @State private var actionsHeight: CGFloat = 110
    /// The pager's position. It starts at the model's card (Back from the checklist lands on the
    /// last one), follows the model's changes with the spring, and tells the model of swipes.
    @State private var position: ScrollPosition

    static let spring = Animation.spring(response: 0.45, dampingFraction: 0.85)

    init(flow: OnboardingModel, theme: TermTheme) {
        self.flow = flow
        self.theme = theme
        _position = State(initialValue: ScrollPosition(id: flow.card ?? .sessions))
    }

    var body: some View {
        VStack(spacing: 0) {
            GuideRegion { layout, size in
                ZStack(alignment: .topLeading) {
                    pager(layout, size)
                        .frame(width: size.width, height: size.height)
                    actions
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { actionsHeight = $0 }
                        .frame(width: layout.card.width, height: layout.card.height, alignment: .bottom)
                        .offset(x: layout.card.minX, y: layout.card.minY)
                }
                .frame(width: size.width, height: size.height, alignment: .topLeading)
            }
        }
    }

    /// A change of card: the spring, or a short cross-fade with Reduce Motion.
    private func go(_ change: () -> Void) {
        withAnimation(reduceMotion ? .easeInOut(duration: 0.25) : Self.spring, change)
    }

    @ViewBuilder
    private func pager(_ layout: OfflineLayout, _ size: CGSize) -> some View {
        if reduceMotion {
            let card = flow.card ?? .sessions
            ZStack {
                page(card, layout, size)
                    .id(card)
                    .transition(.opacity)
            }
            .contentShape(Rectangle())
            .simultaneousGesture(DragGesture(minimumDistance: 24).onEnded { v in
                guard abs(v.translation.width) > abs(v.translation.height), abs(v.translation.width) > 50 else { return }
                if v.translation.width < 0 {
                    // The last card's swipe stays: Continue says where it goes.
                    if card != OnboardingModel.Card.allCases.last { go { flow.next() } }
                } else if card != .sessions {
                    go { flow.back() }
                }
            })
        } else {
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(OnboardingModel.Card.allCases) { card in
                        page(card, layout, size)
                            .frame(width: size.width, height: size.height)
                            .id(card)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition($position)
            .scrollIndicators(.hidden)
            // A scroll view draws into the safe area: the next card would show beside a vertical bar.
            .clipped()
            // The first layout doesn't take the starting position: put it there once laid out.
            .onAppear { position.scrollTo(id: flow.card ?? .sessions) }
            .onChange(of: position.viewID(type: OnboardingModel.Card.self)) { _, swiped in
                if let swiped, swiped != flow.card { flow.card = swiped }
            }
            .onChange(of: flow.card) { _, card in
                guard let card, position.viewID(type: OnboardingModel.Card.self) != card else { return }
                withAnimation(Self.spring) { position.scrollTo(id: card) }
            }
        }
    }

    /// One card: on two pages the picture takes the art page and the words the other.
    private func page(_ card: OnboardingModel.Card, _ layout: OfflineLayout, _ size: CGSize) -> some View {
        let r = layout.card
        let words = CGRect(x: r.minX, y: r.minY, width: r.width, height: max(r.height - actionsHeight, 0))
        let active = flow.card == card
        return ZStack(alignment: .topLeading) {
            if let art = layout.art {
                picture(card, active: active)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .guidePlaced(in: art)
                GuideColumn(height: words.height) { text(card) }
                    .guidePlaced(in: words)
            } else {
                GuideColumn(height: words.height) {
                    // Room above for Glide, perched on the picture's corner.
                    picture(card, active: active)
                        .padding(.top, 36)
                        .padding(.bottom, 32)
                    text(card)
                }
                .guidePlaced(in: words)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func picture(_ card: OnboardingModel.Card, active: Bool) -> some View {
        switch card {
        case .sessions: SessionsArt(theme: theme, active: active)
        case .agents: AgentsArt(theme: theme, active: active)
        }
    }

    private func text(_ card: OnboardingModel.Card) -> some View {
        let (title, line) = switch card {
        case .sessions: ("Your real sessions", "The tabs and panes on your computer, live on your iPhone.")
        case .agents: ("Answer agents anywhere", "See which agent is waiting, and answer it from a notification.")
        }
        return VStack(spacing: 8) {
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(theme.fg)
                .accessibilityAddTraits(.isHeader)
            Text(line)
                .font(.subheadline)
                .foregroundStyle(theme.chrome.secondary)
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 340)
    }

    private var actions: some View {
        let cards = OnboardingModel.Card.allCases
        let index = (flow.card ?? .sessions).rawValue
        return VStack(spacing: 16) {
            HStack(spacing: 6) {
                ForEach(cards) { c in
                    Capsule()
                        .fill(c.rawValue == index ? theme.accent : theme.chrome.tertiary)
                        .frame(width: c.rawValue == index ? 18 : 6, height: 6)
                }
            }
            .animation(reduceMotion ? nil : Self.spring, value: index)
            .accessibilityElement()
            .accessibilityLabel("Card \(index + 1) of \(cards.count)")
            PrimaryButton(title: "Continue", busy: false, theme: theme) {
                Haptic.tap()
                go { flow.next() }
            }
        }
        .padding(.top, 12)
        .padding(.bottom, 16)
    }
}

// MARK: - Pictures

/// How a picture moves once, the first time its card shows: after a beat, with a soft spring.
/// Reduce Motion shows where it would end, still.
private struct OnceOnShow: ViewModifier {
    let active: Bool
    @Binding var shown: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.onChange(of: active, initial: true) { _, now in
            guard now, !shown else { return }
            if reduceMotion {
                shown = true
            } else {
                withAnimation(.spring(response: 0.6, dampingFraction: 0.85).delay(0.3)) { shown = true }
            }
        }
    }
}

/// Glide on the picture's top corner, watching. Still.
private struct Perched: ViewModifier {
    func body(content: Content) -> some View {
        content.overlay(alignment: .topTrailing) {
            GlideMark(width: 40).offset(x: 14, y: -30)
        }
    }
}

/// A tab as the app draws it: the title bar with its tabs, and a pane that splits in two, side by
/// side, as on the computer.
private struct SessionsArt: View {
    let theme: TermTheme
    let active: Bool
    @State private var split = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(theme.chrome.tertiary)
                tab("api", selected: true)
                tab("web", selected: false)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            GeometryReader { g in
                let gap: CGFloat = 4
                let half = (g.size.width - gap) / 2
                HStack(spacing: split ? gap : 0) {
                    pane(["$ npm run dev", "ready in 412 ms", "localhost:5173"], focused: !split)
                        .frame(width: split ? half : g.size.width)
                    pane(["$ git status", "2 files changed"], focused: split)
                        .frame(width: split ? half : 0)
                        .opacity(split ? 1 : 0)
                }
            }
            .padding([.horizontal, .bottom], 6)
        }
        .frame(width: 280, height: 196)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(theme.chrome.canvas))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(theme.chrome.divider, lineWidth: 1))
        .modifier(Perched())
        .modifier(OnceOnShow(active: active, shown: $split))
        .accessibilityHidden(true)
    }

    private func tab(_ title: String, selected: Bool) -> some View {
        Text(title)
            .font(Font(RexFont.ui(9)))
            .foregroundStyle(selected ? theme.fg : theme.chrome.secondary)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(selected ? theme.chrome.rowSelected : .clear))
    }

    private func pane(_ lines: [String], focused: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                Text(line)
                    .font(Font(RexFont.ui(9)))
                    .foregroundStyle(i == 0 ? theme.fg : theme.chrome.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(theme.bg))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .stroke(focused ? theme.chrome.activeBorder : theme.chrome.divider, lineWidth: 1))
    }
}

/// The sidebar's Agents list, and a notification from the agent that waits dropping in over it,
/// with its Enter and Interrupt.
private struct AgentsArt: View {
    let theme: TermTheme
    let active: Bool
    @State private var dropped = false

    var body: some View {
        VStack(spacing: 2) {
            Spacer(minLength: 0)
            row(name: "Tests", place: "api › agent", state: "Working", color: theme.chrome.working, tint: theme.ansiColor(4))
            row(name: "Refactor", place: "web › agent", state: "Waiting for you", color: theme.chrome.blocked,
                tint: theme.ansiColor(5), selected: true)
        }
        .padding(8)
        .frame(width: 280, height: 196)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(theme.chrome.sidebar))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(theme.chrome.divider, lineWidth: 1))
        .overlay(alignment: .top) {
            notification
                .padding(.horizontal, 12)
                .offset(y: dropped ? 12 : -18)
                .opacity(dropped ? 1 : 0)
        }
        .modifier(Perched())
        .modifier(OnceOnShow(active: active, shown: $dropped))
        .accessibilityHidden(true)
    }

    private func row(name: String, place: String, state: String, color: Color, tint: Color, selected: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 9) {
            ZStack {
                // The sidebar's tile for an agent: a circle. Any kind gives it; only shells differ.
                TabRowLabel.tile(.aider).fill(tint.opacity(0.9))
                Image(systemName: "cpu")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(theme.bg)
            }
            .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(name).font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.fg)
                    Spacer(minLength: 0)
                    Text(state)
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(color.opacity(0.18)))
                        .foregroundStyle(color)
                }
                Text(place).font(.system(size: 10)).foregroundStyle(theme.chrome.tertiary)
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? theme.chrome.rowSelected : .clear))
    }

    private var notification: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.chrome.blocked)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Refactor is waiting").font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.fg)
                    Text("Allow edits to 2 files?").font(.system(size: 11)).foregroundStyle(theme.chrome.secondary)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                chip("Enter", fill: theme.accent, text: theme.bg)
                chip("Interrupt", fill: theme.fg.opacity(theme.isDark ? 0.10 : 0.08), text: theme.fg)
            }
        }
        .lineLimit(1)
        .padding(10)
        .modifier(NoticeGlass(theme: theme))
    }

    private func chip(_ title: String, fill: Color, text: Color) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(text)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(Capsule().fill(fill))
    }
}

/// A notification's material: Liquid Glass as the system draws them, or the toasts' card before
/// iOS 26.
private struct NoticeGlass: ViewModifier {
    let theme: TermTheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        if #available(iOS 26.0, *) {
            content
                .glassEffect(.regular, in: shape)
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        } else {
            content
                .background(shape.fill(theme.chrome.sidebar))
                .overlay(shape.stroke(theme.chrome.divider, lineWidth: 1))
                .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
        }
    }
}
