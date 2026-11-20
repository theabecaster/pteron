import GlanceModel
import RexKit
import SwiftUI

/// Tells the snapshot's writer when something the widgets show may have changed. Lives once,
/// in RootView, beside `WaitingWatcher`.
///
/// Its body reads only what is already coalesced: which agents wait, every server's
/// `agentKeys`, each server's link, and the two themes. So it runs again when an agent comes,
/// goes or changes state, when a connection changes or when a theme is chosen, and never for
/// a title, a progress number or a message. The writer reads those later, for the waiting
/// agents only, when it builds the snapshot (`GlanceSource`).
struct GlanceWatcher: View {
    @Environment(AppModel.self) private var model
    @Environment(Prefs.self) private var prefs

    struct Key: Equatable {
        var waiting: Set<String>
        var agents: [[AgentKey]]
        var links: [Link]
        var themes: [String]

        struct Link: Equatable {
            var online: Bool
            var problem: Bool
            var synced: Bool
        }
    }

    /// Everything the body reads, and nothing else.
    static func key(_ model: AppModel, _ prefs: Prefs) -> Key {
        Key(waiting: model.waitingAgentIDs,
            agents: model.servers.map(\.agentKeys),
            links: model.servers.map { Key.Link(online: $0.phase == .online, problem: $0.phase.problem != nil, synced: $0.synced) },
            themes: [prefs.darkThemeID, prefs.lightThemeID])
    }

    var body: some View {
        let key = Self.key(model, prefs)
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onChange(of: key, initial: true) { old, now in
                // In a launch the system made in the background (to hand the app an action from
                // the watch) no server was started and nothing new is known: writing then would
                // only mark what the widgets and the watch show as last known.
                guard model.mayConnect else { return }
                // On the first pass both are the same: whoever waits then is new to the writer.
                let before = old == now ? [] : old.waiting
                model.glance.changed(newWaiting: !now.waiting.isSubset(of: before))
            }
    }
}

/// The snapshot's rows, read from the servers when the writer builds a snapshot: the same
/// agents, names, states and places as the agent board (`BoardSource`). Counts come from
/// `agentKeys`; a pane's metadata is read only for the agents that wait, at its newest
/// (`ServerConnection.currentMeta`), and which agent a pane holds is `BlockMeta.agentKind`'s call.
@MainActor
enum GlanceSource {
    /// `only`: a test launch's session label (`GlanceWriter.Mode.live`); agents elsewhere are left out.
    static func machines(_ servers: [ServerConnection], since: [String: Date], only label: String? = nil) -> [GlanceInput.Machine] {
        servers.map { s in
            var keys = s.agentKeys
            if let label {
                let sessions = Set(s.sessions.filter { $0.label == label }.map(\.id))
                keys.removeAll { !sessions.contains($0.sessionID) }
            }
            var states: [String?] = []
            var waiting: [GlanceInput.Wait] = []
            for key in keys {
                guard key.state == "blocked" else { states.append(key.state); continue }
                let meta = s.currentMeta(key.blockID)
                // A pane whose program has exited is no agent any more, as on the board.
                guard meta?.exited != true else { continue }
                states.append(key.state)
                let record = topRecord(meta)
                let status = record?.status
                let kind = meta?.agentKind ?? key.kind
                let view = s.views[key.sessionID]
                let place = [view?.label ?? "", view?.window(key.windowID).map { WindowTitle.of($0, server: s) } ?? ""]
                    .filter { !$0.isEmpty }.joined(separator: " › ")
                waiting.append(GlanceInput.Wait(
                    session: key.sessionID, window: key.windowID, block: key.blockID, kind: kind?.rawValue,
                    name: kind?.displayName ?? status?.app ?? "Program", symbol: kind?.symbol ?? "cpu",
                    why: status?.waitingFor, place: place, record: record?.id ?? "",
                    msg: status?.text.flatMap { $0.isEmpty ? nil : $0 }, fp: current(meta)?.fingerprint,
                    firstSeen: since[key.blockID]))
            }
            return GlanceInput.Machine(id: s.id.uuidString, name: s.config.name, link: link(s), known: s.connectionSerial > 0,
                                       states: states, waiting: waiting)
        }
    }

    /// The board's rule (`BoardSource`): live while connected with its sessions loaded, stale
    /// once it has been connected or shows a problem, else not connected yet.
    static func link(_ s: ServerConnection) -> GlanceSnapshot.Link {
        if s.phase == .online, s.synced { return .live }
        return s.connectionSerial > 0 || s.phase.problem != nil ? .stale : .never
    }

    /// The status record `BlockMeta.topStatus` picks, with its id. Among records of one rank
    /// the lowest id, so the same wait names the same record every time.
    static func topRecord(_ meta: BlockMeta?) -> (id: String, status: ProgramStatus)? {
        let rank = ["blocked": 5, "error": 4, "working": 3, "done": 2, "idle": 1]
        return meta?.statuses.sorted { $0.key < $1.key }.max { (rank[$0.value.state] ?? 0) < (rank[$1.value.state] ?? 0) }
            .map { ($0.key, $0.value) }
    }

    /// The same record as `ActionGuard` compares it: what the snapshot's fingerprint is made
    /// from, and what an action from the watch is checked against.
    static func current(_ meta: BlockMeta?) -> ActionGuard.Current? {
        topRecord(meta).map { ActionGuard.Current(record: $0.id, state: $0.status.state, kind: $0.status.waitingFor, message: $0.status.text) }
    }

    /// The themes chosen for Dark and Light Mode, as the widgets' colors.
    static func palette(_ prefs: Prefs) -> GlanceSnapshot.Palette {
        func entry(_ t: TermTheme) -> GlancePalette {
            GlancePalette(appearance: t.isDark ? "dark" : "light", bg: t.background, fg: t.foreground, accent: t.cursor, ansi: t.ansi)
        }
        return GlanceSnapshot.Palette(dark: entry(ThemeStore.theme(prefs.darkThemeID)), light: entry(ThemeStore.theme(prefs.lightThemeID)))
    }
}
