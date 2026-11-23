@_spi(Bench) import RexKit
import SwiftUI
import UIKit

// Debug and benchmark builds only (`BENCH`, set by scripts/bench/run.sh for its optimized build):
// driven by launch arguments, not in a shipped app.
#if DEBUG || BENCH
/// Offline replay: one real `TerminalHost` fed from a file, with no server and no network.
/// It is the deterministic benchmark (with `-perfLog`) and a screenshot check.
///
/// Launch arguments:
/// `-replay <file> [-replayCols N -replayRows N]
///  [-replayChunk <bytes>] [-replayRate max|<bytes/s>] [-replayDelay <seconds>]
///  [-replayFontSize <points>] [-echoScript <file> [-echoDelay <ms>]]`.
///
/// - `<file>`: an absolute path (the simulator reads the Mac's files), or a path inside the
///   app's Documents (a device: copy the file there first). `ReplayCapture` lists the formats.
/// - Grid: the largest that fits the screen at the font size, as fit mode would pick, unless
///   given. A grid that doesn't fit is zoomed out, as in mirror mode.
/// - `-replayChunk`: bytes per chunk for files without their own (default 16384).
/// - `-replayRate`: `max`, or bytes per second. Default: a timed file's own delays, `max` for
///   the others.
/// - `-replayDelay`: seconds between the pane being live and the first output of a file that
///   holds no snapshot (default 1), so launch work stays out of the measured window.
/// - `-echoScript`: with a `rex` capture, the pane is a real stream on a scripted link that opens
///   with the capture, and a recorded typing session is typed into it (`EchoScript`); the other
///   replay arguments but the font size do not apply.
/// - If the snapshot in a `rex` capture can't be restored, the screen is seeded from `<file>.vt`
///   if it exists (what `terminal.format` returned when the capture was made), else from nothing.
struct ReplayConfig {
    static let argument = "replay"

    var path: String
    var cols: Int
    var rows: Int
    var chunk: Int
    var rate: ReplayRate
    var delay: Double
    var fontSize: Double

    /// The run's replay, or nil without `-replay <file>`.
    @MainActor static let current = ReplayConfig(defaults: .standard, fontSize: Prefs.shared.fontSize)

    init?(defaults d: UserDefaults, fontSize defaultSize: Double) {
        guard let p = d.string(forKey: Self.argument), !p.isEmpty else { return nil }
        path = p.hasPrefix("/") ? p
            : FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(p).path
        cols = d.integer(forKey: "replayCols")
        rows = d.integer(forKey: "replayRows")
        chunk = d.integer(forKey: "replayChunk") > 0 ? d.integer(forKey: "replayChunk") : ReplayCapture.defaultChunk
        rate = ReplayRate(argument: d.string(forKey: "replayRate")) ?? .recorded
        delay = d.object(forKey: "replayDelay") != nil ? max(0, d.double(forKey: "replayDelay")) : 1
        fontSize = d.double(forKey: "replayFontSize") > 0 ? d.double(forKey: "replayFontSize") : defaultSize
    }
}

struct ReplayScreen: UIViewRepresentable {
    let config: ReplayConfig

    func makeUIView(context: Context) -> ReplayView { ReplayView(config: config) }

    func updateUIView(_ view: ReplayView, context: Context) {}
}

final class ReplayView: UIView {
    private let config: ReplayConfig
    private let theme: TermTheme
    private(set) var host: TerminalHost?
    private var source: ReplaySource?
    private var player: EchoScriptPlayer?
    private var opened = false

    init(config: ReplayConfig) {
        self.config = config
        theme = ThemeStore.theme(Prefs.shared.darkThemeID)
        super.init(frame: .zero)
        backgroundColor = theme.uiBG
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let area = bounds.inset(by: safeAreaInsets)
        guard window != nil, area.width > 20, area.height > 20 else { return }
        if !opened {
            opened = true
            open(in: area)
        }
        host?.frame = area
    }

    private func open(in area: CGRect) {
        guard let file = FileManager.default.contents(atPath: config.path) else {
            fail("replay: can't read \(config.path)")
            return
        }
        let nonce = (try? String(contentsOfFile: config.path + ".nonce", encoding: .utf8))
            .flatMap { UInt64($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let capture = ReplayCapture(file: file, nonce: nonce, chunk: config.chunk, rate: config.rate)
        guard !capture.chunks.isEmpty else {
            fail("replay: \(config.path) is empty")
            return
        }
        // `-echoScript <file>`: the capture opens a pane on a scripted link, and the script types.
        do {
            if let script = try EchoScript.current(beside: config.path) {
                openScripted(script, capture: capture, in: area)
                return
            }
        } catch {
            fail("replay: can't read the echo script: \(error.localizedDescription)")
            return
        }
        let seed = (try? String(contentsOfFile: config.path + ".vt", encoding: .utf8)) ?? ""

        // The host needs a stream. This one has no server: its control connection is never
        // opened, so `start()` fails at its first call and stops. The replay source takes its
        // place as what feeds the host.
        let control = RexControl(address: "", client: ClientInfo(name: "replay", version: "0", label: "replay"))
        let stream = TerminalStream(control: control, sessionID: "replay", blockID: "replay")
        // Mirror: the host shows the grid the "server" has and never claims or resizes.
        let host = TerminalHost(stream: stream, sizing: .mirror, fontSize: config.fontSize, theme: theme)
        stream.sink = nil
        host.frame = area
        addSubview(host)
        self.host = host
        // `-findTest <needle>`: find is open with this needle before the first byte arrives.
        if let needle = UserDefaults.standard.string(forKey: "findTest"), !needle.isEmpty {
            host.openFind(text: needle, focus: false)
        }

        let cell = host.term.cellSize
        let fit = TerminalLayout.fitGrid(in: area.size, cell: cell)
        let grid = (cols: config.cols > 0 ? config.cols : fit.cols, rows: config.rows > 0 ? config.rows : fit.rows)
        let shown = capture.grid ?? grid
        // What `TerminalHost.positionTerm` will make of it in mirror mode.
        let zoom = min(area.width / (ceil(CGFloat(shown.cols) * cell.width) + 0.5), 1)

        let source = ReplaySource(capture: capture, seed: seed, grid: grid, delay: config.delay)
        source.sink = host
        source.onFinished = { [weak host] in
            if let host { PerfProbe.active?.sourceFinished(host) }
        }
        self.source = source
        PerfProbe.active?.replayStarted(PerfReplayInfo(
            file: (config.path as NSString).lastPathComponent, format: capture.format.rawValue, bytes: capture.data.count,
            chunks: capture.chunks.count, rate: config.rate.description, cols: shown.cols, rows: shown.rows,
            zoom: Double(zoom), fontSize: config.fontSize, delay: config.delay))
        // After this layout pass, as a stream's start is.
        Task { @MainActor in source.start() }
    }

    /// The benchmark's `predict` scenario: a real stream on a link that plays the server, so the
    /// stream's queue, its round-trip samples, the server's gate and the host's own gates all
    /// run as they do on a slow link. Nothing forces predictions on.
    private func openScripted(_ script: EchoScript, capture: ReplayCapture, in area: CGRect) {
        let link = ScriptedEchoLink(writeDelay: EchoScript.delay(), opening: [UInt8](capture.data), nonce: capture.nonce)
        let control = RexControl(address: "", client: ClientInfo(name: "replay", version: "0", label: "replay"))
        // `-predict never`: no gate at all, which is the pane without predicted echo, to compare.
        let gate = UserDefaults.standard.string(forKey: "predict") == "never" ? nil : EchoGate()
        let stream = link.stream(control: control, sessionID: "replay", blockID: "replay", echoGate: gate)
        let host = TerminalHost(stream: stream, sizing: .mirror, fontSize: config.fontSize, theme: theme)
        let player = EchoScriptPlayer(script: script, link: link, host: host)
        host.echoContext = { [weak player] in (agent: false, foreground: player?.foreground) }
        host.frame = area
        addSubview(host)
        self.host = host
        self.player = player

        let cell = host.term.cellSize
        let shown = capture.grid ?? (cols: script.cols, rows: script.rows)
        let zoom = min(area.width / (ceil(CGFloat(shown.cols) * cell.width) + 0.5), 1)
        PerfProbe.active?.replayStarted(PerfReplayInfo(
            file: (config.path as NSString).lastPathComponent, format: capture.format.rawValue, bytes: capture.data.count,
            chunks: script.steps.count, rate: "script", cols: shown.cols, rows: shown.rows,
            zoom: Double(zoom), fontSize: config.fontSize, delay: 0))
        // After this layout pass, as a stream's start is.
        Task { @MainActor in
            stream.start()
            await player.run()
        }
    }

    private func fail(_ message: String) {
        let label = UILabel(frame: bounds.insetBy(dx: 16, dy: 80))
        label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        label.numberOfLines = 0
        label.font = RexFont.ui(13)
        label.textColor = theme.uiFG
        label.text = message
        addSubview(label)
        PerfProbe.active?.fail(message)
    }
}
#endif
