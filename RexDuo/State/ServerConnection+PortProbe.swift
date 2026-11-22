import Foundation
import RexKit

/// Which listed ports show: each web port a pane lists is asked once what it answers
/// (`PortProbe`, through `PortForward.probe`), and one that is no web page (an editor plugin's
/// WebSocket server, a raw TCP service) gets no row in the Ports list, the palette or the pane
/// menu. Tapped links never look here (docs/terminal.md, Ports, "Which ports show").
///
/// - The book (`PortProbeBook`) decides; this runs its probes, at most two at once, only while
///   the computer is online with tunnels, and never on a timer.
/// - A new port is held for its answer, at most `PortProbeBook.hold`: one wake, set for the
///   earliest hold, shows it then.
extension ServerConnection {
    /// Probes can run on this computer now.
    var canProbePorts: Bool {
        probePort != nil && phase == .online && control.state == .connected && synced
            && tunnelsAvailable && tunnelConnected
    }

    /// Brings the book up to the lists of `panes` (sidebar order) and writes each pane's hidden
    /// ports. Returns them, for the rows. Called from `refreshPortRows`, where every list change
    /// lands.
    @discardableResult
    func updatePortProbes(panes: [(session: String, block: String)]) -> [String: Set<Int>] {
        let now = probeClock()
        var seen: [PortProbeBook.Key: PortProbeBook.Place] = [:]
        var relisted: Set<PortProbeBook.Key> = []
        let only = probeOnly().map { label in Set(sessions.filter { $0.label == label }.map(\.id)) }
        for p in panes where only?.contains(p.session) ?? true {
            for e in ports.value(p.block)?.webPorts ?? [] {
                let key = PortProbeBook.Key(e)
                if seen[key] == nil { seen[key] = PortProbeBook.Place(session: p.session, block: p.block) }
                if freshPortLists.contains(p.block) { relisted.insert(key) }
            }
        }
        portProbes.update(seen, relisted: relisted, now: now, canProbe: canProbePorts)
        freshPortLists = []
        var hidden: [String: Set<Int>] = [:]
        for p in panes {
            for e in ports.value(p.block)?.webPorts ?? [] where portProbes.hidden(PortProbeBook.Key(e), now: now) {
                hidden[p.block, default: []].insert(e.port)
            }
        }
        portsHidden.removeAll { hidden[$0] == nil }
        for (bid, set) in hidden { portsHidden.set(bid, set) }
        pumpPortProbes()
        wakeForHeldPorts(now: now)
        return hidden
    }

    /// Starts the probes the book hands out. Each answer that still applies updates the rows.
    func pumpPortProbes() {
        guard canProbePorts, let probe = probePort else { return }
        for job in portProbes.start() {
            let target = PortForward.Target(sessionID: job.session, port: job.key.port, dialHost: job.key.host)
            Task { [weak self] in
                let verdict = await probe(target)
                // An answer for a port that went, or for an older attempt, changes nothing.
                guard let self, self.portProbes.finish(job, verdict) else { return }
                self.refreshPortRows()
            }
        }
    }

    /// One wake for the earliest held port: it shows when its hold is up, answered or not.
    private func wakeForHeldPorts(now: Double) {
        guard let at = portProbes.nextRelease(now: now) else {
            probeWake?.task.cancel()
            probeWake = nil
            return
        }
        if probeWake?.at == at { return }
        probeWake?.task.cancel()
        let task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, at - now) + 0.02))
            guard !Task.isCancelled, let self else { return }
            self.probeWake = nil
            self.refreshPortRows()
        }
        probeWake = (task, at)
    }

    /// The pane menu's ports: the pane's web ports less those that show nowhere for now.
    func shownPorts(_ bid: String) -> [PortEntry] {
        let web = ports.value(bid)?.webPorts ?? []
        guard let hidden = portsHidden.value(bid) else { return web }
        return web.filter { !hidden.contains($0.port) }
    }
}
