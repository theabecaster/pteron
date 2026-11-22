import RexKit
import UIKit

// Predicted echo, the pane's side (docs/terminal.md, Predicted echo).
//
// The host follows its server's gate. While the gate says the link is slow, the host listens to
// its stream's input calls and write answers and passes them on to the core's predictor, in
// order with the bytes. Each key goes through the main-thread gate first (`EchoHostGate`): at a
// shell prompt, with no agent, no selection, no find, no composition, the fence down and the
// view at the bottom, a typed key may be a guess; anywhere else it is a boundary. The host does
// nothing here that changes what is sent.
//
// While the gate says the link is fast the host is not an observer of its stream at all: the
// key path is the one without predicted echo.

/// A host's watch on its server's gate. It ends with the host: the gate keeps nothing of a pane
/// that is gone, however the pane left (closed, evicted from the park, its computer removed).
final class EchoGateWatch {
    private let id: UUID
    private weak var gate: EchoGate?

    fileprivate init(id: UUID, gate: EchoGate) {
        self.id = id
        self.gate = gate
    }

    deinit {
        // The gate is main-actor state; a host can be let go from anywhere.
        guard let gate else { return }
        let id = id
        Task { @MainActor in gate.unwatch(id) }
    }
}

extension TerminalHost: EchoInputObserver, EchoWriteObserver {
    /// Starts following the server's gate. Called once, when the host is made.
    func followEchoGate() {
        guard let gate = stream.echoGate, echoWatch == nil else { return }
        let id = gate.watch(changed: { [weak self] level in self?.echoWants(level) },
                            reset: { [weak self] in self?.echoGateReset() })
        echoWatch = EchoGateWatch(id: id, gate: gate)
        term.core.onEcho = { [weak self] event in
            Task { @MainActor in self?.echoEvent(event) }
        }
        if gate.effective != .off { echoWants(gate.effective) }
    }

    /// The gate's level for this server changed.
    private func echoWants(_ level: EchoLevel) {
        echoWanted = level
        if level != .off, stream.inputObserver == nil {
            // Listening first: the stream's acknowledgement state then covers input still out.
            stream.writeObserver = self
            stream.inputObserver = self
        }
        // Off, and the pane never predicted: nothing to tell the core.
        guard stream.inputObserver != nil else { return }
        // A lower level applies in the core once nothing is pending, so the look never changes
        // mid-word; at `.off` the predictor then retires (`echoEvent`).
        term.core.setEchoLevel(level, ack: stream.echoAck)
    }

    /// The link changed under the gate's samples: every guess goes.
    private func echoGateReset() {
        guard stream.inputObserver != nil else { return }
        term.dropHeldPromptClick()
        term.core.echoCleared(.reconnected, through: stream.inputSeq)
    }

    /// What the feed queue asks of the pane.
    private func echoEvent(_ event: GhosttyEchoEvent) {
        switch event {
        case .inputMode(let generation):
            // Asked only in a pane whose shell sends no OSC 133, after a first key was echoed.
            // Not when the program in front can prove nothing whatever the tty says (`ssh`,
            // anything that is not a shell): the predictor hears "no proof" without a call.
            guard EchoInputMode.canProve(foreground: echoContext?().foreground) else {
                term.core.echoInputMode(nil, foreground: nil, generation: generation)
                return
            }
            Task { [weak self] in
                guard let self else { return }
                let mode = await self.stream.inputMode(marked: false)
                self.term.core.echoInputMode(mode, foreground: self.echoContext?().foreground, generation: generation)
            }
        case .slow:
            stream.echoGate?.noteOverdue()
        case .settled:
            term.echoSettled()
        case .retired:
            // Nothing pending and the level off: the pane is the pane without predicted echo
            // again. Not if the gate turned predictions back on meanwhile.
            guard echoWanted == .off else { return }
            stream.inputObserver = nil
            stream.writeObserver = nil
        }
    }

    /// What the pane knows now that the grid cannot say.
    private func echoConditions() -> EchoHostConditions {
        let context = echoContext?()
        return EchoHostConditions(fenced: stream.isFenced, composing: term.markedTextRange != nil,
                                  selecting: term.hasActiveSelection, finding: findOpen, scrolledBack: isScrolledBack,
                                  agent: context?.agent ?? true, foreground: context?.foreground)
    }

    // MARK: EchoInputObserver

    func input(_ kind: EchoInputKind, seq: Int) {
        let began = EchoProbe.active != nil ? EchoProbe.clock() : 0  // PERF
        defer { EchoProbe.active?.cost(.mainKey, since: began) }  // PERF
        term.dropHeldPromptClick()
        let conditions = echoConditions()
        if let before = echoForeground, before != conditions.foreground {
            // Another program in front: OSC 133 marks seen so far are not its own.
            term.core.echoForegroundChanged()
        }
        echoForeground = .some(conditions.foreground)
        let admitted = EchoHostGate.admit(kind, conditions)
        EchoProbe.active?.cost(.mainGate, since: began)  // PERF
        term.core.echoTyped(admitted, seq: seq, at: EchoClock.now)
    }

    // MARK: EchoWriteObserver

    func left(through seq: Int) {
        EchoProbe.active?.left()  // PERF
    }

    func answered(through seq: Int, at time: Double) {
        term.core.echoAnswered(through: seq, at: time)
    }

    func settled(after answer: Double) {
        term.core.echoSettled(after: answer)
    }

    func cleared(_ reason: EchoClearReason, through seq: Int) {
        term.dropHeldPromptClick()
        term.core.echoCleared(reason, through: seq)
    }
}
