import CoreGraphics
import RexKit

/// The pane a tab treats as active, the one typing goes to: the pane picked on the phone, else
/// the zoomed one, else the server's focus, else the first. Never one in a floating window that
/// isn't drawn (minimized on the Mac, say), so a hidden pane never takes the keyboard.
enum ActivePane {
    static func of(_ w: WindowInfo, phone: String?) -> String? {
        if let f = phone, w.allBlocks.contains(where: { $0.id == f }), !w.isHidden(f) { return f }
        if let z = w.zoomedBlockID, !w.isHidden(z) { return z }
        if let f = w.focusedBlockID, !w.isHidden(f) { return f }
        return w.pageBlockIDs.first
    }
}

/// How a tab with floating windows is shown, decided once per body and read by everything that
/// depends on it: the canvas, the floats, the page dots, the Waiting pill and Zoom. Book mode's
/// sidebar question (`bookFits`) stays about the tiled splits, floats or not.
///
/// Only a tab with a floating window on screen has one. Every other tab, a tab whose floats are
/// all minimized included, runs the screen's own split-or-page logic over its tiled panes,
/// unchanged, so it looks exactly as it did before floats were drawn.
enum TabPresentation: Equatable {
    /// What the tiled layer shows under the floats.
    enum TiledLook: Equatable {
        /// No tiled pane: the floats sit on the terminal's background.
        case empty
        /// One tiled pane, drawn as a single pane is.
        case single(String)
        /// The tiled splits as the Mac lays them out.
        case splits
    }

    /// The tiled layer, with the floating windows above it, front last. Wide windows only.
    case floating(tiled: TiledLook, floats: [FloatLayout.Frame])
    /// One pane at a time with page dots: the tiled panes, then the floats' panes, front first.
    case pages(ids: [String], current: String)

    struct Input {
        var window: WindowInfo
        /// A narrow window (folded Duo, iPhone portrait): never floating windows.
        var narrow: Bool
        /// Zoomed, on the server or on the phone: the shown pane alone, as in any tab.
        var zoomed: Bool
        /// The pane the screen treats as active (`WindowScreen.activeBlock`).
        var active: String?
        /// The panes' area with the keyboard down.
        var canvas: CGSize
        var fontSize: Double
        var crease: FloatLayout.Crease?
        /// A layer raised on the phone that the server hasn't put in front yet.
        var front: String?
    }

    /// Nil when no floating window is on screen: the caller then runs its own logic.
    static func decide(_ i: Input) -> TabPresentation? {
        let w = i.window
        let floats = w.visibleFloating
        guard !floats.isEmpty else { return nil }
        let ids = w.pageBlockIDs
        let current = i.active.flatMap { ids.contains($0) ? $0 : nil } ?? ids.first ?? ""
        let pages = TabPresentation.pages(ids: ids, current: current)
        if i.zoomed || i.narrow { return pages }
        let leaves = w.layout?.leaves ?? []
        let tiled: TiledLook
        switch leaves.count {
        case 0: tiled = .empty
        case 1: tiled = .single(leaves[0].id)
        default:
            guard SplitGeometry.legible(leaves.map(\.rect), canvas: i.canvas, fontSize: i.fontSize) else { return pages }
            tiled = .splits
        }
        var frames: [FloatLayout.Frame] = []
        for layer in FloatLayout.ordered(floats, front: i.front) {
            guard let f = FloatLayout.place(layer, canvas: i.canvas, fontSize: i.fontSize, crease: i.crease) else { return pages }
            frames.append(f)
        }
        return .floating(tiled: tiled, floats: frames)
    }

    /// The panes the dots and a swipe move through; nil while several show at once.
    var pageIDs: [String]? {
        if case .pages(let ids, _) = self { return ids }
        return nil
    }

    /// Zoom shows one pane of several on screen.
    var canZoom: Bool {
        if case .floating = self { return true }
        return false
    }

    /// The panes on screen: the page shown, or the tiled panes drawn and every float's panes.
    func visible(in w: WindowInfo) -> Set<String> {
        switch self {
        case .pages(_, let current):
            return [current]
        case .floating(let tiled, let floats):
            var out = Set(floats.flatMap { $0.leaves.map(\.id) })
            switch tiled {
            case .empty: break
            case .single(let id): out.insert(id)
            case .splits: out.formUnion(w.layout?.leaves.map(\.id) ?? [])
            }
            return out
        }
    }
}
