import Foundation

/// The newest Beacon release, as the app read it from the signed release list. Every computer's
/// row is compared against this one value, so two computers can't disagree about which version
/// is the latest.
struct LatestRelease: Equatable, Sendable {
    var version: ReleaseVersion
    /// The oldest version the release list still allows to run.
    var minVersion: ReleaseVersion

    init(version: ReleaseVersion, minVersion: ReleaseVersion) {
        self.version = version
        self.minVersion = minVersion
    }

    init(_ release: VerifiedRelease) {
        self.init(version: release.version, minVersion: release.minVersion)
    }

    /// Where a Beacon's version stands against the release.
    enum Standing: Equatable, Sendable {
        /// The latest, or newer than it (a build ahead of the release list).
        case current
        /// Older than the latest, and still allowed to run.
        case behind
        /// Older than the oldest version the release list allows.
        case belowMinimum
        /// Nothing can be said: no release is known, or the version is not `major.minor.patch`.
        case unknown
    }

    /// `reported` is the version Beacon gave; `release` is nil while the app has no release
    /// list. Only these two decide: what Beacon thinks of its own version is not asked.
    static func standing(of reported: String?, against release: LatestRelease?) -> Standing {
        guard let release, let version = reported.flatMap(ReleaseVersion.init) else { return .unknown }
        if version < release.minVersion { return .belowMinimum }
        return version < release.version ? .behind : .current
    }
}

/// The app's one check for the latest Beacon release. It reads the signed release list with
/// `HelperReleaseFetcher` and keeps the result with its time, so every computer's row and every
/// trigger within the hour share one fetch. `PushRegistrar` asks for it at launch, on each
/// return to the front, when notifications are turned on and when a Beacon takes this phone,
/// and only while notifications are on and a computer is listed.
@MainActor
@Observable
final class ReleaseCheck {
    /// How long a result stands before the list is read again.
    static let goodFor: TimeInterval = 3600
    /// How long after a failed read the next one waits.
    static let retryAfter: TimeInterval = 300

    /// The last release that was read and verified. A failed read leaves it as it is.
    private(set) var latest: LatestRelease?
    /// The last read failed. "Show Details" says so.
    private(set) var lastFailed = false

    @ObservationIgnored private var fetchedAt: Date?
    @ObservationIgnored private var failedAt: Date?
    /// The read that is under way; triggers that arrive meanwhile wait for it.
    @ObservationIgnored private var running: Task<Void, Never>?
    @ObservationIgnored private let fetch: @MainActor () async -> Result<VerifiedRelease, ReleaseFault>
    @ObservationIgnored private let now: @MainActor () -> Date

    init(fetch: @escaping @MainActor () async -> Result<VerifiedRelease, ReleaseFault>, now: @escaping @MainActor () -> Date = { Date() }) {
        self.fetch = fetch
        self.now = now
    }

    convenience init(fetcher: HelperReleaseFetcher, now: @escaping @MainActor () -> Date = { Date() }) {
        self.init(fetch: { await fetcher.verified() }, now: now)
    }

    /// Whether a trigger at `now` reads the list: not within `goodFor` of the last good read,
    /// and not within `retryAfter` of the last failed one. A time in the future (the clock was
    /// set back) counts as long ago.
    static func isDue(now: Date, fetchedAt: Date?, failedAt: Date?) -> Bool {
        func within(_ since: Date?, _ limit: TimeInterval) -> Bool {
            guard let since else { return false }
            return (0..<limit).contains(now.timeIntervalSince(since))
        }
        return !within(fetchedAt, goodFor) && !within(failedAt, retryAfter)
    }

    /// Reads the release list when it is due, and returns once the result is in.
    func refresh() async {
        if let running { return await running.value }
        guard Self.isDue(now: now(), fetchedAt: fetchedAt, failedAt: failedAt) else { return }
        let task = Task { await self.read() }
        running = task
        await task.value
        running = nil
    }

    private func read() async {
        switch await fetch() {
        case .success(let release):
            let found = LatestRelease(release)
            if latest != found { latest = found }
            fetchedAt = now()
            failedAt = nil
            if lastFailed { lastFailed = false }
        case .failure:
            failedAt = now()
            if !lastFailed { lastFailed = true }
        }
    }
}
