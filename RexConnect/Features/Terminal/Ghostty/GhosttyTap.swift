import GhosttyVt
import UIKit

// What a single tap on the terminal does. The order is the one SwiftTerm's `singleTap` and
// TerminalHost's focus tap give together:
//
// 1. A tap on a pane that doesn't have the keyboard only focuses it (the host does that).
// 2. A tap while text is selected only clears the selection.
// 3. An OSC 8 hyperlink opens, even in a program that tracks the mouse.
// 4. A program that tracks the mouse gets a click.
// 5. A web address in the text opens.
// 6. A tap next to the cursor is left alone (SwiftTerm shows its Paste menu there).
// 7. A tap on the shell's prompt moves the shell's cursor (OSC 133).
//
// Steps 3, 5 and 7 are this file's; `GhosttyScroller.tapped` asks `tapOpensLinkOrMovesCursor`
// first and keeps doing 2 and 4 itself.

/// What the terminal says about a tapped cell, read in one hold of its lock.
struct GhosttyTapProbe: Equatable {
    var link: GhosttyTappedLink?
    var mouseTracking = false
    /// SwiftTerm's "near the cursor": fewer than 4 columns and fewer than 2 rows away.
    var nearCursor = false
    var prompt = GhosttyPromptClick.none
}

enum GhosttyTapAction: Equatable {
    /// Not the engine's tap: the host focuses the pane.
    case focusOnly
    case dismissSelection
    case open(String)
    case mouseClick
    case prompt(GhosttyPromptClick)
    case nothing
}

enum GhosttyTapRouting {
    static func action(focusedAtTouch: Bool, shift: Bool, hasSelection: Bool, probe: GhosttyTapProbe) -> GhosttyTapAction {
        // Shift keeps a click away from the program; it has no other meaning for a tap.
        guard focusedAtTouch else { return .focusOnly }
        if shift { return .nothing }
        if hasSelection { return .dismissSelection }
        if let link = probe.link, link.explicit { return .open(link.url) }
        if probe.mouseTracking { return .mouseClick }
        if let link = probe.link { return .open(link.url) }
        if probe.nearCursor { return .nothing }
        if probe.prompt != .none { return .prompt(probe.prompt) }
        return .nothing
    }
}

extension GhosttyCore {
    /// Everything a tap on viewport cell (`col`, `row`) needs to know. Takes the terminal lock once.
    func tapProbe(viewportCol col: Int, row: Int) -> GhosttyTapProbe {
        withTerminal { t in
            var probe = GhosttyTapProbe()
            ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, &probe.mouseTracking)
            probe.link = Self.hyperlink(t, col: col, row: row)
            // A program that takes clicks keeps them unless the cell is a real hyperlink.
            guard !probe.mouseTracking else { return probe }
            if probe.link == nil { probe.link = Self.plainLink(t, col: col, row: row) }
            guard probe.link == nil else { return probe }

            var point = GhosttyPoint()
            point.tag = GHOSTTY_POINT_TAG_VIEWPORT
            point.value.coordinate = GhosttyPointCoordinate(x: UInt16(clamping: col), y: UInt32(clamping: row))
            var ref = GhosttyGridRef()
            var active = GhosttyPointCoordinate()
            if ghostty_terminal_grid_ref(t, point, &ref) == GHOSTTY_SUCCESS,
               ghostty_terminal_point_from_grid_ref(t, &ref, GHOSTTY_POINT_TAG_ACTIVE, &active) == GHOSTTY_SUCCESS {
                var cx: UInt16 = 0, cy: UInt16 = 0
                ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_CURSOR_X, &cx)
                ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_CURSOR_Y, &cy)
                probe.nearCursor = abs(Int(active.x) - Int(cx)) < 4 && abs(Int(active.y) - Int(cy)) < 2
            }
            if !probe.nearCursor { probe.prompt = Self.promptClick(t, mode: promptWatch.mode, col: col, row: row) }
            return probe
        } ?? GhosttyTapProbe()
    }
}

/// Per-view state for taps. Main thread.
@MainActor
final class GhosttyTapState {
    /// Whether the view had the keyboard when the tap was recognized, before the host's own tap
    /// (which focuses an unfocused pane for the same touch) could change it.
    var focusedAtTouch = false
    /// Opens a link. `UIApplication.open` by default, as the SwiftTerm engine does; tests put
    /// their own here.
    var open: (URL) -> Void = { UIApplication.shared.open($0) }
}

extension GhosttyTerminalView {
    /// Asked by the scroll surface's tap before anything else. True if the tap opened a link or
    /// moved the shell's cursor, and so is used up.
    func tapOpensLinkOrMovesCursor(at point: CGPoint, shift: Bool) -> Bool {
        let cell = viewportCell(at: point)
        let action = GhosttyTapRouting.action(focusedAtTouch: taps.focusedAtTouch, shift: shift, hasSelection: hasActiveSelection,
                                              probe: core.tapProbe(viewportCol: cell.col, row: cell.row))
        switch action {
        case .open(let link):
            // Any scheme iOS has a handler for, as with the SwiftTerm engine.
            guard let url = URL(string: link) else { return false }
            taps.open(url)
            return true
        case .prompt(let click):
            return send(promptClick: click)
        case .focusOnly, .dismissSelection, .mouseClick, .nothing:
            return false
        }
    }

    /// Sends a prompt click as one write.
    private func send(promptClick click: GhosttyPromptClick) -> Bool {
        switch click {
        case .none:
            return false
        case .keys(let left, let right):
            // Through the key encoder, so the arrows follow DECCKM and the keyboard protocol.
            let key = GhosttyInputKey(left > 0 ? GHOSTTY_KEY_ARROW_LEFT : GHOSTTY_KEY_ARROW_RIGHT)
            let one = core.input.encode(key)
            let count = max(left, right)
            guard !one.isEmpty, count > 0 else { return false }
            var bytes: [UInt8] = []
            bytes.reserveCapacity(one.count * count)
            for _ in 0..<count { bytes += one }
            // Keys, like typed ones: the line the keyboard's shadow document mirrors has a new
            // cursor, and a scrolled-up view returns to the bottom.
            resetInputDocument()
            scroller.sendKeys(bytes)
            return true
        case .press(let column, let row):
            // A mouse report: it leaves the view where it is.
            engineDelegate?.engineSend(GhosttyPromptClick.pressBytes(column: column, row: row))
            return true
        }
    }
}

#if DEBUG
/// `-tapTest col,row[;col,row…]` (Debug builds, testing): once the pane is live, taps those
/// viewport cells as a focused finger tap would, `-tapTestAfter` seconds in (default 3) and a
/// second apart, and writes what each tap did to `Documents/tapTest.txt`. With `-tapTestType
/// <text>`, types the text a second after the last tap, to show where the shell's cursor went.
@MainActor
enum GhosttyTapTest {
    private static var ran = false

    static func run(on engine: any TerminalEngineView) {
        guard !ran, let view = engine as? GhosttyTerminalView,
              let spec = UserDefaults.standard.string(forKey: "tapTest") else { return }
        ran = true
        let cells = spec.split(separator: ";").compactMap { pair -> (Int, Int)? in
            let n = pair.split(separator: ",").compactMap { Int($0) }
            return n.count == 2 ? (n[0], n[1]) : nil
        }
        let after = UserDefaults.standard.object(forKey: "tapTestAfter") == nil ? 3 : UserDefaults.standard.double(forKey: "tapTestAfter")
        var report: [String] = []
        for (i, cell) in cells.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + after + Double(i)) { [weak view] in
                guard let view else { return }
                let rect = view.viewportRect(row: cell.1, columns: cell.0..<(cell.0 + 1))
                let probe = view.core.tapProbe(viewportCol: cell.0, row: cell.1)
                view.taps.focusedAtTouch = true
                let used = view.tapOpensLinkOrMovesCursor(at: CGPoint(x: rect.midX, y: rect.midY), shift: false)
                report.append("\(cell.0),\(cell.1) used=\(used) probe=\(probe)")
                let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("tapTest.txt")
                try? report.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            }
        }
        if let text = UserDefaults.standard.string(forKey: "tapTestType") {
            DispatchQueue.main.asyncAfter(deadline: .now() + after + Double(cells.count)) { [weak view] in view?.send(txt: text) }
        }
    }
}
#endif
