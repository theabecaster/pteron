import CoreGraphics
import Foundation
import Testing
import RexKit
@testable import Pteron

/// A server's zoom in a tab with a floating window, in both shapes: up to revision 20 the one
/// zoomed pane covers the tab; from revision 21 the tiled zoom is drawn in the tiled layer's place
/// behind the floats, and only a float's zoom covers the tab.
@MainActor
struct ZoomShapeTests {
    typealias F = FloatsTests

    /// Tiled A and B side by side, float F over them.
    private func window(focused: String?, zoomed: String?, tiledZoomed: String?) -> WindowInfo {
        var t: JSONObject = ["layer_id": "layer:t", "kind": "tiled", "bounds": [0, 0, 1, 1], "blocks": ["A", "B"].map(F.block)]
        t["layout"] = F.two
        var w: JSONObject = ["window_id": "window:1", "label": "", "layers": [t, F.floatF]]
        if let focused { w["focused_block_id"] = focused }
        if let zoomed { w["zoomed_block_id"] = zoomed }
        if let tiledZoomed { w["tiled_zoomed_block_id"] = tiledZoomed }
        return WindowInfo(w)
    }

    /// As `WindowScreen.presentation` asks it, with no phone zoom.
    private func shown(_ w: WindowInfo, narrow: Bool) -> TabPresentation? {
        TabPresentation.decide(.init(window: w, narrow: narrow, zoomed: w.zoomCoveringWindow != nil,
                                     tiledZoom: w.tiledZoomUnderFloats, active: ActivePane.of(w, phone: nil),
                                     canvas: narrow ? FloatSheetTests.canvas : F.canvas, fontSize: F.font, crease: nil, front: nil))
    }

    @Test func revision20AZoomedTiledPaneCoversTheFloats() {
        let w = window(focused: "A", zoomed: "A", tiledZoomed: nil)
        #expect(shown(w, narrow: false) == .pages(ids: ["A", "B", "F"], current: "A"))
        #expect(shown(w, narrow: true) == .pages(ids: ["A", "B", "F"], current: "A"))
    }

    @Test func revision21TheTiledZoomIsDrawnBehindTheFloat() {
        // Focus on the float; A stays zoomed behind it.
        let w = window(focused: "F", zoomed: nil, tiledZoomed: "A")
        guard case .floating(let tiled, let floats)? = shown(w, narrow: false) else {
            Issue.record("wide: the floats over the tiled zoom")
            return
        }
        #expect(tiled == .single("A"))
        #expect(floats.map(\.id) == ["layer:f"])
        #expect(ActivePane.of(w, phone: nil) == "F")
        // Narrow: A alone under the float's sheet.
        guard case .floatSheet(let s)? = shown(w, narrow: true) else {
            Issue.record("narrow: the float sheet")
            return
        }
        #expect(s.tiled == .page("A", ids: ["A"]))
        #expect(s.shown?.layer == "layer:f")
    }

    @Test func revision21TheZoomedTiledPaneWithFocusStaysBehindTheFloatToo() {
        let w = window(focused: "A", zoomed: "A", tiledZoomed: "A")
        guard case .floating(let tiled, _)? = shown(w, narrow: false) else {
            Issue.record("the floats over the tiled zoom")
            return
        }
        #expect(tiled == .single("A"))
    }

    @Test func revision21AZoomedFloatCoversEverything() {
        let w = window(focused: "F", zoomed: "F", tiledZoomed: "A")
        #expect(shown(w, narrow: false) == .pages(ids: ["A", "B", "F"], current: "F"))
        #expect(shown(w, narrow: true) == .pages(ids: ["A", "B", "F"], current: "F"))
    }

    @Test func aTiledZoomWithItsFloatMinimizedShowsTheZoomedPane() {
        // The float minimized with focus in it: the tab shows the tiled zoom.
        let min = F.float("layer:f", "F", [0.3, 0.2, 0.5, 0.6], state: "minimized")
        var t: JSONObject = ["layer_id": "layer:t", "kind": "tiled", "bounds": [0, 0, 1, 1], "blocks": ["A", "B"].map(F.block)]
        t["layout"] = F.two
        let w = WindowInfo(["window_id": "window:1", "label": "", "layers": [t, min], "focused_block_id": "F",
                            "tiled_zoomed_block_id": "B"])
        #expect(ActivePane.of(w, phone: nil) == "B")
        #expect(w.isZoomed)
    }
}
