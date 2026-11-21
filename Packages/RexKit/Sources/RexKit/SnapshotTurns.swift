import Foundation

/// One fresh snapshot at a time for a host's unseen panes, on cellular. A pane's fresh start
/// brings its whole screen and scrollback over the data socket. On a cellular path several of
/// those at once share a thin link and the phone's tunnel with the pane the user is looking
/// at, so there the fresh start of a pane that streams unseen takes a turn, in the order asked.
///
/// A pane on screen never takes a turn and never waits: it starts at once, whoever holds the
/// turn, and a pane that comes on screen while it waits starts then. On Wi-Fi nobody takes a
/// turn (`TerminalStream.fullStart` asks only on an expensive path, for an unseen pane).
///
/// A turn is always given back: by the stream when its snapshot ends or fails, when it stops,
/// parks or restarts, when its socket drops, when the host dies and when the app goes to the
/// background; when the path stops being expensive every turn ends (`openUp`); and whatever a
/// stream does, a turn ends by itself after `limit` seconds. That last one is no deadline on
/// the snapshot: the stream goes on, and the next one starts beside it.
@MainActor
final class SnapshotTurns {
    /// A stream's place: waiting, or holding the turn.
    final class Turn {}

    /// The longest a turn is held, in seconds.
    var limit: @MainActor () -> Double = { ReconnectPolicy.standard.connectDeadlineExpensive }
    /// The wait of a turn's limit; a test ends it by hand.
    var sleep: @MainActor (Double) async -> Void = { try? await Task.sleep(for: .milliseconds(Int(($0 * 1000).rounded()))) }

    private var held: Turn?
    private var deadline: Task<Void, Never>?
    private var waiting: [(turn: Turn, go: CheckedContinuation<Void, Never>)] = []

    var isHeld: Bool { held != nil }
    var waitingCount: Int { waiting.count }
    func holds(_ turn: Turn?) -> Bool { turn != nil && held === turn }

    /// Returns when `turn` may start: at once with nobody holding, otherwise after those ahead
    /// of it. It also returns when the turn is given back while it waits (`give`: the stream
    /// stopped, or its pane came on screen): the caller looks at its own state then, as after
    /// any wait.
    func take(_ turn: Turn) async {
        if held == nil {
            grant(turn)
            return
        }
        await withCheckedContinuation { waiting.append((turn, $0)) }
    }

    /// Gives a turn back: the holder's, so the next one starts, or a waiter's, which stops
    /// waiting. Nothing for a turn that is neither (given back already, or timed out).
    func give(_ turn: Turn?) {
        guard let turn else { return }
        if held === turn {
            held = nil
            deadline?.cancel()
            deadline = nil
            next()
        } else if let i = waiting.firstIndex(where: { $0.turn === turn }) {
            waiting.remove(at: i).go.resume()
        }
    }

    /// The path is no longer expensive: nobody waits, and whoever asks next starts at once.
    func openUp() {
        held = nil
        deadline?.cancel()
        deadline = nil
        let all = waiting
        waiting = []
        for w in all { w.go.resume() }
    }

    private func next() {
        guard held == nil, !waiting.isEmpty else { return }
        let w = waiting.removeFirst()
        grant(w.turn)
        w.go.resume()
    }

    private func grant(_ turn: Turn) {
        held = turn
        deadline?.cancel()
        let sleep = self.sleep, seconds = limit()
        deadline = Task { @MainActor [weak self] in
            await sleep(seconds)
            guard !Task.isCancelled, let self, self.held === turn else { return }
            self.held = nil
            self.deadline = nil
            self.next()
        }
    }
}
