import Foundation
import GlanceModel

/// Writes the snapshot the widgets read (docs/glance.md, The snapshot). Owned by `AppModel`;
/// the only writer of the file.
///
/// It is told when something the snapshot holds may have changed (`GlanceWatcher`), and
/// `WriteThrottle` decides when that becomes a write and when WidgetKit is asked to redraw.
/// The main actor only builds the snapshot and encodes it, about 2 to 4 KB; the file is written
/// by `SnapshotFileWriter`.
///
/// It reads the snapshot before it lazily, at its first write and never at `init`: a launch
/// before the phone's first unlock couldn't read the file, and would lose the wait starts and
/// the count it carries on from.
@MainActor
final class GlanceWriter {
    /// What a launch does with the snapshot.
    enum Mode: Equatable {
        /// Nothing: the test host and every launch that shows made-up or throwaway state
        /// (`-servers`, `-boardDemo`, `-autoOpen`, `-simulateOffline`), which must not replace
        /// what the widgets know.
        case off
        /// The app's own servers. `only`: a test launch that asked to write anyway
        /// (`-glanceLive YES` with `-autoOpen <label>`, Debug builds) writes only the agents
        /// of the session with that label, so no other session is named in the file.
        case live(only: String?)
        /// `-glanceDemo <scenario>` (Debug builds): that made-up snapshot, written once.
        case demo(String)

        @MainActor static func current(defaults: UserDefaults = .standard, testHost: Bool = RexDuoApp.isTestHost) -> Mode {
            if testHost { return .off }
            #if DEBUG
            if let name = defaults.string(forKey: "glanceDemo"), !name.isEmpty { return .demo(name) }
            #endif
            let label = defaults.string(forKey: "autoOpen")
            let test = ["servers", "boardDemo", "autoOpen", "simulateOffline"].contains { defaults.string(forKey: $0) != nil }
            guard test else { return .live(only: nil) }
            #if DEBUG
            if defaults.bool(forKey: "glanceLive"), let label { return .live(only: label) }
            #endif
            return .off
        }
    }

    /// Time and the system, passed in so tests have their own.
    struct Parts {
        var now: @MainActor () -> Date = { Date() }
        var sleep: @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64(max($0, 0) * 1_000_000_000)) }
        /// Asks WidgetKit to draw the widgets again from the file.
        var reload: @MainActor () -> Void = {}
        /// Given each snapshot as it is written, with the bytes that go to the file, and whether
        /// the app is on its way to the background: what `GlanceBridge` sends on to the watch.
        var wrote: @MainActor (GlanceSnapshot, Data, _ leaving: Bool) -> Void = { _, _, _ in }
        #if DEBUG
        /// Given the bytes of a `-glanceDemo` scenario.
        var wroteDemo: @MainActor (Data) -> Void = { _ in }
        #endif
    }

    let mode: Mode
    /// The servers' agents now. Set by `AppModel`.
    var source: @MainActor () -> [GlanceInput.Machine] = { [] }
    var palette: @MainActor () -> GlanceSnapshot.Palette = { .standard }
    /// Whether a machine is connected now. Asked each time the timer is set, so `AppModel`
    /// answers from the servers' link alone, without building the rows `source` builds.
    var anyLive: @MainActor () -> Bool = { false }

    private let file: SnapshotFileWriter?
    private let parts: Parts
    private var throttle = WriteThrottle<GlanceSnapshot.VisibleKey>()
    /// The snapshot on disk: read once, then the last one written.
    private(set) var latest: GlanceSnapshot?
    private var loaded = false
    private var seq = 0
    /// The app is in front.
    private var active = false
    private var timer: Task<Void, Never>?
    private var firing = false

    /// `store` is asked for the store once, off the main thread, at the first read or write and
    /// never at launch. It answers nil when there is no App Group; the writer then writes nothing.
    /// With the mode off it is never asked.
    convenience init(mode: Mode, parts: Parts = Parts(), store: @escaping @Sendable () -> GlanceStore?) {
        self.init(mode: mode, parts: parts, file: mode == .off ? nil : SnapshotFileWriter(store: store))
    }

    /// A writer onto this store (tests). `store` nil: the writer does nothing.
    convenience init(mode: Mode, store: GlanceStore?, parts: Parts = Parts()) {
        self.init(mode: mode, parts: parts, file: mode == .off ? nil : store.map { s in SnapshotFileWriter { s } })
    }

    private init(mode: Mode, parts: Parts, file: SnapshotFileWriter?) {
        self.mode = mode
        self.parts = parts
        self.file = file
    }

    private var live: Bool {
        if case .live = mode { return file != nil }
        return false
    }

    // MARK: What the app tells it

    /// Something the snapshot holds may have changed. `newWaiting`: an agent began to wait.
    func changed(newWaiting: Bool) {
        guard live else { return }
        throttle.changed(newWaiting: newWaiting, now: parts.now())
        schedule()
    }

    func becameActive() {
        guard live else { return }
        active = true
        schedule()
    }

    /// The app goes to the background: write what is known now, and wait for the file. The
    /// caller holds a background task meanwhile.
    func flush() async {
        guard live, let file else { return }
        active = false
        timer?.cancel()
        timer = nil
        await load()
        let snapshot = build()
        let step = throttle.background(now: parts.now(), key: snapshot.visibleKey)
        await write(snapshot, to: file, leaving: true)
        if step.reload { parts.reload() }
    }

    /// The snapshot on disk, for a link that names a pane the app hasn't loaded yet.
    func current() async -> GlanceSnapshot? {
        guard file != nil else { return nil }
        await load()
        return latest
    }

    #if DEBUG
    /// `-glanceDemo <scenario>`: writes that snapshot and redraws the widgets. `none` removes
    /// the file, `newer` writes one from a later, incompatible app.
    func writeDemo() async {
        guard case .demo(let name) = mode, let file else { return }
        let now = parts.now()
        if let snapshot = GlanceDemo.snapshot(name, now: now), let data = try? snapshot.encoded() {
            await file.replace(with: data)
            parts.wroteDemo(data)
        } else {
            await file.replace(with: name == "newer" ? GlanceDemo.newerFile : nil)
            if name == "newer" { parts.wroteDemo(GlanceDemo.newerFile) }
        }
        NSLog("GLANCE_DEMO %@", name)
        parts.reload()
    }
    #endif

    // MARK: Writing

    private func schedule() {
        guard !firing else { return }
        timer?.cancel()
        timer = nil
        guard let at = throttle.wake(active: active, anyLive: anyLive()) else { return }
        let wait = at.timeIntervalSince(parts.now())
        let sleep = parts.sleep
        timer = Task { [weak self] in
            await sleep(wait)
            guard !Task.isCancelled, let self else { return }
            self.timer = nil
            await self.fire()
        }
    }

    private func fire() async {
        guard let file, !firing else { return }
        firing = true
        await load()
        let snapshot = build()
        let step = throttle.fire(now: parts.now(), key: snapshot.visibleKey, active: active,
                                 anyLive: snapshot.machines.contains { $0.link == .live })
        if step.write { await write(snapshot, to: file) }
        // After the file is there: a reload reads it.
        if step.reload { parts.reload() }
        firing = false
        schedule()
    }

    private func load() async {
        guard !loaded, let file else { return }
        let (snapshot, last) = await file.load()
        guard !loaded else { return }
        loaded = true
        latest = snapshot
        seq = max(seq, last)
    }

    private func build() -> GlanceSnapshot {
        GlanceSummary.snapshot(machines: source(), palette: palette(), previous: latest, seq: nil, now: parts.now())
    }

    private func write(_ snapshot: GlanceSnapshot, to file: SnapshotFileWriter, leaving: Bool = false) async {
        var snapshot = snapshot
        seq += 1
        snapshot.seq = seq
        latest = snapshot
        guard let data = try? snapshot.encoded() else { return }
        #if DEBUG
        // To check on a simulator that the app wrote: `eventMessage CONTAINS "GLANCE_WRITE"`.
        NSLog("GLANCE_WRITE seq=%d bytes=%d", seq, data.count)
        #endif
        await file.write(data, seq: seq)
        parts.wrote(snapshot, data, leaving)
    }
}

/// The one place the snapshot file is written from. An actor, so writes run one at a time and
/// off the main thread. Each write carries the number the snapshot was given when it was built;
/// one that arrives after a newer one has landed is dropped, so an older snapshot can never
/// replace a newer one, whatever order the writes arrive in.
actor SnapshotFileWriter {
    /// Finds the store: asked once, here on the actor, at the first read or write.
    private let find: @Sendable () -> GlanceStore?
    private var found: GlanceStore??
    /// The highest number written.
    private var newest = 0

    init(store: @escaping @Sendable () -> GlanceStore?) {
        find = store
    }

    private var store: GlanceStore? {
        if let found { return found }
        let store = find()
        found = .some(store)
        return store
    }

    /// The snapshot on disk and the highest number handed out so far.
    func load() -> (GlanceSnapshot?, Int) {
        guard let store else { return (nil, 0) }
        let last = store.lastSeq()
        newest = max(newest, last)
        return (store.read().snapshot, last)
    }

    func write(_ data: Data, seq: Int) {
        guard let store, seq > newest else { return }
        newest = seq
        try? store.write(data)
        store.saveSeq(seq)
    }

    /// Debug demo snapshots: put these bytes there as they are, or remove the file.
    func replace(with data: Data?) {
        guard let store else { return }
        if let data { try? store.write(data) } else { store.remove() }
    }
}
