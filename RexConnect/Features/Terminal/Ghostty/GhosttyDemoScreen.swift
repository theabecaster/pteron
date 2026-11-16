import SwiftUI
import UIKit

/// Offline replay for development: shows a full-screen Ghostty terminal fed from a file. No server.
///
/// Launch arguments: `-ghosttyDemo <absolute path> [-demoCols N -demoRows N -demoFontSize S]`.
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
    }
}
