#if DEBUG
import Foundation
import RexKit

/// `-panesTest '<step>;<step>…'` (Debug builds, testing): runs Arrange's commands on the tab on
/// screen once it shows, where the simulator can't tap through the pane menu. Steps run two
/// seconds apart, each through the same path as its menu item or key:
///
/// - `swap`: Swap With the next pane. `moveTo:<n>`: Move to Tab, the session's n-th tab (from 1).
/// - `newTab`: Move to New Tab. `balance`: Balance Splits. `closeOthers`: Close Other Panes,
///   confirmed. `tab:+1`, `tab:-1`: `client.tab.move.*`.
/// - `dragTab:<gap>`: the sidebar's drop of this tab in that gap of its session's tabs.
///   `dragSession:<gap>`: the same for this session among its machine's.
/// - `wait:<seconds>`: pause.
///
/// After each step it logs `PANES_STATE` with the session's tabs and each tab's panes and split
/// ratios. Use only with a throwaway `zz-` session you made.
@MainActor
enum PanesTest {
    struct Actions {
        var swapNext: () -> Void
        var moveTo: (Int) -> Void
        var newTab: () -> Void
        var balance: () -> Void
        var closeOthers: () -> Void
        var moveTab: (Int) -> Void
        var dragTab: (Int) -> Void
        var dragSession: (Int) -> Void
        var state: () -> String
    }

    private static var ran = false

    static func run(_ a: Actions) {
        guard !ran, let script = UserDefaults.standard.string(forKey: "panesTest") else { return }
        ran = true
        let steps = script.split(separator: ";").map(String.init)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            NSLog("PANES_STATE start %@", a.state())
            for step in steps {
                let (verb, arg) = step.firstIndex(of: ":").map { (String(step[..<$0]), String(step[step.index(after: $0)...])) } ?? (step, "")
                NSLog("PANES_TEST %@", step)
                let n = Int(arg.replacingOccurrences(of: "+", with: "")) ?? 0
                switch verb {
                case "swap": a.swapNext()
                case "moveTo": a.moveTo(n)
                case "newTab": a.newTab()
                case "balance": a.balance()
                case "closeOthers": a.closeOthers()
                case "tab": a.moveTab(n)
                case "dragTab": a.dragTab(n)
                case "dragSession": a.dragSession(n)
                case "wait": try? await Task.sleep(for: .seconds(Double(arg) ?? 1))
                default: NSLog("PANES_TEST unknown step %@", step)
                }
                try? await Task.sleep(for: .seconds(2))
                NSLog("PANES_STATE %@ %@", step, a.state())
            }
        }
    }

    /// The session's tabs in order, each with its tiled panes and split ratios.
    static func describe(_ v: SessionView?, current: String) -> String {
        guard let v else { return "no view" }
        return "rev=\(v.revision) " + v.windows.map { w in
            let ratios = w.layout?.splits.map { String(format: "%@%.3f", $0.direction == "vertical" ? "v" : "h", $0.ratio) } ?? []
            let mark = w.id == current ? "*" : ""
            return "\(mark)\(w.id.suffix(4))[\(PaneScope.arrangeable(window: w).map { String($0.suffix(4)) }.joined(separator: ","))](\(ratios.joined(separator: ",")))"
        }.joined(separator: " ")
    }
}
#endif
