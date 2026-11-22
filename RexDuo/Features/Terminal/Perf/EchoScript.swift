import Foundation
@_spi(Bench) import RexKit

// Debug and benchmark builds only (`BENCH`, set by scripts/bench/run.sh for its optimized build):
// driven by launch arguments, not in a shipped app.
#if DEBUG || BENCH
/// A recorded typing session (`RexDuoTests/Fixtures/echo`, written by
/// `scripts/record-echo-fixtures.py`), for the benchmark's `predict` scenario: what a shell wrote
/// and when, when each key was typed, and the tty's state, on the client's clock.
///
/// `-replay <capture> -echoScript <file>`: the pane opens with the recorded stream `<capture>`
/// (its snapshot and size) on a scripted link that answers every call after `-echoDelay`
/// milliseconds (default 150), and the script is typed into it (`EchoScriptPlayer`).
struct EchoScript: Decodable {
    static let argument = "echoScript"

    struct Step: Decodable {
        var t: Double
        /// One message of the data socket, in hex.
        var out: String?
        var key: UInt8?
        var back: Bool?
        var boundary: Bool?
        var newLine: Bool?
        /// The tty's (echo, canonical) from now on, with the program in front (`fg`).
        var mode: [Bool]?
        var fg: String?
    }

    var cols: Int
    var rows: Int
    var steps: [Step]

    /// The run's script, or nil without `-echoScript <file>`. A path that is not absolute is
    /// beside the capture. Throws when the file can't be read.
    static func current(beside capture: String, defaults d: UserDefaults = .standard) throws -> EchoScript? {
        guard let path = d.string(forKey: argument), !path.isEmpty else { return nil }
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path)
            : URL(fileURLWithPath: capture).deletingLastPathComponent().appendingPathComponent(path)
        return try JSONDecoder().decode(EchoScript.self, from: Data(contentsOf: url))
    }

    /// The scripted link's delay, from `-echoDelay <ms>`.
    static func delay(defaults d: UserDefaults = .standard) -> Duration {
        .milliseconds(d.object(forKey: "echoDelay") == nil ? 150 : max(0, d.integer(forKey: "echoDelay")))
    }

    static func bytes(hex: String) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(hex.count / 2)
        var i = hex.startIndex
        while let j = hex.index(i, offsetBy: 2, limitedBy: hex.endIndex) {
            out.append(UInt8(hex[i..<j], radix: 16) ?? 0)
            i = j
        }
        return out
    }
}

/// Plays an `EchoScript` into a pane on a `ScriptedEchoLink`, at the script's own times: keys
/// through the software keyboard's path (`insertText`, `deleteBackward`), the program's output
/// on the link's data socket, the tty's state as the link's answer to `terminal.input_mode`.
/// The writes are the stream's own, answered by the link; the server's gate turns predictions
/// on from their round trips, as it does on a slow link.
@MainActor
final class EchoScriptPlayer {
    private let script: EchoScript
    private let link: ScriptedEchoLink
    private weak var host: TerminalHost?
    /// The program in front, as the script says; the pane's `echoContext` reads it.
    private(set) var foreground: String?

    init(script: EchoScript, link: ScriptedEchoLink, host: TerminalHost) {
        self.script = script
        self.link = link
        self.host = host
    }

    /// Waits until the pane is live with its fence down, plays the script, and tells the
    /// probes when the last step went.
    func run() async {
        guard let host else { return }
        let probe = EchoProbe.active
        probe?.watch(host.term.core)
        // At most 20 s: a snapshot that never restores ends the run with what there is.
        for _ in 0..<2000 where !link.isOpen || host.isCatchingUp { try? await Task.sleep(for: .milliseconds(10)) }
        // The launch transition and the first frame stay out of the measured window.
        try? await Task.sleep(for: .seconds(1))
        let clock = ContinuousClock()
        let start = clock.now
        for step in script.steps {
            try? await clock.sleep(until: start + .seconds(step.t))
            guard let host = self.host else { return }
            if let m = step.mode, m.count == 2 {
                link.inputMode = (echo: m[0], canonical: m[1])
                foreground = step.fg
            } else if let hex = step.out {
                link.deliver(EchoScript.bytes(hex: hex))
            } else if let key = step.key {
                probe?.typed(key, core: host.term.core, fenced: host.isCatchingUp)
                host.term.insertText(String(UnicodeScalar(key)))
            } else if step.back == true {
                host.term.deleteBackward()
            } else if step.boundary == true {
                // What ends a line in the recording, or a control key that does not.
                host.engineSend([step.newLine == true ? 0x0D : 0x0C])
            }
        }
        // The last answer, its settle and the frame that shows it.
        try? await Task.sleep(for: .seconds(1.5))
        if let host = self.host { PerfProbe.active?.sourceFinished(host) }
    }
}
#endif
