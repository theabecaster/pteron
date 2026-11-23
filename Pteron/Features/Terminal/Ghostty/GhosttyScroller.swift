import UIKit

/// The scroll view laid over the terminal. It has no content of its own: it supplies UIKit's
/// scroll physics (pan, deceleration, rubber band, trackpad and wheel scrolling) and the scroll
/// indicator, while the Metal view under it stays put and draws the rows for the offset.
final class GhosttyScrollSurface: UIScrollView {
    weak var scroller: GhosttyScroller?
    private var laidOut = CGSize.zero

    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        // UIKit also asks the touched view about its ancestors' recognizers; decide only our own.
        if g.view === self, let scroller, !scroller.shouldBegin(g) { return false }
        return super.gestureRecognizerShouldBegin(g)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Runs on every scroll step too; only a new size matters.
        guard bounds.size != laidOut else { return }
        laidOut = bounds.size
        scroller?.layoutChanged()
    }
}

/// Where the view is in the scrollback, for whoever shows a way back down (`scrollPlaceHook`).
struct GhosttyScrollPlace: Equatable {
    /// Rows between the view and the newest line; 0 at the bottom.
    var rowsAbove = 0.0
    /// Rows in all, scrollback included.
    var total = 0
    /// How far the terminal has moved by itself (`GhosttyScrollState.Snapshot.rebase`).
    var rebase = 0
    /// The newest scroll request the frame had applied.
    var sequence = 0
    /// The program gets one-finger drags (mouse tracking or alternate screen).
    var programScroll = false
}

/// Scrolling and mouse reporting for one `GhosttyTerminalView`.
///
/// Structure: the terminal view stays a plain view. It holds the Metal view and, above it, a
/// transparent `GhosttyScrollSurface` of the same size. TerminalHost keeps laying out, zooming
/// and transforming the terminal view as one piece, and every recognizer here sits on the
/// surface, where the terminal view's `panGate` and `tapGate` decide whether it may begin.
///
/// Scrolling never takes the terminal lock on the main thread. A scroll step leaves the new
/// offset in `GhosttyScrollState`; the render thread moves the viewport and draws in one step.
/// What comes back (`apply`) is coalesced and only arrives when the scrollable area changed or
/// the terminal moved by itself.
@MainActor
final class GhosttyScroller: NSObject, UIScrollViewDelegate {
    let surface = GhosttyScrollSurface()
    let mouse = GhosttyMouseReporter()
    /// One finger, while the program gets drags (mouse tracking or alternate screen): wheel
    /// reports or arrow keys. The scroll view's own pan then needs two fingers.
    let programPan = UIPanGestureRecognizer()
    /// Trackpad (continuous) and mouse wheel (discrete) scrolls for the program.
    private(set) var pointerScrolls: [UIPanGestureRecognizer] = []
    /// A click for a program that tracks the mouse.
    let tap = UITapGestureRecognizer()
    let hover = UIHoverGestureRecognizer()

    private weak var view: GhosttyTerminalView?
    private let core: GhosttyCore

    /// The last state the render thread sent over.
    private(set) var state = GhosttyScrollState.Snapshot()
    private var appliedRebase = 0
    /// The newest scroll request this view made (`GhosttyScrollState.Snapshot.appliedSequence`
    /// says which a frame had applied).
    private(set) var lastRequest = 0
    private var applying = false
    /// The surface size the content size and offset were last set for.
    private var contentLaidOutFor = CGSize.zero
    private var animating = false
    /// When a finger or the scroll's momentum last moved the scrollback (`TerminalScrollTouch`).
    private(set) var lastUserMove: CFTimeInterval?
    /// The scrollback is moving under a finger or by its momentum.
    var userMoving: Bool { surface.isDragging || surface.isDecelerating }
    /// Points of the view's bottom that the keyboard covers (`setCover`).
    private(set) var cover: CGFloat = 0
    /// Points the find bar covers above the bottom edge, apart from the keyboard (`setFindInset`).
    private(set) var findInset: CGFloat = 0
    /// Everything that hides the view's bottom: the keyboard and the find bar.
    var coveredBottom: CGFloat { cover + findInset }
    /// This drag has already said that it went into the scrollback.
    private var toldReading = false
    private var alternateScreen = false

    private var dragAccumulator = GhosttyWheelAccumulator()
    private var pointerAccumulator = GhosttyWheelAccumulator()
    private var budget = GhosttyWheelBudget()

    /// Scroll steps handled and the time they took, for tuning (`measures` on).
    var measures = false
    private(set) var scrollSteps = 0
    private(set) var scrollStepSeconds: CFTimeInterval = 0
    /// Updates received from the render thread.
    private(set) var updates = 0

    init(view: GhosttyTerminalView) {
        self.view = view
        core = view.core
        super.init()

        surface.scroller = self
        surface.frame = view.bounds
        surface.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        surface.backgroundColor = .clear
        surface.isOpaque = false
        surface.delegate = self
        surface.scrollsToTop = false
        surface.contentInsetAdjustmentBehavior = .never
        surface.showsHorizontalScrollIndicator = false
        surface.showsVerticalScrollIndicator = true
        surface.alwaysBounceHorizontal = false
        surface.delaysContentTouches = false
        surface.isDirectionalLockEnabled = true
        surface.contentSize = view.bounds.size
        contentLaidOutFor = view.bounds.size
        view.addSubview(surface)

        programPan.addTarget(self, action: #selector(programPanned(_:)))
        programPan.maximumNumberOfTouches = 1
        // Fingers only, like the scroll pan once the host has set it up: a mouse or trackpad drag
        // selects (the host's pointer pan) and never reports a wheel.
        programPan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        programPan.isEnabled = false
        surface.addGestureRecognizer(programPan)

        for type: UIScrollTypeMask in [.continuous, .discrete] {
            let scroll = UIPanGestureRecognizer(target: self, action: #selector(pointerScrolled(_:)))
            scroll.allowedScrollTypesMask = type
            scroll.allowedTouchTypes = []
            surface.addGestureRecognizer(scroll)
            // The program gets pointer scrolls first. Ones it doesn't take scroll locally.
            surface.panGestureRecognizer.require(toFail: scroll)
            pointerScrolls.append(scroll)
        }

        tap.addTarget(self, action: #selector(tapped(_:)))
        surface.addGestureRecognizer(tap)

        hover.addTarget(self, action: #selector(hovered(_:)))
        surface.addGestureRecognizer(hover)

        updateIndicator()
        core.scroll.setPublishHandler { [weak self] snapshot in self?.apply(snapshot) }
        core.onDirty?()
    }

    // MARK: Scroll view ↔ terminal

    private var scale: CGFloat { max(1, view?.displayScale ?? 1) }

    private var interacting: Bool {
        surface.isTracking || surface.isDragging || surface.isDecelerating || animating
    }

    /// Takes the render thread's news: a new scrollable height, and how far the terminal moved
    /// by itself since the last time (the rebase), which shifts the offset without a jump on
    /// screen and without stopping a drag or a deceleration.
    func apply(_ snapshot: GhosttyScrollState.Snapshot) {
        updates += 1
        refresh(snapshot)
        view?.selectionScrollApplied(snapshot)
    }

    private func refresh(_ snapshot: GhosttyScrollState.Snapshot) {
        state = snapshot
        applying = true
        defer { applying = false }
        let scale = scale
        let size = CGSize(width: surface.bounds.width,
                          height: CGFloat(snapshot.maxRow * snapshot.cellHeight) / scale + surface.bounds.height)
        if surface.contentSize != size { surface.contentSize = size }
        let moved = snapshot.rebase - appliedRebase
        appliedRebase = snapshot.rebase
        var y = surface.contentOffset.y + CGFloat(moved) / scale
        // At rest, and with nothing of ours still on its way, the terminal is simply right.
        var settle = false
        if !interacting, snapshot.appliedSequence >= lastRequest {
            // The shift at rest is inside the cover; anything else is a rubber band that nothing
            // brought back (an offset set past an edge without a finger), and is put right. Only
            // a shift decided against the cover set here: one from before a new cover reached
            // the render side is put inside it there, which moves the terminal by itself, and a
            // position sent for it too would move the view that far again, into the scrollback.
            let covered = Int((coveredBottom * scale).rounded())
            let shift = min(max(snapshot.bounce, 0), covered)
            settle = shift != snapshot.bounce && snapshot.covered == covered
            y = CGFloat(snapshot.position + shift) / scale
        }
        if abs(y - surface.contentOffset.y) > 0.01 { surface.contentOffset = CGPoint(x: 0, y: y) }
        if settle { sendOffset() }

        // While the program takes one-finger drags, scrollback needs two.
        let pan = surface.panGestureRecognizer
        let fingers = snapshot.programScroll ? 2 : 1
        if pan.minimumNumberOfTouches != fingers { pan.minimumNumberOfTouches = fingers }
        if programPan.isEnabled != snapshot.programScroll { programPan.isEnabled = snapshot.programScroll }
        updateIndicator()
        noteScreen(alternate: snapshot.alternateScreen)
        tellPlace()
    }

    /// A snapshot replaced the terminal: the screen it is on is known before a frame is drawn.
    func screenRestored(alternate: Bool) { noteScreen(alternate: alternate) }

    private func noteScreen(alternate: Bool) {
        guard alternate != alternateScreen else { return }
        alternateScreen = alternate
        view?.alternateScreenHook?(alternate)
    }

    /// The keyboard covers the bottom `points` of the view, whose grid keeps its rows. The scroll
    /// view gets that much more room at the bottom, so the last rows can sit above the keyboard
    /// and the covered ones can be scrolled into view (`GhosttyScrollState`, "The cover").
    func setCover(_ points: CGFloat) {
        let c = max(0, points)
        guard abs(c - cover) > 0.01 else { return }
        cover = c
        applyInsets()
        core.scroll.setCover(px: Int((c * scale).rounded()))
        core.onDirty?()
    }

    /// The find bar covers the bottom `points` of the view (the bottom overlay on the main
    /// screen). Like the keyboard's cover it adds room to scroll past the last row and keeps the
    /// last rows above it, but it never counts as the keyboard: a drag under it is not reading.
    func setFindInset(_ points: CGFloat) {
        let c = max(0, points)
        guard abs(c - findInset) > 0.01 else { return }
        findInset = c
        applyInsets()
        core.scroll.setFindInset(px: Int((c * scale).rounded()))
        core.onDirty?()
    }

    private func applyInsets() {
        applying = true
        surface.contentInset.bottom = coveredBottom
        surface.verticalScrollIndicatorInsets.bottom = coveredBottom
        applying = false
    }

    func layoutChanged() {
        contentLaidOutFor = surface.bounds.size
        refresh(state)
    }

    /// A scroll indicator that shows on the theme's background.
    private func updateIndicator() {
        let style: UIScrollView.IndicatorStyle = (view?.theme?.isDark ?? true) ? .white : .black
        if surface.indicatorStyle != style { surface.indicatorStyle = style }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // A new size (keyboard, fold, a pane moved to another place) makes UIKit pull the offset
        // back inside the old content before `layoutChanged` runs. That isn't the user scrolling:
        // sent on, it would leave a taller view scrolled into history. `layoutChanged` puts the
        // offset where the terminal is.
        guard !applying, surface.bounds.size == contentLaidOutFor else { return }
        if userMoving { lastUserMove = CACurrentMediaTime() }
        noteReading()
        if measures {
            let start = CACurrentMediaTime()
            sendOffset()
            scrollStepSeconds += CACurrentMediaTime() - start
            scrollSteps += 1
        } else {
            sendOffset()
        }
        tellPlace()
    }

    /// The offset at which the newest rows show: the last row position, plus the shift that keeps
    /// them above the keyboard while it covers the view (the pin). In the scrollback the pin of
    /// the screen below isn't drawn; a screen with scrollback above it is full, so the whole cover.
    var pinnedBottom: CGFloat {
        let pin = state.active ? CGFloat(state.pin) / scale : coveredBottom
        return CGFloat(state.maxRow * state.cellHeight) / scale + min(max(pin, 0), coveredBottom)
    }

    /// Tells the view's `scrollPlaceHook` how far the view is from the newest line, as it shows
    /// with the keyboard up: rows the user scrolled down over the covered ones count as well.
    private func tellPlace() {
        guard let view, let hook = view.scrollPlaceHook else { return }
        let cell = view.cellSize.height
        guard cell > 0 else { return }
        hook(GhosttyScrollPlace(rowsAbove: Double(max(0, (pinnedBottom - surface.contentOffset.y) / cell)), total: state.total,
                                rebase: state.rebase, sequence: state.appliedSequence, programScroll: state.programScroll))
    }

    private func sendOffset() {
        let px = Int((surface.contentOffset.y * scale).rounded())
        lastRequest = core.scrollViewport(.position(px: px, rebaseSeen: appliedRebase))
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        toldReading = false
        updateIndicator()
    }

    /// A drag let go, or a fling that will come to rest, within a row of the pin with the
    /// keyboard up ends at the pin: a nudge, or a scroll back down, sticks to the bottom again.
    /// Further up it ends where UIKit takes it, and output leaves it there (`GhosttyScrollState`,
    /// "The cover").
    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                   targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        guard coveredBottom > 0, let view else { return }
        let target = targetContentOffset.pointee.y
        let pinned = pinnedBottom
        if Self.sticks(target: target, pinned: pinned, cell: view.cellSize.height) {
            targetContentOffset.pointee.y = pinned
        }
    }

    /// A release that comes to rest at `target` sticks to the bottom (`pinned`): from a row
    /// above it on down.
    nonisolated static func sticks(target: CGFloat, pinned: CGFloat, cell: CGFloat) -> Bool {
        target < pinned && target >= pinned - max(cell, 1)
    }

    /// A finger took the view a row or more into the scrollback while the keyboard covers it:
    /// the user is reading, and the view says so once for the drag (`readingHook`).
    private func noteReading() {
        guard cover > 0, !toldReading, userMoving, let view else { return }
        let end = CGFloat(state.maxRow * state.cellHeight) / scale
        guard Self.reads(offset: surface.contentOffset.y, end: end, cell: view.cellSize.height) else { return }
        toldReading = true
        view.readingHook?()
    }

    /// An offset a row or more into the scrollback, past every covered row (`end` is the last row
    /// position): far enough to put the keyboard away. Anywhere among the covered rows is not.
    nonisolated static func reads(offset: CGFloat, end: CGFloat, cell: CGFloat) -> Bool {
        offset < end - cell
    }
    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { animating = false }

    /// Scrolls like a finger would, for the demo and tests. `y` is a scroll view offset in points.
    func setOffset(_ y: CGFloat, animated: Bool) {
        animating = animated && abs(y - surface.contentOffset.y) > 0.01
        surface.setContentOffset(CGPoint(x: 0, y: y), animated: animated)
    }

    /// A jump that isn't a drag: lines, pages, prompts, top or bottom. Ends a deceleration.
    func jump(_ request: GhosttyScrollState.Request) {
        if surface.isDecelerating || animating {
            applying = true
            surface.setContentOffset(surface.contentOffset, animated: false)
            applying = false
            animating = false
        }
        lastRequest = core.scrollViewport(request)
    }

    // MARK: Gates

    func shouldBegin(_ g: UIGestureRecognizer) -> Bool {
        guard let view else { return false }
        if let pan = g as? UIPanGestureRecognizer {
            if let gate = view.panGate, !gate(pan) { return false }
            // Shift on a hardware keyboard keeps a pointer scroll local.
            if pointerScrolls.contains(pan) { return state.programScroll && !pan.modifierFlags.contains(.shift) }
            return true
        }
        if g === tap {
            // Lifting a long press that selected is not a tap.
            let press = view.selectionPress
            if press.state == .began || press.state == .changed || press.state == .ended {
                return false
            }
            return view.tapGate?() ?? true
        }
        return true
    }

    // MARK: Wheel and arrows

    @objc private func programPanned(_ g: UIPanGestureRecognizer) {
        guard let view else { return }
        switch g.state {
        case .began:
            dragAccumulator.reset()
        case .changed:
            let travelled = g.translation(in: view).y
            g.setTranslation(.zero, in: view)
            forwardWheel(distance: travelled, at: g.location(in: view), flags: g.modifierFlags, accumulator: &dragAccumulator)
        default:
            dragAccumulator.reset()
        }
    }

    @objc private func pointerScrolled(_ g: UIPanGestureRecognizer) {
        guard let view else { return }
        switch g.state {
        case .began, .changed:
            if g.state == .began { pointerAccumulator.reset() }
            let travelled = g.translation(in: view).y
            g.setTranslation(.zero, in: view)
            forwardWheel(distance: travelled, at: g.location(in: view), flags: g.modifierFlags, accumulator: &pointerAccumulator,
                         precise: g.allowedScrollTypesMask != .discrete)
        default:
            pointerAccumulator.reset()
        }
    }

    /// Sends drag distance to the program: whole lines as wheel reports where it tracks the
    /// mouse, or as arrow keys on an alternate screen with alternate scroll. Positive is up.
    /// Returns what was sent.
    @discardableResult
    func forwardWheel(distance: CGFloat, at point: CGPoint, flags: UIKeyModifierFlags = [],
                      accumulator: inout GhosttyWheelAccumulator, precise: Bool = true) -> [UInt8] {
        guard let view else { return [] }
        let cellHeight = view.cellSize.height
        let modes = core.programScrollModes()
        let route = GhosttyScrollRouting.route(mouseTracking: modes.mouseTracking, alternateScreen: modes.alternateScreen,
                                               alternateScroll: modes.alternateScroll, shiftBypass: flags.contains(.shift))
        guard route != .none, cellHeight > 0 else {
            accumulator.reset()
            return []
        }
        let lines: Int
        if precise {
            lines = accumulator.takeWholeLines(distance: distance, cellHeight: cellHeight, route: route)
        } else {
            accumulator.reset()
            lines = distance == 0 ? 0 : (distance > 0 ? 1 : -1)
        }
        guard lines != 0 else { return [] }
        var bytes: [UInt8] = []
        switch route {
        case .mouse:
            guard view.bounds.contains(point), let position = mousePosition(point) else { return [] }
            var modifiers = Self.modifiers(flags)
            if view.controlModifier { modifiers.insert(.control) }
            let count = budget.grant(GhosttyWheelBudget.requested(lines: lines, precise: precise))
            bytes = mouse.mouse(.press, button: lines > 0 ? .wheelUp : .wheelDown, at: position, modifiers: modifiers,
                                buttonHeld: false, geometry: geometry, count: count, core: core)
            sendReport(bytes)
        case .cursorKeys:
            let count = budget.grant(GhosttyWheelBudget.requested(lines: lines))
            bytes = mouse.key(lines > 0 ? .arrowUp : .arrowDown, count: count, core: core)
            sendKeys(bytes, fromTouch: true)
        case .none:
            break
        }
        return bytes
    }

    // MARK: Clicks and motion

    @objc private func tapped(_ g: UITapGestureRecognizer) {
        guard g.state == .ended, let view else { return }
        // Under a host this never fires: the host decides every tap and sends the click itself
        // (`tapGate`, `TerminalTapDecision`). Alone, a view without the keyboard takes no click.
        guard view.isFirstResponder, !g.modifierFlags.contains(.shift) else { return }
        guard core.programScrollModes().mouseTracking else { return }
        if view.hasActiveSelection {
            // With a selection up, the tap dismisses it instead of clicking.
            view.clearSelectedRange()
            return
        }
        forwardTap(at: g.location(in: view))
    }

    /// A left click at `point` (this view's coordinates): press, then release if the program's
    /// tracking mode reports releases. Uses up a one-shot ctrl from the key bar.
    @discardableResult
    func forwardTap(at point: CGPoint) -> [UInt8] {
        let bytes = tapBytes(at: point)
        sendReport(bytes)
        return bytes
    }

    /// The bytes of a left click at `point`, not sent; empty where there is no cell to click
    /// (a row of the scrollback). Uses up a one-shot ctrl from the key bar.
    func tapBytes(at point: CGPoint) -> [UInt8] {
        guard let view, let position = mousePosition(point) else { return [] }
        var modifiers: GhosttyMouseReporter.Modifiers = []
        if view.controlModifier { modifiers.insert(.control) }
        var bytes = mouse.mouse(.press, button: .left, at: position, modifiers: modifiers, buttonHeld: true,
                                geometry: geometry, core: core)
        bytes += mouse.mouse(.release, button: .left, at: position, modifiers: modifiers, buttonHeld: false,
                             geometry: geometry, core: core)
        if view.controlModifier {
            view.controlModifier = false
            NotificationCenter.default.post(name: .terminalEngineControlModifierReset, object: view)
        }
        return bytes
    }

    @objc private func hovered(_ g: UIHoverGestureRecognizer) {
        guard let view, state.programScroll else { return }
        switch g.state {
        case .began:
            mouse.resetMotion()
            forwardMotion(at: g.location(in: view), flags: g.modifierFlags, buttonHeld: false)
        case .changed:
            forwardMotion(at: g.location(in: view), flags: g.modifierFlags, buttonHeld: false)
        default:
            break
        }
    }

    /// Pointer motion. The encoder reports it only where the program asked: with no button in
    /// any-event tracking (1003), with a button also in button-event tracking (1002), and once
    /// per cell.
    @discardableResult
    func forwardMotion(at point: CGPoint, flags: UIKeyModifierFlags = [], buttonHeld: Bool) -> [UInt8] {
        guard let view, view.bounds.contains(point), !flags.contains(.shift), let position = mousePosition(point) else { return [] }
        let bytes = mouse.mouse(.motion, button: buttonHeld ? .left : .none, at: position, modifiers: Self.modifiers(flags),
                                buttonHeld: buttonHeld, geometry: geometry, core: core)
        sendReport(bytes)
        return bytes
    }

    // MARK: Geometry

    /// The view in device pixels, as the mouse encoder wants it.
    var geometry: GhosttyMouseReporter.Geometry {
        guard let view else { return .init(width: 0, height: 0, cellWidth: 0, cellHeight: 0) }
        let m = view.atlas.metrics
        return .init(width: Int((view.bounds.width * scale).rounded()), height: Int((view.bounds.height * scale).rounded()),
                     cellWidth: m.cellWidth, cellHeight: m.cellHeight)
    }

    /// A point in the view as pixels on the active screen, or nil if it is on a scrollback row
    /// (the program can't be told about those).
    func mousePosition(_ point: CGPoint) -> CGPoint? {
        let s = core.scroll.snapshot
        let y = point.y * scale + CGFloat(s.fraction + s.bounce + (s.offset - s.maxRow) * s.cellHeight)
        guard y >= 0 else { return nil }
        return CGPoint(x: point.x * scale, y: y)
    }

    private static func modifiers(_ flags: UIKeyModifierFlags) -> GhosttyMouseReporter.Modifiers {
        var m: GhosttyMouseReporter.Modifiers = []
        if flags.contains(.shift) { m.insert(.shift) }
        if flags.contains(.control) { m.insert(.control) }
        if flags.contains(.alternate) { m.insert(.alt) }
        return m
    }

    /// A mouse report (click, wheel, motion). It leaves a scrolled-up view where it is: only
    /// keys and pastes bring it back to the bottom.
    private func sendReport(_ bytes: [UInt8]) {
        guard !bytes.isEmpty, let view else { return }
        view.engineDelegate?.engineSendReport(bytes)
    }

    /// Keys for the program. Like typing, they bring a scrolled-up view back to the bottom.
    /// `fromTouch`: a tap or a drag made them from a place on the screen, so they are sent as
    /// a report is.
    func sendKeys(_ bytes: [UInt8], fromTouch: Bool = false) {
        guard !bytes.isEmpty, let view else { return }
        if fromTouch { view.engineDelegate?.engineSendReport(bytes) } else { view.engineDelegate?.engineSend(bytes) }
        scrollToBottomForInput()
    }

    /// The rule for input: keys and pastes sent while the view is scrolled up jump back to the
    /// bottom.
    /// Output, mouse reports and focus reports never move the view.
    func scrollToBottomForInput() {
        let s = core.scroll.snapshot
        // The bottom is the last row position, plus the shift that keeps the last rows above
        // the keyboard while it covers the view.
        let bottom = CGFloat(s.position + s.bounce) / scale
        if !s.active || !s.following || surface.contentOffset.y < bottom - 0.5 { jump(.bottom) }
    }
}
