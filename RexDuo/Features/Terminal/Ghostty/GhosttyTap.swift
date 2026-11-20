import GhosttyVt
import UIKit

// What a single tap on the terminal does, in order (with TerminalHost's focus tap,
// `TerminalTapDecision`):
//
// 1. A tap on a pane that doesn't have the keyboard opens the link under it (`tapOpensLink`)
//    and leaves the keyboard down; anywhere else it only focuses the pane (the host does that).
// 2. A tap while text is selected only clears the selection.
// 3. A link opens: an OSC 8 hyperlink or a web address in the text, also in a program that
//    tracks the mouse. A tap on a link is the phone's Cmd-click, as Mac terminals open a link
//    on Cmd-click even where a program takes clicks; a long press still selects the text.
// 4. A program that tracks the mouse gets a click.
// 5. A tap next to the cursor is left alone (the host shows its Paste menu there).
// 6. A tap on the shell's prompt moves the shell's cursor (OSC 133).
//
// The links of 1 and 3, and 6, are this file's: TerminalHost's tap asks `tapOpensLink` or
// `tapOpensLinkOrMovesCursor` (`TAP HOOK`) in the order `TerminalTapDecision` gives. The host
// does the focus of 1, 2 and 5 (its Paste menu uses the same "next to the cursor"), the scroll
// surface's tap does 4.

/// What the terminal says about a tapped cell, read in one hold of its lock.
struct GhosttyTapProbe: Equatable {
    var link: GhosttyTappedLink?
    var mouseTracking = false
    /// Near the cursor: fewer than 4 columns and fewer than 2 rows away.
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
        if let link = probe.link { return .open(link.url) }
        if probe.mouseTracking { return .mouseClick }
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
            // A link wins over a program's click; a program that takes clicks keeps every other one.
            probe.link = Self.hyperlink(t, col: col, row: row) ?? Self.plainLink(t, col: col, row: row)
            guard probe.link == nil, !probe.mouseTracking else { return probe }

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

    /// Opens a link. `asked`: the user just confirmed it (`LinkOpenPolicy`), so whatever opens
    /// it doesn't ask again. `UIApplication.open` by default; a pane's link router
    /// (`PanePorts`) and tests put their own here.
    var open: (URL, _ asked: Bool) -> Void = { url, _ in UIApplication.shared.open(url) }
    /// Asks before a link opens that `LinkOpenPolicy` doesn't open at once. Nil: the view shows
    /// an alert (`TerminalPrompt`). Tests put their own here.
    var ask: ((URL, LinkOpenPolicy.LinkQuestion, @escaping @MainActor (Bool) -> Void) -> Void)?
    /// Says why a tapped link didn't open. `Notice` by default; tests put their own here.
    var notify: (String) -> Void = { Notice.shared.show($0, style: .neutral) }
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

extension GhosttyTerminalView {
    /// Asked by the host's tap on a pane without the keyboard (`TAP HOOK` in TerminalHost), in
    /// place of the focus: true if a link was under the finger, so the tap is used up and the
    /// keyboard stays down. Never moves the shell's cursor or clicks in the program.
    func tapOpensLink(at point: CGPoint) -> Bool {
        guard !taps.repeats(at: point) else { return false }
        let cell = viewportCell(at: point)
        guard let link = core.link(atViewportCol: cell.col, row: cell.row) else { return false }
        open(tapped: link, cell: cell)
        taps.used(at: point)
        return true
    }

    /// Asked by the host's tap on a pane with the keyboard (`TAP HOOK` in TerminalHost). True if
    /// the tap opened a link or moved the shell's cursor, and so is used up.
    func tapOpensLinkOrMovesCursor(at point: CGPoint, focused: Bool, shift: Bool) -> Bool {
        // The cheap conditions first: the rest costs a terminal lock.
        guard focused, !shift, !taps.repeats(at: point) else { return false }
        let cell = viewportCell(at: point)
        let probe = core.tapProbe(viewportCol: cell.col, row: cell.row)
        let action = GhosttyTapRouting.action(focusedAtTouch: focused, shift: shift, hasSelection: hasActiveSelection, probe: probe)
        var used = false
        switch action {
        case .open:
            if let link = probe.link { open(tapped: link, cell: cell) }
            used = true
        case .prompt(let click):
            used = send(promptClick: click)
        case .focusOnly, .dismissSelection, .mouseClick, .nothing:
            break
        }
        if used { taps.used(at: point) }
        return used
    }

    /// Opens a tapped link. A program wrote it: web and mail addresses open, anything else, and a
    /// label that names another site, is asked about first (`LinkOpenPolicy`). An address found
    /// in the text is its own label. One that is no address at all says so: the tap was the
    /// user's, and it must not look as if it did nothing.
    private func open(tapped link: GhosttyTappedLink, cell: (col: Int, row: Int)) {
        let label = link.explicit ? core.hyperlinkLabel(atViewportCol: cell.col, row: cell.row) : nil
        switch LinkOpenPolicy.decide(target: link.url, label: label) {
        case .open(let url):
            taps.open(url, false)
        case .ask(let url, let question):
            let open = taps.open
            let answer: @MainActor (Bool) -> Void = { if $0 { open(url, true) } }
            if let ask = taps.ask {
                ask(url, question, answer)
            } else {
                TerminalPrompt.ask(over: self, link: url, question: question, answer: answer)
            }
        case .refuse:
            taps.notify("Couldn't open this link: it isn't a web address.")
        }
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
            scroller.sendKeys(bytes, fromTouch: true)
            return true
        case .press(let column, let row):
            // A mouse report: it leaves the view where it is.
            engineDelegate?.engineSendReport(GhosttyPromptClick.pressBytes(column: column, row: row))
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

    static func run(on view: GhosttyTerminalView) {
        guard !ran, let spec = UserDefaults.standard.string(forKey: "tapTest") else { return }
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
