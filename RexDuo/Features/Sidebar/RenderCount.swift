#if DEBUG
import Foundation

/// Counts sidebar body runs and progress writes, to show that a flood of progress reports
/// re-renders only the status leaf. `-renderCount YES` logs one `RENDER_COUNT` line every 5 s
/// with the totals since launch (docs/debug-args.md).
@MainActor
enum RenderCount {
    enum Counter: String, CaseIterable {
        case sessionLists, tabRows, tabRowLabels, statusLeaves, progressWrites, windowScreens, paneMenuItems, portRows
        case tabStrips, tabChips, emptyStates
    }

    private static var counts: [Counter: Int] = [:]
    private static var logging = false

    /// Use as `let _ = RenderCount.bump(.tabRows)` in a body.
    @discardableResult
    static func bump(_ c: Counter) -> Bool {
        counts[c, default: 0] += 1
        guard !logging, UserDefaults.standard.bool(forKey: "renderCount") else { return true }
        logging = true
        Task { @MainActor in
            while true {
                try? await Task.sleep(for: .seconds(5))
                let line = Counter.allCases.map { "\($0.rawValue)=\(counts[$0] ?? 0)" }.joined(separator: " ")
                NSLog("RENDER_COUNT %@", line)
            }
        }
        return true
    }

    static func value(_ c: Counter) -> Int { counts[c] ?? 0 }
}
#endif
