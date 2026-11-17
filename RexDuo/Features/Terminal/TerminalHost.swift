import UIKit
import RexKit
import GameController
/// The scroll view that zooms and pans the terminal in mirror mode.
final class ZoomScrollView: UIScrollView {
    var panGate: ((UIPanGestureRecognizer) -> Bool)?

    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        if g === panGestureRecognizer, let gate = panGate, !gate(panGestureRecognizer) { return false }
        return super.gestureRecognizerShouldBegin(g)
    }
}

/// A UIKit view that shows one Rex terminal block in a `GhosttyTerminalView`.
/// Fit mode: claims the block and resizes it to this view. Mirror mode: keeps the server's size, zoom/pan.
///
/// The local grid always follows the server: it changes only when the stream says the server's
/// size changed, at that point in the stream. Fit mode asks the server for the size that fits and
/// keeps the stream open; the program redraws itself.
@MainActor
final class TerminalHost: UIView, TerminalSink, TerminalEngineDelegate, UIScrollViewDelegate, UIGestureRecognizerDelegate,
    @preconcurrency UIEditMenuInteractionDelegate {
    static let fontRange: ClosedRange<CGFloat> = 7...20

    let stream: TerminalStream
    let term: GhosttyTerminalView
    private let zoomer = ZoomScrollView()
    private let statusLabel = UILabel()
    private let keyBar: KeyBar

    var sizing: SizingMode
    var fontSize: CGFloat
    var theme: TermTheme
    /// The tab's active pane. Only the active pane holds the keyboard: a pane that becomes
    /// active takes it (`reclaimKeyboard`), and one that stops being active gives it up and
    /// stops any key it was repeating.
    var isActive = false {
        didSet {
            guard isActive != oldValue else { return }
            if isActive {
                reclaimKeyboard()
            } else {
                stopKeyRepeats()
                // After the new active pane had its turn to take the keyboard (its own hop to
                // the main queue, which may have been queued after this one): taking it from
                // this pane directly keeps the keyboard on screen, where resigning first would
                // drop it and bring it back.
                DispatchQueue.main.async { [weak self] in
                    DispatchQueue.main.async { self?.resignIfInactive() }
                }
            }
        }
    }
    var onFocus: (() -> Void)?
    /// Horizontal swipe: +1 = next pane, -1 = previous pane.
    var onSwipe: ((Int) -> Void)?
    /// App-level commands (keyboard shortcuts, two-finger tap); the window screen performs them.
    var onCommand: ((RexCommand) -> Void)?
    /// The server's keymap; hardware keys bound in it run their action instead of reaching the terminal.
    var keymap: KeymapStore?
    /// Sending files to this pane: the attach key, Paste of an image, drops. Nil where the pane
    /// has no server (a replay).
    var files: PaneFiles? {
        didSet {
            files?.view = self
            files?.onSupportChanged = { [weak self] in self?.refreshFiles() }
            keyBar.attachMenu = { [weak self] in self?.files?.menu() ?? UIMenu() }
            refreshFiles()
        }
    }

    /// The size the server confirmed for this pane in fit mode.
    private var claimedSize: (Int, Int)?
    /// Own, resize, give back: every fit-mode call to the server goes through here, in order.
    private let claim: FitClaim
    private var started = false
    private var lastBounds: CGSize = .zero
    private var serverSize: (Int, Int) = (80, 24)
    /// The grid the engine has now; reported by `engineGridChanged`.
    private var localGrid: (Int, Int) = (0, 0)
    #if DEBUG
    private var typedTest = false
    #endif
    private var lostOwnership = false
    /// When its view was moved or left the window while it had the keyboard (see `scheduleStop`).
    /// It takes the keyboard back only if it lands again within a second.
    private var movedWithKeyboardAt: CFTimeInterval = -10
    private var hadKeyboard: Bool { CACurrentMediaTime() - movedWithKeyboardAt < 1 }
    /// When the engine view last stopped being first responder. UIKit resigns a view before it
    /// tells it that it leaves the window, so `isFirstResponder` is already false by then.
    private var lostKeyboardAt: CFTimeInterval = -1
    /// The key bar's hide key put the keyboard away; a tap brings it back.
    private(set) var userHidKeyboard = false
    /// The terminal's input views are the quiet ones: as first responder it takes hardware keys
    /// but shows no software keyboard and no key bar (`setKeyboardQuiet`).
    private(set) var keyboardQuiet = false
    /// An input view with no height: the system keyboard's place, empty.
    private let quietInputView = UIView(frame: .zero)
    /// A sheet, an alert or a menu covered the pane while it had the keyboard, and the pane
    /// gave it up; it takes it back when the cover goes.
    private var resignedUnderCover = false
    /// Whether a hardware keyboard is attached. Tests put their own here.
    var hardwareKeyboard: () -> Bool = { GCKeyboard.coalesced != nil }
    private var moveRetakes = KeyboardFocusPolicy.RetakeLimiter()
    private var stopWork: DispatchWorkItem?
    /// The view let go of its stream for good (see `TerminalHostPool`).
    var onStopped: (() -> Void)?

    private var tapGR: UITapGestureRecognizer!
    private var swipeGR: UIPanGestureRecognizer!
    private var pinchGR: UIPinchGestureRecognizer!
    private var pinchBase: CGFloat = 0
    /// What the pane knew when the latest touch went down: a tap is decided on this, not on
    /// what the tap itself has changed by the time it is recognized.
    private var touch = (keyboardUp: false, hadSelection: false)
    /// Copy and Paste at the selection, after a long press.
    private lazy var editMenu = UIEditMenuInteraction(delegate: self)
    private var menuTarget: CGRect?
    /// SELECTION UI: the loupe, handles, haptics, double and triple tap (Selection/, docs/selection.md).
    private var selectionUI: TerminalSelectionController!
    /// A long-press or pointer selection drag is under way: nothing else may scroll or swipe.
    private var selecting = false
    private var pointerSelectGR: UIPanGestureRecognizer!
    private var twoTapGR: UITapGestureRecognizer!
    /// The latest touch came from a mouse or trackpad (its drags select instead of scrolling).
    private var touchIsPointer = false

    // Hardware keys.
    private var cachedCommands: (generation: Int, commands: [UIKeyCommand])?
    /// Repeats a held key that a binding took from the engine. Tests put their own here.
    var keyRepeat = KeyRepeater()

    /// A Ghostty snapshot being received.
    private var snapshot = SnapshotBuffer()
    /// Asks before a paste that could run a command. Nil: an alert. Tests put their own here.
    var confirmPaste: ((String, @escaping @MainActor (Bool) -> Void) -> Void)?

    /// Background longer than this re-reads the screen on return.
    static let staleAfterBackground: CFTimeInterval = 30
    private var backgroundedAt: CFTimeInterval?
    /// Transient states (connecting, reconnecting) show only if they last this long.
    static let statusDelay: TimeInterval = 1.0
    private var statusWork: DispatchWorkItem?
    private static let lostText = "Resized elsewhere · tap to fit here"

    init(stream: TerminalStream, sizing: SizingMode, fontSize: CGFloat, theme: TermTheme, claim: FitClaim? = nil) {
        PerfProbe.active?.paneOpening()  // PERF: pane open, before the engine view is made
        self.stream = stream
        self.sizing = sizing
        self.fontSize = fontSize
        self.theme = theme
        term = GhosttyTerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 240), fontSize: fontSize)
        keyBar = KeyBar()
        self.claim = claim ?? FitClaim(transport: StreamFitTransport(stream: stream))
        super.init(frame: .zero)
        self.claim.onClaimed = { [weak self] cols, rows in self?.claimed(cols: cols, rows: rows) }
        term.engineDelegate = self
        keyBar.terminal = term
        keyBar.onPaste = { [weak self] in self?.pasteFromClipboard() }
        keyBar.onHideKeyboard = { [weak self] in self?.hideKeyboard() }
        term.inputAccessoryView = keyBar

        zoomer.delegate = self
        zoomer.showsHorizontalScrollIndicator = false
        zoomer.bouncesZoom = true
        zoomer.contentInsetAdjustmentBehavior = .never
        zoomer.scrollsToTop = false
        addSubview(zoomer)
        zoomer.addSubview(term)

        statusLabel.font = RexFont.ui(11)
        statusLabel.textAlignment = .center
        statusLabel.layer.cornerRadius = 11
        statusLabel.layer.masksToBounds = true
        statusLabel.isHidden = true
        statusLabel.isUserInteractionEnabled = true
        statusLabel.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(statusTapped)))
        addSubview(statusLabel)

        clipsToBounds = true
        applyTheme(theme)
        stream.sink = self
        // The data socket isn't read while megabytes wait to be parsed (`applyBackpressure`).
        // The core calls from the thread that crossed a mark, so the state is read on arrival.
        term.core.onBackpressureChange = { [weak self] in
            DispatchQueue.main.async { self?.applyBackpressure() }
        }

        NotificationCenter.default.addObserver(self, selector: #selector(didBackground),
                                               name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(willForeground),
                                               name: UIApplication.willEnterForegroundNotification, object: nil)
        // Moments when the keyboard may be free for the active pane to take (`reclaimKeyboard`).
        let free: [Notification.Name] = [.GCKeyboardDidConnect, UIApplication.didBecomeActiveNotification,
                                         UIWindow.didBecomeKeyNotification, UITextField.textDidEndEditingNotification,
                                         UITextView.textDidEndEditingNotification]
        for name in free {
            NotificationCenter.default.addObserver(self, selector: #selector(keyboardMayBeFree), name: name, object: nil)
        }
        term.keyHook = { [weak self] key in self?.handleKey(key) ?? false }
        term.keyboardFocusHook = { [weak self] focused in self?.keyboardFocusChanged(focused) }
        // A program may write the pasteboard (OSC 52) only from the pane the user works in.
        term.setProgramClipboardGate { [weak self] in self?.isFrontPane ?? false }
        // The pane shows its own focus (cursor, border): no system focus halo on top of it.
        term.focusEffect = nil
        setupGestures()
        PerfProbe.active?.paneOpened(self)  // PERF
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Gestures

    private var fitted: Bool { sizing == .fit && !lostOwnership }

    private func setupGestures() {
        // Gates, not failure requirements: a pan that waits for another to fail starts late and
        // loses most of the drag. Each pan decides at once whether the motion is its own.
        zoomer.panGate = { [weak self] pan in self?.canvasPanShouldBegin(pan) ?? true }
        term.panGate = { [weak self] pan in self?.termPanShouldBegin(pan) ?? true }
        // The host decides every tap (`tap(at:shift:)`) and sends the program its click itself,
        // so the terminal view's own tap never fires.
        term.tapGate = { false }

        // Long press selects the word under the finger and offers Copy.
        let lp = term.selectionPress
        lp.addTarget(self, action: #selector(longPressed(_:)))
        lp.minimumPressDuration = 0.45
        // A pointer selects by dragging; holding the button must not start a touch selection.
        lp.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]

        tapGR = UITapGestureRecognizer(target: self, action: #selector(tapped))
        tapGR.cancelsTouchesInView = false
        tapGR.delegate = self
        tapGR.require(toFail: lp)  // releasing a long press is not a tap
        addGestureRecognizer(tapGR)

        // Fingers only: a mouse or trackpad drag selects text instead.
        let direct = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        swipeGR = UIPanGestureRecognizer(target: self, action: #selector(swiped(_:)))
        swipeGR.maximumNumberOfTouches = 1
        swipeGR.allowedTouchTypes = direct
        swipeGR.delegate = self
        addGestureRecognizer(swipeGR)

        pinchGR = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        pinchGR.delegate = self
        addGestureRecognizer(pinchGR)

        twoTapGR = UITapGestureRecognizer(target: self, action: #selector(twoFingerTapped))
        twoTapGR.numberOfTouchesRequired = 2
        twoTapGR.cancelsTouchesInView = false
        twoTapGR.delegate = self
        addGestureRecognizer(twoTapGR)

        // Pointer drag selects at once, like a Mac. Wheel and trackpad scrolls still scroll.
        term.scrollPanRecognizer.allowedTouchTypes = direct
        pointerSelectGR = UIPanGestureRecognizer(target: self, action: #selector(pointerDragged(_:)))
        pointerSelectGR.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        pointerSelectGR.maximumNumberOfTouches = 1
        pointerSelectGR.delegate = self
        term.addGestureRecognizer(pointerSelectGR)
        term.addInteraction(editMenu)
        setupSelectionUI()
    }

    /// SELECTION UI: everything the controller needs from the host. It owns no recognizer but
    /// the handles' own press.
    private func setupSelectionUI() {
        let ui = TerminalSelectionController(term: term)
        ui.install(in: self, above: zoomer)
        ui.apply(tint: theme.uiCursor, rim: theme.uiBG)
        ui.playShimmer = { [weak self] rects in
            guard let self else { return }
            SelectionShimmer.play(on: self.term.layer, rects: rects, dark: self.theme.isDark)
        }
        ui.presentMenu = { [weak self] rect in self?.presentEditMenu(at: rect) }
        ui.dismissMenu = { [weak self] in self?.editMenu.dismissMenu() }
        ui.trackingChanged = { [weak self] tracking in self?.selecting = tracking }
        selectionUI = ui
    }

    /// Shows the edit menu around `rect` (engine view coordinates), or moves the one on screen.
    private func presentEditMenu(at rect: CGRect) {
        menuTarget = rect
        if selectionUI.menuVisible {
            editMenu.reloadVisibleMenu()
            editMenu.updateVisibleMenuPosition(animated: false)
        } else {
            let configuration = UIEditMenuConfiguration(identifier: nil, sourcePoint: CGPoint(x: rect.midX, y: rect.minY))
            // Above the selection when there is room: the end handle hangs below it.
            configuration.preferredArrowDirection = .down
            editMenu.presentEditMenu(with: configuration)
        }
    }

    /// Clears the selection and its handles.
    private func clearSelection() {
        term.clearSelectedRange()
        selectionUI.selectionCleared()
    }

    /// Mostly-horizontal motion of a pan that is about to begin.
    private func isHorizontal(_ pan: UIPanGestureRecognizer) -> Bool {
        var d = pan.translation(in: self)
        if abs(d.x) + abs(d.y) < 1 { d = pan.velocity(in: self) }
        return abs(d.x) > abs(d.y) * 1.2
    }

    private var canvasOverflowsX: Bool { zoomer.contentSize.width > zoomer.bounds.width + 1 }
    private var canvasOverflowsY: Bool { zoomer.contentSize.height > zoomer.bounds.height + 1 }

    private func canvasPanShouldBegin(_ pan: UIPanGestureRecognizer) -> Bool {
        guard !fitted, !selecting else { return false }
        if pan.numberOfTouches > 0, touchIsPointer { return false }
        return isHorizontal(pan) ? canvasOverflowsX : canvasOverflowsY
    }

    private func termPanShouldBegin(_ pan: UIPanGestureRecognizer) -> Bool {
        if pan === pointerSelectGR { return !selecting }
        // Only a long press or a pointer drag selects; nothing scrolls meanwhile.
        if selecting { return false }
        // Trackpad and wheel scrolls (no touches) and multi-finger drags go to the engine.
        if pan.allowedTouchTypes.isEmpty || pan.numberOfTouches == 0 || pan.numberOfTouches > 1 { return true }
        // A pointer drag selects (pointerSelectGR); it never scrolls or reports a wheel.
        if touchIsPointer { return false }
        let horizontal = isHorizontal(pan)
        // Mirror mode: the zoomed canvas pans first when it has room to in that direction.
        if !fitted, horizontal ? canvasOverflowsX : canvasOverflowsY { return false }
        // A horizontal flick is a pane swipe (or the canvas pan), never a terminal scroll.
        return !horizontal
    }

    private func swipeShouldBegin(_ pan: UIPanGestureRecognizer) -> Bool {
        guard onSwipe != nil, !selecting, isHorizontal(pan) else { return false }
        if !fitted && canvasOverflowsX { return false }
        // Leave the screen's left edge to the system's swipe back.
        if let w = window {
            let start = pan.location(in: w).x - pan.translation(in: w).x
            if start < 24 { return false }
        }
        return true
    }

    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        if g === swipeGR { return swipeShouldBegin(swipeGR) }
        if g === pinchGR { return fitted && !selecting }
        if g === twoTapGR { return onCommand != nil && !selecting }
        return true
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // Every touch on the pane passes the focus tap first: remember whether it is a pointer.
        if g === tapGR {
            self.touch = (keyboardUp, term.hasActiveSelection)
            touchIsPointer = touch.type == .indirectPointer
            // SELECTION UI: a long press may follow; wake the haptics now so its start has no lag.
            if !touchIsPointer { selectionUI.touchDown() }
        }
        return true
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // The focus tap observes; it must never cancel the engine's taps, selection or our swipe.
        g === tapGR || other === tapGR
    }

    /// A single-finger tap. What it does is decided once, in order, by `TerminalTapDecision`,
    /// from what the pane knew when the finger went down.
    @objc private func tapped() {
        tap(at: tapGR.location(in: term), shift: tapGR.modifierFlags.contains(.shift),
            keyboardUp: touch.keyboardUp, hadSelection: touch.hadSelection)
    }

    /// Decides a tap at `point` (engine view coordinates) and does the one thing it means.
    @discardableResult
    func tap(at point: CGPoint, shift: Bool, keyboardUp: Bool, hadSelection: Bool) -> TerminalTapOutcome {
        // SELECTION UI: handles, and which tap of a double or triple tap this is.
        let counted = selectionUI.countTap(at: point)
        let facts = TerminalTapFacts(onHandle: counted.onHandle, tapCount: counted.count, keyboardUp: keyboardUp,
                                     hadSelection: hadSelection, shift: shift, menuVisible: selectionUI.menuVisible)
        let outcome = TerminalTapDecision.outcome(
            facts,
            // TAP HOOK (links, prompts): the engine opens the link or moves the shell's cursor.
            engineUses: { term.tapOpensLinkOrMovesCursor(at: point, focused: true, shift: false) },
            tracksMouse: { term.sendsTapsToProgram },
            nearCursor: { selectionUI.tapIsByCursor(at: point) })
        if outcome == .handle { return outcome }
        onFocus?()
        switch outcome {
        case .handle:
            break
        case .select(let line):
            selectionUI.selectTap(at: point, line: line)
        case .focus(let clearsSelection):
            editMenu.dismissMenu()
            if clearsSelection { clearSelection() }
            showKeyboard()
        case .dismissSelection:
            editMenu.dismissMenu()
            clearSelection()
        case .programClick:
            editMenu.dismissMenu()
            term.sendClickToProgram(at: point)
        case .pasteMenu:
            // SELECTION UI: a tap by the cursor offers Paste.
            presentEditMenu(at: CGRect(origin: point, size: .zero).insetBy(dx: -4, dy: -4))
        case .engineUsed, .nothing:
            editMenu.dismissMenu()
        }
        return outcome
    }

    /// Two-finger tap: zoom this pane (or unzoom).
    @objc private func twoFingerTapped() {
        guard let onCommand else { return }
        onFocus?()
        Haptic.tap()
        onCommand(.toggleZoom)
    }

    /// Long press selects the word under the finger; dragging on extends the selection. On release
    /// the selection is copied (copy-on-select), shimmers, and the edit menu offers Copy and Paste.
    /// Nothing here takes the keyboard focus, so the keyboard never pops up for a selection.
    @objc private func longPressed(_ g: UILongPressGestureRecognizer) {
        let p = g.location(in: term)
        switch g.state {
        // SELECTION UI: the controller selects, shows the loupe, plays the haptics, and on release
        // copies, shows the handles and the menu. `selecting` follows it (`trackingChanged`).
        case .began:
            onFocus?()
            selectionUI.pressBegan(at: p)
        case .changed:
            selectionUI.pressMoved(to: p)
        case .ended:
            selectionUI.pressEnded(at: p)
        default:
            selectionUI.pressCancelled()
        }
    }

    /// Mouse or trackpad drag: select from where the button went down, copy on release.
    @objc private func pointerDragged(_ g: UIPanGestureRecognizer) {
        let p = g.location(in: term)
        switch g.state {
        case .began:
            onFocus?()
            selecting = true
            editMenu.dismissMenu()
            selectionUI.selectionCleared()
            let t = g.translation(in: term)
            term.beginSelection(at: CGPoint(x: p.x - t.x, y: p.y - t.y), word: false)
            term.extendSelection(to: p, autoscroll: false)
        case .changed:
            term.extendSelection(to: p, autoscroll: true)
        case .ended:
            finishPointerSelection()
        default:
            clearSelection()
            endSelection()
        }
    }

    private func endSelection() {
        selecting = false
        term.endSelectionDrag()
    }

    /// The pointer's button came up: copy the selection to the clipboard (copy-on-select) and
    /// play the shimmer. No menu follows a pointer drag.
    private func finishPointerSelection() {
        endSelection()
        let text = term.hasActiveSelection ? term.selectedText ?? "" : ""
        // Empty when the selection isn't one this gesture made.
        let rects = text.isEmpty ? [] : term.selectionRects
        if !rects.isEmpty {
            UIPasteboard.general.string = text
            Haptic.tap()
            SelectionShimmer.play(on: term.layer, rects: rects, dark: theme.isDark)
        } else {
            clearSelection()
        }
    }

    // MARK: Edit menu

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
                             suggestedActions: [UIMenuElement]) -> UIMenu? {
        var items: [UIMenuElement] = []
        if term.hasActiveSelection {
            items.append(UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
                guard let self else { return }
                if let s = self.term.selectedText, !s.isEmpty { UIPasteboard.general.string = s }
                self.clearSelection()
            })
        }
        if UIPasteboard.general.hasStrings || [.files, .image].contains(files?.pasteChoice) {
            items.append(UIAction(title: "Paste", image: UIImage(systemName: "doc.on.clipboard")) { [weak self] _ in
                guard let self else { return }
                self.clearSelection()
                self.pasteFromClipboard()
            })
        }
        // SELECTION UI: Select All, with handles to pull it back in from.
        items.append(UIAction(title: "Select All", image: UIImage(systemName: "character.textbox")) { [weak self] _ in
            guard let self else { return }
            self.selectionUI.selectAll(showsMenu: false)
            // Once this menu has gone: Copy for what is selected now.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.selectionUI.showMenu() }
        })
        return UIMenu(children: items)
    }

    // SELECTION UI: the controller needs to know whether the menu is up (a tap then hides it
    // instead of showing Paste; a new target moves it instead of presenting again).
    func editMenuInteraction(_ interaction: UIEditMenuInteraction, willPresentMenuFor configuration: UIEditMenuConfiguration,
                             animator: any UIEditMenuInteractionAnimating) {
        selectionUI.menuVisible = true
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, willDismissMenuFor configuration: UIEditMenuConfiguration,
                             animator: any UIEditMenuInteractionAnimating) {
        selectionUI.menuVisible = false
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, targetRectFor configuration: UIEditMenuConfiguration) -> CGRect {
        menuTarget ?? .null
    }

    @objc private func swiped(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: self)
        switch g.state {
        case .changed:
            zoomer.transform = CGAffineTransform(translationX: t.x * 0.3, y: 0)
        case .ended:
            let v = g.velocity(in: self)
            let far = abs(t.x) > 60
            let flick = abs(v.x) > 450 && abs(t.x) > 16 && (v.x < 0) == (t.x < 0)
            springBack()
            if far || flick { onSwipe?(t.x < 0 ? 1 : -1) }
        default:
            springBack()
        }
    }

    private func springBack() {
        guard zoomer.transform != .identity else { return }
        UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
            self.zoomer.transform = .identity
        }
    }

    /// Pinch: live preview by scaling, then one font change (and one resize claim) at the end.
    @objc private func pinched(_ g: UIPinchGestureRecognizer) {
        switch g.state {
        case .began:
            pinchBase = fontSize
        case .changed:
            let k = clampFont(pinchBase * g.scale) / fontSize
            let p = g.location(in: self)
            let d = CGPoint(x: p.x - bounds.midX, y: p.y - bounds.midY)
            zoomer.transform = CGAffineTransform(translationX: d.x, y: d.y).scaledBy(x: k, y: k).translatedBy(x: -d.x, y: -d.y)
        case .ended:
            zoomer.transform = .identity
            zoomer.frame = bounds
            let s = (clampFont(pinchBase * g.scale) * 2).rounded() / 2
            if abs(s - fontSize) > 0.01 {
                setFontSize(s)
                Prefs.shared.fontSize = Double(s)
            }
        default:
            zoomer.transform = .identity
            zoomer.frame = bounds
        }
    }

    private func clampFont(_ s: CGFloat) -> CGFloat { min(max(s, Self.fontRange.lowerBound), Self.fontRange.upperBound) }

    // MARK: Hardware keyboard

    /// ⌘ shortcuts, titled for the shortcut overlay shown while ⌘ is held. Keys without ⌘ (ctrl+tab,
    /// shift+enter, …) are caught in `handleKey` instead, before the engine turns them into bytes.
    override var keyCommands: [UIKeyCommand]? {
        guard let keymap else { return nil }
        if let c = cachedCommands, c.generation == keymap.generation { return c.commands }
        var taken = Set<String>()
        var out: [UIKeyCommand] = []
        func add(_ title: String, _ input: String, _ flags: UIKeyModifierFlags, _ payload: String, physical: Bool, repeats: Bool) {
            let id = "\(input)|\(flags.rawValue)"
            guard !taken.contains(id) else { return }
            taken.insert(id)
            let cmd = UIKeyCommand(title: title, action: #selector(keyCommandFired(_:)), input: input,
                                   modifierFlags: flags, propertyList: payload)
            cmd.discoverabilityTitle = title
            // Ahead of the text system's own ⌘ keys (⌘←, ⌘⌫, ⌘↩).
            cmd.wantsPriorityOverSystemBehavior = true
            if physical { cmd.allowsAutomaticLocalization = false }
            if #available(iOS 26.0, *) { cmd.repeatBehavior = repeats ? .repeatable : .nonRepeatable }
            out.append(cmd)
        }
        var decided = Set<KeyChord>()
        for b in keymap.bindings where b.chord.mods.contains(.cmd) && !decided.contains(b.chord) {
            // The first binding on a key that Rex DUO can perform runs; one it can't falls through.
            guard AppAction.resolve(b.action, b.args) != nil else { continue }
            decided.insert(b.chord)
            guard let input = KeyInput.commandInput(b.chord) else { continue }
            add(KeyActions.title(b), input, KeyInput.flags(b.chord.mods), b.chord.spelling,
                physical: b.chord.isPhysical, repeats: KeyActions.repeats(b.action))
        }
        // The Edit menu's keys, as on the Mac (unless the keymap took them).
        add("Copy", "c", .command, "edit:copy", physical: false, repeats: false)
        add("Paste", "v", .command, "edit:paste", physical: false, repeats: false)
        add("Select All", "a", .command, "edit:selectAll", physical: false, repeats: false)
        cachedCommands = (keymap.generation, out)
        return out
    }

    @objc private func keyCommandFired(_ sender: UIKeyCommand) {
        guard let payload = sender.propertyList as? String else { return }
        switch payload {
        case "edit:copy": perform(.copy, key: nil)
        case "edit:paste": perform(.paste, key: nil)
        case "edit:selectAll": perform(.selectAll, key: nil)
        default:
            guard let chord = KeyChord(spelling: payload), let (_, action) = keymap?.resolve([chord]) else { return }
            perform(action, key: nil)
        }
    }

    /// A hardware key press, before the engine sees it (`keyHook`). True when a binding ran (the key doesn't reach the
    /// terminal). Only keys the keymap binds are taken; every other key is typed as usual.
    private func handleKey(_ key: UIKey) -> Bool {
        // A sheet, an alert or a menu covers the pane: the key is not for it. (The pane gives
        // the keyboard up when it is covered, `coverChanged`; this catches a cover that came
        // without that.)
        if KeyboardFocusPolicy.sheetUp(in: window) {
            stopKeyRepeats()
            return true
        }
        guard let keymap, !KeyInput.isModifierKey(key.keyCode) else { return false }
        guard let (binding, action) = keymap.resolve(tiers: KeyInput.chordTiers(for: key)) else { return false }
        perform(action, key: key)
        if KeyActions.repeats(binding.action) {
            keyRepeat.start(usage: key.keyCode.rawValue, timing: .command, while: { [weak self] in self?.mayRepeatKeys ?? false }) {
                [weak self] in self?.perform(action, key: key)
            }
        }
        return true
    }

    /// A held key repeats only in the active pane, on screen, while it has the keyboard and
    /// nothing covers it. (`KeyRepeater` adds the app's state, the key's own state and a limit.)
    private var mayRepeatKeys: Bool {
        isActive && window != nil && term.isFirstResponder && !KeyboardFocusPolicy.sheetUp(in: window)
    }

    /// Ends every key repeat of this pane: the host's (bound keys) and the engine's.
    private func stopKeyRepeats() {
        keyRepeat.stop()
        term.stopKeyRepeat()
    }

    private func perform(_ action: AppAction, key: UIKey?) {
        switch action {
        case .command(let c):
            onCommand?(c)
        case .splitAuto:
            // Split along the longer side, as the Mac does.
            onCommand?(bounds.width >= bounds.height ? .splitRight : .splitDown)
        case .sendKey(let chord):
            if let bytes = KeyInput.bytes(chord) { term.send(data: bytes[...]) }
        case .copy:
            if term.hasActiveSelection, let s = term.selectedText, !s.isEmpty { UIPasteboard.general.string = s }
        case .paste:
            pasteFromClipboard()
        case .selectAll:
            selectionUI.selectAll(showsMenu: false)  // SELECTION UI: with handles
        case .pageUp:
            term.scrollPage(up: true)
        case .pageDown:
            term.scrollPage(up: false)
        case .promptPrevious:
            term.scrollToPrompt(next: false)
        case .promptNext:
            term.scrollToPrompt(next: true)
        case .server(let name, let args):
            stream.perform(action: name, args: args) { [weak self] queued in
                // A configuration-file action may ask this client to perform its own actions.
                for q in queued {
                    guard let n = q.str("action"), let a = AppAction.resolve(n, q.obj("args")) else { continue }
                    if case .server = a { continue }
                    self?.perform(a, key: nil)
                }
            }
        case .forwardKey:
            if let key { stream.forward(key: KeyInput.clientKeyEvent(key)) }
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses { if let key = press.key { keyRepeat.released(usage: key.keyCode.rawValue) } }
        super.pressesEnded(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses { if let key = press.key { keyRepeat.released(usage: key.keyCode.rawValue) } }
        super.pressesCancelled(presses, with: event)
    }

    // MARK: Keyboard focus

    @objc private func keyboardMayBeFree() { reclaimKeyboard() }

    /// What `KeyboardFocusPolicy` decides on, for this pane now.
    private var keyboardSituation: KeyboardFocusPolicy.Situation {
        KeyboardFocusPolicy.Situation(
            paneActive: isActive, inWindow: window != nil,
            appActive: UIApplication.shared.applicationState == .active,
            holdsKeyboard: term.isFirstResponder, hardwareKeyboard: hardwareKeyboard(),
            hadKeyboard: hadKeyboard, userHidKeyboard: userHidKeyboard,
            sheetUp: KeyboardFocusPolicy.sheetUp(in: window),
            holder: KeyboardFocusPolicy.holder(UIResponder.rexCurrentFirstResponder(), own: term))
    }

    /// The terminal has the keyboard and shows it (the system keyboard or the key bar).
    private var keyboardUp: Bool { term.isFirstResponder && !keyboardQuiet }

    /// The pane the user is working in: active, on screen, in the foreground app.
    private var isFrontPane: Bool {
        isActive && window != nil && UIApplication.shared.applicationState == .active
    }

    /// Takes the keyboard when the policy says this pane should have it: with a hardware keyboard
    /// the active pane always does, as on a Mac, so keys go to the pane on screen without a tap
    /// first; without one, only to keep the keyboard it had (a fold moved the pane, or the active
    /// pane changed). Never from a text field or under a sheet. After the user put the keyboard
    /// away the pane still takes it, quietly: hardware keys reach it, nothing shows.
    /// Called whenever the keyboard may have become free: the pane became active or came on screen,
    /// a keyboard connected, the app or its window became active, a text field finished.
    private func reclaimKeyboard(afterMove: Bool = false) {
        #if DEBUG
        // `-focus none` (testing): the simulator reports a hardware keyboard; leave the keyboard down.
        if UserDefaults.standard.string(forKey: "focus") == "none" { return }
        #endif
        // Cheap checks first: this runs for every pane on every notification.
        guard isActive, window != nil, !term.isFirstResponder else { return }
        // Later: the view may still be on its way into the window, or the app into the foreground.
        DispatchQueue.main.async { [weak self] in
            guard let self, KeyboardFocusPolicy.takesKeyboard(self.keyboardSituation) else { return }
            if afterMove, !self.moveRetakes.allows(at: CACurrentMediaTime()) {
                // The layout keeps moving this pane as it takes the keyboard: leave the keyboard down.
                self.movedWithKeyboardAt = -10
                return
            }
            self.setKeyboardQuiet(KeyboardFocusPolicy.takesQuietly(self.keyboardSituation))
            _ = self.term.becomeFirstResponder()
        }
    }

    /// The pane stopped being the active one: it must not keep the keyboard, or keys would go
    /// to a pane the user has left.
    private func resignIfInactive() {
        guard KeyboardFocusPolicy.mustResign(paneActive: isActive, holdsKeyboard: term.isFirstResponder) else { return }
        _ = term.resignFirstResponder()
    }

    private func keyboardFocusChanged(_ focused: Bool) {
        if focused {
            movedWithKeyboardAt = -10
            resignedUnderCover = false
        } else {
            lostKeyboardAt = CACurrentMediaTime()
            keyRepeat.stop()
        }
    }

    /// Being first responder and showing a keyboard are two things. Quiet: the terminal's input
    /// view is an empty one and it has no key bar, so as first responder it gets hardware keys
    /// and nothing shows. Not quiet: the system keyboard and the key bar.
    private func setKeyboardQuiet(_ quiet: Bool) {
        guard quiet != keyboardQuiet else { return }
        keyboardQuiet = quiet
        term.inputView = quiet ? quietInputView : nil
        term.inputAccessoryView = quiet ? nil : keyBar
        if term.isFirstResponder { term.reloadInputViews() }
    }

    /// A tap on the pane: the keyboard comes up, also after the hide key.
    private func showKeyboard() {
        userHidKeyboard = false
        setKeyboardQuiet(false)
        if !term.isFirstResponder { _ = term.becomeFirstResponder() }
    }

    /// UIKit dims the tint of everything under a sheet, an alert or a menu, and tells each view:
    /// the one sign a view gets that it has been covered. A covered pane gives up the keyboard,
    /// so neither a hardware key nor the software keyboard types into it behind the cover, and
    /// takes it back when the cover goes.
    override func tintColorDidChange() {
        super.tintColorDidChange()
        coverChanged(covered: tintAdjustmentMode == .dimmed)
    }

    func coverChanged(covered: Bool) {
        if covered {
            stopKeyRepeats()
            guard term.isFirstResponder else { return }
            resignedUnderCover = true
            _ = term.resignFirstResponder()
        } else if resignedUnderCover {
            resignedUnderCover = false
            // It had the keyboard: the policy lets it take it back without a hardware keyboard.
            movedWithKeyboardAt = CACurrentMediaTime()
            reclaimKeyboard()
        }
    }

    /// The engine view is about to move to another superview or leave the window: note whether it
    /// has the keyboard, to take it back where it lands. UIKit resigns it first, so a keyboard lost
    /// in this same turn of the run loop counts.
    func noteKeyboardBeforeMove() {
        let now = CACurrentMediaTime()
        if term.isFirstResponder || now - lostKeyboardAt < 0.05 { movedWithKeyboardAt = now }
    }

    /// The key bar's hide key: the keyboard and the bar go away until the next tap on the pane.
    /// With a hardware keyboard the terminal stays first responder, quietly, so its keys still
    /// type into this pane; without one there is nothing left to type with and it resigns.
    func hideKeyboard() {
        userHidKeyboard = true
        if hardwareKeyboard() {
            setKeyboardQuiet(true)
        } else {
            _ = term.resignFirstResponder()
        }
    }

    // MARK: App state

    /// Hand fitted panes back to the Mac while the app is in the background.
    @objc private func didBackground() {
        backgroundedAt = CACurrentMediaTime()
        stopKeyRepeats()
        // Also when nothing is claimed yet: a claim on its way must not resize the pane now.
        claimedSize = nil
        claim.release()
    }

    @objc private func willForeground() {
        // After a long suspension the socket is likely dead and the server may have dropped the
        // stream; read the real screen again rather than show a stale one.
        if let t = backgroundedAt, CACurrentMediaTime() - t > Self.staleAfterBackground, started, window != nil {
            stream.restart()
        }
        backgroundedAt = nil
        guard window != nil, sizing == .fit, !lostOwnership else { return }
        lastBounds = .zero
        setNeedsLayout()
    }

    /// Tapping the "another device has this pane" chip takes the pane back.
    @objc private func statusTapped() {
        guard sizing == .fit, lostOwnership else { return }
        lostOwnership = false
        hideStatus()
        claimedSize = nil
        lastBounds = .zero
        setNeedsLayout()
    }

    func focusKeyboard() {
        showKeyboard()
    }

    func applyTheme(_ t: TermTheme) {
        theme = t
        backgroundColor = t.uiBG
        zoomer.backgroundColor = t.uiBG
        term.apply(theme: t)
        // Native scroll indicators that stay visible on both light and dark themes.
        zoomer.indicatorStyle = t.isDark ? .white : .black
        statusLabel.backgroundColor = t.uiFG.withAlphaComponent(0.15)
        statusLabel.textColor = t.uiFG
        keyBar.apply(theme: t)
        selectionUI?.apply(tint: t.uiCursor, rim: t.uiBG)  // SELECTION UI (nil during init)
    }

    /// What the key bar lays itself out around: the system's vertical bar edge (nil where bars are
    /// horizontal) and a vertical crease in window coordinates (nil without one).
    func setKeyBarSurroundings(barEdge: NSDirectionalRectEdge?, crease: CGRect?) {
        keyBar.barEdge = barEdge
        keyBar.crease = crease
    }

    func setFontSize(_ s: CGFloat) {
        guard abs(s - fontSize) > 0.01 else { return }
        fontSize = s
        // The server's grid at the new cell size. The terminal keeps its modes and its content;
        // fit mode then claims the grid that fits now and the program redraws itself.
        term.setFont(size: s)
        applyLocalGrid(serverSize.0, serverSize.1, force: true)
        positionTerm()
        lastBounds = .zero
        setNeedsLayout()
    }

    func setSizing(_ m: SizingMode) {
        guard m != sizing else { return }
        sizing = m
        if m == .mirror {
            claimedSize = nil
            claim.release()
        }
        lastBounds = .zero
        setNeedsLayout()
    }

    // MARK: Lifecycle

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil { noteKeyboardBeforeMove() }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            stopKeyRepeats()
            // Off screen: no new size is claimed for a pane nobody sees. A fold brings it back
            // in a moment; otherwise `stop()` gives the pane back.
            claim.pause()
            scheduleStop()
        } else {
            stopWork?.cancel()
            stopWork = nil
            // Claim again what was paused, if the size still isn't the one that fits.
            lastBounds = .zero
            setNeedsLayout()
            yieldContentSwipeBack()
            // Moved by a fold or unfold while it had the keyboard, or a hardware keyboard is attached.
            reclaimKeyboard(afterMove: true)
        }
    }

    /// Off screen: let go of the stream, unless the view is back on screen in a moment. A fold or an
    /// unfold rebuilds the layout around the pane and `PaneView` moves this view to its new place
    /// (`TerminalHostPool`), keeping the screen, the scrollback and the keyboard.
    func scheduleStop() {
        stopWork?.cancel()
        // Strong capture: the pool may be the only owner, and the stream must be stopped either way.
        let work = DispatchWorkItem { [self] in
            stopWork = nil
            guard window == nil else { return }
            stop()
            onStopped?()
        }
        stopWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// iOS 26 swipes back from anywhere in the content. Over the terminal a horizontal flick
    /// switches panes instead; the screen-edge swipe back still works.
    private func yieldContentSwipeBack() {
        guard #available(iOS 26.0, *) else { return }
        var r: UIResponder? = next
        while let cur = r {
            if let nav = cur as? UINavigationController {
                nav.interactiveContentPopGestureRecognizer?.require(toFail: swipeGR)
                return
            }
            if let vc = cur as? UIViewController, let nav = vc.navigationController {
                nav.interactiveContentPopGestureRecognizer?.require(toFail: swipeGR)
                return
            }
            r = cur.next
        }
    }


    func stop() {
        stopKeyRepeats()
        // A snapshot half received is of no use to the next start.
        snapshot.reset()
        stream.stop()
        // Gives the pane back once any call in flight has returned; no resize follows.
        claimedSize = nil
        claim.release()
        started = false
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if zoomer.transform == .identity { zoomer.frame = bounds }
        if !statusLabel.isHidden { layoutStatus() }
        guard bounds.width > 20, bounds.height > 20 else { return }
        guard bounds.size != lastBounds else { return }
        lastBounds = bounds.size
        layoutTerminal()
    }

    private func layoutTerminal() {
        positionTerm()
        switch sizing {
        case .fit:
            guard !lostOwnership else { return }
            // In the background the pane belongs to the Mac. A layout change there (the keyboard
            // leaving as the app goes away) must not claim it back; `willForeground` lays out again.
            guard backgroundedAt == nil else { return }
            let want = fitGrid()
            // A new size needs no redraw from the server: the terminal reflows as the server's
            // does (both are Ghostty), and the stream carries the resize.
            if started, let c = claimedSize, c == want, serverSize == want { return }
            claim.request(cols: want.0, rows: want.1)
        case .mirror:
            if !started { started = true; stream.start() }
        }
    }

    /// One cell's size in points at the current font.
    private func cellSize() -> CGSize { term.cellSize }

    /// Largest grid that fits the view at the current font.
    private func fitGrid() -> (Int, Int) {
        let g = TerminalLayout.fitGrid(in: bounds.size, cell: cellSize())
        return (g.cols, g.rows)
    }

    /// Sizes the engine to a grid, at this point of the stream, keeping the modes the program set.
    private func applyLocalGrid(_ cols: Int, _ rows: Int, force: Bool = false) {
        guard force || localGrid != (cols, rows) else { return }
        term.setGrid(cols: cols, rows: rows, force: force)
    }

    /// Places the terminal for the current grid. Fit: 1:1, bottom rows kept in view while the server
    /// catches up with a smaller size (keyboard opening). Mirror: zoomed to fit the width.
    private func positionTerm() {
        guard bounds.width > 1, bounds.height > 1 else { return }
        let cell = cellSize()
        let size = CGSize(width: ceil(CGFloat(localGrid.0) * cell.width) + 0.5,
                          height: ceil(CGFloat(localGrid.1) * cell.height) + 0.5)
        if fitted {
            zoomer.minimumZoomScale = 1
            zoomer.maximumZoomScale = 1
            zoomer.zoomScale = 1
            term.frame = CGRect(x: 0, y: min(0, bounds.height - size.height), width: size.width, height: size.height)
            zoomer.contentSize = bounds.size
            zoomer.contentOffset = .zero
        } else {
            zoomer.minimumZoomScale = min(zoomer.minimumZoomScale, 1)
            zoomer.maximumZoomScale = max(zoomer.maximumZoomScale, 1)
            zoomer.zoomScale = 1
            term.frame = CGRect(origin: .zero, size: size)
            zoomer.contentSize = size
            let fitW = bounds.width / size.width
            let fitH = bounds.height / size.height
            zoomer.minimumZoomScale = min(fitW, fitH, 1)
            zoomer.maximumZoomScale = max(2, fitW)
            zoomer.zoomScale = min(fitW, 1)
        }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { term }

    /// The pane is ours at this size (`FitClaim.onClaimed`: still wanted, never after a release).
    /// Once started, the stream carries the resize and the program's redraw; nothing to reload.
    private func claimed(cols: Int, rows: Int) {
        claimedSize = (cols, rows)
        if !started {
            started = true
            stream.start()
        }
    }

    // MARK: TerminalSink

    /// Only when a snapshot could not be restored (`TerminalStream`): the screen follows as text.
    func streamReset(cols: Int, rows: Int) {
        // RIS + clear scrollback, then match the server's grid.
        term.feed(text: "\u{1b}c\u{1b}[3J")
        serverSize = (cols, rows)
        applyLocalGrid(cols, rows)
        positionTerm()
    }

    func streamGhosttySnapshot(_ part: GhosttySnapshotPart) -> Bool {
        PerfProbe.active?.snapshot(part, host: self)  // PERF
        switch part {
        case .begin:
            snapshot.reset()
        case .bytes(let b):
            // Past the phone's limit the snapshot is refused and freed; the stream falls back
            // to `terminal.format`.
            return snapshot.append(b)
        case .ready:
            break
        case .end(let complete):
            guard complete else {
                snapshot.reset()
                return true
            }
            // One contiguous copy, made while the parts are freed (`SnapshotBuffer.take`).
            return term.restoreSnapshot(snapshot.take()) { [weak self] in self?.stream.snapshotRestoreFailed() }
        }
        return true
    }

    /// The fallback for a snapshot that could not be restored: the screen as escape sequences.
    func streamSnapshot(_ text: String) {
        PerfProbe.active?.seedReceived(text.utf8.count, host: self)  // PERF
        term.feed(text: text)
        PerfProbe.active?.seedParsed(host: self)  // PERF
    }

    func streamFeed(_ bytes: UnsafeBufferPointer<UInt8>) {
        PerfProbe.active?.fed(bytes.count, host: self)  // PERF
        // The terminal copies the bytes and parses them on its own queue, in stream order.
        term.feed(buffer: bytes)
    }

    /// The engine's unparsed backlog crossed a mark (`GhosttyCore.isBackedUp`: on above 4 MB,
    /// off below 1 MB). While it is backed up the data socket isn't read, so a program that
    /// writes faster than the phone parses fills the server's buffer, not the phone's memory.
    private func applyBackpressure() {
        if term.core.isBackedUp { stream.pauseReading() } else { stream.resumeReading() }
    }

    func streamResized(cols: Int, rows: Int, owner: String?) {
        // The terminal keeps stream order itself: output fed before this is parsed at the old size.
        serverSize = (cols, rows)
        let wasFitted = fitted
        if sizing == .fit, let c = claimedSize, c != (cols, rows), owner != stream.control.clientID {
            // Another client (the Mac, or another phone) resized it. Don't fight over it; offer to take it back.
            claimedSize = nil
            lostOwnership = true
            claim.lost()
            showStatus(Self.lostText)
        }
        guard localGrid != (cols, rows) || wasFitted != fitted else { return }
        applyLocalGrid(cols, rows)
        positionTerm()
    }

    func streamTheme(_ theme: JSONObject) {}

    func streamExited(code: Int?) {
        showStatus("Program exited\(code.map { " (\($0))" } ?? "")")
    }

    func streamStatus(_ status: TerminalStream.Status) {
        PerfProbe.active?.status(status, host: self)  // PERF
        switch status {
        case .live:
            if lostOwnership { showStatus(Self.lostText) } else { hideStatus() }
            #if DEBUG
            if isActive { GhosttyTapTest.run(on: term) }  // `-tapTest` (testing, GhosttyTap.swift)
            if isActive { FilesTest.run(on: self) }  // `-filesTest` (testing, FilesTest.swift)
            // `-typeTest <text>` (Debug builds, testing): types into the live shell.
            if isActive, let t = UserDefaults.standard.string(forKey: "typeTest"), !typedTest {
                typedTest = true
                let text = t.replacingOccurrences(of: "\\n", with: "\r")
                // `-scrollBackTest <seconds>` (testing): scroll two pages into the scrollback first
                // and type that much later, to check that input returns the view to the bottom.
                let wait = UserDefaults.standard.double(forKey: "scrollBackTest")
                guard wait > 0 else { term.send(txt: text); return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    self?.term.scrollPage(up: true)
                    self?.term.scrollPage(up: true)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5 + wait) { [weak self] in self?.term.send(txt: text) }
            }
            #endif
        case .connecting: showStatus("Connecting…", after: Self.statusDelay)
        // A failure retries on its own; to the user it is still reconnecting.
        case .reconnecting, .failed: showStatus("Reconnecting…", after: Self.statusDelay)
        case .ended(let m): showStatus(m)
        }
    }

    /// One small chip at the top. Transient states wait `after` seconds, so brief blips never show.
    private func showStatus(_ s: String, after delay: TimeInterval = 0) {
        statusWork?.cancel()
        statusWork = nil
        guard delay > 0 else { applyStatus(s); return }
        guard statusLabel.isHidden else { applyStatus(s); return }  // already showing: just update
        let w = DispatchWorkItem { [weak self] in self?.applyStatus(s) }
        statusWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    private func applyStatus(_ s: String) {
        statusLabel.text = s
        let wasHidden = statusLabel.isHidden
        statusLabel.isHidden = false
        layoutStatus()
        if wasHidden {
            statusLabel.alpha = 0
            UIView.animate(withDuration: 0.2) { self.statusLabel.alpha = 1 }
        }
    }

    private func hideStatus() {
        statusWork?.cancel()
        statusWork = nil
        statusLabel.isHidden = true
    }

    private func layoutStatus() {
        let fit = statusLabel.sizeThatFits(CGSize(width: bounds.width - 24, height: 22))
        let w = min(fit.width + 20, bounds.width - 24)
        statusLabel.frame = CGRect(x: (bounds.width - w) / 2, y: 8, width: w, height: 22)
        statusLabel.layer.cornerRadius = 11
    }

    // MARK: TerminalEngineDelegate

    func engineGridChanged(cols: Int, rows: Int) {
        localGrid = (cols, rows)
    }

    func engineSend(_ bytes: [UInt8]) {
        stream.send(bytes)
        keyBar.consumedModifiers()
    }

    /// Pastes through the engine, so the text is bracketed when the program asked for bracketed
    /// paste. When it didn't, every line end is the Return key and a shell runs each line: such a
    /// paste is asked about first (`PasteConfirmation`), with a preview and the line count.
    func paste(_ s: String) {
        guard term.pasteNeedsConfirmation(s) else { return term.pasteText(s) }
        let answer: @MainActor (Bool) -> Void = { [weak self] yes in
            if yes { self?.term.pasteText(s) }
        }
        if let confirmPaste {
            confirmPaste(s, answer)
        } else {
            TerminalPrompt.ask(over: self, title: PasteConfirmation.title(s), message: PasteConfirmation.message(s),
                               confirm: "Paste", answer: answer)
        }
    }

    func sendKey(_ bytes: [UInt8]) { stream.send(bytes) }

    /// Paste key, ⌘V and the menu's Paste: text pastes as before; a clipboard with only an image or
    /// copied files sends them to the pane's computer, which types their paths (`ClipboardChoice`).
    func pasteFromClipboard() {
        switch files?.pasteChoice ?? (UIPasteboard.general.hasStrings ? .text : .nothing) {
        case .text: if let s = UIPasteboard.general.string { paste(s) }
        case .files, .image: files?.pasteFiles()
        case .nothing: break
        }
    }

    #if DEBUG
    /// `-filesTest menu`: opens the attach key's menu as a tap does.
    func openAttachMenu() { keyBar.openAttachMenu() }
    #endif

    /// Shows the attach key once the server is known to take files.
    func refreshFiles() {
        files?.checkSupport()
        keyBar.attachAvailable = files?.supported == true
    }
}
