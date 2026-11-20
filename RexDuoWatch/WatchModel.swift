import Foundation
import GlanceModel
import Observation

/// What the watch app shows now. It reads the snapshot file off the main actor, works out the
/// screen (`WatchScreen`, pure), and does so again at the moments the snapshot's age changes
/// what is shown, so an open app turns "as of" and dims without a delivery.
@MainActor
@Observable
final class WatchModel {
    struct Parts {
        var now: @MainActor () -> Date = { Date() }
        var sleep: @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64(max($0, 0) * 1_000_000_000)) }
    }

    private(set) var screen: WatchScreen
    @ObservationIgnored private let read: @Sendable () -> GlanceReading
    @ObservationIgnored private let parts: Parts
    @ObservationIgnored private var timer: Task<Void, Never>?

    init(parts: Parts = Parts(), read: @escaping @Sendable () -> GlanceReading) {
        self.read = read
        self.parts = parts
        // Until the first read: as with no snapshot.
        screen = WatchScreen(.missing, now: parts.now())
    }

    func reload() async {
        let read = read
        let reading = await Task.detached { read() }.value
        show(reading)
    }

    private func show(_ reading: GlanceReading) {
        let now = parts.now()
        let next = WatchScreen(reading, now: now)
        if next != screen { screen = next }
        timer?.cancel()
        timer = nil
        guard let at = WatchScreen.nextChange(reading, after: now) else { return }
        let sleep = parts.sleep
        timer = Task { [weak self] in
            await sleep(at.timeIntervalSince(now))
            guard !Task.isCancelled, let self else { return }
            self.show(reading)
        }
    }
}
