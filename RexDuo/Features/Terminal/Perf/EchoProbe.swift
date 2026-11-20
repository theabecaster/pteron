import Foundation
import QuartzCore
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
/// - `answeredMs`: the server answered a write of typed text. Answers go to the oldest key
///   without one, so this is exact only for keys typed more than a round trip apart (a key typed
///   while a write is out goes in the next one);
/// - `fedMs`: the first chunk of output that holds the letter (escape sequences skipped)
///   reached the terminal on the main thread;
/// - `shownMs`: the first frame that shows it was handed to the GPU. That chunk is marked once
///   it has been parsed, and the first render pass that began after it decides, as `PerfProbe`
///   decides a frame that shows a state.
/// `fenced` says whether the pane's catch-up fence was up at the keypress.
final class EchoProbe: Sendable {
    #if DEBUG || BENCH
    static let active: EchoProbe? = UserDefaults.standard.string(forKey: "echoTest").map { EchoProbe(name: $0) }
    #else
    static var active: EchoProbe? { nil }
    #endif

    struct Key {
        var char: UInt8
        var typed: Double
        var fenced: Bool
        var answered: Double?
        var fed: Double?
        var parsed: Double?
        var shown: Double?
    }

    private struct State {
        var core: ObjectIdentifier?
        var keys: [Key] = []
        var lastPresent: Double?
    }

    let name: String
    private let state = Mutex(State())

    init(name: String) { self.name = name }

    @inline(__always) private static func clock() -> Double { CACurrentMediaTime() }

    /// A key is typed into the pane of `core` now.
    func typed(_ char: UInt8, core: GhosttyCore, fenced: Bool) {
        let now = Self.clock()
        state.withLock { s in
            s.core = ObjectIdentifier(core)
            s.keys.append(Key(char: char, typed: now, fenced: fenced))
        }
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

    /// The result, as written to the file.
    func result() -> [String: Any] {
        let keys = state.withLock { $0.keys }
        func ms(_ a: Double, _ b: Double?) -> Double? { b.map { (($0 - a) * 1e5).rounded() / 100 } }
        let fed = keys.compactMap { ms($0.typed, $0.fed) }, shown = keys.compactMap { ms($0.typed, $0.shown) }
        func pct(_ v: [Double], _ q: Double) -> Double? {
            guard !v.isEmpty else { return nil }
            let s = v.sorted()
            return s[min(s.count - 1, Int((Double(s.count - 1) * q).rounded()))]
        }
        return [
            "name": name,
            "keys": keys.map { k -> [String: Any] in
                ["char": String(UnicodeScalar(k.char)), "fenced": k.fenced,
                 "answeredMs": ms(k.typed, k.answered) ?? NSNull(), "fedMs": ms(k.typed, k.fed) ?? NSNull(), "shownMs": ms(k.typed, k.shown) ?? NSNull()]
            },
            "fenced": keys.filter(\.fenced).count,
            "missing": keys.filter { $0.shown == nil }.count,
            "fedMedianMs": pct(fed, 0.5) ?? NSNull(), "fedP95Ms": pct(fed, 0.95) ?? NSNull(),
            "shownMedianMs": pct(shown, 0.5) ?? NSNull(), "shownP95Ms": pct(shown, 0.95) ?? NSNull(),
        ]
    }

    func write() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("perf")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = String(name.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0) })
        guard let data = try? JSONSerialization.data(withJSONObject: result(), options: [.prettyPrinted, .sortedKeys]) else { return }
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
            probe.typed(c, core: host.term.core, fenced: host.isCatchingUp)
            host.term.insertText(String(UnicodeScalar(c)))
            try? await Task.sleep(for: .seconds(every))
        }
        try? await Task.sleep(for: .seconds(1.5))
        target?.engineSend([0x15])
        probe.write()
    }
}
