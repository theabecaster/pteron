import UIKit

/// The selection UI of one pane: the loupe under way, the two handles, haptics, double and
/// triple taps, and when copy-on-select and the edit menu happen. Design: docs/selection.md.
///
/// TerminalHost keeps its recognizers and their arbitration and reports to this object: touch
/// down, the long press's phases, taps, Select All, a cleared selection. `SelectionSession`
/// decides what follows; this object does it, through the engine seam (`TerminalEngineView`)
/// and a few closures the host fills in (clipboard, shimmer, edit menu).
///
/// Cost: a drag event makes one seam call to extend and one to read the selection's ends (three
/// short, bounded waits for the terminal lock on the Ghostty engine) and allocates nothing. The
/// display link runs only while a selection is up, and reads the ends again only when the
/// scroll position changed.
@MainActor
final class TerminalSelectionController: NSObject {
    /// What the host's tap was, as far as selection is concerned.
    enum Tap: Equatable {
        /// On a handle: not a tap on the terminal at all.
        case handle
        /// The second or third tap of a double or triple tap: a word or line was selected (or
        /// nothing was there). The host does nothing more with it.
        case selected
        /// A plain tap: the host's own handling runs. `showsPaste`: then show the menu here.
        case single(showsPaste: Bool)
    }

    let term: any TerminalEngineView
    private let feedback: any SelectionFeedback
    private let loupe: any SelectionLoupe
    let handles = SelectionHandlesView()
    private(set) var session = SelectionSession()
    private var taps = SelectionTapCounter()

    // Filled in by the host.
    /// Puts text on the clipboard.
    var copyText: (String) -> Void = { UIPasteboard.general.string = $0 }
    /// Plays the copy-on-select shimmer over rects in the engine view's coordinates.
    var playShimmer: ([CGRect]) -> Void = { _ in }
    /// Shows the edit menu at a rect in the engine view's coordinates.
    var presentMenu: (CGRect) -> Void = { _ in }
    var dismissMenu: () -> Void = {}
    /// A finger took or let go of the selection (a handle drag): the host's other gestures
    /// stand down meanwhile.
    var trackingChanged: (Bool) -> Void = { _ in }
    /// The host's edit menu is on screen (set from its delegate callbacks).
    var menuVisible = false
    var clock: () -> TimeInterval = { CACurrentMediaTime() }

    /// The finger, in the engine view's coordinates.
    private var finger = CGPoint.zero
    /// From the cell a grabbed handle marks to the finger: the knob sits beside the text, and
    /// the selection must not jump when it is taken.
    private(set) var grabOffset = CGSize.zero
    /// The cell the long press landed on. Until the finger leaves it, the press's word stands.
    private var pressCell: TerminalGridCell?
    /// The word the long press selected, first and last cell, until the drag leaves it. The drag
    /// then extends from the word's far end, so the word stays whole (`anchorWord`).
    private var pressWord: (first: TerminalGridCell, last: TerminalGridCell)?
    private var tracking = false
    private var link: CADisplayLink?
    private var stamp = 0
    private var lastRefresh: TimeInterval = 0
    private var lastAutoscroll: TimeInterval = 0
    /// How often the selection is looked at again when nothing says it moved: an engine can
    /// drop it by itself (a reset, the program's own click handling).
    private static let pollInterval: TimeInterval = 0.1

    init(term: any TerminalEngineView, feedback: any SelectionFeedback = SystemSelectionFeedback(),
         loupe: any SelectionLoupe = SystemSelectionLoupe()) {
        self.term = term
        self.feedback = feedback
        self.loupe = loupe
        super.init()
        handles.press.addTarget(self, action: #selector(handlePressed(_:)))
        handles.takesTouch = { [weak self] p in
            guard let self else { return true }
            return !self.taps.continues(at: self.handles.convert(p, to: nil), now: self.clock())
        }
        handles.onWindowChange = { [weak self] in
            self?.updateLink()
            #if DEBUG
            if let self { SelectionDemo.runIfRequested(self) }  // `-selectionDemo` (testing)
            #endif
        }
    }

    /// Puts the handle layer in the host, over `sibling` (the terminal's container).
    func install(in host: UIView, above sibling: UIView) {
        handles.frame = host.bounds
        host.insertSubview(handles, aboveSubview: sibling)
    }

    /// Handle colour (the theme's cursor colour) and the rim that sets it off the background.
    func apply(tint: UIColor, rim: UIColor) {
        handles.tintColor = tint
        handles.rimColor = rim
    }

    // MARK: From the host

    /// A finger touched the pane.
    func touchDown() {
        guard session.phase == .idle || session.phase == .selected else { return }
        perform(session.touchDown())
    }

    /// The long press was recognized at `p` (engine view coordinates).
    func pressBegan(at p: CGPoint) {
        finger = p
        grabOffset = .zero
        term.beginSelection(at: p, word: true)
        pressCell = term.gridCell(at: p)
        pressWord = nil
        let selected = term.hasActiveSelection
        if selected, let ends = term.selectionEnds, let a = ends.start, let b = ends.end,
           let first = term.gridCell(at: CGPoint(x: a.midX, y: a.midY)), let last = term.gridCell(at: CGPoint(x: b.midX, y: b.midY)) {
            pressWord = (first, last)
        }
        perform(session.pressBegan(selected: selected, cell: pressCell))
    }

    func pressMoved(to p: CGPoint) {
        guard session.phase == .pressing else { return }
        finger = p
        dragged(autoscroll: false)
    }

    func pressEnded(at p: CGPoint) {
        guard session.phase == .pressing else { return }
        finger = p
        term.endSelectionDrag()
        let selected = term.hasActiveSelection
        if !selected { term.clearSelectedRange() }
        perform(session.pressEnded(selected: selected))
    }

    func pressCancelled() {
        guard session.phase == .pressing else { return }
        term.endSelectionDrag()
        perform(session.pressCancelled(selected: term.hasActiveSelection))
    }

    /// Counts a tap at `p` (engine view coordinates): whether it is on a handle, and else which
    /// tap of a run it is (1, 2 or 3). The host decides what the tap does with these
    /// (`TerminalTapDecision`); call it once per tap.
    func countTap(at p: CGPoint) -> (onHandle: Bool, count: Int) {
        let now = clock(), inWindow = term.convert(p, to: nil)
        // The next tap of a double or triple tap lands on the handles the last one put up: it
        // is still a tap on the text.
        if !taps.continues(at: inWindow, now: now), handles.showsHandles,
           handles.layout.handle(at: handles.convert(p, from: term)) != nil { return (true, 1) }
        guard term.usesHostSelectionUI else { return (false, 1) }
        return (false, taps.tap(at: inWindow, now: now))
    }

    /// A double tap at `p` selects the word there, a triple tap (`line`) the line.
    func selectTap(at p: CGPoint, line: Bool) {
        finger = p
        if line {
            perform(session.tapSelected(term.selectLine(at: p)))
        } else {
            term.beginSelection(at: p, word: true)
            term.endSelectionDrag()
            perform(session.tapSelected(term.hasActiveSelection))
        }
    }

    /// SwiftTerm's zone for the cursor's Paste menu: within 3 columns and 1 row of the cursor.
    func tapIsByCursor(at p: CGPoint) -> Bool {
        SelectionRules.tapShowsPaste(tap: term.gridCell(at: p), cursor: term.cursorGridCell, focused: true,
                                     clearedSelection: false, tapsGoToProgram: false, menuVisible: false)
    }

    /// A tap at `p` (engine view coordinates) as the selection UI alone sees it: counted, and
    /// selecting on the second and third tap. `focused`: the terminal had the keyboard focus
    /// when the tap came. The host's own taps go through `TerminalTapDecision` instead.
    func tap(at p: CGPoint, focused: Bool) -> Tap {
        let (onHandle, count) = countTap(at: p)
        if onHandle { return .handle }
        guard term.usesHostSelectionUI else { return .single(showsPaste: false) }
        if count >= 2 {
            selectTap(at: p, line: count >= 3)
            return .selected
        }
        // The cheap conditions first: the cursor and the mouse mode cost a terminal lock each.
        guard focused, !menuVisible, !term.hasActiveSelection else { return .single(showsPaste: false) }
        return .single(showsPaste: !term.sendsTapsToProgram && tapIsByCursor(at: p))
    }

    /// Select All, from the keyboard (`showsMenu` false) or the edit menu.
    func selectAll(showsMenu: Bool) {
        term.selectAllText()
        perform(session.selectedAll(term.hasActiveSelection, showsMenu: showsMenu))
    }

    /// The selection was cleared (by the host, after `clearSelectedRange`).
    func selectionCleared() {
        taps.reset()
        perform(session.cleared())
    }

    /// Shows the edit menu for the standing selection, if there still is one.
    func showMenu() {
        guard session.phase == .selected, term.hasActiveSelection else { return }
        presentMenu(menuTarget(fallback: finger))
    }

    /// Where the edit menu goes for the selection as it is now: around all of its visible
    /// lines; near the top of the pane for one with no rects of its own (Select All, or all of
    /// it scrolled away); at `fallback` when nothing is selected.
    func menuTarget(fallback: CGPoint) -> CGRect {
        let rects = term.selectionRects
        if let first = rects.first { return rects.dropFirst().reduce(first) { $0.union($1) } }
        if session.phase == .selected {
            let visible = visible
            return CGRect(x: visible.midX - 4, y: visible.minY + min(60, visible.height / 2), width: 8, height: 8)
        }
        return CGRect(origin: fallback, size: .zero).insetBy(dx: -4, dy: -4)
    }

    // MARK: Handles

    @objc private func handlePressed(_ g: UILongPressGestureRecognizer) {
        let p = g.location(in: term)
        switch g.state {
        case .began:
            guard handleBegan(at: p) else {
                // Not ours after all: end the gesture without a selection change.
                g.isEnabled = false
                g.isEnabled = true
                return
            }
        case .changed: handleMoved(to: p)
        case .ended: handleEnded(cancelled: false)
        default: handleEnded(cancelled: true)
        }
    }

    /// A finger came down at `p` (engine view coordinates). True if it took a handle.
    @discardableResult
    func handleBegan(at p: CGPoint) -> Bool {
        guard session.phase == .selected, let which = handles.layout.handle(at: handles.convert(p, from: term)),
              let handle = which == .start ? handles.layout.start : handles.layout.end,
              term.beginSelectionAdjust(movingStart: which == .start) else { return false }
        let cell = term.convert(handle.cell, from: handles)
        grabOffset = CGSize(width: p.x - cell.x, height: p.y - cell.y)
        finger = p
        pressCell = nil
        perform(session.handleGrabbed(which, cell: term.gridCell(at: target)))
        return true
    }

    func handleMoved(to p: CGPoint) {
        guard case .adjusting = session.phase else { return }
        finger = p
        dragged(autoscroll: false)
    }

    func handleEnded(cancelled: Bool) {
        guard case .adjusting = session.phase else { return }
        term.endSelectionDrag()
        let selected = term.hasActiveSelection
        perform(cancelled ? session.handleCancelled(selected: selected) : session.handleReleased(selected: selected))
    }

    // MARK: Dragging

    /// The point the selection is dragged to: the finger, less the offset a handle was grabbed at.
    private var target: CGPoint { CGPoint(x: finger.x - grabOffset.width, y: finger.y - grabOffset.height) }

    /// The part of the engine view the host shows, in the engine view's coordinates.
    private var visible: CGRect {
        guard let host = handles.superview else { return term.bounds }
        return term.convert(host.bounds, from: host).intersection(term.bounds)
    }

    /// The finger moved, or it rests at an edge and it is time for another line (`autoscroll`).
    private func dragged(autoscroll: Bool) {
        let now = clock()
        let target = target
        let cell = term.gridCell(at: target)
        if session.phase == .pressing, !anchorWord(for: cell) {
            // Still on the word the press selected: it stands as it is.
            moved(cell: cell, now: now)
            return
        }
        if autoscroll {
            // Ask the engine for a line as a drag past the edge does, then put the end back
            // under the finger: the zone is wider than the engine's own half cell.
            let edge = SelectionRules.edge(of: target, in: visible)
            let bounds = term.bounds
            term.extendSelection(to: CGPoint(x: target.x, y: edge < 0 ? bounds.minY - 1 : bounds.maxY + 1), autoscroll: true)
            lastAutoscroll = now
        }
        term.extendSelection(to: target, autoscroll: false)
        moved(cell: cell, now: now)
    }

    /// A long press selects a word and a drag then extends by cells. Once the finger leaves the
    /// word, the drag is anchored on the word's far end, so the whole word stays selected, as
    /// in a text view. Returns false while the finger is still on the word.
    ///
    /// An engine without `beginSelectionAdjust` keeps its own anchor (the pressed cell).
    private func anchorWord(for cell: TerminalGridCell?) -> Bool {
        guard let word = pressWord, let cell else { return true }
        func before(_ a: TerminalGridCell, _ b: TerminalGridCell) -> Bool { a.row < b.row || (a.row == b.row && a.col < b.col) }
        let backward = before(cell, word.first)
        guard backward || before(word.last, cell) else { return false }
        pressWord = nil
        _ = term.beginSelectionAdjust(movingStart: backward)
        return true
    }

    /// Tells the session where the moving end is now.
    private func moved(cell: TerminalGridCell?, now: TimeInterval) {
        switch session.phase {
        case .pressing: perform(session.pressMoved(selected: term.hasActiveSelection, cell: cell, now: now))
        case .adjusting: perform(session.handleMoved(cell: cell, now: now))
        case .idle, .selected: break
        }
    }

    /// True once a drag may scroll at an edge: a handle drag always, a long press only after
    /// the finger left the cell it pressed (holding a word near an edge must not scroll it away).
    private var mayAutoscroll: Bool {
        switch session.phase {
        case .adjusting: true
        case .pressing: pressWord == nil && term.gridCell(at: target) != pressCell
        case .idle, .selected: false
        }
    }

    // MARK: Effects

    private func perform(_ effects: SelectionSession.Effects) {
        if effects.contains(.hapticStart) { feedback.play(.start) }
        if effects.contains(.hapticGrab) { feedback.play(.grab) }
        if effects.contains(.hapticTick) { feedback.play(.tick) }
        if effects.contains(.hideMenu) { dismissMenu() }
        if effects.contains(.hideLoupe) { loupe.end() }
        if effects.contains(.copy) { copySelection() }
        // After anything played: a generator that fired has gone back to sleep.
        if effects.contains(.prepare) { feedback.prepare() }

        if !effects.isDisjoint(with: [.showLoupe, .moveLoupe, .showHandles]) {
            let ends = term.selectionEnds
            if effects.contains(.showLoupe) { loupe.begin(at: loupePoint(ends).point, in: term) }
            if !effects.isDisjoint(with: [.showLoupe, .moveLoupe]) {
                let place = loupePoint(ends)
                loupe.move(to: place.point, caret: place.caret)
            }
            if effects.contains(.showHandles) { showHandles(ends) }
        }
        if effects.contains(.hideHandles) {
            shownEnds = nil
            handles.hide()
        }
        if effects.contains(.showMenu) { presentMenu(menuTarget(fallback: finger)) }

        if session.isTracking != tracking {
            tracking = session.isTracking
            trackingChanged(tracking)
        }
        updateLink()
    }

    /// Copy-on-select: the clipboard, the confirming haptic and the shimmer in one step.
    private func copySelection() {
        guard let text = term.selectedText, !text.isEmpty else { return }
        copyText(text)
        feedback.play(.copy)
        playShimmer(term.selectionRects)
    }

    /// Where the loupe looks: at the finger's column, on the row of the selection end that is
    /// moving (the one nearer the finger), with that end's outer edge as the caret. Without a
    /// selection in view, at the finger.
    private func loupePoint(_ ends: TerminalSelectionEnds?) -> (point: CGPoint, caret: CGRect?) {
        let target = target
        func distance(_ r: CGRect?) -> CGFloat { r.map { hypot($0.midX - target.x, $0.midY - target.y) } ?? .infinity }
        let toStart = distance(ends?.start), toEnd = distance(ends?.end)
        guard let ends, min(toStart, toEnd) < .infinity else { return (target, nil) }
        if toStart < toEnd, let r = ends.start {
            return (CGPoint(x: target.x, y: r.midY), CGRect(x: r.minX - 1, y: r.minY, width: 2, height: r.height))
        }
        guard let r = ends.end else { return (target, nil) }
        return (CGPoint(x: target.x, y: r.midY), CGRect(x: r.maxX - 1, y: r.minY, width: 2, height: r.height))
    }

    /// The ends last read from the engine, in its coordinates. The host can move the engine
    /// view without the selection changing (mirror mode's pan and zoom, a pinch), so the handles
    /// are laid out from these on every frame, and read again only when the grid moved.
    private var shownEnds: TerminalSelectionEnds?

    private func showHandles(_ ends: TerminalSelectionEnds?) {
        shownEnds = ends
        guard term.usesHostSelectionUI, let ends else { handles.hide(); return }
        handles.show(SelectionHandleLayout(start: ends.start.map { handles.convert($0, from: term) },
                                           end: ends.end.map { handles.convert($0, from: term) }, in: handles.bounds))
    }

    // MARK: Display link

    /// Runs while a selection is up and the pane is on screen; never otherwise.
    private func updateLink() {
        let wanted = session.phase != .idle && handles.window != nil
        if wanted, link == nil {
            let link = CADisplayLink(target: LinkTarget(self), selector: #selector(LinkTarget.tick(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
            stamp = term.selectionGeometryStamp
            lastRefresh = clock()
        } else if !wanted, let link {
            link.invalidate()
            self.link = nil
        }
    }

    /// One display frame with a selection up.
    func tick() {
        let now = clock()
        if session.isTracking, mayAutoscroll, now - lastAutoscroll >= SelectionRules.autoscrollInterval,
           SelectionRules.edge(of: target, in: visible) != 0 {
            dragged(autoscroll: true)
        }
        let current = term.selectionGeometryStamp
        guard current != stamp || now - lastRefresh >= Self.pollInterval else {
            if session.phase == .selected, handles.showsHandles { showHandles(shownEnds) }
            return
        }
        stamp = current
        lastRefresh = now
        refresh(now: now)
    }

    /// The view scrolled, output moved the text, or it is time to look again.
    private func refresh(now: TimeInterval) {
        guard term.hasActiveSelection || session.phase == .pressing else {
            // The engine dropped the selection by itself.
            perform(session.cleared())
            return
        }
        switch session.phase {
        case .pressing, .adjusting:
            // An edge scroll the engine applied put another row under the finger.
            moved(cell: term.gridCell(at: target), now: now)
        case .selected:
            showHandles(term.selectionEnds)
        case .idle:
            break
        }
    }

    /// Keeps the display link from holding the controller alive.
    @MainActor
    private final class LinkTarget: NSObject {
        weak var controller: TerminalSelectionController?
        init(_ controller: TerminalSelectionController) { self.controller = controller }
        @objc func tick(_ link: CADisplayLink) {
            if let controller { controller.tick() } else { link.invalidate() }
        }
    }
}
