import SwiftUI
import UIKit
import RexKit

/// Tent mode: while the phone stands folded back as a tent, the agent board covers the tab.
///
/// The board is an overlay on the root's layout, not a screen of its own: the tab under it stays
/// mounted with its streams, so leaving tent shows it at once. It only displays. Under it the
/// panes stop drawing and take no key (`TerminalHostPool.setCovered`), and nothing is claimed,
/// resized or given back on the Mac.
///
/// The hinge decides when the board comes and goes (`TentDetector`) and nothing about layout:
/// the board lays itself out from its own size, like everything else.
///
/// **Only on a phone with a hinge.** UIKit has no question "does this device have a hinge": the
/// one sign is a `UIHingeInteraction` update that carries a `UIHinge` (iOS 27.1+). So on iOS
/// 27.1 and later a view of no size holds that interaction (`HingeObserver`), and everything
/// else here (the detector, the timers, the touch watch, the power observer, the pool's key
/// hook) starts with the first update that has a hinge. On an iPhone that never reports one,
/// and on older systems, this modifier adds an empty overlay and nothing more. The tab's own
/// view is the same view either way, so the first hinge update rebuilds nothing.
struct TentBoard: ViewModifier {
    /// The fold in the window, as the root's layout sees it.
    let division: Division?
    let size: CGSize
    /// The sidebar sits beside the tab. A drawer is closed when the board shows; this one stays.
    let inline: Bool
    /// Whether the window covers its screen, where a simulated posture says so itself. Nil: the
    /// window is asked.
    let fills: Bool?
    @Binding var sidebar: SidebarState
    let pool: TerminalHostPool
    /// The room the docked keyboard or the key bar takes at the bottom. 0 with neither.
    let keyboardHeight: CGFloat
    let theme: TermTheme

    @Environment(AppModel.self) private var model
    @State private var tent = TentModel()

    /// A docked keyboard taller than this is the software keyboard, not the key bar alone.
    nonisolated static let tallestKeyBar: CGFloat = 120

    /// `-boardDemo`: the board shows at once, with no tent.
    private var demo: Bool {
        #if DEBUG
        return BoardDemo.scenario != nil
        #else
        return false
        #endif
    }

    /// A launch argument stands in for the hinge (`-simulateTent`), so no real one is needed.
    private var simulated: Bool {
        #if DEBUG
        return TentSimulation.sequence != nil
        #else
        return false
        #endif
    }

    func body(content: Content) -> some View {
        let shown = tent.presence.shown || demo
        content
            // The board is the screen while it shows: the tab under it takes no touch and is
            // not read out.
            .allowsHitTesting(!shown)
            .accessibilityHidden(shown)
            .overlay {
                ZStack {
                    if shown {
                        board.transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.25), value: shown)
            }
            .background {
                if #available(iOS 27.1, *), !simulated, !demo {
                    HingeObserver(ref: tent.probe, watching: tent.presence.inTent && !tent.presence.shown,
                                  onHinge: { tent.hingeReported($0) },
                                  onTouch: { tent.presence.activity(now: Date()) })
                        .frame(width: 0, height: 0)
                        .accessibilityHidden(true)
                }
                if tent.hasHinge || simulated {
                    TentDriver(tent: tent,
                               input: .init(hasDivision: division != nil, divisionActive: division?.isActive, size: size,
                                            fills: fills, keyboardHeight: keyboardHeight, inline: inline),
                               sidebar: $sidebar, pool: pool)
                }
            }
    }

    @ViewBuilder private var board: some View {
        #if DEBUG
        if let name = BoardDemo.scenario {
            DemoBoard(scenario: name, theme: theme)
        } else {
            live
        }
        #else
        live
        #endif
    }

    private var live: some View {
        LiveBoard(theme: theme, onOpen: open, onMore: {
            Haptic.tap()
            if model.prefs.navigation == .tabs {
                // No sidebar to list them in: the Agents sheet.
                model.showAgents()
            } else {
                sidebar.mode = .agents
                sidebar.open = true
            }
            tent.dismiss()
        })
    }

    /// A tile: its agent's tab with its pane in view, as a tap on it in the Agents mode gives.
    private func open(_ agent: BoardAgent) {
        guard let s = model.server(agent.server),
              model.openPane(s, session: agent.sessionID, window: agent.windowID, block: agent.blockID) else {
            Haptic.bump()
            return
        }
        Haptic.selection()
        tent.dismiss()
    }
}

/// What tent mode knows: the hinge, whether the phone stands as a tent and whether the board
/// shows. A reference, so a timer that fires later reads what is true then, not what was true
/// when it was set.
@MainActor
@Observable
final class TentModel {
    /// What the layout says now. Written by `TentDriver` on every change.
    struct Input: Equatable {
        var hasDivision = false
        /// For the log only.
        var divisionActive: Bool?
        var size = CGSize.zero
        var fills: Bool?
        var keyboardHeight: CGFloat = 0
        var inline = false
    }

    var presence = BoardPresence()
    /// The device has reported a hinge at least once.
    private(set) var hasHinge = false
    /// When the detector's one-second hold ends.
    private(set) var holdUntil: Date?
    private(set) var inTent = false
    @ObservationIgnored private var detector = TentDetector()
    @ObservationIgnored private var hinge = HingeReading()
    @ObservationIgnored var input = Input()
    @ObservationIgnored let probe = HingeProbeRef()
    #if DEBUG
    @ObservationIgnored var simIndex = 0
    #endif

    func hingeReported(_ reading: HingeReading) {
        hinge = reading
        if reading.degrees != nil, !hasHinge { hasHinge = true }
        // Before the first hinge nothing listens, and there is nothing to decide.
        if hasHinge { return evaluate() }
        #if DEBUG
        HingeLog.note(reading, division: nil, fills: probe.fillsScreen, tent: false)
        #endif
    }

    /// The hinge's angle: the real one, or `-simulateTent`'s.
    private var angle: Double? {
        #if DEBUG
        if let seq = TentSimulation.sequence { return seq.isEmpty ? nil : seq[simIndex % seq.count] }
        #endif
        return hinge.degrees
    }

    /// Asks the detector again, with the hinge and the layout as they are now.
    func evaluate() {
        let full = input.fills ?? probe.fillsScreen
        let now = Date()
        let until = detector.update(.init(hasDivision: input.hasDivision, fillsScreen: full, angle: angle), now: now)
        if until != holdUntil { holdUntil = until }
        if detector.inTent != inTent {
            inTent = detector.inTent
            presence.tent(inTent, modal: ScreenInspector.modalPresented(), now: now)
        }
        #if DEBUG
        var h = hinge
        if TentSimulation.sequence != nil { h = HingeReading(degrees: angle, status: "simulated") }
        let fold = input.divisionActive.map { Division(frame: .zero, isActive: $0) }
        HingeLog.note(h, division: fold, fills: full, tent: detector.inTent)
        #endif
    }

    /// The return timer fired: the keyboard and a sheet are asked now.
    func tick() {
        presence.tick(now: Date(), busy: input.keyboardHeight > 0, modal: ScreenInspector.modalPresented())
    }

    func dismiss() {
        presence.dismissed(now: Date())
    }
}

/// Runs tent mode once the phone is known to have a hinge: feeds the layout to `TentModel`, keeps
/// its timers, puts the board away when the app itself comes on screen, covers the panes and
/// keeps the screen awake. A view of no size behind the tab.
private struct TentDriver: View {
    let tent: TentModel
    let input: TentModel.Input
    @Binding var sidebar: SidebarState
    let pool: TerminalHostPool

    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var phase
    /// This code turned the idle timer off, and turns it back on.
    @State private var keepsAwake = false
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onChange(of: input, initial: true) { old, new in
                tent.input = new
                // The keyboard came up: somebody is using the app.
                if new.keyboardHeight > 0, old.keyboardHeight == 0 { tent.presence.activity(now: Date()) }
                tent.evaluate()
            }
            .task(id: tent.holdUntil) {
                guard let until = tent.holdUntil else { return }
                await Self.sleep(until: until)
                if !Task.isCancelled { tent.evaluate() }
            }
            .task(id: tent.presence.deadline) {
                guard let until = tent.presence.deadline else { return }
                await Self.sleep(until: until)
                if !Task.isCancelled { tent.tick() }
            }
            .onChange(of: tent.presence.shown) { _, on in apply(on) }
            // Anything that puts the app itself on screen puts the board away.
            .onChange(of: model.openRequest) { _, _ in tent.dismiss() }
            .onChange(of: model.lastCommand) { _, _ in tent.dismiss() }
            .onChange(of: sidebar.open) { _, open in if open { tent.dismiss() } }
            .onChange(of: model.showSettings) { _, on in if on { tent.dismiss() } }
            .onChange(of: model.agentsShown) { _, on in if on { tent.dismiss() } }
            .onChange(of: model.showPairing) { _, on in if on { tent.dismiss() } }
            .onChange(of: phase) { _, _ in updateAwake() }
            .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
                lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
                updateAwake()
            }
            .onAppear {
                pool.onKeyPress = { [tent] in tent.presence.activity(now: Date()) }
                #if DEBUG
                if let s = TentSimulation.returnAfter { tent.presence.returnAfter = s }
                #endif
            }
            .onDisappear {
                pool.onKeyPress = nil
                // The screen may sleep again, whatever happens to this view.
                if keepsAwake {
                    keepsAwake = false
                    UIApplication.shared.isIdleTimerDisabled = false
                }
            }
            #if DEBUG
            .task {
                guard let seq = TentSimulation.sequence, seq.count > 1 else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64(TentSimulation.interval * 1_000_000_000))
                    if Task.isCancelled { break }
                    tent.simIndex += 1
                    tent.evaluate()
                }
            }
            #endif
    }

    /// Sleeps to a little past `until`, so that a timer that wakes a moment early has still
    /// passed its deadline when it asks.
    private static func sleep(until: Date) async {
        let wait = until.timeIntervalSinceNow + 0.05
        if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
    }

    /// The board came or went. Coming, it puts the keyboard and a drawer away; going, the tab is
    /// as it was, with the software keyboard down.
    private func apply(_ on: Bool) {
        if on {
            // More than a key bar: the software keyboard is on screen, and stays down afterwards.
            pool.setCovered(true, softwareKeyboard: tent.input.keyboardHeight > TentBoard.tallestKeyBar)
            // A text field somewhere else (a rename, the sidebar's search) gives the keyboard up
            // too. The panes have decided for themselves.
            if let holder = UIResponder.rexCurrentFirstResponder(), !(holder is GhosttyTerminalView || holder is TerminalHost) {
                _ = holder.resignFirstResponder()
            }
            if !tent.input.inline, sidebar.open { sidebar.open = false }
            model.boardShown = true
            AccessibilityNotification.ScreenChanged().post()
        } else {
            model.boardShown = false
            pool.setCovered(false)
            AccessibilityNotification.ScreenChanged().post()
        }
        updateAwake()
    }

    /// The screen stays awake while the board shows, except in Low Power Mode or when the app
    /// isn't active. Turned back on only by the code that turned it off.
    private func updateAwake() {
        let want = BoardAwake.keepsAwake(shown: tent.presence.shown, lowPower: lowPower, active: phase == .active)
        guard want != keepsAwake else { return }
        keepsAwake = want
        UIApplication.shared.isIdleTimerDisabled = want
    }
}

/// The board over the app's real servers.
private struct LiveBoard: View {
    @Environment(AppModel.self) private var model
    let theme: TermTheme
    let onOpen: (BoardAgent) -> Void
    let onMore: () -> Void

    var body: some View {
        AgentBoardView(machines: BoardSource.machines(model.servers, since: PhoneState.shared.waitingSince),
                       theme: theme, onOpen: onOpen, onMore: onMore)
    }
}

#if DEBUG
/// `-boardDemo`: the board over made-up agents. Its tiles open nothing.
private struct DemoBoard: View {
    let scenario: String
    let theme: TermTheme
    @State private var step = 0
    @State private var started = Date()

    var body: some View {
        AgentBoardView(machines: BoardDemo.machines(scenario, now: started, step: step) ?? [], theme: theme,
                       onOpen: { _ in Haptic.bump() }, onMore: { Haptic.bump() })
            .task {
                guard scenario == "churn" else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    step += 1
                }
            }
    }
}
#endif

/// The board's machines and agents, read from the servers: the same agents, names, states and
/// places as the sidebar's Agents mode, without panes whose program has exited.
@MainActor
enum BoardSource {
    static func machines(_ servers: [ServerConnection], since: [String: Date]) -> [BoardMachine] {
        servers.map { s in
            let link: BoardMachine.Link
            if s.phase == .online, s.synced {
                link = .live
            } else if s.connectionSerial > 0 || s.phase.problem != nil {
                link = .stale
            } else {
                link = .never
            }
            let agents: [BoardAgent] = s.agentKeys.compactMap { key in
                let meta = s.meta[key.blockID]
                guard meta?.exited != true else { return nil }
                let status = meta?.topStatus
                let kind = meta?.agentKind ?? key.kind
                let state = status?.state ?? key.state
                let view = s.views[key.sessionID]
                let place = [view?.label ?? "", view?.window(key.windowID).map { WindowTitle.of($0, server: s) } ?? ""]
                    .filter { !$0.isEmpty }.joined(separator: " › ")
                let text = status?.text.flatMap { $0.isEmpty ? nil : $0 }
                return BoardAgent(server: s.id, sessionID: key.sessionID, windowID: key.windowID, blockID: key.blockID,
                                  kind: kind, name: kind?.displayName ?? status?.app ?? "Program", state: state,
                                  stateText: AgentRowLabel.stateText(status), progress: status?.progress, message: text,
                                  place: place, waitingSince: state == "blocked" ? since[key.blockID] : nil)
            }
            return BoardMachine(id: s.id, name: s.config.name, link: link, agents: agents)
        }
    }
}
