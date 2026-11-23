import Foundation
import QuartzCore
import RexKit
import Synchronization

/// Measures key-to-echo on a real pane: from a typed key to the first frame on screen that
/// shows the program's echo of it. On with `-echoTest <name>` (Debug and the benchmark's
/// `BENCH` build), nil otherwise: every hook is `EchoProbe.active?.…`, one load and one branch.
///
/// Once the active pane is live, `EchoDriver` waits `-echoStart` seconds (default 3), walks the
/// tab as a swipe does with `-echoWalk YES` (back two panes, then forward two, which leaves the
/// two before the last one warm) and waits `-echoAfterWalk` seconds there (default 3; 0 types
/// as the pane comes back), and types `-echoKeys` distinct letters (default 30),
/// `-echoEvery` seconds apart (default 0.4), through the software keyboard's path
/// (`insertText`). Then it clears the line (Control-U) and writes
/// `Documents/perf/<name>.json`.
///
/// For each key, milliseconds after the keypress:
/// - `leftMs`: the write that holds the key left for the server (recorded only while predicted
///   echo is on, when the pane hears its stream's writes): the app's own share of the wait;
/// - `answeredMs`: the server answered a write of typed text. Answers go to the oldest key
///   without one, so this is exact only for keys typed more than a round trip apart (a key typed
///   while a write is out goes in the next one);
/// - `fedMs`: the first chunk of output that holds the letter (escape sequences skipped)
///   reached the terminal on the main thread;
/// - `shownMs`: the first frame that shows it was handed to the GPU. That chunk is marked once
///   it has been parsed, and the first render pass that began after it decides, as `PerfProbe`
///   decides a frame that shows a state.
/// - `predictedMs`: the first frame that shows the key's guess was handed to the GPU, decided
///   the same way from the moment the feed queue published an overlay holding the letter. Nil
///   for a key that was never a drawn guess (a fast link, the first key at a prompt);
/// - `firstVisibleMs`: the earlier of `predictedMs` and `shownMs`: when the user saw the key.
/// `fenced` says whether the pane's catch-up fence was up at the keypress.
///
/// With predicted echo the result also holds the predictor's counters (`drawn`, `confirmed`,
/// `mismatched`, `vanished` and the rest, summed over the run's predictors) and what a key cost
/// in microseconds: `mainKeyUs` on the main thread (the host's gate and the hand-off to the feed
/// queue; `mainGateUs` is the gate alone, the rest is waking the feed queue; `mainSendUs` is
/// the whole of the host's send of one typed key, with or without predicted echo), `feedKeyUs`
/// (split into `feedGridUs`, `feedCallUs` and `feedPublishUs`, with `feedCellReads`) on the feed queue (placing the guess and publishing the overlay) and
/// `feedSliceUs` (the overlay's check after a slice of output while a predictor exists).
///
/// `-echoScript <file>` (`EchoScriptPlayer`, the benchmark's `predict` scenario) turns the probe
/// on as well; there the script types, not `EchoDriver`.
final class EchoProbe: Sendable {
    #if DEBUG || BENCH
    static let active: EchoProbe? = (UserDefaults.standard.string(forKey: "echoTest")
        ?? UserDefaults.standard.string(forKey: EchoScript.argument).map { _ in "script" }).map { EchoProbe(name: $0) }
    #else
    static var active: EchoProbe? { nil }
    #endif

    struct Key {
        var char: UInt8
        var typed: Double
        var fenced: Bool
        /// The write holding the key left for the server (seen only while predictions are on).
        var left: Double?
        var answered: Double?
        var fed: Double?
        var parsed: Double?
        var shown: Double?
        /// An overlay holding the key's guess was published.
        var guessed: Double?
        var predicted: Double?
    }

    /// A step of a key's path whose cost is sampled.
    enum Cost: Int, CaseIterable {
        case mainSend, mainKey, mainGate, feedKey, feedGrid, feedCall, feedPublish, feedSlice

        var title: String {
            switch self {
            case .mainSend: "mainSendUs"
            case .mainKey: "mainKeyUs"
            case .mainGate: "mainGateUs"
            case .feedKey: "feedKeyUs"
            case .feedGrid: "feedGridUs"
            case .feedCall: "feedCallUs"
            case .feedPublish: "feedPublishUs"
            case .feedSlice: "feedSliceUs"
            }
        }
    }

    private struct State {
        var core: ObjectIdentifier?
        var keys: [Key] = []
        var lastPresent: Double?
        /// Seconds, by `Cost`.
        var costs: [[Double]] = Array(repeating: [], count: Cost.allCases.count)
        /// The counters of predictors that retired during the run.
        var retired: [EchoPredictor.Counters] = []
        weak var watched: GhosttyCore?
        var cellReads: [Double] = []
        /// What the screen showed each time a predictor counted a wrong guess, a cap or a reset.
        var trace: [String] = []
        var traced = [0, 0, 0]
    }
    /// Samples kept per cost: a run types tens of keys, and a flood's slices need no more.
    private static let costCap = 4096

    let name: String
    private let state = Mutex(State())

    init(name: String) { self.name = name }

    @inline(__always) static func clock() -> Double { CACurrentMediaTime() }

    /// A step that began at `began` (`clock()`) ends now.
    func cost(_ what: Cost, since began: Double) { cost(what, seconds: Self.clock() - began) }

    func cost(_ what: Cost, seconds took: Double) {
        state.withLock { s in if s.costs[what.rawValue].count < Self.costCap { s.costs[what.rawValue].append(took) } }
    }

    /// A key's op on the feed queue read this many cells from the terminal.
    func cellsRead(_ n: Int) {
        state.withLock { s in if s.cellReads.count < Self.costCap { s.cellReads.append(Double(n)) } }
    }

    /// The feed queue published the overlay of the pane of `core`: a typed key whose letter it
    /// holds is a drawn guess from now. Only a key the program has not echoed yet can be one,
    /// which tells a letter typed twice apart.
    func published(_ overlay: EchoOverlay?, core: GhosttyCore) {
        guard let overlay, !overlay.cells.isEmpty else { return }
        let now = Self.clock()
        state.withLock { s in
            guard s.core == ObjectIdentifier(core) else { return }
            for i in s.keys.indices where s.keys[i].guessed == nil && s.keys[i].fed == nil {
                let c = UInt32(s.keys[i].char)
                if overlay.cells.contains(where: { $0.scalar == c }) { s.keys[i].guessed = now }
            }
        }
    }

    /// The predictor's counters after an op. When it counted a wrong guess, a cap or a reset
    /// since the last call, `screen` is asked for the cursor's row and the moment is kept.
    func counted(_ c: EchoPredictor.Counters, screen: () -> String) {
        let now = Self.clock()
        let have = [c.mismatched, c.capped, c.resets]
        let changed = state.withLock { s -> Bool in
            defer { s.traced = have }
            return s.traced != have
        }
        guard changed else { return }
        let row = screen()
        state.withLock { s in
            guard s.trace.count < 64 else { return }
            let first = s.keys.first?.typed ?? now
            let typed = String(decoding: s.keys.suffix(12).map(\.char), as: UTF8.self)
            let pending = String(decoding: s.keys.filter { $0.fed == nil }.map(\.char), as: UTF8.self)
            s.trace.append("t=\(((now - first) * 1000).rounded() / 1000) mismatched=\(c.mismatched) drawnMismatched=\(c.mismatchedDrawn) capped=\(c.capped) "
                + "vanished=\(c.vanished) resets=\(c.resets) placed=\(c.placed) drawn=\(c.drawn) confirmed=\(c.confirmed) "
                + "lastKeys='\(typed)' notEchoed='\(pending)' \(row)")
        }
    }

    /// A predictor retired (the link turned fast): its counters stay in the result.
    func retired(_ counters: EchoPredictor.Counters) {
        state.withLock { $0.retired.append(counters) }
    }

    /// A key is typed into the pane of `core` now.
    func typed(_ char: UInt8, core: GhosttyCore, fenced: Bool) {
        let now = Self.clock()
        state.withLock { s in
            s.core = ObjectIdentifier(core)
            s.keys.append(Key(char: char, typed: now, fenced: fenced))
        }
    }

    /// A write left for the server (main thread): it holds every key typed so far.
    func left() {
        let now = Self.clock()
        state.withLock { s in for i in s.keys.indices where s.keys[i].left == nil { s.keys[i].left = now } }
    }

    /// The server answered a write (main thread).
    func answered() {
        let now = Self.clock()
        state.withLock { s in if let i = s.keys.firstIndex(where: { $0.answered == nil }) { s.keys[i].answered = now } }
    }

    /// Output for the pane of `core` reached the terminal (main thread, `streamFeed`).
    func fed(_ bytes: UnsafeBufferPointer<UInt8>, core: GhosttyCore) {
        let id = ObjectIdentifier(core)
        let now = Self.clock()
        let text = Self.printable(bytes)
        let found: [Int] = state.withLock { s in
            guard s.core == id else { return [] }
            var hits: [Int] = []
            for i in s.keys.indices where s.keys[i].fed == nil && text.contains(s.keys[i].char) {
                s.keys[i].fed = now
                hits.append(i)
            }
            return hits
        }
        guard !found.isEmpty else { return }
        // Behind these bytes on the feed queue: parsed when it runs.
        core.enqueue { [self, weak core] in
            let parsed = Self.clock()
            self.state.withLock { s in for i in found { s.keys[i].parsed = parsed } }
            core?.onDirty?()
        }
    }

    /// A render pass ended (render thread). `built` is when it began, 0 if it lacked glyphs.
    func pass(core: GhosttyCore, built: Double, presented: Bool) {
        let now = Self.clock()
        state.withLock { s in
            guard s.core == ObjectIdentifier(core) else { return }
            if presented { s.lastPresent = now }
            for i in s.keys.indices {
                if s.keys[i].predicted == nil, let g = s.keys[i].guessed, built > 0, g <= built {
                    // A pass with nothing new to draw: a frame handed over since the overlay
                    // was published showed it (a pass that began before and latched after).
                    // Without such a frame nothing has shown the guess yet.
                    if presented {
                        s.keys[i].predicted = now
                    } else if let last = s.lastPresent, last >= g {
                        s.keys[i].predicted = last
                    }
                }
                guard s.keys[i].shown == nil, let p = s.keys[i].parsed, built > 0, p <= built else { continue }
                // A pass with nothing new to draw: the frame before it showed the echo.
                s.keys[i].shown = presented ? now : max(s.lastPresent ?? now, p)
            }
        }
    }

    /// The letters of a chunk, without its escape sequences (CSI, OSC and two-byte ones).
    static func printable(_ bytes: UnsafeBufferPointer<UInt8>) -> [UInt8] {
        var out: [UInt8] = []
        var i = 0
        let n = bytes.count
        while i < n {
            let b = bytes[i]
            if b == 0x1B, i + 1 < n {
                let next = bytes[i + 1]
                i += 2
                if next == UInt8(ascii: "[") {
                    while i < n, !(0x40...0x7E).contains(bytes[i]) { i += 1 }
                    i += 1
                } else if next == UInt8(ascii: "]") {
                    while i < n, bytes[i] != 0x07, !(bytes[i] == 0x1B && i + 1 < n && bytes[i + 1] == UInt8(ascii: "\\")) { i += 1 }
                    i += bytes.indices.contains(i) && bytes[i] == 0x1B ? 2 : 1
                }
                continue
            }
            if b >= 0x20, b < 0x7F { out.append(b) }
            i += 1
        }
        return out
    }

    /// The result, as written to the file. `live` is the counters of the pane's predictor, if
    /// it has one now.
    func result(live: EchoPredictor.Counters? = nil) -> [String: Any] {
        let (keys, costs, retired, trace, cellReads, watched) = state.withLock { ($0.keys, $0.costs, $0.retired, $0.trace, $0.cellReads, $0.watched) }
        func ms(_ a: Double, _ b: Double?) -> Double? { b.map { (($0 - a) * 1e5).rounded() / 100 } }
        func visible(_ k: Key) -> Double? { [k.predicted, k.shown].compactMap { $0 }.min() }
        let fed = keys.compactMap { ms($0.typed, $0.fed) }, shown = keys.compactMap { ms($0.typed, $0.shown) }
        let predicted = keys.compactMap { ms($0.typed, $0.predicted) }
        let seen = keys.compactMap { ms($0.typed, visible($0)) }
        // Keys that were drawn guesses, and the others (a fast link, the first key at a prompt).
        let seenGuessed = keys.filter { $0.predicted != nil }.compactMap { ms($0.typed, visible($0)) }
        let seenOthers = keys.filter { $0.predicted == nil }.compactMap { ms($0.typed, visible($0)) }
        var counters: [String: Int] = [:]
        for c in retired + (live.map { [$0] } ?? []) {
            for child in Mirror(reflecting: c).children {
                if let name = child.label, let n = child.value as? Int { counters[name, default: 0] += n }
            }
        }
        func pct(_ v: [Double], _ q: Double) -> Double? {
            guard !v.isEmpty else { return nil }
            let s = v.sorted()
            return s[min(s.count - 1, Int((Double(s.count - 1) * q).rounded()))]
        }
        var out: [String: Any] = [
            "name": name,
            "keys": keys.map { k -> [String: Any] in
                ["char": String(UnicodeScalar(k.char)), "fenced": k.fenced,
                 "leftMs": ms(k.typed, k.left) ?? NSNull(),
                 "answeredMs": ms(k.typed, k.answered) ?? NSNull(), "fedMs": ms(k.typed, k.fed) ?? NSNull(), "shownMs": ms(k.typed, k.shown) ?? NSNull(),
                 "predictedMs": ms(k.typed, k.predicted) ?? NSNull(), "firstVisibleMs": ms(k.typed, visible(k)) ?? NSNull()]
            },
            "fenced": keys.filter(\.fenced).count,
            "missing": keys.filter { $0.shown == nil }.count,
            "fedMedianMs": pct(fed, 0.5) ?? NSNull(), "fedP95Ms": pct(fed, 0.95) ?? NSNull(),
            "shownMedianMs": pct(shown, 0.5) ?? NSNull(), "shownP95Ms": pct(shown, 0.95) ?? NSNull(),
            "leftMedianMs": pct(keys.compactMap { ms($0.typed, $0.left) }, 0.5) ?? NSNull(),
            "predictedKeys": predicted.count,
            "predictedMedianMs": pct(predicted, 0.5) ?? NSNull(), "predictedP95Ms": pct(predicted, 0.95) ?? NSNull(),
            "firstVisibleMedianMs": pct(seen, 0.5) ?? NSNull(), "firstVisibleP95Ms": pct(seen, 0.95) ?? NSNull(),
            "firstVisibleGuessedMedianMs": pct(seenGuessed, 0.5) ?? NSNull(), "firstVisibleGuessedP95Ms": pct(seenGuessed, 0.95) ?? NSNull(),
            "firstVisibleOthersMedianMs": pct(seenOthers, 0.5) ?? NSNull(), "firstVisibleOthersP95Ms": pct(seenOthers, 0.95) ?? NSNull(),
        ]
        for (name, n) in counters { out[name] = n }
        out["trace"] = trace
        // Predictors the pane ever made: none on a link that stayed fast.
        out["predictors"] = watched?.echo.created.load(ordering: .relaxed) ?? 0
        let reads: [String: Any] = ["count": cellReads.count, "median": pct(cellReads, 0.5) ?? NSNull(), "max": cellReads.max() ?? NSNull()]
        out["feedCellReads"] = reads
        for c in Cost.allCases {
            let us = costs[c.rawValue].map { ($0 * 1e8).rounded() / 100 }
            let numbers: [String: Any] = ["count": us.count, "median": pct(us, 0.5) ?? NSNull(), "p95": pct(us, 0.95) ?? NSNull(),
                                          "max": us.max() ?? NSNull()]
            out[c.title] = numbers
        }
        return out
    }

    /// The pane whose predictor's counters the result reads.
    func watch(_ core: GhosttyCore) { state.withLock { $0.watched = core } }

    /// The result with the pane's counters, for the file and for `PerfProbe`'s result.
    func resultNow() -> [String: Any] { result(live: state.withLock { $0.watched }?.echoCounters) }

    func write() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("perf")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = String(name.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0) })
        guard let data = try? JSONSerialization.data(withJSONObject: resultNow(), options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: dir.appendingPathComponent("\(safe).json"), options: .atomic)
    }
}

/// Types for `EchoProbe`: on the main thread, into the pane on screen.
@MainActor
final class EchoDriver {
    static let active: EchoDriver? = EchoProbe.active.map { EchoDriver(probe: $0) }

    private let probe: EchoProbe
    private var started = false
    private var hosts: [WeakHost] = []
    private var switcher: ((Int) -> Void)?
    /// The host whose writes are timed.
    private weak var wired: TerminalHost?
    private struct WeakHost { weak var host: TerminalHost? }

    init(probe: EchoProbe) { self.probe = probe }

    func setSwitcher(_ s: @escaping (Int) -> Void) { switcher = s }

    /// A pane's stream is live.
    func live(_ host: TerminalHost) {
        hosts.removeAll { $0.host == nil || $0.host === host }
        hosts.append(WeakHost(host: host))
        guard !started, host.isActive else { return }
        started = true
        Task { await run() }
    }

    private var target: TerminalHost? { hosts.compactMap(\.host).last { $0.window != nil && $0.isActive } }

    private func run() async {
        let d = UserDefaults.standard
        func seconds(_ key: String, _ fallback: Double) -> Double { d.object(forKey: key) == nil ? fallback : d.double(forKey: key) }
        try? await Task.sleep(for: .seconds(seconds("echoStart", 3)))
        if d.bool(forKey: "echoWalk") {
            for (i, dir) in [-1, -1, 1, 1].enumerated() {
                switcher?(dir)
                if i < 3 { try? await Task.sleep(for: .seconds(1.5)) }
            }
            // Back on the last pane: `-echoAfterWalk` seconds before the first key (default 3).
            try? await Task.sleep(for: .seconds(seconds("echoAfterWalk", 3)))
        }
        let count = d.object(forKey: "echoKeys") == nil ? 30 : d.integer(forKey: "echoKeys")
        let every = seconds("echoEvery", 0.4)
        let letters = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ".utf8)
        for i in 0..<count {
            guard let host = target else { break }
            let c = letters[i % letters.count]
            if host !== wired {
                wired = host
                let before = host.stream.onWritten
                host.stream.onWritten = { [probe] in
                    before?()
                    probe.answered()
                }
            }
            probe.watch(host.term.core)
            probe.typed(c, core: host.term.core, fenced: host.isCatchingUp)
            host.term.insertText(String(UnicodeScalar(c)))
            try? await Task.sleep(for: .seconds(every))
        }
        try? await Task.sleep(for: .seconds(1.5))
        target?.engineSend([0x15])
        probe.write()
    }
}
