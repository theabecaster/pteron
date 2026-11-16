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
// Steps 3, 5 and 7 are this file's: TerminalHost's tap asks `tapOpensLinkOrMovesCursor` first
// (`TAP HOOK`), before the selection UI counts the tap and before the focus logic. The host does
// 1, 2 and 6 (its Paste menu uses the same "next to the cursor"), the scroll surface's tap does 4.

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
    /// A tap this soon after a used-up one, this close to it, is the next tap of a double or
    /// triple tap: it selects (the host), and is never a second link or prompt tap.
    /// Both are wider than the host's own window for a multi-tap (`SelectionTapCounter`).
    static let repeatInterval: CFTimeInterval = 0.5
    static let repeatDistance: CGFloat = 40

    /// Opens a link. `UIApplication.open` by default; tests put their own here.
    var open: (URL) -> Void = { UIApplication.shared.open($0) }
    /// Asks before a link opens that `LinkOpenPolicy` doesn't open at once. Nil: the view shows
    /// an alert (`TerminalPrompt`). Tests put their own here.
    var ask: ((URL, LinkOpenPolicy.LinkQuestion, @escaping @MainActor (Bool) -> Void) -> Void)?
    var clock: () -> CFTimeInterval = { CACurrentMediaTime() }
    private var last: (time: CFTimeInterval, point: CGPoint)?

    /// True if a tap at `point` now continues the last used-up tap.
    func repeats(at point: CGPoint) -> Bool {
        guard let last else { return false }
        return clock() - last.time < Self.repeatInterval
            && abs(point.x - last.point.x) <= Self.repeatDistance && abs(point.y - last.point.y) <= Self.repeatDistance
    }

    func used(at point: CGPoint) { last = (clock(), point) }
}

/// Engines without links or prompt clicks leave every tap to the host.
extension TerminalEngineView {
    func tapOpensLinkOrMovesCursor(at p: CGPoint, focused: Bool, shift: Bool) -> Bool { false }
}

extension GhosttyTerminalView {
    /// Asked by the host's tap before anything else (`TAP HOOK` in TerminalHost). True if the tap
    /// opened a link or moved the shell's cursor, and so is used up.
    func tapOpensLinkOrMovesCursor(at point: CGPoint, focused: Bool, shift: Bool) -> Bool {
        // The cheap conditions first: the rest costs a terminal lock.
        guard focused, !shift, !taps.repeats(at: point) else { return false }
        let cell = viewportCell(at: point)
        let probe = core.tapProbe(viewportCol: cell.col, row: cell.row)
        let action = GhosttyTapRouting.action(focusedAtTouch: focused, shift: shift, hasSelection: hasActiveSelection, probe: probe)
        var used = false
        switch action {
        case .open(let link):
            // A program wrote the link: web and mail addresses open, anything else, and a label
            // that names another site, is asked about first (`LinkOpenPolicy`). An address found
            // in the text is its own label.
            let label = probe.link?.explicit == true ? core.hyperlinkLabel(atViewportCol: cell.col, row: cell.row) : nil
            switch LinkOpenPolicy.decide(target: link, label: label) {
            case .open(let url):
                taps.open(url)
                used = true
            case .ask(let url, let question):
                let open = taps.open
                let answer: @MainActor (Bool) -> Void = { if $0 { open(url) } }
                if let ask = taps.ask {
                    ask(url, question, answer)
                } else {
                    TerminalPrompt.ask(over: self, link: url, question: question, answer: answer)
                }
                used = true
            case .refuse:
                break
            }
        case .prompt(let click):
            used = send(promptClick: click)
        case .focusOnly, .dismissSelection, .mouseClick, .nothing:
            break
        }
        if used { taps.used(at: point) }
        return used
    }

    /// A click the host decided on (`TerminalTapDecision`): press and release at the cell.
    func sendClickToProgram(at point: CGPoint) {
        scroller.forwardTap(at: point)
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
                let used = view.tapOpensLinkOrMovesCursor(at: CGPoint(x: rect.midX, y: rect.midY), focused: true, shift: false)
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
