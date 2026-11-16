import UIKit

/// Development: applies a known selection in the offline demo (`-ghosttyDemo <path>`), through
/// the same seam members TerminalHost calls, so a screenshot can check the highlight.
///
/// - `-demoSelect c0,r0,c1,r1`: press on viewport cell (c0, r0) and drag to (c1, r1).
/// - `-demoSelectWord c,r`: long press on a cell.
/// - `-demoSelectOutline YES`: also outline `selectionRects` (what the shimmer and the edit menu
///   use), to compare them with the drawn highlight.
enum GhosttySelectionDemo {
    /// Call once the demo has fed its file. Waits for the feed queue to get through it.
    @MainActor
    static func applyIfRequested(to view: GhosttyTerminalView) {
        let defaults = UserDefaults.standard
        func cells(_ key: String) -> [Int]? {
            defaults.string(forKey: key).map { $0.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) } }
        }
        let drag = cells("demoSelect"), word = cells("demoSelectWord")
        guard drag?.count == 4 || word?.count == 2 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak view] in
            guard let view else { return }
            let cell = view.cellSize, origin = view.bounds.origin
            func point(_ col: Int, _ row: Int) -> CGPoint {
                CGPoint(x: origin.x + (CGFloat(col) + 0.5) * cell.width, y: origin.y + (CGFloat(row) + 0.5) * cell.height)
            }
            if let word, word.count == 2 {
                view.beginSelection(at: point(word[0], word[1]), word: true)
            } else if let drag, drag.count == 4 {
                view.beginSelection(at: point(drag[0], drag[1]), word: false)
                view.extendSelection(to: point(drag[2], drag[3]), autoscroll: false)
            }
            view.endSelectionDrag()
            guard defaults.bool(forKey: "demoSelectOutline") else { return }
            for rect in view.selectionRects {
                let outline = CALayer()
                outline.frame = rect
                outline.borderColor = UIColor.systemYellow.cgColor
                outline.borderWidth = 1
                outline.zPosition = 10
                view.layer.addSublayer(outline)
            }
        }
    }
}
