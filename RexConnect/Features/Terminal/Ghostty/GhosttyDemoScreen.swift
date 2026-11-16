import SwiftUI
import UIKit

/// Offline replay for development: shows a full-screen Ghostty terminal fed from a file. No server.
///
/// Launch arguments: `-ghosttyDemo <absolute path> [-demoCols N -demoRows N -demoFontSize S]`.
/// `-demoScrollTest <step>` scrolls by program once the file is in (the simulator can't be sent
/// touches from a script): a number is rows above the bottom (`120.5` leaves half a row cut at
/// the top), `top`, `bounce` (held past the top edge), `pageup`, `fling` (a decelerating scroll to
/// the top and back, which logs `SCROLLPERF`), or `type` (scroll up, then input arrives).
/// The file is either plain VT bytes or a raw Rex data stream capture (a `GHOSTSNP` snapshot,
/// then `ESC _ rex1;…ESC \` messages mixed with VT bytes).
enum GhosttyDemo {
    static var path: String? {
        let p = UserDefaults.standard.string(forKey: "ghosttyDemo")
        return (p?.isEmpty ?? true) ? nil : p
    }

    /// Removes Rex's `ESC _ rex1;` … `ESC \` control messages. Enough for a whole file in memory;
    /// the stream's real filter handles chunk boundaries.
    static func stripRexMessages(_ bytes: ArraySlice<UInt8>) -> [UInt8] {
        let marker = Array("\u{1b}_rex1;".utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = bytes.startIndex
        let end = bytes.endIndex
        while i < end {
            if bytes[i] == 0x1b, end - i >= marker.count, bytes[i..<(i + marker.count)].elementsEqual(marker) {
                var j = i + marker.count
                while j + 1 < end, !(bytes[j] == 0x1b && bytes[j + 1] == 0x5c) { j += 1 }
                i = min(end, j + 2)
            } else {
                out.append(bytes[i])
                i += 1
            }
        }
        return out
    }
}

struct GhosttyDemoScreen: UIViewRepresentable {
    let path: String

    func makeUIView(context: Context) -> GhosttyDemoView {
        let d = UserDefaults.standard
        let size = d.double(forKey: "demoFontSize")
        return GhosttyDemoView(path: path, fontSize: size > 0 ? size : 12,
                               cols: d.integer(forKey: "demoCols"), rows: d.integer(forKey: "demoRows"))
    }

    func updateUIView(_ view: GhosttyDemoView, context: Context) {}
}

final class GhosttyDemoView: UIView {
    let terminal: GhosttyTerminalView
    private let path: String
    private let fixedCols: Int
    private let fixedRows: Int
    private var started = false

    init(path: String, fontSize: CGFloat, cols: Int, rows: Int) {
        self.path = path
        fixedCols = cols
        fixedRows = rows
        terminal = GhosttyTerminalView(frame: .zero, fontSize: fontSize)
        super.init(frame: .zero)
        let theme = ThemeStore.theme(UserDefaults.standard.string(forKey: "demoTheme") ?? "github-dark-dimmed")
        terminal.apply(theme: theme)
        backgroundColor = theme.uiBG
        addSubview(terminal)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let area = bounds.inset(by: safeAreaInsets)
        guard area.width > 0, area.height > 0 else { return }
        let cell = terminal.cellSize
        let cols = fixedCols > 0 ? fixedCols : max(1, Int(area.width / cell.width))
        let rows = fixedRows > 0 ? fixedRows : max(1, Int(area.height / cell.height))
        terminal.setGrid(cols: cols, rows: rows, force: false)
        terminal.frame = CGRect(x: area.minX, y: area.minY, width: CGFloat(cols) * cell.width, height: CGFloat(rows) * cell.height)
        if !started {
            started = true
            start()
        }
    }

    private func start() {
        guard let data = FileManager.default.contents(atPath: path) else {
            terminal.feed(text: "ghosttyDemo: can't read \(path)\r\n")
            return
        }
        let bytes = [UInt8](data)
        let terminal = terminal
        let core = terminal.core
        let restoring = terminal.restoreSnapshot(bytes, consumed: { used in
            // On the feed queue: these bytes are parsed right after the restore.
            core.feed(GhosttyDemo.stripRexMessages(bytes[used...]))
        }, failed: {
            terminal.feed(text: "ghosttyDemo: snapshot did not decode\r\n")
        })
        if !restoring { core.feed(GhosttyDemo.stripRexMessages(bytes[...])) }
        GhosttySelectionDemo.applyIfRequested(to: terminal)
        if let step = UserDefaults.standard.string(forKey: "demoScrollTest"), !step.isEmpty {
            // After everything queued above has been parsed and a frame has reported its size.
            core.enqueue { [weak self] in DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self?.scrollTest(step) } }
        }
    }

    private var flingStart: CFTimeInterval = 0
    private var flingFrames = 0
    private var flingBuild: CFTimeInterval = 0
    private var flingBuildMax: CFTimeInterval = 0
    private var flingTicks = 0
    private static let flingSeconds: CFTimeInterval = 4

    /// A fling by program: from the bottom to the top of the scrollback and back, one offset per
    /// display frame with the speed of a decelerating scroll, then one `SCROLLPERF` line.
    @objc private func flingTick(_ link: CADisplayLink) {
        let scroller = terminal.scroller, surface = scroller.surface
        let bottom = surface.contentSize.height - surface.bounds.height
        let t = min(1, (CACurrentMediaTime() - flingStart) / Self.flingSeconds)
        // Up in the first half, down in the second, each easing out.
        let half = t < 0.5 ? t * 2 : (t - 0.5) * 2
        let eased = 1 - pow(1 - half, 3)
        scroller.setOffset(t < 0.5 ? bottom * (1 - eased) : bottom * eased, animated: false)
        // A look at the render thread's last frame. Unsynchronized: good enough for a demo log.
        let build = terminal.renderer.lastBuildSeconds + terminal.renderer.lastEncodeSeconds
        flingBuild += build
        flingBuildMax = max(flingBuildMax, build)
        flingTicks += 1
        guard t >= 1 else { return }
        link.invalidate()
        let seconds = CACurrentMediaTime() - flingStart, steps = max(1, scroller.scrollSteps)
        NSLog("SCROLLPERF fling over %d rows: %d display ticks, %d scroll steps, %.2f us main thread per step, %d frames drawn in %.1f s, render thread %.3f ms per frame (max %.3f), %d updates from the render thread",
              scroller.state.maxRow, flingTicks, scroller.scrollSteps, scroller.scrollStepSeconds / Double(steps) * 1e6,
              terminal.renderer.framesDrawn - flingFrames, seconds, flingBuild / Double(max(1, flingTicks)) * 1000,
              flingBuildMax * 1000, scroller.updates)
    }

    private func scrollTest(_ step: String) {
        let scroller = terminal.scroller, surface = scroller.surface
        let bottom = surface.contentSize.height - surface.bounds.height
        let cell = terminal.cellSize.height
        switch step {
        case "top":
            scroller.setOffset(0, animated: false)
        case "bounce":
            scroller.setOffset(-2.5 * cell, animated: false)
        case "pageup":
            terminal.scrollPage(up: true)
            terminal.scrollPage(up: true)
        case "type":
            scroller.setOffset(bottom - 200 * cell, animated: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [terminal] in terminal.scrollToBottomForInput() }
        case "fling":
            flingStart = CACurrentMediaTime()
            flingFrames = terminal.renderer.framesDrawn
            scroller.measures = true
            let link = CADisplayLink(target: self, selector: #selector(flingTick(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)
        default:
            if let rows = Double(step) { scroller.setOffset(bottom - CGFloat(rows) * cell, animated: false) }
        }
    }
}
