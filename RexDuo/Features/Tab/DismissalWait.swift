import Foundation

/// Holds what a row of a popover or a sheet asked for until that popover or sheet has gone, so
/// what the row puts on screen comes up over the app and not over the thing that is closing: a
/// sheet can't open over a popover, and the palette's field wants the keyboard.
///
/// It waits for the real end of the dismissal, which the view reports with `dismissed()` (when
/// its content has left the screen), and no longer than `cap`: without that report the row
/// still runs. The sleep is given, so the tests drive the cap themselves.
@MainActor
final class DismissalWait {
    typealias Sleep = @MainActor (Duration) async -> Void

    /// The longest a row waits. A popover or a sheet closes in about a third of that.
    static let cap: Duration = .seconds(1)

    private let cap: Duration
    private let sleep: Sleep
    private var held: [@MainActor () -> Void] = []
    /// Runs out `cap` after the first action was held. Nil while nothing is held.
    private(set) var timer: Task<Void, Never>?

    init(cap: Duration = DismissalWait.cap, sleep: @escaping Sleep = { try? await Task.sleep(for: $0) }) {
        self.cap = cap
        self.sleep = sleep
    }

    /// Something waits for the dismissal.
    var isWaiting: Bool { !held.isEmpty }

    /// Holds `action` until `dismissed()`, or until the cap runs out. Call it before closing,
    /// so a dismissal that ends at once still finds the action.
    func hold(_ action: @escaping @MainActor () -> Void) {
        held.append(action)
        guard timer == nil else { return }
        timer = Task { [weak self, sleep, cap] in
            await sleep(cap)
            guard !Task.isCancelled else { return }
            self?.release()
        }
    }

    /// The popover or the sheet has gone: what was held runs now, in the order it was held. A
    /// report with nothing held does nothing, and doesn't count for an action held later.
    func dismissed() { release() }

    private func release() {
        timer?.cancel()
        timer = nil
        let actions = held
        held = []
        for action in actions { action() }
    }
}
