import QuartzCore
import RexKit
import Synchronization
import UIKit

/// What a replay run fed, for the result file.
struct PerfReplayInfo: Sendable {
    var file: String
    var format: String
    var bytes: Int
    var chunks: Int
    var rate: String
    var cols: Int
    var rows: Int
    /// The mirror-mode zoom the grid got. 1 means the terminal is drawn 1:1, as in fit mode.
    var zoom: Double
    var fontSize: Double
    var delay: Double
}

/// Measures one pane for one run and writes the numbers to `Documents/perf/<name>.json`.
///
/// On with the launch argument `-perfLog <name>`, off otherwise. Off, `active` is nil: every
/// hook in shared code is `PerfProbe.active?.…`, one load and one branch, and nothing is
/// allocated, observed or timed.
///
/// It measures the first `TerminalHost` made in the process (replay and the benchmark's live
/// runs show one pane). All times are `CACurrentMediaTime()`.
///
/// ## What the numbers mean
///
/// **Time to first frame** (`firstFrame`, milliseconds after pane open). Pane open is the start
/// of `TerminalHost.init`, so making the engine view counts.
/// - `connecting`, `live`: the stream's first `.connecting` and `.live` status. `live` is the
///   data socket's WELCOME.
/// - `snapshotBegin`: the snapshot's first bytes arrived.
/// - `snapshotReceived`: the whole snapshot is here: its `end` part (or, for a snapshot that
///   could not be restored, `streamSnapshot` was called with the screen as text).
/// - `restored`: the engine holds the restored screen: the decoder's terminal was swapped in,
///   or the text was parsed (both on the feed queue).
/// - `presented`: the first frame that shows the restored screen was handed to the GPU. See
///   "A frame that shows a state" below.
///
/// **Flow** (`flow`), when output was fed: the window runs from the first `streamFeed` to the
/// frame that shows the final state.
/// - `parseMs`: first byte fed to last byte parsed: the feed queue ran dry (a marker queued
///   behind the last bytes).
/// - `drawnMs`: first byte fed to the frame that shows the final state.
/// - `firstOutputMs`: first byte fed to the first frame that shows the first chunk.
///
/// **Frame pacing**, over the window.
/// - `mainLink`: the probe's own main-thread `CADisplayLink`. A gap between two callbacks over
///   25 ms is a main-thread hitch: the main thread could not run a display callback in time.
/// - `presents`: frames handed to the GPU: each `present` committed on the render thread. Gaps
///   over 25 ms count the same way; they only mean a stall while output arrives faster than that.
///
/// **Main-thread busy time** (`mainBusy`): the main run loop's slices between `afterWaiting`
/// and `beforeWaiting`, summed over the window, and the longest slice.
///
/// **CPU time** (`cpu`): user + system time over the window, for the process (`getrusage`) and
/// for the main thread (`thread_info`); `otherMs` is the difference.
///
/// **Memory** (`memory`): `phys_footprint` at the window's start, the highest value a 50 ms
/// timer saw from there on, at the window's end, and 2 s after it (`idle`).
///
/// ## A frame that shows a state
///
/// "The frame that shows the state at time T" has to be decided without guessing, because a
/// frame handed over just after T may have been built just before it.
/// - The renderer reports each pass with the time it started (before it locks the terminal).
///   The first pass that started at or after T decides: if it presented, that present; if it
///   found nothing to draw, the present before it already showed the state. The probe marks
///   the core dirty once at T, so there is always such a pass.
/// - If none decides within 0.5 s (a view that isn't drawing), the last frame handed over is
///   taken and the result says so (`…Assumed`).
final class PerfProbe: Sendable {
    /// The run's probe. Nil without `-perfLog <name>`.
    /// A global on purpose: the hooks sit on three threads (main, render, feed queue), in types
    /// nothing is injected into, and must cost one branch when it is nil.
    ///
    /// The launch argument is read in Debug builds and in the benchmark's optimized build
    /// (`BENCH`, set by scripts/bench/run.sh). A shipped app has no probe and no argument.
    #if DEBUG || BENCH
    static let argument = "perfLog"
    static let active: PerfProbe? = make(name: UserDefaults.standard.string(forKey: argument))
    #else
    static var active: PerfProbe? { nil }
    #endif

    static let gapThreshold = 0.025
    /// How long after the window the idle memory is read and the file written.
    static let settle = 2.0
    /// How long a frame that shows a state is waited for.
    static let frameWait = 0.5
    /// A run that hasn't finished by then is written as it is, with an error.
    static let runLimit = 120.0

    #if DEBUG || BENCH
    /// `-perfClean YES` (scripts/bench/run-device.sh --clean): deletes what the device benchmark
    /// left in Documents (`perf`, the results, and `bench`, the scenarios) and quits.
    static func cleanUpIfAsked() {
        guard UserDefaults.standard.bool(forKey: "perfClean") else { return }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        for folder in ["perf", "bench"] { try? FileManager.default.removeItem(at: docs.appendingPathComponent(folder)) }
        exit(0)
    }
    #endif

    static func make(name: String?, directory: URL? = nil) -> PerfProbe? {
        guard let name else { return nil }
        let safe = String(name.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0) })
        guard !safe.isEmpty else { return nil }
        let dir = directory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("perf")
        return PerfProbe(name: safe, directory: dir)
    }

    let name: String
    let directory: URL
    var fileURL: URL { directory.appendingPathComponent(name + ".json") }

    private init(name: String, directory: URL) {
        self.name = name
        self.directory = directory
    }

    // MARK: State

    enum Mark: Int, CaseIterable { case restored, firstOutput, final }

    private struct Target: Sendable {
        /// T: when the engine held the state.
        var at: Double
        /// When the frame that shows it was handed to the GPU.
        var shown: Double?
        var assumed = false
    }

    private struct Sample: Sendable {
        var at: Double
        var cpu: Double
        var mainCPU: Double
        var footprint: UInt64
        var power = PerfSystem.power()
    }

    /// Everything more than one thread touches.
    private struct State: Sendable {
        var core: GhosttyCore?
        var mainThread: thread_act_t = 0
        var replay: PerfReplayInfo?
        var opening: Double?
        var connecting: Double?
        var live: Double?
        var snapshotBegin: Double?
        var snapshotReceived: Double?
        var snapshotBytes = 0
        var targets = [Target?](repeating: nil, count: Mark.allCases.count)
        var presents: [Double] = []
        var lastPresent: Double?
        var passes = 0
        var buildSeconds = 0.0
        var buildWorst = 0.0
        var encodeSeconds = 0.0
        var encodeWorst = 0.0
        var firstFed: Double?
        var lastFed: Double?
        var bytesFed = 0
        var chunks = 0
        var sourceDone = false
        var openSample: Sample?
        var flowSample: Sample?
        var endSample: Sample?
        var windowEnd: Double?
        var peak: UInt64 = 0
        var error: String?
        var written = false
        /// The launch transition (`LaunchSplashView`), `launch…` hooks: process start and the
        /// times of its steps, all on the probe's clock.
        var processStart: Double?
        var launchSteps: [String: Double] = [:]
        /// "metal" or "fold", and why the fold.
        var launchPeel: String?
        /// The Metal peel's frame times (`StickerPeelStats`), in milliseconds.
        var launchPeelFrames: [String: Double] = [:]
        /// Where its frames skipped refreshes: "<ms after the start>+<refreshes skipped>", in order.
        var launchPeelHitchesAt = ""

        func sample(_ now: Double) -> Sample {
            Sample(at: now, cpu: PerfSystem.processCPUSeconds(), mainCPU: PerfSystem.threadCPUSeconds(mainThread),
                   footprint: PerfSystem.footprint())
        }

        /// Sets a mark once.
        mutating func mark(_ m: Mark, at: Double) {
            guard targets[m.rawValue] == nil else { return }
            targets[m.rawValue] = Target(at: at)
        }

        /// The run has shown everything it was going to.
        var complete: Bool {
            func shown(_ m: Mark) -> Bool { targets[m.rawValue]?.shown != nil }
            func pending(_ m: Mark) -> Bool { targets[m.rawValue] != nil && !shown(m) }
            if pending(.restored) || pending(.firstOutput) || pending(.final) { return false }
            if replay != nil { return sourceDone && (bytesFed == 0 || shown(.final)) }
            return shown(.restored)
        }

        /// Call after a target got its frame. True when that ended the window.
        mutating func closeIfComplete(_ now: Double) -> Bool {
            guard windowEnd == nil, complete else { return false }
            let ends = targets.compactMap { $0 }.flatMap { [$0.at, $0.shown ?? $0.at] }
            windowEnd = ends.max() ?? now
            endSample = sample(now)
            return true
        }
    }

    private let state = Mutex(State())

    /// Main-thread only (the `main` property is): the run loop observers, the display link and
    /// what they collect.
    private struct MainState {
        weak var host: TerminalHost?
        var installed = false
        var link: CADisplayLink?
        var observers: [CFRunLoopObserver] = []
        var sampler: DispatchSourceTimer?
        var ticks: [Double] = []
        var busy: [PerfWindow] = []
        var sliceStart: Double?
        var finishing = false
        /// `phys_footprint` `settle` seconds after the window.
        var idleFootprint: UInt64?
        /// The phases after the window (`-perfIdle`, `-perfScroll`), for the result file.
        var phases: JSONObject = [:]
        /// The scroll phase's fling, driven from the display link: its start, length and travel.
        var fling: (start: Double, seconds: Double, bottom: CGFloat, travel: CGFloat)?
        var flingDone: CheckedContinuation<Void, Never>?
    }

    @MainActor private var main = MainState()

    @inline(__always) private static func clock() -> Double { CACurrentMediaTime() }

    // MARK: Hooks in TerminalHost (main thread)

    /// First statement of `TerminalHost.init`: pane open.
    func paneOpening() {
        let now = Self.clock()
        state.withLock { if $0.opening == nil { $0.opening = now } }
    }

    /// End of `TerminalHost.init`. The first host is the one measured.
    @MainActor
    func paneOpened(_ host: TerminalHost) {
        guard !main.installed else { return }
        main.installed = true
        main.host = host
        let core = host.term.core
        let thread = PerfSystem.currentThread()
        let now = Self.clock()
        state.withLock { s in
            s.core = core
            s.mainThread = thread
            s.openSample = s.sample(s.opening ?? now)
            s.peak = s.openSample?.footprint ?? 0
            s.presents.reserveCapacity(1 << 14)
        }
        install(now)
    }

    @MainActor
    private func tracks(_ host: TerminalHost) -> Bool { main.host === host }

    @MainActor
    func status(_ status: TerminalStream.Status, host: TerminalHost) {
        guard tracks(host) else { return }
        let now = Self.clock()
        state.withLock { s in
            if status == .connecting, s.connecting == nil { s.connecting = now }
            if status == .live, s.live == nil { s.live = now }
        }
    }

    /// A part of the stream's Ghostty snapshot arrived.
    @MainActor
    func snapshot(_ part: GhosttySnapshotPart, host: TerminalHost) {
        guard tracks(host) else { return }
        let now = Self.clock()
        state.withLock { s in
            switch part {
            case .begin: if s.snapshotBegin == nil { s.snapshotBegin = now }
            case .bytes(let b): if s.snapshotReceived == nil { s.snapshotBytes += b.count }
            case .ready: break
            case .end: if s.snapshotReceived == nil { s.snapshotReceived = now }
            }
        }
    }

    /// `streamSnapshot` was called with the screen as escape sequences (the fallback for a
    /// snapshot that could not be restored).
    @MainActor
    func seedReceived(_ bytes: Int, host: TerminalHost) {
        guard tracks(host), bytes > 0 else { return }
        let now = Self.clock()
        state.withLock { s in
            guard s.snapshotReceived == nil else { return }
            s.snapshotReceived = now
            s.snapshotBytes = bytes
        }
    }

    /// That text was handed to the engine, which parses it on its feed queue.
    @MainActor
    func seedParsed(host: TerminalHost) {
        guard tracks(host) else { return }
        let core = state.withLock { $0.snapshotReceived != nil ? $0.core : nil }
        if let core { holdsWhenParsed(.restored, core: core) }
    }

    /// `streamFeed` was called with `count` bytes of output.
    @MainActor
    func fed(_ count: Int, host: TerminalHost) {
        guard tracks(host) else { return }
        let now = Self.clock()
        let first: GhosttyCore? = state.withLock { s in
            s.bytesFed += count
            s.chunks += 1
            s.lastFed = now
            guard s.firstFed == nil else { return nil }
            s.firstFed = now
            s.flowSample = s.sample(now)
            s.peak = s.flowSample?.footprint ?? 0
            return s.core
        }
        // The engine parses elsewhere: the mark is set on its feed queue once the first chunk is
        // parsed. The host calls this before it hands the bytes to the core, so the mark is
        // queued from the next main-queue turn: behind the first chunk, ahead of the second.
        if let core = first { DispatchQueue.main.async { self.holdsWhenParsed(.firstOutput, core: core) } }
    }

    // MARK: Replay

    @MainActor
    func replayStarted(_ info: PerfReplayInfo) {
        state.withLock { $0.replay = info }
    }

    /// The replay handed its last chunk to the host.
    @MainActor
    func sourceFinished(_ host: TerminalHost) {
        guard tracks(host) else { return }
        let now = Self.clock()
        let (core, closed): (GhosttyCore?, Bool) = state.withLock { s in
            s.sourceDone = true
            return (s.firstFed != nil ? s.core : nil, s.closeIfComplete(now))
        }
        if let core { holdsWhenParsed(.final, core: core) }
        if closed { finishSoon() }
    }

    func fail(_ message: String) {
        state.withLock { if $0.error == nil { $0.error = message } }
        Task { @MainActor in self.write() }
    }

    // MARK: Hooks in the launch transition (any thread)

    /// A step of the launch transition happened now: `kitReady` (the peel's Metal kit is built),
    /// `splash` (the app's first frame is committed and the transition is scheduled), `decided`
    /// (Metal peel or fold chosen), `start` (the transition's first frame is due), `done` (the
    /// splash is gone: the app is on screen and takes touches). The first time of each counts.
    func launchStep(_ step: String, at time: Double? = nil) {
        let now = time ?? Self.clock()
        let uptime = LaunchSplashView.processUptime()
        state.withLock { s in
            if s.processStart == nil, let uptime { s.processStart = Self.clock() - uptime }
            if s.launchSteps[step] == nil { s.launchSteps[step] = now }
        }
    }

    /// Which peel ran: "metal", or "fold (<reason>)".
    func launchPeel(_ kind: String) {
        state.withLock { if $0.launchPeel == nil { $0.launchPeel = kind } }
    }

    /// The Metal peel's frames: when each was due, how long before that its callback ran, and its
    /// CPU encode and GPU times. Frames due before the start (`launchStep("start")`) are the
    /// still lead-in and count apart.
    @MainActor
    func launchPeelFrames(targets all: [Double], leads: [Double], encode: [Double], gpu: [Double], late: Int) {
        let start = state.withLock { $0.launchSteps["start"] } ?? -.infinity
        let first = all.firstIndex { $0 >= start - 0.001 } ?? all.count
        let targets = Array(all[first...])
        let gaps = zip(targets.dropFirst(), targets).map { $0 - $1 }
        func pct(_ a: [Double], _ q: Double) -> Double {
            let a = a.sorted()
            return a.isEmpty ? 0 : a[min(a.count - 1, Int((Double(a.count - 1) * q).rounded()))] * 1000
        }
        let period = 1 / Double(max(60, UIScreen.main.maximumFramesPerSecond))
        let hitches = PerfHitchStats.measure(targets, in: PerfWindow(from: -.infinity, to: .infinity), period: period)
        // Where the missed refreshes were: ms after the start, and how many refreshes each skipped.
        let at = zip(targets, gaps).filter { $0.1 > period * 1.5 }.map { target, gap in
            "\(Int(((target - start) * 1000).rounded()))+\(Int((gap / period).rounded()) - 1)"
        }
        let frameLeads = Array(leads.suffix(targets.count))
        state.withLock { s in
            s.launchPeelFrames = [
                "frames": Double(targets.count), "leadInFrames": Double(first),
                "intervalP50Ms": pct(gaps, 0.5), "intervalP95Ms": pct(gaps, 0.95),
                "intervalMaxMs": (gaps.max() ?? 0) * 1000, "hitches": Double(hitches.hitches),
                "hitchMs": hitches.hitchSeconds * 1000, "gpuLate": Double(late),
                "callbackLeadMinMs": (frameLeads.min() ?? 0) * 1000, "callbackLeadP50Ms": pct(frameLeads, 0.5),
                "encodeP50Ms": pct(encode, 0.5), "encodeMaxMs": (encode.max() ?? 0) * 1000,
                "gpuP50Ms": pct(gpu, 0.5), "gpuMaxMs": (gpu.max() ?? 0) * 1000,
            ]
            s.launchPeelHitchesAt = at.joined(separator: " ")
        }
    }

    // MARK: Hooks in the engine

    /// The snapshot's terminal was swapped in (GhosttyTerminalView, on the feed queue).
    func ghosttyRestored(_ core: GhosttyCore) { ghosttyHolds(.restored, core: core) }

    /// Marks the state the core holds once it has parsed everything fed so far.
    private func holdsWhenParsed(_ mark: Mark, core: GhosttyCore) {
        core.enqueue { [self] in ghosttyHolds(mark, core: core) }
    }

    /// The core holds a state as of now (feed queue). Asks for a render pass that starts after now.
    private func ghosttyHolds(_ mark: Mark, core: GhosttyCore) {
        let now = Self.clock()
        let ours = state.withLock { s in
            guard s.core === core else { return false }
            s.mark(mark, at: now)
            return true
        }
        if ours { core.onDirty?() }
    }

    /// A render pass ended (GhosttyRenderer.render, render thread). `built` is when it started;
    /// `presented` is false when it found nothing new to draw.
    func ghosttyPass(_ renderer: GhosttyRenderer, built: Double, presented: Bool) {
        let now = Self.clock()
        let closed = state.withLock { s in
            guard s.core === renderer.core else { return false }
            s.passes += 1
            s.buildSeconds += renderer.lastBuildSeconds
            s.buildWorst = max(s.buildWorst, renderer.lastBuildSeconds)
            if presented {
                s.encodeSeconds += renderer.lastEncodeSeconds
                s.encodeWorst = max(s.encodeWorst, renderer.lastEncodeSeconds)
                s.presents.append(now)
                s.lastPresent = now
            }
            var any = false
            for i in s.targets.indices {
                guard let t = s.targets[i], t.shown == nil, t.at <= built else { continue }
                // A pass with nothing to draw means the state was on screen before it was marked
                // (it changed nothing visible): no later than T, and never before it.
                s.targets[i]?.shown = max(s.lastPresent ?? now, t.at)
                any = true
            }
            return any && s.closeIfComplete(now)
        }
        if closed { finishSoon() }
    }

    // MARK: Main-thread collection

    @MainActor
    private func install(_ now: Double) {
        GhosttyCore.measuresLockWait.store(true, ordering: .relaxed)
        main.ticks.reserveCapacity(1 << 14)
        main.busy.reserveCapacity(1 << 16)
        main.sliceStart = now

        let link = CADisplayLink(target: Ticker(self), selector: #selector(Ticker.tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        main.link = link

        // The main run loop's slices, from the first observer after a wait to the last before
        // the next.
        func observe(_ activity: CFRunLoopActivity, order: CFIndex, _ body: @escaping @MainActor (PerfProbe) -> Void) {
            let o = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, activity.rawValue, true, order) { [self] _, _ in
                MainActor.assumeIsolated { body(self) }
            }
            guard let o else { return }
            CFRunLoopAddObserver(CFRunLoopGetMain(), o, .commonModes)
            main.observers.append(o)
        }
        observe(.afterWaiting, order: CFIndex.min) { p in
            if p.main.sliceStart == nil { p.main.sliceStart = Self.clock() }
        }
        observe(.beforeWaiting, order: CFIndex.max) { p in
            let now = Self.clock()
            if let from = p.main.sliceStart { p.main.busy.append(PerfWindow(from: from, to: now)) }
            p.main.sliceStart = nil
        }

        main.sampler = startSampler()
        // A run with nobody touching the phone must not lock it halfway.
        UIApplication.shared.isIdleTimerDisabled = true

        Task { @MainActor [self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.runLimit * 1e9))
            let late = state.withLock { s in
                guard !s.written else { return false }
                if s.error == nil { s.error = "not finished after \(Int(Self.runLimit)) s" }
                return true
            }
            if late { write() }
        }
    }

    /// Reads the footprint every 50 ms, off the main thread. (Not main-actor code: the handler
    /// must not inherit the main actor.)
    private func startSampler() -> DispatchSourceTimer {
        let sampler = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        sampler.schedule(deadline: .now(), repeating: .milliseconds(50), leeway: .milliseconds(5))
        sampler.setEventHandler { [self] in
            let f = PerfSystem.footprint()
            state.withLock { $0.peak = max($0.peak, f) }
        }
        sampler.resume()
        return sampler
    }

    /// The display link's target. The link holds it until `uninstall`.
    @MainActor
    private final class Ticker: NSObject {
        let probe: PerfProbe
        init(_ probe: PerfProbe) { self.probe = probe }
        @objc func tick() { probe.tick() }
    }

    @MainActor
    private func tick() {
        let now = Self.clock()
        main.ticks.append(now)
        if main.fling != nil { flingStep(now) }
        // A target nothing decided in time takes the last frame handed over.
        let closed = state.withLock { s in
            var any = false
            for i in s.targets.indices {
                guard let t = s.targets[i], t.shown == nil, now - t.at > Self.frameWait else { continue }
                s.targets[i]?.shown = s.lastPresent ?? now
                s.targets[i]?.assumed = true
                any = true
            }
            return any && s.closeIfComplete(now)
        }
        if closed { finishSoon() }
    }

    // MARK: Result

    /// The window is closed: read the idle memory after `settle`, run the phases asked for,
    /// then write.
    private func finishSoon() {
        Task { @MainActor [self] in
            guard !main.finishing else { return }
            main.finishing = true
            try? await Task.sleep(nanoseconds: UInt64(Self.settle * 1e9))
            main.idleFootprint = PerfSystem.footprint()
            await runPhases()
            write()
        }
    }

    // MARK: Phases after the window

    /// `-perfIdle <seconds>`: the pane sits still for that long, with the probe's own display
    /// link and memory timer stopped, and the result gets what the app cost meanwhile (CPU,
    /// wake-ups, render passes, energy). `-perfScroll <seconds>`: then a fling by program through
    /// the scrollback, up and back down, one scroll view offset per display frame, and the
    /// result gets its frame pacing. Both run after the launch transition has finished.
    @MainActor
    private func runPhases() async {
        let d = UserDefaults.standard
        let idle = d.double(forKey: "perfIdle"), scroll = d.double(forKey: "perfScroll")
        let steps = d.integer(forKey: "findSteps")
        guard idle > 0 || scroll > 0 || steps > 0 else { return }
        // The transition must not land in a phase (5 s at most: one that never ends isn't waited for).
        for _ in 0..<50 {
            let waiting = state.withLock { $0.launchSteps["splash"] != nil && $0.launchSteps["done"] == nil }
            guard waiting else { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if steps > 0 { main.phases["find"] = await findPhase(steps: steps) }
        if idle > 0 { main.phases["idle"] = await idlePhase(seconds: idle) }
        if scroll > 0 { main.phases["scroll"] = await scrollPhase(seconds: scroll) }
    }

    /// What a phase measures from its start to its end.
    private struct PhaseMark {
        var at: Double
        var cpu: Double
        var mainCPU: Double
        var power: PerfSystem.Power
        var renderTicks: Int
        var renderPasses: Int
        var buildSeconds: Double
        var encodeSeconds: Double
        var passes: Int
    }

    @MainActor
    private func phaseMark() -> PhaseMark {
        let r = GhosttyRenderThread.shared
        let (thread, build, encode, passes) = state.withLock { ($0.mainThread, $0.buildSeconds, $0.encodeSeconds, $0.passes) }
        return PhaseMark(at: Self.clock(), cpu: PerfSystem.processCPUSeconds(), mainCPU: PerfSystem.threadCPUSeconds(thread),
                         power: PerfSystem.power(), renderTicks: r.ticks.load(ordering: .relaxed),
                         renderPasses: r.passes.load(ordering: .relaxed), buildSeconds: build, encodeSeconds: encode,
                         passes: passes)
    }

    /// The numbers every phase reports, from `a` to `b`.
    @MainActor
    private func phaseResult(_ a: PhaseMark, _ b: PhaseMark) -> JSONObject {
        let seconds = max(b.at - a.at, 1e-6)
        func ms(_ v: Double) -> Double { (v * 1e6).rounded() / 1e3 }
        func perSecond(_ v: Double) -> Double { (v / seconds * 10).rounded() / 10 }
        let window = PerfWindow(from: a.at, to: b.at)
        let busy = PerfBusyStats.measure(main.busy, in: window)
        let wakes = main.busy.filter { $0.from >= a.at && $0.from < b.at }.count
        let energy = Double(b.power.energyNJ &- a.power.energyNJ) / 1e6   // mJ
        let cpu = b.cpu - a.cpu
        return [
            "seconds": (seconds * 1000).rounded() / 1000,
            "cpu": ["processMs": ms(cpu), "mainMs": ms(b.mainCPU - a.mainCPU),
                    "percent": (cpu / seconds * 1000).rounded() / 10],
            "mainBusy": ["totalMs": ms(busy.totalSeconds), "worstMs": ms(busy.worstSeconds)],
            "wakeups": ["mainPerSecond": perSecond(Double(wakes)),
                        "processPerSecond": perSecond(Double(b.power.interruptWakeups &- a.power.interruptWakeups)),
                        "idlePerSecond": perSecond(Double(b.power.idleWakeups &- a.power.idleWakeups))],
            "power": ["energyMJ": (energy * 100).rounded() / 100, "averageMW": (energy / seconds * 10).rounded() / 10,
                      "gpuMs": ms(Double(b.power.gpuNS &- a.power.gpuNS) / 1e9)],
            "render": ["ticks": b.renderTicks - a.renderTicks, "passes": b.renderPasses - a.renderPasses,
                       "panePasses": b.passes - a.passes,
                       "buildMsPerPass": b.passes > a.passes ? ms((b.buildSeconds - a.buildSeconds) / Double(b.passes - a.passes)) : 0,
                       "encodeMs": ms(b.encodeSeconds - a.encodeSeconds)],
        ]
    }

    /// `-findSteps <n>` (with `-findTest`): the next match n times, 100 ms apart, after the
    /// replay: each step selects a match, scrolls to it (`.reveal`) and refreshes at once.
    @MainActor
    private func findPhase(steps: Int) async -> JSONObject {
        guard let host = main.host, host.findOpen else { return ["error": "find is not open"] }
        main.link?.isPaused = false
        let a = phaseMark()
        for _ in 0..<steps {
            host.performFind(.next)
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let b = phaseMark()
        let window = PerfWindow(from: a.at, to: b.at)
        let period = 1 / Double(max(60, UIScreen.main.maximumFramesPerSecond))
        var out = phaseResult(a, b)
        out["steps"] = steps
        out["selected"] = host.term.findResult.selectedIndex ?? -1
        out["presents"] = Self.hitchJSON(PerfHitchStats.measure(state.withLock { $0.presents }, in: window, period: period), window: window)
        out["mainLink"] = Self.hitchJSON(PerfHitchStats.measure(main.ticks, in: window, period: period), window: window)
        return out
    }

    @MainActor
    private func idlePhase(seconds: Double) async -> JSONObject {
        // The probe's own wake-ups would be most of an idle app's.
        main.link?.isPaused = true
        main.sampler?.cancel()
        main.sampler = nil
        let a = phaseMark()
        let presentsBefore = state.withLock { $0.presents.count }
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
        let b = phaseMark()
        var out = phaseResult(a, b)
        out["presents"] = state.withLock { $0.presents.count } - presentsBefore
        main.link?.isPaused = false
        return out
    }

    @MainActor
    private func scrollPhase(seconds: Double) async -> JSONObject {
        guard let term = main.host?.term else { return ["error": "no pane"] }
        let surface = term.scroller.surface
        let bottom = surface.contentSize.height - surface.bounds.height
        // At most 1000 rows each way: a long, fast fling (about 5000 points a second at its
        // fastest with 6 s and 11 pt), with new rows in every frame.
        let travel = min(bottom, 1000 * term.cellSize.height)
        guard travel > 0 else { return ["error": "no scrollback"] }
        main.link?.isPaused = false
        let a = phaseMark()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            main.flingDone = done
            main.fling = (a.at, seconds, bottom, travel)
        }
        let b = phaseMark()
        let window = PerfWindow(from: a.at, to: b.at)
        let period = 1 / Double(max(60, UIScreen.main.maximumFramesPerSecond))
        let presents = PerfHitchStats.measure(state.withLock { $0.presents }, in: window, period: period)
        let link = PerfHitchStats.measure(main.ticks, in: window, period: period)
        var out = phaseResult(a, b)
        out["rows"] = Int((travel / term.cellSize.height).rounded())
        out["presents"] = Self.hitchJSON(presents, window: window)
        out["mainLink"] = Self.hitchJSON(link, window: window)
        return out
    }

    /// One step of the fling: up and back down, the speed a smooth cosine, so it starts and
    /// turns gently and moves fastest halfway each way.
    @MainActor
    private func flingStep(_ now: Double) {
        guard let f = main.fling, let term = main.host?.term else { return }
        let t = min(1, (now - f.start) / f.seconds)
        let y = f.bottom - f.travel * (1 - cos(2 * .pi * t)) / 2
        term.scroller.setOffset(y, animated: false)
        guard t >= 1 else { return }
        main.fling = nil
        main.flingDone?.resume()
        main.flingDone = nil
    }

    private static func hitchJSON(_ h: PerfHitchStats, window: PerfWindow) -> JSONObject {
        let s = max(window.seconds, 1e-6)
        return ["perSecond": (Double(h.events) / s * 10).rounded() / 10, "hitches": h.hitches,
                "hitchMs": (h.hitchSeconds * 1e6).rounded() / 1e3, "hitchMsPerSecond": (h.hitchSeconds * 1e3 / s * 10).rounded() / 10,
                "worstGapMs": (h.worstSeconds * 1e6).rounded() / 1e3]
    }

    @MainActor
    private func uninstall() {
        main.link?.invalidate()
        main.link = nil
        for o in main.observers { CFRunLoopRemoveObserver(CFRunLoopGetMain(), o, .commonModes) }
        main.observers = []
        main.sampler?.cancel()
        main.sampler = nil
        main.fling = nil
        main.flingDone?.resume()
        main.flingDone = nil
        // Auto-lock stays off until the process ends: the device benchmark launches the next run
        // into this one, and a phone that locked in between could not be launched into.
    }

    @MainActor
    private func write() {
        let now = Self.clock()
        let idle = main.idleFootprint ?? PerfSystem.footprint()
        let phases = main.phases
        var busy = main.busy
        if let from = main.sliceStart { busy.append(PerfWindow(from: from, to: now)) }
        let ticks = main.ticks
        let s: State? = state.withLock { s in
            guard !s.written else { return nil }
            s.written = true
            return s
        }
        guard let s else { return }
        uninstall()
        var json = Self.result(name: name, state: s, ticks: ticks, busy: busy, idle: idle, now: now,
                               screenHz: UIScreen.main.maximumFramesPerSecond, screen: UIScreen.main.bounds.size, scale: UIScreen.main.scale)
        // Find (`-findTest`): its passes and feeds, to compare with a run that has none.
        if let find = main.host?.term.core.find {
            json["find"] = ["passes": find.passes.load(ordering: .relaxed), "feeds": find.feeds.load(ordering: .relaxed),
                            "total": find.published.withLock { $0.total }]
        }
        json.merge(phases) { a, _ in a }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Atomic: whoever waits for the file never reads half of it.
        try? JSONCodec.data(json, pretty: true).write(to: fileURL, options: .atomic)
    }

    private static func result(name: String, state s: State, ticks: [Double], busy: [PerfWindow], idle: UInt64,
                               now: Double, screenHz: Int, screen: CGSize = .zero, scale: CGFloat = 0) -> JSONObject {
        func ms(_ seconds: Double) -> Double { (seconds * 1e6).rounded() / 1e3 }
        func mb(_ bytes: UInt64) -> Double { (Double(bytes) / 1_048_576 * 100).rounded() / 100 }
        func since(_ base: Double?, _ t: Double?) -> Any {
            guard let base, let t else { return NSNull() }
            return ms(t - base)
        }
        func target(_ m: Mark) -> Target? { s.targets[m.rawValue] }

        var asserts = false
        assert({ asserts = true; return true }())
        var out: JSONObject = [
            "schema": 1,
            "name": name,
            "mode": s.replay == nil ? "live" : "replay",
            "build": ["assertions": asserts, "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""],
            "device": device(screenHz: screenHz, screen: screen, scale: scale),
        ]
        if let e = s.error { out["error"] = e }
        if let r = s.replay {
            out["replay"] = ["file": r.file, "format": r.format, "bytes": r.bytes, "chunks": r.chunks, "rate": r.rate,
                             "cols": r.cols, "rows": r.rows, "zoom": r.zoom, "fontSize": r.fontSize, "delay": r.delay]
        }

        let restored = target(.restored)
        out["firstFrame"] = [
            "connectingMs": since(s.opening, s.connecting),
            "liveMs": since(s.opening, s.live),
            "snapshotBeginMs": since(s.opening, s.snapshotBegin),
            "snapshotReceivedMs": since(s.opening, s.snapshotReceived),
            "restoredMs": since(s.opening, restored?.at),
            "presentedMs": since(s.opening, restored?.shown),
            "presentedAssumed": restored?.assumed ?? false,
            "snapshotBytes": s.snapshotBytes,
        ]
        // Milliseconds after the process started.
        if let p0 = s.processStart, !s.launchSteps.isEmpty {
            var launch = s.launchSteps.reduce(into: JSONObject()) { $0[$1.key + "Ms"] = ms($1.value - p0) }
            launch["paneOpenMs"] = since(p0, s.opening)
            launch["paneFirstFrameMs"] = since(p0, restored?.shown)
            launch["peel"] = s.launchPeel ?? NSNull()
            launch["peelFrames"] = s.launchPeelFrames
            launch["peelHitchesAt"] = s.launchPeelHitchesAt
            // The main thread during the transition, on the probe's display link (it runs from pane
            // open, so it covers the transition when the pane opened before it).
            if let a = s.launchSteps["start"], let b = s.launchSteps["done"] {
                let w = PerfWindow(from: a, to: b)
                let period = 1 / Double(max(60, screenHz))
                launch["mainDuringTransition"] = hitchJSON(PerfHitchStats.measure(ticks, in: w, period: period), window: w)
                launch["mainBusyDuringTransitionMs"] = ms(PerfBusyStats.measure(busy, in: w).totalSeconds)
            }
            out["launch"] = launch
        }

        // The window: the flow when output was fed, else pane open to the first frame.
        let start = s.flowSample ?? s.openSample
        guard let start, let to = s.windowEnd ?? (s.error != nil ? now : nil) else { return out }
        let window = PerfWindow(from: start.at, to: to)
        let end = s.endSample ?? s.sample(now)
        out["window"] = ["kind": s.flowSample != nil ? "flow" : "open", "seconds": (window.seconds * 1e6).rounded() / 1e6]

        if let first = s.firstFed {
            let final = target(.final)
            let parse = final.map { $0.at - first }
            let drawn = final?.shown.map { $0 - first }
            func rate(_ seconds: Double?) -> Any {
                guard let seconds, seconds > 0 else { return NSNull() }
                return (Double(s.bytesFed) / 1_048_576 / seconds * 100).rounded() / 100
            }
            out["flow"] = [
                "bytesFed": s.bytesFed,
                "chunks": s.chunks,
                "feedMs": since(first, s.lastFed),
                "parseMs": since(first, final?.at),
                "drawnMs": since(first, final?.shown),
                "drawnAssumed": final?.assumed ?? false,
                "firstOutputMs": since(first, target(.firstOutput)?.shown),
                "firstOutputAssumed": target(.firstOutput)?.assumed ?? false,
                "parsedMBps": rate(parse),
                "drawnMBps": rate(drawn),
            ]
        }

        let link = PerfGapStats.measure(ticks, in: window, threshold: gapThreshold)
        out["mainLink"] = ["ticks": link.events, "gapsOver25": link.over, "gapsOver25Ms": ms(link.overSeconds),
                           "worstGapMs": ms(link.worstSeconds)]
        let presents = PerfGapStats.measure(s.presents, in: window, threshold: gapThreshold)
        out["presents"] = [
            "count": presents.events,
            "perSecond": window.seconds > 0 ? (Double(presents.events) / window.seconds * 10).rounded() / 10 : 0,
            "gapsOver25": presents.over, "gapsOver25Ms": ms(presents.overSeconds), "worstGapMs": ms(presents.worstSeconds),
        ]
        // Against the display's frame interval: at 120 Hz, gaps over 12.5 ms. Main-thread ticks
        // should never miss one; presents only when output arrives faster than the display.
        let period = 1 / Double(max(60, screenHz))
        out["hitches"] = ["periodMs": ms(period),
                          "mainLink": hitchJSON(PerfHitchStats.measure(ticks, in: window, period: period), window: window),
                          "presents": hitchJSON(PerfHitchStats.measure(s.presents, in: window, period: period), window: window)]
        let b = PerfBusyStats.measure(busy, in: window)
        out["mainBusy"] = ["totalMs": ms(b.totalSeconds), "worstMs": ms(b.worstSeconds),
                           "fraction": window.seconds > 0 ? (b.totalSeconds / window.seconds * 1000).rounded() / 1000 : 0]
        let cpu = end.cpu - start.cpu, mainCPU = end.mainCPU - start.mainCPU
        out["cpu"] = ["processMs": ms(cpu), "mainMs": ms(mainCPU), "otherMs": ms(cpu - mainCPU)]
        let energy = Double(end.power.energyNJ &- start.power.energyNJ) / 1e6   // mJ
        out["power"] = ["energyMJ": (energy * 100).rounded() / 100,
                        "averageMW": window.seconds > 0 ? (energy / window.seconds * 10).rounded() / 10 : 0,
                        "gpuMs": ms(Double(end.power.gpuNS &- start.power.gpuNS) / 1e9),
                        "wakeups": end.power.interruptWakeups &- start.power.interruptWakeups,
                        "idleWakeups": end.power.idleWakeups &- start.power.idleWakeups]
        out["memory"] = ["startMB": mb(start.footprint), "peakMB": mb(max(s.peak, end.footprint)), "endMB": mb(end.footprint),
                         "idleMB": mb(idle)]
        // The renderer's own timers, for tuning: row rebuild and encode, per pass.
        out["ghosttyRender"] = ["termLockWaitWorstMs": ms(Double(GhosttyCore.lockWaitWorstNs.load(ordering: .relaxed)) / 1e9),
                                "passes": s.passes, "buildMs": ms(s.buildSeconds), "buildWorstMs": ms(s.buildWorst),
                                "encodeMs": ms(s.encodeSeconds), "encodeWorstMs": ms(s.encodeWorst)]
        return out
    }

    private static func device(screenHz: Int, screen: CGSize, scale: CGFloat) -> JSONObject {
        let env = ProcessInfo.processInfo.environment
        var system = utsname()
        uname(&system)
        let machine = withUnsafeBytes(of: &system.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return [
            "simulator": env["SIMULATOR_UDID"] != nil,
            "model": env["SIMULATOR_MODEL_IDENTIFIER"] ?? machine,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "cores": ProcessInfo.processInfo.activeProcessorCount,
            "screenHz": screenHz,
            "screenPoints": "\(Int(screen.width))x\(Int(screen.height))@\(Int(scale))x",
            "drawables": GhosttyTerminalView.drawableCount,
        ]
    }
}
