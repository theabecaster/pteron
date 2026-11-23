import Foundation

/// Time a test holds. A sleep taken from it ends when the test fires it, at the end of the
/// test, or when its task is cancelled, and never by the wall clock: a limit can't run out
/// because the machine is busy, and a test that wants one to run out says when.
///
/// `@unchecked Sendable`: every stored property is read and written under `lock`.
final class HeldClock: @unchecked Sendable {
    private let lock = NSLock()
    private var sleepers: [Int: (seconds: TimeInterval, done: CheckedContinuation<Void, Never>)] = [:]
    private var last = 0
    private var elapsed: TimeInterval = 0
    private var ended = false

    /// The time that fired sleeps have added up to.
    var now: TimeInterval { lock.withLock { elapsed } }

    /// How many sleeps of exactly `seconds` wait to be fired.
    func waiting(_ seconds: TimeInterval) -> Int {
        lock.withLock { sleepers.values.filter { $0.seconds == seconds }.count }
    }

    /// How many sleeps wait in all.
    var pending: Int { lock.withLock { sleepers.count } }

    func sleep(_ seconds: TimeInterval) async {
        let id = lock.withLock {
            last += 1
            return last
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                let over = lock.withLock {
                    if ended || Task.isCancelled { return true }
                    sleepers[id] = (seconds, done)
                    return false
                }
                if over { done.resume() }
            }
        } onCancel: {
            lock.withLock { sleepers.removeValue(forKey: id) }?.done.resume()
        }
    }

    /// Ends every waiting sleep of exactly `seconds`, and that much time has passed.
    @discardableResult
    func fire(_ seconds: TimeInterval) -> Int {
        let due = lock.withLock {
            let ids = sleepers.filter { $0.value.seconds == seconds }.map(\.key)
            elapsed += seconds
            return ids.compactMap { sleepers.removeValue(forKey: $0)?.done }
        }
        for done in due { done.resume() }
        return due.count
    }

    /// Fires the sleeps of `seconds` once one waits. False when none came (20 s of real time,
    /// which only a broken test reaches).
    @MainActor
    func fireWhenWaiting(_ seconds: TimeInterval) async -> Bool {
        let end = Date().addingTimeInterval(20)
        while waiting(seconds) == 0 {
            guard Date() < end else { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return fire(seconds) > 0
    }

    /// The test is over: every sleep ends, and so does any taken later.
    func end() {
        let all = lock.withLock {
            ended = true
            defer { sleepers = [:] }
            return sleepers.values.map(\.done)
        }
        for done in all { done.resume() }
    }
}
