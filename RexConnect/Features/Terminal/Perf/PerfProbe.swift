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
///   data socket's WELCOME. SwiftTerm reads the screen (`terminal.format`) before it opens the
///   data socket, so its `live` comes after its first frame; Ghostty's comes before.
/// - `snapshotBegin`: Ghostty only, the snapshot's first bytes arrived.
/// - `snapshotReceived`: the whole snapshot is here. Ghostty: the `end` part. SwiftTerm:
///   `streamSnapshot` was called with the text.
/// - `restored`: the engine holds the restored screen. Ghostty: the decoder's terminal was
///   swapped in (feed queue). SwiftTerm: `feed(text:)` returned (it parses on the caller).
/// - `presented`: the first frame that shows the restored screen was handed to the GPU. See
///   "A frame that shows a state" below.
///
/// **Flow** (`flow`), when output was fed: the window runs from the first `streamFeed` to the
/// frame that shows the final state.
/// - `parseMs`: first byte fed to last byte parsed. Ghostty: its feed queue ran dry (a marker
///   queued behind the last bytes). SwiftTerm: the host's paced output queue is empty and the
///   last slice was parsed.
/// - `drawnMs`: first byte fed to the frame that shows the final state.
/// - `firstOutputMs`: first byte fed to the first frame that shows the first chunk.
///
/// **Frame pacing**, over the window.
/// - `mainLink`: the probe's own main-thread `CADisplayLink`. A gap between two callbacks over
///   25 ms is a main-thread hitch: the main thread could not run a display callback in time.
/// - `presents`: frames handed to the GPU. Ghostty: each `present` committed on the render
///   thread. SwiftTerm: each increase of its `diagnostics.renders`, seen at the end of the main
///   run loop pass that drew it. Gaps over 25 ms count the same way; they only mean a stall
///   while output arrives faster than that.
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
/// - Ghostty: the renderer reports each pass with the time it started (before it locks the
///   terminal). The first pass that started at or after T decides: if it presented, that
///   present; if it found nothing to draw, the present before it already showed the state. The
///   probe marks the core dirty once at T, so there is always such a pass.
/// - SwiftTerm: it counts frames prepared (`frames`) and frames drawn (`renders`), both on the
///   main thread. The probe reads both at T, before and after Core Animation's commit in every
///   run loop pass, and on its display link. A draw seen between two reads shows a frame at
///   least as new as the first read counted, so it shows T once that count is past the count
///   at T.
/// - If neither decides within 0.5 s (a view that isn't drawing), the last frame handed over is
///   taken and the result says so (`…Assumed`).
final class PerfProbe: Sendable {
    static let argument = "perfLog"
    /// The run's probe. Nil without `-perfLog <name>`.
    /// A global on purpose: the hooks sit on three threads (main, render, feed queue), in types
    /// nothing is injected into, and must cost one branch when it is nil.
    static let active: PerfProbe? = make(name: UserDefaults.standard.string(forKey: argument))

    static let gapThreshold = 0.025
    /// How long after the window the idle memory is read and the file written.
    static let settle = 2.0
    /// How long a frame that shows a state is waited for.
    static let frameWait = 0.5
    /// A run that hasn't finished by then is written as it is, with an error.
    static let runLimit = 120.0

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
        /// SwiftTerm's `frames` at T.
        var frames = 0
        /// When the frame that shows it was handed to the GPU.
        var shown: Double?
        var assumed = false
    }

    private struct Sample: Sendable {
        var at: Double
        var cpu: Double
        var mainCPU: Double
        var footprint: UInt64
    }

    /// Everything more than one thread touches.
    private struct State: Sendable {
        var engine = ""
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
        var bytesParsedOnMain = 0
        var sourceDone = false
        var openSample: Sample?
        var flowSample: Sample?
        var endSample: Sample?
        var windowEnd: Double?
        var peak: UInt64 = 0
        var error: String?
        var written = false

        func sample(_ now: Double) -> Sample {
            Sample(at: now, cpu: PerfSystem.processCPUSeconds(), mainCPU: PerfSystem.threadCPUSeconds(mainThread),
                   footprint: PerfSystem.footprint())
        }

        /// Sets a mark once.
        mutating func mark(_ m: Mark, at: Double, frames: Int = 0) {
            guard targets[m.rawValue] == nil else { return }
            targets[m.rawValue] = Target(at: at, frames: frames)
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
        weak var swiftTerm: RexTerminalView?
        var installed = false
        var link: CADisplayLink?
        var observers: [CFRunLoopObserver] = []
        var sampler: DispatchSourceTimer?
        var ticks: [Double] = []
        var busy: [PerfWindow] = []
        var sliceStart: Double?
        /// SwiftTerm's counters at the last read.
        var seen: (frames: Int, renders: Int)?
        var finishing = false
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
        main.swiftTerm = host.term as? RexTerminalView
        let core = (host.term as? GhosttyTerminalView)?.core
        let thread = PerfSystem.currentThread()
        let now = Self.clock()
        state.withLock { s in
            s.engine = host.engineKind.rawValue
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

    /// `streamSnapshot` was called with the screen as escape sequences (SwiftTerm).
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

    /// The engine parsed that text.
    @MainActor
    func seedParsed(host: TerminalHost) {
        guard tracks(host) else { return }
        let now = Self.clock()
        let frames = counters()?.frames ?? 0
        let core: GhosttyCore? = state.withLock { s in
            guard s.snapshotReceived != nil else { return nil }
            // Ghostty (after a snapshot it couldn't restore) parses the text on its feed queue.
            if let core = s.core { return core }
            s.mark(.restored, at: now, frames: frames)
            return nil
        }
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
        // Ghostty parses elsewhere: this runs on its feed queue once the first chunk is parsed.
        if let core = first { holdsWhenParsed(.firstOutput, core: core) }
    }

    /// The host parsed `count` bytes on the main thread (an engine that doesn't parse elsewhere).
    @MainActor
    func parsedOnMain(_ count: Int, host: TerminalHost) {
        guard tracks(host) else { return }
        let now = Self.clock()
        let wanted = state.withLock { s in
            s.bytesParsedOnMain += count
            return s.firstFed != nil
                && (s.targets[Mark.firstOutput.rawValue] == nil || (s.sourceDone && s.bytesParsedOnMain >= s.bytesFed))
        }
        guard wanted else { return }
        let frames = counters()?.frames ?? 0
        state.withLock { s in
            s.mark(.firstOutput, at: now, frames: frames)
            if s.sourceDone, s.bytesParsedOnMain >= s.bytesFed { s.mark(.final, at: now, frames: frames) }
        }
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
        let frames = counters()?.frames ?? 0
        let (core, closed): (GhosttyCore?, Bool) = state.withLock { s in
            s.sourceDone = true
            if s.core == nil, s.firstFed != nil, s.bytesParsedOnMain >= s.bytesFed { s.mark(.final, at: now, frames: frames) }
            return (s.firstFed != nil ? s.core : nil, s.closeIfComplete(now))
        }
        if let core { holdsWhenParsed(.final, core: core) }
        if closed { finishSoon() }
    }

    func fail(_ message: String) {
        state.withLock { if $0.error == nil { $0.error = message } }
        Task { @MainActor in self.write() }
    }

    // MARK: Hooks in the Ghostty engine

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
                s.targets[i]?.shown = s.lastPresent ?? now
                any = true
            }
            return any && s.closeIfComplete(now)
        }
        if closed { finishSoon() }
    }

    // MARK: Main-thread collection

    @MainActor
    private func counters() -> (frames: Int, renders: Int)? { main.swiftTerm?.perfCounters }

    @MainActor
    private func install(_ now: Double) {
        main.ticks.reserveCapacity(1 << 14)
        main.busy.reserveCapacity(1 << 16)
        main.sliceStart = now
        main.seen = counters()

        let link = CADisplayLink(target: Ticker(self), selector: #selector(Ticker.tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        main.link = link

        // Core Animation commits (and MTKView draws) from a `beforeWaiting` observer of order
        // 2,000,000. One read just before it, one after everything.
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
        observe(.beforeWaiting, order: 1_999_999) { p in p.readSwiftTerm(Self.clock()) }
        observe(.beforeWaiting, order: CFIndex.max) { p in
            let now = Self.clock()
            p.readSwiftTerm(now)
            if let from = p.main.sliceStart { p.main.busy.append(PerfWindow(from: from, to: now)) }
            p.main.sliceStart = nil
        }

        main.sampler = startSampler()

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
        readSwiftTerm(now)
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

    /// Reads SwiftTerm's counters. A draw since the last read shows a frame at least as new as
    /// the last read counted.
    @MainActor
    private func readSwiftTerm(_ now: Double) {
        guard let c = counters() else { return }
        defer { main.seen = c }
        guard let before = main.seen, c.renders > before.renders else { return }
        let drawn = c.renders - before.renders
        let closed = state.withLock { s in
            for _ in 0..<drawn { s.presents.append(now) }
            s.lastPresent = now
            var any = false
            for i in s.targets.indices {
                guard let t = s.targets[i], t.shown == nil, before.frames > t.frames else { continue }
                s.targets[i]?.shown = now
                any = true
            }
            return any && s.closeIfComplete(now)
        }
        if closed { finishSoon() }
    }

    // MARK: Result

    /// The window is closed: read the idle memory after `settle`, then write.
    private func finishSoon() {
        Task { @MainActor [self] in
            guard !main.finishing else { return }
            main.finishing = true
            try? await Task.sleep(nanoseconds: UInt64(Self.settle * 1e9))
            write()
        }
    }

    @MainActor
    private func uninstall() {
        main.link?.invalidate()
        main.link = nil
        for o in main.observers { CFRunLoopRemoveObserver(CFRunLoopGetMain(), o, .commonModes) }
        main.observers = []
        main.sampler?.cancel()
        main.sampler = nil
    }

    @MainActor
    private func write() {
        let now = Self.clock()
        let idle = PerfSystem.footprint()
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
        let json = Self.result(name: name, state: s, ticks: ticks, busy: busy, idle: idle, now: now,
                               screenHz: UIScreen.main.maximumFramesPerSecond)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Atomic: whoever waits for the file never reads half of it.
        try? JSONCodec.data(json, pretty: true).write(to: fileURL, options: .atomic)
    }

    private static func result(name: String, state s: State, ticks: [Double], busy: [PerfWindow], idle: UInt64,
                               now: Double, screenHz: Int) -> JSONObject {
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
            "engine": s.engine,
            "mode": s.replay == nil ? "live" : "replay",
            "build": ["assertions": asserts, "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""],
            "device": device(screenHz: screenHz),
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
        let b = PerfBusyStats.measure(busy, in: window)
        out["mainBusy"] = ["totalMs": ms(b.totalSeconds), "worstMs": ms(b.worstSeconds),
                           "fraction": window.seconds > 0 ? (b.totalSeconds / window.seconds * 1000).rounded() / 1000 : 0]
        let cpu = end.cpu - start.cpu, mainCPU = end.mainCPU - start.mainCPU
        out["cpu"] = ["processMs": ms(cpu), "mainMs": ms(mainCPU), "otherMs": ms(cpu - mainCPU)]
        out["memory"] = ["startMB": mb(start.footprint), "peakMB": mb(max(s.peak, end.footprint)), "endMB": mb(end.footprint),
                         "idleMB": mb(idle)]
        if s.core != nil {
            // The Ghostty renderer's own timers, for tuning: row rebuild and encode, per pass.
            out["ghosttyRender"] = ["passes": s.passes, "buildMs": ms(s.buildSeconds), "buildWorstMs": ms(s.buildWorst),
                                    "encodeMs": ms(s.encodeSeconds), "encodeWorstMs": ms(s.encodeWorst)]
        }
        return out
    }

    private static func device(screenHz: Int) -> JSONObject {
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
        ]
    }
}
