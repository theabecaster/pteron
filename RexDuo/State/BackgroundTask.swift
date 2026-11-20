import UIKit

/// Time the system gives a job that is under way when the app goes to the background (a file on
/// its way, a share's long read). It starts on `init`, and `end()` gives it back; ending twice is
/// fine. When the time runs out, `expired` runs once, on the main thread, and the task ends right
/// after: the job stops cleanly instead of being killed in the middle.
@MainActor
final class BackgroundTask {
    private var id = UIBackgroundTaskIdentifier.invalid
    private var expired: (@MainActor () -> Void)?

    init(name: String, expired: @escaping @MainActor () -> Void) {
        self.expired = expired
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in self?.expire() }
    }

    var running: Bool { id != .invalid }

    /// The job is over: the time goes back to the system.
    func end() {
        expired = nil
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }

    /// What the system does when the time is up. Tests call it to play that moment.
    func expire() {
        let e = expired
        expired = nil
        e?()
        end()
    }
}
