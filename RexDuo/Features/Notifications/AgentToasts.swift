import SwiftUI

extension View {
    /// In-app toasts for waiting agents and programs' notices. Apply once, at the app root,
    /// inside the `AppModel` and `Prefs` environment.
    func agentToasts() -> some View { modifier(AgentToasts()) }
}

/// Shows a small toast when an agent the user isn't looking at starts waiting, or a program in a
/// pane off screen sends a desktop notification (rules in `ToastPolicy`, state in `ToastState`).
/// Tapping it opens the pane; it fades on its own and can be swiped up.
private struct AgentToasts: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(Prefs.self) private var prefs
    @Environment(\.scenePhase) private var phase
    @Environment(\.colorScheme) private var scheme

    @State private var state = ToastState()
    @State private var hideTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        let theme = prefs.theme(for: scheme)
        content
            .overlay(alignment: .top) {
                ZStack {
                    if let toast = state.toast {
                        ToastCard(toast: toast, theme: theme, onOpen: { open(toast) }, onDismiss: { dismiss() })
                            .id(toast.id)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .frame(maxWidth: 520)
                .padding(.horizontal, 12)
                .padding(.top, 4)
                .animation(.snappy(duration: 0.25), value: state.toast?.id)
            }
            .onChange(of: model.notifier.latest?.id) { _, _ in
                if let a = model.notifier.latest { consider(a) }
            }
            .onChange(of: model.notifier.noticeSerial) { _, _ in
                // Every notice of the turn, in order.
                for n in model.notifier.takeNotices() { considerNotice(n) }
            }
            .onChange(of: model.openRequest) { _, _ in
                // A push tapped while a sheet was up: close it so the pane shows.
                model.showSettings = false
                model.agentsShown = false
                ScreenInspector.dismissModals()
            }
            // The board takes the screen: a waiting toast already up goes, a notice toast waits
            // for the board to go.
            .onChange(of: model.boardShown) { _, shown in
                if shown, state.toast != nil {
                    hideTask?.cancel()
                    state.boardCame()
                }
            }
            .onChange(of: phase, initial: true) { _, p in if p == .active { state.activeSince = Date() } }
            .task(id: state.held.map(\.id)) { await offerHeld() }
            .task(id: state.noticesWaiting) { await releaseNotices() }
    }

    private var context: ToastPolicy.Context {
        ToastPolicy.Context(appActive: phase == .active,
                            visibleBlocks: VisiblePanes.onScreen(),
                            modalPresented: ScreenInspector.modalPresented(),
                            boardShowing: model.boardShown)
    }

    private func consider(_ a: AgentAlert) {
        apply(state.considerWaiting(a, context: context, now: Date()), title: a.title)
    }

    private func considerNotice(_ n: AgentAlert) {
        apply(state.considerNotice(n, context: context, now: Date()), title: n.title)
    }

    private func apply(_ effect: ToastState.Effect, title: String) {
        switch effect {
        case .shown:
            AccessibilityNotification.Announcement(title).post()
            scheduleHide()
        case .updated:
            scheduleHide()
        case .none:
            break
        }
    }

    /// Re-offers held waiting alerts once nothing covers the screen.
    private func offerHeld() async {
        guard !state.held.isEmpty else { return }
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled, !ScreenInspector.modalPresented() else { continue }
            let ready = state.takeHeld(stillWaiting: { a in
                model.server(a.serverID)?.meta[a.blockID]?.topStatus?.state == "blocked"
            }, now: Date())
            for a in ready { consider(a) }
            return
        }
    }

    /// Shows waiting notices as one toast once they may show: after held waiting alerts, with
    /// nothing over the screen and no toast up.
    private func releaseNotices() async {
        while state.noticesWaiting, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            // The cheap checks first: the screen walk (`context`) runs only when the notices may
            // show, not every half second while a gap, the quiet or a held alert says no.
            let now = Date()
            guard phase == .active, state.noticesMayShow(now: now), !model.boardShown,
                  !ScreenInspector.modalPresented() else { continue }
            let effect = state.releaseNotices(context: context, now: now)
            if case .shown(let t) = effect {
                apply(effect, title: t.alert.title)
                return
            }
        }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(ToastPolicy.lifetime * 1_000_000_000))
            guard !Task.isCancelled else { return }
            state.toastEnded()
        }
    }

    private func dismiss() {
        hideTask?.cancel()
        state.toastEnded()
    }

    private func open(_ t: AgentToast) {
        dismiss()
        guard let s = model.server(t.alert.serverID) else { return }
        Haptic.selection()
        model.openPane(s, session: t.alert.sessionID, window: t.alert.windowID, block: t.alert.blockID)
    }
}

/// The toast: who is waiting or what a program said, where, and how many others did.
private struct ToastCard: View {
    let toast: AgentToast
    let theme: TermTheme
    let onOpen: () -> Void
    let onDismiss: () -> Void

    private var notice: Bool { toast.alert.kind == .notice }

    var body: some View {
        SwipeAway(onDismiss: onDismiss) {
            HStack(spacing: 10) {
                Image(systemName: notice ? "bell.fill" : "hand.raised.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(notice ? theme.chrome.secondary : theme.chrome.blocked)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(toast.alert.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(theme.fg)
                        .lineLimit(1)
                    if !toast.alert.body.isEmpty {
                        Text(toast.alert.body)
                            .font(.caption)
                            .foregroundStyle(theme.chrome.secondary)
                            .lineLimit(2)
                    }
                    if !toast.others.isEmpty {
                        let n = toast.others.count
                        let sentence = notice ? AlertCopy.moreNotices(n)
                            : n == 1 ? "1 more agent is waiting" : "\(n) more agents are waiting"
                        // One line: the short form where the sentence doesn't fit; VoiceOver reads the sentence.
                        ViewThatFits(in: .horizontal) {
                            Text(sentence)
                            Text(notice ? AlertCopy.moreNoticesShort(n) : "\(n) more waiting")
                        }
                        .font(.caption2.weight(.medium))
                        .monospacedDigit()
                        .lineLimit(1)
                        .foregroundStyle(notice ? theme.chrome.secondary : theme.chrome.blocked)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(sentence)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.chrome.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(minHeight: 44)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(theme.chrome.sidebar))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke((notice ? theme.chrome.secondary : theme.chrome.blocked).opacity(0.45), lineWidth: 1))
            .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .onTapGesture(perform: onOpen)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens the pane.")
        .accessibilityAction(named: "Dismiss", onDismiss)
    }
}

/// Follows an upward drag and calls `onDismiss` once it passes a threshold; otherwise springs back.
private struct SwipeAway<Content: View>: View {
    let onDismiss: () -> Void
    @ViewBuilder let content: Content
    @State private var drag: CGFloat = 0

    var body: some View {
        content
            .offset(y: drag < 0 ? drag : drag / 4)
            .gesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { drag = $0.translation.height }
                    .onEnded { v in
                        if v.translation.height < -24 || v.predictedEndTranslation.height < -80 {
                            onDismiss()
                        } else {
                            withAnimation(.snappy(duration: 0.2)) { drag = 0 }
                        }
                    }
            )
    }
}
