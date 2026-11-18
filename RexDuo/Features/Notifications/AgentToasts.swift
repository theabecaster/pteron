import SwiftUI

extension View {
    /// In-app agent toasts. Apply once, at the app root, inside the `AppModel` and `Prefs`
    /// environment.
    func agentToasts() -> some View { modifier(AgentToasts()) }
}

/// Shows a small toast when an agent the user isn't looking at starts waiting (rules in
/// `ToastPolicy`). Tapping it opens the pane; it fades on its own and can be swiped up.
private struct AgentToasts: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(Prefs.self) private var prefs
    @Environment(\.scenePhase) private var phase
    @Environment(\.colorScheme) private var scheme

    @State private var toast: AgentToast?
    @State private var lastShown: [String: Date] = [:]
    /// Alerts held while a sheet or alert covers the screen.
    @State private var held: [AgentAlert] = []
    @State private var hideTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        let theme = prefs.theme(for: scheme)
        content
            .overlay(alignment: .top) {
                ZStack {
                    if let toast {
                        ToastCard(toast: toast, theme: theme, onOpen: { open(toast) }, onDismiss: { dismiss() })
                            .id(toast.id)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .frame(maxWidth: 520)
                .padding(.horizontal, 12)
                .padding(.top, 4)
                .animation(.snappy(duration: 0.25), value: toast?.id)
            }
            .onChange(of: model.notifier.latest?.id) { _, _ in
                if let a = model.notifier.latest { consider(a) }
            }
            .onChange(of: model.openRequest) { _, _ in
                // A push tapped while a sheet was up: close it so the pane shows.
                model.showSettings = false
                ScreenInspector.dismissModals()
            }
            .task(id: held.map(\.id)) { await offerHeld() }
    }

    private func consider(_ a: AgentAlert) {
        let ctx = ToastPolicy.Context(appActive: phase == .active,
                                      visibleBlocks: ScreenInspector.visibleBlocks(),
                                      modalPresented: ScreenInspector.modalPresented())
        switch ToastPolicy.decide(a, context: ctx, current: toast, lastShown: lastShown, now: Date()) {
        case .show(let t), .update(let t):
            let isNew = toast == nil
            toast = t
            lastShown[a.blockID] = Date()
            if isNew { AccessibilityNotification.Announcement(a.title).post() }
            scheduleHide()
        case .hold:
            held = ToastPolicy.hold(a, in: held)
        case .suppress:
            break
        }
    }

    /// Re-offers held alerts once nothing covers the screen.
    private func offerHeld() async {
        guard !held.isEmpty else { return }
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled, !ScreenInspector.modalPresented() else { continue }
            let now = Date()
            let ready = held.filter { a in
                let waiting = model.server(a.serverID)?.meta[a.blockID]?.topStatus?.state == "blocked"
                return ToastPolicy.worthOfferingAgain(a, stillWaiting: waiting, now: now)
            }
            held = []
            for a in ready { consider(a) }
            return
        }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(ToastPolicy.lifetime * 1_000_000_000))
            guard !Task.isCancelled else { return }
            toast = nil
        }
    }

    private func dismiss() {
        hideTask?.cancel()
        toast = nil
    }

    private func open(_ t: AgentToast) {
        dismiss()
        guard let s = model.server(t.alert.serverID) else { return }
        Haptic.selection()
        model.openPane(s, session: t.alert.sessionID, window: t.alert.windowID, block: t.alert.blockID)
    }
}

/// The toast: who is waiting, where, and how many others are.
private struct ToastCard: View {
    let toast: AgentToast
    let theme: TermTheme
    let onOpen: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        SwipeAway(onDismiss: onDismiss) {
            HStack(spacing: 10) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.chrome.blocked)
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
                        // One line: the short form where the sentence doesn't fit; VoiceOver reads the sentence.
                        ViewThatFits(in: .horizontal) {
                            Text(n == 1 ? "1 more agent is waiting" : "\(n) more agents are waiting")
                            Text("\(n) more waiting")
                        }
                        .font(.caption2.weight(.medium))
                        .monospacedDigit()
                        .lineLimit(1)
                        .foregroundStyle(theme.chrome.blocked)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(n == 1 ? "1 more agent is waiting" : "\(n) more agents are waiting")
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
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(theme.chrome.blocked.opacity(0.45), lineWidth: 1))
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
