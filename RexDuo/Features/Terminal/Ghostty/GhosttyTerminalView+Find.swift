import UIKit
import Synchronization

/// An atomic flag that closures can share (an `Atomic` can't be captured).
final class GhosttyFlag: Sendable {
    let value = Atomic<Bool>(false)
}

// Find in the pane's history (GhosttyCore+Find.swift does the searching off the main thread).
extension GhosttyTerminalView {
    /// Opens find on this pane's terminal: the search handle is made on the next pass, nothing is
    /// searched until a needle is set. Results arrive through `findHook`, on the main thread.
    func openFind() {
        let find = core.makeFind()
        let renderer = renderer
        find.isVisible = { [weak renderer] in renderer?.isVisible.load(ordering: .relaxed) ?? false }
        let pending = findUpdatePending
        find.onUpdate = { [weak self] in
            // One hop per burst of publishes; the hook reads the newest result when it runs.
            guard !pending.value.exchange(true, ordering: .relaxed) else { return }
            DispatchQueue.main.async { [weak self] in
                pending.value.store(false, ordering: .relaxed)
                MainActor.assumeIsolated { self?.findUpdated() }
            }
        }
        find.open()
    }

    /// Searches for `needle` (sanitized with `FindQuery.sanitize`; empty clears).
    func setFindNeedle(_ needle: [UInt8]) { core.find?.setNeedle(needle) }

    /// The next (older, `+1`) or previous (newer, `-1`) match, scrolled into view.
    func stepFind(_ by: Int) { core.find?.step(by) }

    /// Closes find: the handle is freed off the main thread and the tints go with the next frame.
    func closeFind() { core.find?.close() }

    /// The last result published. Any thread.
    var findResult: FindResult { core.find?.published.withLock { $0 } ?? FindResult() }

    /// Find is open on this pane.
    var findOpened: Bool { core.find?.opened ?? false }

    private func findUpdated() {
        findHook?(findResult)
    }
}
