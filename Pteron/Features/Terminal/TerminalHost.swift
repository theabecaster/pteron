import UIKit
import RexKit
import GameController
/// The scroll view that scales and pans the terminal in mirror mode.
final class ZoomScrollView: UIScrollView {
    var panGate: ((UIPanGestureRecognizer) -> Bool)?

    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        if g === panGestureRecognizer, let gate = panGate, !gate(panGestureRecognizer) { return false }
        // A pinch sets the text size in every mode (the host's own pinch); the canvas never zooms by it.
        if g === pinchGestureRecognizer { return false }
        return super.gestureRecognizerShouldBegin(g)
    }
}

/// What a delayed item of `TerminalHost.scheduleStop` holds its pane by. A cancelled item stays
/// in the main queue until its time, with all it captured: it captures this, and cancelling
/// takes the pane out, so a pane that was stopped is not kept for the rest of the delay.
@MainActor
private final class LeaveHold {
    private var host: TerminalHost?
    init(_ host: TerminalHost) { self.host = host }
    /// The pane, once: the item has run.
    func take() -> TerminalHost? {
        defer { host = nil }
        return host
    }
    func clear() { host = nil }
}

/// A UIKit view that shows one Rex terminal block in a `GhosttyTerminalView`.
/// Fit mode: claims the block and resizes it to this view. Mirror mode: keeps the server's size, scaled and panned.
///
/// The software keyboard covers a fitted pane instead of resizing it: the grid stays the one
/// that fits the pane with the keyboard down (`restSize`), so the program is not told to redraw
/// each time the keyboard shows or hides. The engine view keeps that height, the pane shows its
/// top part, and the engine shifts the rows so the last ones sit above the key bar and the rest
/// scroll into view (`GhosttyTerminalView.setCover`). On the alternate screen (an editor, a
/// pager) the grid fits above the keyboard instead: those rows can't be scrolled.
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
    /// Find in this pane (TerminalHost+Find.swift). Nil until find first opens.
    var finder: PaneFind?
    let keyBar: KeyBar
    /// Back to the newest line. It shows only while the view is well into the scrollback
    /// (`JumpToBottomRule`).
    let jumpButton = JumpToBottomButton()
    private var jumpRule = JumpToBottomRule()
    /// Where the view is in the scrollback, as the engine last said (`scrollPlaceHook`).
    private var scrollPlace = GhosttyScrollPlace()

    var sizing: SizingMode
    var fontSize: CGFloat
    var theme: TermTheme
    /// The tab's active pane. Only the active pane holds the keyboard: a pane that becomes
    /// active takes it (`reclaimKeyboard`), and one that stops being active gives it up and
    /// stops any key it was repeating.
    var isActive = false {
        didSet {
            guard isActive != oldValue else { return }
            // In a split only the active pane's program has the focus.
            refreshProgramFocus()
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
    /// This pane's files: the attach key, Paste of an image, drops, the file browser and Insert
    /// Path. Nil where the pane has no server (a replay).
    var files: PaneFiles? {
        didSet {
            files?.view = self
            files?.installDrop(on: self)
            files?.onSupportChanged = { [weak self] in self?.refreshFiles() }
            files?.insertText = { [weak self] text in self?.insertPath(text) }
            files?.whenCurrent = { [weak self] body in
                guard let self else { return body() }
                self.stream.whenCurrent(body)
            }
            files?.bracketedPaste = { [weak self] in self?.term.core.input.modes.bracketedPaste ?? false }
            files?.keyboard = (capture: { [weak self] in self.map(KeyboardRecord.capture) ?? .none },
                               retake: { [weak self] record in self?.retakeKeyboard(record) })
            keyBar.attachMenu = { [weak self] in self?.files?.menu() ?? UIMenu() }
            refreshFiles()
        }
    }

    /// Sharing this pane's output: Share… in the edit menu and Share ▸ in the pane menu. Nil
    /// where the pane has no server (a replay).
    var share: PaneShare? {
        didSet { share?.host = self }
    }

    /// The pane's ports: followed while it is on screen, and its tapped links routed
    /// (`PanePorts`). Nil where the pane has no server (a replay): links open as they always did.
    var ports: PanePorts? {
        didSet {
            ports?.view = self
            if let ports {
                term.taps.open = { [weak ports] url, asked in ports?.open(url, asked: asked) }
                if window != nil { ports.watch() }
            }
        }
    }

    /// The pane's size with the software keyboard down, from the layout around it; nil when
    /// that isn't known. The grid is fitted to its height while the keyboard covers the pane.
    private var restSize: CGSize?
    /// The bottom a float sheet leaves below the screen (`setSheetCover`).
    private(set) var sheetCover: CGFloat = 0
    /// The program is on the alternate screen (`alternateScreenHook`).
    private(set) var alternateScreen = false
    /// The size the server confirmed for this pane in fit mode.
    private var claimedSize: (Int, Int)? {
        // Given up or lost: the tenure ends with it, and the next answered claim starts one.
        didSet { if claimedSize == nil { tenure.released() } }
    }
    /// What the pane knows about losing its size: to another client, or only to this phone's
    /// own absence (`FitTenure`).
    private var tenure = FitTenure()
    /// The control connection's welcomes since this host was made (`controlCameBack`).
    private var welcomes = 0
    /// Whether the control connection is lost or being made again; nil: the control
    /// connection's own state. Tests put their own here.
    var controlDown: (() -> Bool)?
    /// Which of its clients the control connection is on the server; nil: the control
    /// connection's own count (`RexControl.clientGeneration`). Tests put their own here.
    var clientGeneration: (() -> Int)?
    /// Own, resize, give back: every fit-mode call to the server goes through here, in order.
    private let claim: FitClaim
    private var started = false
    private var lastBounds: CGSize = .zero
    private var serverSize: (Int, Int) = (80, 24)
    /// The stream has said the pane's size since its last fresh start (`reportedSize`).
    private var serverSizeReported = false
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
    let quietInputView = UIView(frame: .zero)
    /// The key bar is up with its hide key in the vertical bar (`KeyBar.hidesInVerticalBar`): the
    /// terminal has the keyboard and shows the key bar, over the software keyboard or alone for
    /// a hardware one. The tab's toolbar then has Hide Keyboard for this pane (`HideKeyboardItem`).
    private(set) var barHidesKeyboard = false
    /// Told each time `barHidesKeyboard` changes.
    var onBarHidesKeyboard: ((Bool) -> Void)?
    /// A sheet, an alert or a menu covered the pane while it had the keyboard, and the pane
    /// gave it up; it takes it back when the cover goes.
    var resignedUnderCover = false
    /// Whether a hardware keyboard is attached. Tests put their own here.
    var hardwareKeyboard: () -> Bool = { GCKeyboard.coalesced != nil }
    /// Whether VoiceOver runs. Tests put their own here.
    var voiceOver: () -> Bool = { UIAccessibility.isVoiceOverRunning }
    /// How often the stream's fence went up: a click queued before the last time is stale.
    private var fencesRaised = 0
    /// Counts what the user did to the pane (a tap, a long press, the hide key): a keyboard
    /// that waits for a click comes only if nothing else was done since.
    private var userActs = 0
    /// The keyboard that waits for a click's answer comes only if the answer took at most
    /// this long. Tests shorten it.
    var clickKeyboardLimit: TimeInterval = 2
    /// The pane left the screen for good, or was never on it: set once it has stayed out of
    /// its window (`scheduleStop`) or another pane came to the front meanwhile
    /// (`leftForAnother`), cleared when it is back (`cameBackOnScreen`). A fold, which moves
    /// the pane through no window for a moment, never sets it.
    private var leftScreen = true
    /// This pane became the front pane. The pool tells the panes that are on their way out.
    var onCameToFront: (() -> Void)?
    /// Whether another pane of the pool is the front pane now.
    var anotherIsFront: (() -> Bool)?
    private var moveRetakes = KeyboardFocusPolicy.RetakeLimiter()
    private var stopWork: DispatchWorkItem?
    private var stopHold: LeaveHold?
    /// How long a pane off screen waits before it lets go, and how long it keeps its fit claim.
    struct LeaveTiming {
        /// Off screen this long, the pane stops or parks (`scheduleStop`). A fold is back sooner.
        var settle: TimeInterval = 0.5
        /// A parked pane keeps its size on the Mac this long after it left the screen, so going
        /// back and forth between two panes resizes neither.
        var claimGrace: TimeInterval = 10
    }
    /// Tests shorten it.
    var leaveTiming = LeaveTiming()
    /// The pool keeps this pane when it leaves the screen (`TerminalHostPool`): it parks
    /// instead of stopping.
    var canPark = false
    /// Parked: off screen with its screen, scrollback and place in the stream kept, and no
    /// socket, no drawables and no timers (`park`).
    private(set) var isParked = false
    /// Warm: off screen like a parked pane, but its stream goes on and is parsed, unseen, so
    /// the screen is current the moment the pane is back (`warm`). The pool decides which panes.
    private(set) var isWarm = false {
        // On cellular a pane that streams unseen takes its turn for a fresh snapshot behind those on screen.
        didSet { stream.isOnScreen = !isWarm }
    }
    private var warmRate = WarmRate()
    /// Back from warm, until the first layout has decided whether a claim follows.
    private var returnedWarm = false
    /// The terminal's memory by the engine's figure, read once as the pane left the screen
    /// (and again if a warm pane parks): the pool's bound adds these up without asking the
    /// engine again.
    private(set) var keptBytes = 0
    /// Off screen for `leaveTiming.settle`. The pool answers with `warm()` or `park()`; without
    /// a pool the pane parks.
    var onLeft: (() -> Void)?
    /// The pane parked itself; and it is back on screen.
    var onParked: (() -> Void)?
    var onUnparked: (() -> Void)?
    private var graceWork: DispatchWorkItem?
    private var graceHold: LeaveHold?
    /// The agent board lies over the pane (`setCovered`).
    private(set) var covered = false
    /// A sheet, an alert or a menu lies over the pane, as UIKit's dimmed tint last said
    /// (`coverChanged`).
    private var dimmed = false
    /// The palette lies over the pane. `PaneHostView` sets it together with `isActive` and
    /// then calls `refreshProgramFocus`, so the two changing at once are one change.
    var underPalette = false
    /// The app is the one in front, as its notifications last said (`appActiveChanged`).
    private var appActive = false
    /// The cover took the keyboard from a pane that showed only its key bar; it gets it back.
    private var coverTookKeyBar = false
    /// How long an uncovered pane waits for its keyboard before it fits itself again.
    static let uncoverSettle: TimeInterval = 0.4
    /// The relayout due `uncoverSettle` after the board left, dropped if it comes back sooner.
    private var uncoverRelayout: DispatchWorkItem?
    /// Called for every hardware key press that reaches the pane.
    var onKeyPress: (() -> Void)?
    /// The keyboard the palette owes this pane, taken once (`TerminalHostPool.owe`): whether
    /// quietly, or nil when none is owed here.
    var takeOwedKeyboard: (() -> Bool?)?
    /// A key ran a Lua or block action here (name, title). Returns what to call when its
    /// `client.action` answers. The palette keeps the run, so a question it asks shows here.
    var onServerRun: ((String, String) -> (@MainActor (Bool) -> Void)?)?
    /// The view let go of its stream for good (see `TerminalHostPool`).
    var onStopped: (() -> Void)?

    private(set) var tapGR: UITapGestureRecognizer!
    private var swipeGR: UIPanGestureRecognizer!
    /// A drag across a resize handle's strip where it reaches over this pane (`HandleStrips`):
    /// it does nothing itself, and the pane's taps and drags wait for it to fail on a touch that
    /// starts in a strip, so the handle's drag is the handle's alone.
    let gripPan = UIPanGestureRecognizer()
    /// The handles' strips of the window (`HandleStrip`); nil outside the app's layout.
    var handleStrips: HandleStrips?
    /// The strip the latest touch started in, if any.
    private weak var gripStrip: HandleStripView?
    private var pinchGR: UIPinchGestureRecognizer!
    private var pinchBase: CGFloat = 0
    /// What the pane knew when the latest touch went down: a tap is decided on this, not on
    /// what the tap itself has changed by the time it is recognized.
    private var touch = (keyboardUp: false, hadSelection: false, stopsScroll: false)
    /// Copy and Paste at the selection, after a long press.
    private lazy var editMenu = UIEditMenuInteraction(delegate: self)
    private var menuTarget: CGRect?
    /// SELECTION UI: the loupe, handles, haptics, double and triple tap (Selection/, docs/selection.md).
    private var selectionUI: TerminalSelectionController!
    /// A long-press or pointer selection drag is under way: nothing else may scroll or swipe.
    private var selecting = false { didSet { if selecting != oldValue { updateJumpButton() } } }
    private var pinching = false { didSet { if pinching != oldValue { updateJumpButton() } } }
    private var pointerSelectGR: UIPanGestureRecognizer!
    private var twoTapGR: UITapGestureRecognizer!
    /// The latest touch came from a mouse or trackpad (its drags select instead of scrolling).
    private var touchIsPointer = false

    // Hardware keys.
    private var cachedCommands: (generation: Int, findEditing: Bool, commands: [UIKeyCommand])?
    /// Repeats a held key that a binding took from the engine. Tests put their own here.
    var keyRepeat = KeyRepeater()

    /// A Ghostty snapshot being received.
    private var snapshot = SnapshotBuffer()
    /// Asks before a paste that could run a command. Nil: an alert. Tests put their own here.
    var confirmPaste: ((String, @escaping @MainActor (Bool) -> Void) -> Void)?

    private var backgroundedAt: CFTimeInterval?
    /// Transient chips wait until this time: in the background (infinity), and for the wake's grace
    /// after it, while the connection is made again (`ForegroundWake`). The title bar says so then.
    private var quietUntil: CFTimeInterval = 0
    /// The transient chip that is up or waiting to show, so a return can wait for it again.
    private var transientStatus: String?
    /// Transient states (connecting, reconnecting) show only if they last this long.
    static let statusDelay: TimeInterval = 1.0
    private var statusWork: DispatchWorkItem?
    /// A fence still up after this long says "Reconnecting…". Tests shorten it.
    var fenceStatusDelay: TimeInterval = 2.5
    private var fenceStatusWork: DispatchWorkItem?
    private static let reconnectingText = "Reconnecting…"
    /// The pane holds its screen while its stream catches up, until the server's size is known
    /// to be the one it shows (`streamFence`, `streamResized`).
    private var holdsForCatchUp = false
    /// The frame on show as the app left, kept at its grid until the return has caught up.
    private var away = AwayFrame()
    /// Under this hold a resize of ours was answered, and the stream said a size that does not
    /// fit: the two together mean the reflow and the program's redraw are still to come in the
    /// stream, so a size report that fits is the resize's echo and not a pane that opens at the
    /// size it will keep (`streamResized`). Of one hold: cleared when a hold begins or ends.
    private var resizedUnderHold = false
    private var otherSizeUnderHold = false
    /// Glide, while the pane has nothing to draw yet (`GlideLoader`). Nil once it has a screen.
    private(set) var loader: GlideLoader?
    /// The pane has been given a screen: a restored snapshot or a screen read.
    private var hasScreen = false
    /// A pane that opens says "Connecting…" under its loader, and only after this long.
    var connectingDelay: TimeInterval = 2.5
    /// Reduce Motion. Tests put their own here.
    var reduceMotion: () -> Bool = { UIAccessibility.isReduceMotionEnabled }
    var loaderTiming = GlideLoaderTiming()
    /// Our own resize has come back in the stream since the claim was last asked for.
    private var ownResizeSeen = false
    /// The next claim takes the pane before it sizes it (`FitClaim.request(reassert:)`): set
    /// at every claim moment, when the pane comes on screen, the app comes back, or the user
    /// taps to fit.
    private var reassertNext = true
    /// The pane's owner as the session's view last said; nil when unknown or when the server has
    /// no owners. Read only by `checkFit`.
    var blockOwner: (() -> String?)?
    /// Writes a line about this pane's computer into the connection log (`ownerChanged`,
    /// `resizedElsewhere`). Nil where there is no log.
    var note: ((ConnectionEvent) -> Void)?

    // Predicted echo (Predict/TerminalHost+Predict.swift).
    /// Whether an agent runs in the pane, and the program in front, as the server's metadata
    /// says now. Read for each input call while predictions are on, never otherwise. Without it
    /// no key is ever a guess.
    var echoContext: (@MainActor () -> (agent: Bool, foreground: String?))?
    /// The level the server's gate wants for this pane.
    var echoWanted = EchoLevel.off
    /// The watch on the server's gate; it ends itself once the host is gone.
    var echoWatch: EchoGateWatch?
    /// The foreground program at the last input call, to tell the core when it changes. Nil
    /// until the first input call heard: that one is where the watch starts, not a change.
    var echoForeground: String??
    /// The view is scrolled into the history (`scrollPlace`).
    var isScrolledBack: Bool { scrollPlace.rowsAbove > 0 }
    /// This client's id, for `blockOwner` and the `owner` of a size; nil: the control
    /// connection's. Tests put their own here.
    var ownClientID: (() -> String?)?
    /// How long after a claim's answer, a size from the stream or the fence coming down the
    /// pane looks at whether it shows the grid it fits (`checkFit`). Tests shorten it.
    var fitCheckDelay: TimeInterval = 1
    private var fitCheckWork: DispatchWorkItem?
    /// `checkFit` claimed once already, and the server's grid hasn't matched since.
    private var fitGuardUsed = false
    /// `stop()` is ending the stream: its fence goes without the stream having caught up.
    private var stoppingStream = false
    private static let lostText = "Resized on another screen · tap to fit this one"
    #if DEBUG
    /// `-forceStatus <text>` (Debug builds, testing): every pane shows this chip once it opens and
    /// again each time it is live, to look at the chip over any output.
    private static let forcedStatus = UserDefaults.standard.string(forKey: "forceStatus").flatMap { $0.isEmpty ? nil : $0 }
    #endif

    init(stream: TerminalStream, sizing: SizingMode, fontSize: CGFloat, theme: TermTheme, claim: FitClaim? = nil) {
        PerfProbe.active?.paneOpening()  // PERF: pane open, before the engine view is made
        self.stream = stream
        self.sizing = sizing
        self.fontSize = fontSize
        self.theme = theme
        term = GhosttyTerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 240), fontSize: fontSize)
        keyBar = KeyBar()
        self.claim = claim ?? FitClaim(transport: AttachGatedFitTransport(stream: stream))
        super.init(frame: .zero)
        appActive = UIApplication.shared.applicationState == .active
        self.claim.onClaimed = { [weak self] cols, rows in self?.claimed(cols: cols, rows: rows) }
        self.claim.onRefused = { [weak self] in self?.resizedElsewhere(.refused) }
        self.claim.reported = { [weak self] in self?.reportedSize }
        // Each welcome is counted, for as long as the host lives: a pane that kept its claim
        // through a drop looks at who has it once it is back (`FitTenure`).
        stream.control.observeConnected { [weak self] in
            guard let self else { return false }
            self.controlCameBack()
            return true
        }
        term.engineDelegate = self
        keyBar.terminal = term
        keyBar.onPaste = { [weak self] in self?.pasteFromClipboard() }
        keyBar.onHideKeyboard = { [weak self] in self?.hideKeyboard() }
        keyBar.onShortcut = { [weak self] press, isRepeat in self?.keyBarShortcut(press, isRepeat: isRepeat) ?? false }
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
        followEchoGate()
        // The data socket isn't read while megabytes wait to be parsed (`applyBackpressure`).
        // The core calls from the thread that crossed a mark, so the state is read on arrival.
        term.core.onBackpressureChange = { [weak self] in
            DispatchQueue.main.async { self?.applyBackpressure() }
        }

        NotificationCenter.default.addObserver(self, selector: #selector(didBackground),
                                               name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(willForeground),
                                               name: UIApplication.willEnterForegroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(fitHoldDeferralCleared(_:)),
                                               name: FitHoldDeferral.cleared, object: nil)
        // The program's focus follows the app coming to the front and leaving it (`PaneFront`).
        NotificationCenter.default.addObserver(self, selector: #selector(appBecameActive),
                                               name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appLeftFront),
                                               name: UIApplication.willResignActiveNotification, object: nil)
        // Moments when the keyboard may be free for the active pane to take (`reclaimKeyboard`).
        let free: [Notification.Name] = [.GCKeyboardDidConnect, UIApplication.didBecomeActiveNotification,
                                         UIWindow.didBecomeKeyNotification, UITextField.textDidEndEditingNotification,
                                         UITextView.textDidEndEditingNotification]
        for name in free {
            NotificationCenter.default.addObserver(self, selector: #selector(keyboardMayBeFree), name: name, object: nil)
        }
        term.keyHook = { [weak self] key in self?.handleKey(key) ?? false }
        term.keyboardFocusHook = { [weak self] focused in self?.keyboardFocusChanged(focused) }
        // Quiet, find's bar in the accessory slot, the key bar back: whatever swaps the accessory.
        term.inputAccessoryHook = { [weak self] in self?.refreshBarHidesKeyboard() }
        term.alternateScreenHook = { [weak self] alternate in self?.alternateScreenChanged(alternate) }
        term.readingHook = { [weak self] in self?.readingBegan() }
        term.scrollPlaceHook = { [weak self] place in self?.scrollPlaceChanged(place) }
        // A program may write the pasteboard (OSC 52) only from the pane the user works in.
        term.setProgramClipboardGate { [weak self] in self?.isFrontPane ?? false }
        // The pane shows its own focus (cursor, border): no system focus halo on top of it.
        term.focusEffect = nil
        setupGestures()
        // Over the selection handles (it hides while there is a selection), under the status chip.
        jumpButton.onFire = { [weak self] in self?.jumpToBottom() }
        insertSubview(jumpButton, belowSubview: statusLabel)
        #if DEBUG
        if let s = Self.forcedStatus { showStatus(s) }  // `-forceStatus` (testing)
        #endif
        PerfProbe.active?.paneOpened(self)  // PERF
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Gestures

    var fitted: Bool { sizing == .fit && !lostOwnership }

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

        gripPan.maximumNumberOfTouches = 1
        gripPan.delegate = self
        addGestureRecognizer(gripPan)

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
        // The controller shows or hides the menu whenever it makes or drops a selection, which
        // is also when the jump-to-bottom button has to look again.
        ui.presentMenu = { [weak self] rect in
            self?.presentEditMenu(at: rect)
            self?.updateJumpButton()
        }
        ui.dismissMenu = { [weak self] in
            self?.editMenu.dismissMenu()
            self?.updateJumpButton()
        }
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
        updateJumpButton()
    }

    /// Mostly-horizontal motion of a pan that is about to begin.
    private func isHorizontal(_ pan: UIPanGestureRecognizer) -> Bool {
        var d = pan.translation(in: self)
        if abs(d.x) + abs(d.y) < 1 { d = pan.velocity(in: self) }
        return TerminalScrollTouch.isHorizontal(dx: d.x, dy: d.y)
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
        // A drag that catches moving scrollback goes on scrolling it.
        if term.touchStopsScroll(now: CACurrentMediaTime()) { return false }
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
        if g === pinchGR { return TerminalPinch.starts(selecting: selecting) }
        if g === twoTapGR { return onCommand != nil && !selecting }
        if g === gripPan { return gripShouldBegin() }
        return true
    }

    // MARK: Handle strips

    /// Notes the handle strip a touch at `point` (window coordinates) starts in, for the grip's
    /// rules until the next touch, and returns it. Nil outside every strip over this pane.
    @discardableResult
    func noteGripTouch(at point: CGPoint) -> HandleStripView? {
        gripStrip = handleStrips?.strip(at: point, over: self)
        return gripStrip
    }

    /// The grip starts on a drag across its strip only: a drag along it is the pane's scroll.
    private func gripShouldBegin() -> Bool {
        guard let strip = gripStrip, !selecting else { return false }
        var d = gripPan.translation(in: self)
        if abs(d.x) + abs(d.y) < 1 { d = gripPan.velocity(in: self) }
        return HandleStrips.claims(dx: d.x, dy: d.y, sideways: strip.sideways)
    }

    /// Whether the pane's recognizer `other` waits for the grip to fail on the latest touch: its
    /// one-finger taps and its drags, while the touch started in a strip. A long press, a pinch
    /// and a two-finger tap never wait: a held finger never starts the grip.
    func waitsForGrip(_ other: UIGestureRecognizer) -> Bool {
        guard gripStrip != nil, other !== gripPan, other.view?.isDescendant(of: self) == true else { return false }
        if other is UIPanGestureRecognizer { return true }
        if let tap = other as? UITapGestureRecognizer { return tap.numberOfTouchesRequired == 1 }
        return false
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        g === gripPan && waitsForGrip(other)
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if g === gripPan { gripStrip = nil }
        // A touch on the jump-to-bottom button is the button's alone: it is no tap, swipe or
        // pinch on the pane, and it doesn't count as the pane's latest touch.
        if touch.view?.isDescendant(of: jumpButton) == true { return false }
        // The find bar's touches are its own too.
        if let f = finder, touch.view?.isDescendant(of: f.overlay) == true { return false }
        if g === gripPan { return noteGripTouch(at: touch.location(in: nil)) != nil }
        // Every touch on the pane passes the focus tap first: remember whether it is a pointer.
        if g === tapGR {
            self.touch = (keyboardUp, term.hasActiveSelection, term.touchStopsScroll(now: CACurrentMediaTime()))
            touchIsPointer = touch.type == .indirectPointer
            // SELECTION UI: a long press may follow; wake the haptics now so its start has no lag.
            if !touchIsPointer { selectionUI.touchDown() }
        }
        return true
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // The grip runs beside the handle's own drag (outside the pane), never beside the pane's.
        if g === gripPan || other === gripPan {
            let peer = g === gripPan ? other : g
            return peer.view?.isDescendant(of: self) != true
        }
        // The focus tap observes; it must never cancel the engine's taps, selection or our swipe.
        return g === tapGR || other === tapGR
    }

    /// A single-finger tap. What it does is decided once, in order, by `TerminalTapDecision`,
    /// from what the pane knew when the finger went down.
    @objc private func tapped() {
        tap(at: tapGR.location(in: term), shift: tapGR.modifierFlags.contains(.shift),
            keyboardUp: touch.keyboardUp, hadSelection: touch.hadSelection, stopsScroll: touch.stopsScroll)
    }

    /// Decides a tap at `point` (engine view coordinates) and does the one thing it means.
    @discardableResult
    func tap(at point: CGPoint, shift: Bool, keyboardUp: Bool, hadSelection: Bool,
             stopsScroll: Bool = false) -> TerminalTapOutcome {
        userActs += 1
        // SELECTION UI: handles, and which tap of a double or triple tap this is.
        let counted = selectionUI.countTap(at: point)
        // `isActive` is still what it was at touch time: `onFocus` comes after the decision.
        let facts = TerminalTapFacts(onHandle: counted.onHandle, tapCount: counted.count, keyboardUp: keyboardUp,
                                     hadSelection: hadSelection, shift: shift, menuVisible: selectionUI.menuVisible,
                                     stopsScroll: stopsScroll, active: isActive, voiceOver: voiceOver())
        let outcome = TerminalTapDecision.outcome(
            facts,
            // TAP HOOK (links): with the keyboard down, a link still opens and the keyboard stays.
            opensLink: { term.tapOpensLink(at: point) },
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
        case .programClickThenKeyboard:
            editMenu.dismissMenu()
            // The keyboard waits for the click: it resizes a fitted pane on the alternate
            // screen, and the server does not order that resize with the click's write. A
            // click that could not go (the fence, no connection, a row of the scrollback)
            // still brings the keyboard: no tap is a dead one.
            let serial = userActs, began = CACurrentMediaTime()
            term.sendClickToProgram(at: point) { [weak self] _ in self?.showKeyboardAfterClick(serial: serial, since: began) }
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
            userActs += 1
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
        // A selection that names a file: Open brings it from the pane's computer into Quick Look.
        // Only a small one is read as text here, on the main thread (`PathGuess.isSmall`).
        if term.hasActiveSelection, files?.canOpen == true, let e = term.core.selectionExtent,
           PathGuess.isSmall(rows: e.endRow - e.startRow + 1, cols: e.cols, startCol: e.startCol, endCol: e.endCol,
                             clipped: e.startClipped || e.endClipped),
           let text = term.selectedText, files?.openablePath(in: text) != nil {
            items.append(UIAction(title: "Open File", image: UIImage(systemName: "doc.viewfinder")) { [weak self] _ in
                guard let self else { return }
                self.clearSelection()
                self.files?.open(selection: text)
            })
        }
        // A one-row selection of at most 200 bytes can be searched for. The row count is read
        // before the text, which is read on the main thread.
        if term.hasActiveSelection, let e = term.core.selectionExtent, e.startRow == e.endRow,
           let text = term.selectedText, !text.isEmpty, text.utf8.count <= 200 {
            items.append(UIAction(title: "Find Selection", image: UIImage(systemName: "magnifyingglass")) { [weak self] _ in
                guard let self else { return }
                self.onFocus?()
                self.clearSelection()
                self.openFind(text: text, focus: true)
            })
        }
        if UIPasteboard.general.hasStrings || [.files, .image].contains(files?.pasteChoice) {
            items.append(UIAction(title: "Paste", image: UIImage(systemName: "doc.on.clipboard")) { [weak self] _ in
                guard let self else { return }
                self.clearSelection()
                self.pasteFromClipboard()
            })
        }
        // Beside Paste, which keeps pasting text: an image or copied files on the clipboard can be
        // sent even when it also holds text (an image copied from Safari carries its address).
        if let title = files?.pasteFileTitle {
            items.append(UIAction(title: title, image: UIImage(systemName: "photo.on.rectangle")) { [weak self] _ in
                guard let self else { return }
                self.clearSelection()
                self.files?.pasteFiles()
            })
        }
        // SELECTION UI: Select All, with handles to pull it back in from.
        items.append(UIAction(title: "Select All", image: UIImage(systemName: "character.textbox")) { [weak self] _ in
            guard let self else { return }
            self.selectionUI.selectAll(showsMenu: false)
            self.updateJumpButton()
            // Once this menu has gone: Copy for what is selected now.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.selectionUI.showMenu() }
        })
        // The selection as plain text, through the share sheet. Formatted off the main thread; the
        // selection goes once the sheet is up.
        if term.hasActiveSelection, let share {
            items.append(UIAction(title: "Share…", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
                guard let self else { return }
                share.shareSelection(at: self.menuTarget) { [weak self] in self?.clearSelection() }
            })
        }
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

    /// Pinch: live preview by scaling, then one font change (and one resize claim) at the end. The size
    /// is stored in every state; a pinch on a pane resized elsewhere also fits it here (`TerminalPinch`).
    @objc private func pinched(_ g: UIPinchGestureRecognizer) {
        switch g.state {
        case .began:
            pinchBase = fontSize
            pinching = true
        case .changed:
            let k = clampFont(pinchBase * g.scale) / fontSize
            let p = g.location(in: self)
            let d = CGPoint(x: p.x - bounds.midX, y: p.y - bounds.midY)
            zoomer.transform = CGAffineTransform(translationX: d.x, y: d.y).scaledBy(x: k, y: k).translatedBy(x: -d.x, y: -d.y)
        case .ended:
            pinching = false
            zoomer.transform = .identity
            zoomer.frame = bounds
            let out = TerminalPinch.outcome(pinchState, base: Double(pinchBase), scale: Double(g.scale))
            if let s = out.size {
                setFontSize(CGFloat(s))
                Prefs.shared.fontSize = s
            }
            if out.fitHere { fitHere() }
        default:
            pinching = false
            zoomer.transform = .identity
            zoomer.frame = bounds
        }
    }

    private var pinchState: TerminalPinch.PaneState {
        sizing == .mirror ? .mirror : lostOwnership ? .resizedElsewhere : .fitted
    }

    private func clampFont(_ s: CGFloat) -> CGFloat { min(max(s, Self.fontRange.lowerBound), Self.fontRange.upperBound) }

    // MARK: Hardware keyboard

    /// ⌘ shortcuts, titled for the shortcut overlay shown while ⌘ is held. Keys without ⌘ (ctrl+tab,
    /// shift+enter, …) are caught in `handleKey` instead, before the engine turns them into bytes.
    override var keyCommands: [UIKeyCommand]? {
        guard let keymap else { return nil }
        // While the pane's find field edits, only app commands and the find keys stay, and no key
        // that edits text: those are the field's (an allowlist, so a new pane action stays out).
        let editing = findFieldHoldingKeyboard != nil
        if let c = cachedCommands, c.generation == keymap.generation, c.findEditing == editing { return c.commands }
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
            // The first binding on a key that the app can perform runs; one it can't falls through.
            guard let action = keymap.action(b) else { continue }
            decided.insert(b.chord)
            if editing, !FindKeys.keepsWhileEditing(action: action, chord: b.chord) { continue }
            guard let input = KeyInput.commandInput(b.chord) else { continue }
            add(KeyActions.title(b), input, KeyInput.flags(b.chord.mods), b.chord.spelling,
                physical: b.chord.isPhysical, repeats: KeyActions.repeats(b.action))
        }
        // The Edit menu's keys, as on the Mac (unless the keymap took them). Not while the find
        // field edits: they are its own.
        if !editing {
            add("Copy", "c", .command, "edit:copy", physical: false, repeats: false)
            add("Paste", "v", .command, "edit:paste", physical: false, repeats: false)
            add("Select All", "a", .command, "edit:selectAll", physical: false, repeats: false)
        }
        cachedCommands = (keymap.generation, editing, out)
        return out
    }

    @objc private func keyCommandFired(_ sender: UIKeyCommand) {
        // Under the board a pane that kept a hardware keyboard takes no ⌘ shortcut either:
        // UIKit finds these on the responder chain, past `pressesBegan`'s check.
        guard !covered, let payload = sender.propertyList as? String else { return }
        switch payload {
        case "edit:copy": perform(.copy, press: nil)
        case "edit:paste": perform(.paste, press: nil)
        case "edit:selectAll": perform(.selectAll, press: nil)
        default:
            guard let chord = KeyChord(spelling: payload), let (_, action) = keymap?.resolve([chord]) else { return }
            perform(action, press: nil)
        }
    }

    /// A hardware key press, before the engine sees it (`keyHook`). True when a binding ran (the key doesn't reach the
    /// terminal). Only keys the keymap binds are taken; every other key is typed as usual.
    private func handleKey(_ key: UIKey) -> Bool {
        onKeyPress?()
        // A sheet, an alert or a menu covers the pane: the key is not for it. (The pane gives
        // the keyboard up when it is covered, `coverChanged`; this catches a cover that came
        // without that.)
        if KeyboardFocusPolicy.sheetUp(in: window) || covered {
            stopKeyRepeats()
            return true
        }
        guard let keymap, !KeyInput.isModifierKey(key.keyCode) else { return false }
        let press = KeyInput.Press(key)
        guard let (binding, action) = keymap.resolve(press: press) else { return false }
        perform(action, press: press)
        if KeyActions.repeats(binding.action) {
            keyRepeat.start(usage: key.keyCode.rawValue, timing: .command, while: { [weak self] in self?.mayRepeatKeys ?? false }) {
                [weak self] in self?.perform(action, press: press)
            }
        }
        return true
    }

    /// The key bar's ⌘ with the next key: the press a hardware keyboard would report for it runs
    /// through the same lookup and the same actions as `handleKey`. False when nothing is bound
    /// (nothing is sent). A held bar key (`isRepeat`) runs again only where a held hardware key would.
    func keyBarShortcut(_ press: KeyInput.Press, isRepeat: Bool) -> Bool {
        // Under the board no shortcut is this pane's.
        guard !covered else { return false }
        guard let keymap, let (binding, action) = keymap.resolve(press: press) else { return false }
        if !isRepeat || KeyActions.repeats(binding.action) { perform(action, press: press) }
        return true
    }

    /// A held key repeats only in the active pane, on screen, while it has the keyboard and
    /// nothing covers it. (`KeyRepeater` adds the app's state, the key's own state and a limit.)
    private var mayRepeatKeys: Bool {
        isActive && window != nil && term.isFirstResponder && !covered && !KeyboardFocusPolicy.sheetUp(in: window)
    }

    /// Ends every key repeat of this pane: the host's (bound keys) and the engine's.
    private func stopKeyRepeats() {
        keyRepeat.stop()
        term.stopKeyRepeat()
    }

    private func perform(_ action: AppAction, press: KeyInput.Press?) {
        switch action {
        case .command(.find(let step)):
            // This pane's own find.
            performFind(step)
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
        case .files(let command):
            // Where the pane's host doesn't have it, the key does nothing.
            files?.run(command)
        case .selectAll:
            selectionUI.selectAll(showsMenu: false)  // SELECTION UI: with handles
            updateJumpButton()
        case .pageUp:
            term.scrollPage(up: true)
        case .pageDown:
            term.scrollPage(up: false)
        case .promptPrevious:
            term.scrollToPrompt(next: false)
        case .promptNext:
            term.scrollToPrompt(next: true)
        case .server(let name, let args):
            let ended = onServerRun?(name, keymap?.title(forAction: name) ?? name)
            stream.perform(action: name, args: args, ended: ended) { [weak self] queued in
                // A configuration-file action may ask this client to perform its own actions.
                self?.performQueued(queued)
            }
        case .forwardKey:
            if let press { stream.forward(key: KeyInput.clientKeyEvent(press)) }
        }
    }

    /// Performs the client actions an action asked for (`rex.client.queue`), as their keys would.
    /// Returns how many it skipped: names it doesn't know, and server actions.
    @discardableResult
    private func performQueued(_ queued: [JSONObject]) -> Int {
        var skipped = 0
        for q in queued {
            guard let n = q.str("action"), let a = AppAction.resolve(n, q.obj("args"), panes: keymap?.panes ?? .none) else {
                skipped += 1
                continue
            }
            if case .server = a { skipped += 1; continue }
            perform(a, press: nil)
        }
        return skipped
    }

    /// A pane action from the palette (Paste into Pane, a bound Send Key, …): exactly what its key
    /// runs, so typed bytes take the same input queue.
    func performFromPalette(_ action: AppAction) { perform(action, press: nil) }

    /// Text is selected in the terminal: Copy from Pane has something to copy.
    var hasSelection: Bool { term.hasActiveSelection }

    /// Runs a Lua or block action on this pane from the palette (`origin: palette`): behind the
    /// keys typed before it, never later than now (`TerminalStream.perform`). `ended` hears how
    /// its `client.action` ended; `skipped` how many of the client actions it asked for this app
    /// doesn't have.
    func runFromPalette(_ name: String, args: JSONObject?, title: String,
                        ended: @escaping @MainActor (Bool) -> Void, skipped: @escaping @MainActor (Int) -> Void) {
        stream.perform(action: name, args: args, origin: .palette, title: title, ended: ended) { [weak self] queued in
            skipped(self?.performQueued(queued) ?? 0)
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
            holdsKeyboard: term.isFirstResponder || findFieldHoldingKeyboard != nil, hardwareKeyboard: hardwareKeyboard(),
            hadKeyboard: hadKeyboard, userHidKeyboard: userHidKeyboard,
            sheetUp: covered || KeyboardFocusPolicy.sheetUp(in: window),
            holder: KeyboardFocusPolicy.holder(UIResponder.rexCurrentFirstResponder(), own: term, ownFields: ownFindFields))
    }

    /// The terminal has the keyboard and shows it (the system keyboard or the key bar).
    var keyboardUp: Bool { term.isFirstResponder && !keyboardQuiet }

    /// The pane the user is working in: active, on screen, in the app in front, with nothing
    /// lying over it (`PaneFront`). The program's focus and its right to write the pasteboard
    /// both follow it.
    var isFrontPane: Bool { window != nil && hasProgramFocus }

    /// The same for the program's focus, with one difference: a pane out of its window for a
    /// moment (a fold) is still on screen to its program (`leftScreen`).
    var hasProgramFocus: Bool {
        PaneFront(active: isActive, onScreen: !leftScreen && !isParked, appActive: appActive,
                  underBoard: covered, underSheet: dimmed, underPalette: underPalette).isFront
    }

    /// Tells the engine whether this is the front pane now; a program that asked for focus
    /// reports hears of a change (`GhosttyTerminalView.setProgramFocus`). Called at every
    /// moment the answer can change: the pane becomes active or stops being it, comes back on
    /// screen or has left it for good, the app comes to the front or leaves it, and a cover
    /// (the board, a sheet, the palette) comes or goes. The keyboard is not one of them.
    ///
    /// A pane that leaves its window says so only once it has stayed away (`scheduleStop`) or
    /// another pane came to the front (`leftForAnother`): a fold moves the pane through no
    /// window for a moment, and the program is not told of that.
    func refreshProgramFocus() {
        let front = hasProgramFocus
        let came = front && !term.programFocus.front
        term.setProgramFocus(front)
        if came { onCameToFront?() }
    }

    /// Another pane came to the front (`TerminalHostPool`). A pane that is out of its window
    /// then has left for good, a tab switch and not a fold: its program loses the focus now,
    /// not when the pane has stayed away.
    func leftForAnother() {
        guard window == nil, !leftScreen else { return }
        leftScreen = true
        refreshProgramFocus()
    }

    @objc private func appBecameActive() { appActiveChanged(true) }
    @objc private func appLeftFront() { appActiveChanged(false) }

    /// The app came to the front, or is leaving it.
    func appActiveChanged(_ active: Bool) {
        guard active != appActive else { return }
        appActive = active
        refreshProgramFocus()
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
        // Cheap checks first: this runs for every pane on every notification. The pane's own find
        // field holding the keyboard counts as holding it.
        guard isActive, window != nil, !term.isFirstResponder, findFieldHoldingKeyboard == nil else { return }
        // Later: the view may still be on its way into the window, or the app into the foreground.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // The palette showed this pane with the keyboard up: it takes it, as it was.
            if self.isActive, self.window != nil, !self.term.isFirstResponder, !self.covered,
               !KeyboardFocusPolicy.sheetUp(in: self.window), let quiet = self.takeOwedKeyboard?() {
                self.setKeyboardQuiet(quiet)
                _ = self.term.becomeFirstResponder()
                return
            }
            guard KeyboardFocusPolicy.takesKeyboard(self.keyboardSituation) else { return }
            if afterMove, !self.moveRetakes.allows(at: CACurrentMediaTime()) {
                // The layout keeps moving this pane as it takes the keyboard: leave the keyboard down.
                self.movedWithKeyboardAt = -10
                return
            }
            // A fold moved the pane while its overlay find field had the keyboard: the field gets it back.
            if afterMove, self.findRetakesAfterMove() { return }
            self.setKeyboardQuiet(KeyboardFocusPolicy.takesQuietly(self.keyboardSituation))
            _ = self.term.becomeFirstResponder()
        }
    }

    /// The pane stopped being the active one: it must not keep the keyboard, or keys would go
    /// to a pane the user has left.
    private func resignIfInactive() {
        // A find field of this pane gives it up too; its bar, needle and matches stay.
        resignFindFieldIfInactive()
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
            findHandOverAbandoned()
        }
        refreshBarHidesKeyboard()
    }

    /// Works `barHidesKeyboard` out again, and says when it changed.
    private func refreshBarHidesKeyboard() {
        let up = keyBar.hidesInVerticalBar && term.isFirstResponder && term.inputAccessoryView === keyBar
        guard up != barHidesKeyboard else { return }
        barHidesKeyboard = up
        onBarHidesKeyboard?(up)
    }

    /// Being first responder and showing a keyboard are two things. Quiet: the terminal's input
    /// view is an empty one and it has no key bar, so as first responder it gets hardware keys
    /// and nothing shows. Not quiet: the system keyboard and the key bar.
    func setKeyboardQuiet(_ quiet: Bool) {
        guard quiet != keyboardQuiet else { return }
        keyboardQuiet = quiet
        term.inputView = quiet ? quietInputView : nil
        term.inputAccessoryView = quiet ? nil : keyBar
        // The system keyboard comes up: it reads the pane's aids now (`TypingAids`).
        if !quiet { term.takeTypingAids() }
        if term.isFirstResponder { term.reloadInputViews() }
    }

    /// A tap on the pane: the keyboard comes up, also after the hide key.
    private func showKeyboard() {
        userHidKeyboard = false
        setKeyboardQuiet(false)
        if !term.isFirstResponder { _ = term.becomeFirstResponder() }
    }

    /// The click of a tap with the keyboard down is with the program, or never will be: the
    /// keyboard comes up as for any tap. Not when the answer took too long to still be that
    /// tap's, when the user did something else to the pane since, or when the pane is no
    /// longer the front pane or lies under a sheet.
    private func showKeyboardAfterClick(serial: Int, since began: CFTimeInterval) {
        guard serial == userActs, CACurrentMediaTime() - began <= clickKeyboardLimit,
              isFrontPane, !KeyboardFocusPolicy.sheetUp(in: window) else { return }
        showKeyboard()
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
        // Only a change counts: this is also called for a tint change that is no cover.
        if covered != dimmed {
            dimmed = covered
            refreshProgramFocus()
        }
        if covered {
            stopKeyRepeats()
            // The find field's keyboard is treated like the terminal's.
            if findFieldCovered() {
                resignedUnderCover = true
                return
            }
            guard term.isFirstResponder else { return }
            resignedUnderCover = true
            _ = term.resignFirstResponder()
        } else if findRetakesAfterCover() {
            resignedUnderCover = false
        } else if resignedUnderCover {
            resignedUnderCover = false
            // It had the keyboard: the policy lets it take it back without a hardware keyboard.
            movedWithKeyboardAt = CACurrentMediaTime()
            reclaimKeyboard()
        }
    }

    /// The agent board covers the pane, or uncovers it (`TerminalHostPool.setCovered`). Covered,
    /// the pane draws nothing, gives up the keyboard and can't take it, and takes no key. It
    /// keeps its stream and its size on the Mac: nothing is claimed, resized or given back, also
    /// when the layout under the board changes (`layoutTerminal`).
    ///
    /// Uncovered, the pane is as it was. A software keyboard that was up (`softwareKeyboard`, or
    /// no hardware keyboard to type with) stays down, as after the hide key. A pane that showed
    /// only its key bar, for a hardware keyboard, gets the keyboard and the bar back, so its
    /// size is the one from before.
    func setCovered(_ c: Bool, softwareKeyboard: Bool = false) {
        guard c != covered else { return }
        covered = c
        refreshProgramFocus()
        uncoverRelayout?.cancel()
        uncoverRelayout = nil
        if c {
            stopKeyRepeats()
            coverTookKeyBar = false
            // The find field's keyboard counts as the terminal's: the key bar of a hardware
            // keyboard comes back with it, a software keyboard stays down.
            if let place = findFieldHoldingKeyboard, place == .accessory {
                if softwareKeyboard || !hardwareKeyboard() {
                    userHidKeyboard = true
                } else {
                    coverTookKeyBar = true
                    _ = findFieldCovered()
                }
                resignFindField()
            } else if findFieldHoldingKeyboard == .overlay {
                // Quiet, as the terminal would be: it keeps the keyboard and takes no key covered.
                yieldOverlayFieldToTerminal()
            }
            // A pane that holds the keyboard quietly shows nothing and keeps it: covered, it
            // takes no key anyway (`GhosttyTerminalView.covered`).
            if keyboardUp {
                if softwareKeyboard || !hardwareKeyboard() {
                    userHidKeyboard = true
                } else {
                    coverTookKeyBar = true
                }
                _ = term.resignFirstResponder()
            }
            term.covered = true
            layoutFind()
        } else {
            term.covered = false
            layoutFind()
            // Only the key bar of a hardware keyboard comes back by itself. Anything else
            // waits for a tap, or for the next moment a pane looks for the keyboard.
            if coverTookKeyBar {
                coverTookKeyBar = false
                movedWithKeyboardAt = CACurrentMediaTime()
                // The find field that had it gets it back, in the accessory slot as before.
                if !findRetakesAfterCover() { reclaimKeyboard() }
            }
            // A pane first laid out under the board has claimed nothing yet: it starts now.
            if !started {
                lastBounds = .zero
                setNeedsLayout()
            }
            // Once the keyboard is back where it was: fit again if the pane's room changed under
            // the board (a rotation). Before that, the layout is still the one without a key bar.
            let relayout = DispatchWorkItem { [weak self] in
                guard let self, !self.covered, self.window != nil else { return }
                self.lastBounds = .zero
                self.setNeedsLayout()
            }
            uncoverRelayout = relayout
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.uncoverSettle, execute: relayout)
        }
    }

    /// The engine view is about to move to another superview or leave the window: note whether it
    /// has the keyboard, to take it back where it lands. UIKit resigns it first, so a keyboard lost
    /// in this same turn of the run loop counts.
    func noteKeyboardBeforeMove() {
        let now = CACurrentMediaTime()
        let field = noteFindFieldBeforeMove(now: now)
        if term.isFirstResponder || now - lostKeyboardAt < 0.05 || field { movedWithKeyboardAt = now }
    }

    /// The key bar's hide key, or the vertical bar's Hide Keyboard in its place
    /// (`HideKeyboardItem`): the keyboard and the bar go away until the next tap on the pane.
    /// With a hardware keyboard the terminal stays first responder, quietly, so its keys still
    /// type into this pane; without one there is nothing left to type with and it resigns.
    func hideKeyboard() {
        userActs += 1
        userHidKeyboard = true
        if hardwareKeyboard() {
            setKeyboardQuiet(true)
        } else {
            _ = term.resignFirstResponder()
        }
    }

    /// A drag took the view into the scrollback while the software keyboard covers it: the user
    /// is reading, so the keyboard goes away as with the hide key, and a tap brings it back.
    /// Nothing on screen moves: the rows the keyboard covered come into view below.
    private func readingBegan() {
        guard keyboardUp, !selecting else { return }
        hideKeyboard()
    }

    // MARK: App state

    /// Hand fitted panes back to the Mac while the app is in the background.
    @objc private func didBackground() {
        backgroundedAt = CACurrentMediaTime()
        quietUntil = .infinity
        // Said when the app left the front; again here for a background that came without it.
        appActiveChanged(false)
        stopKeyRepeats()
        // Also when nothing is claimed yet: a claim on its way must not resize the pane now.
        claimedSize = nil
        releaseClaim()
        // The Mac's size can come while the app still runs here: the screen the user saw stays
        // on show at its own grid, never stretched to another (`AwayFrame`).
        if away.left(showing: localGrid, hasScreen: hasScreen, inWindow: window != nil) { term.holdWhileAway() }
    }

    @objc private func willForeground() {
        // The socket may have died while the app was suspended. The stream checks it and, if it
        // has, resumes where it stopped (no new snapshot), so the screen on show stays until then.
        if backgroundedAt != nil, started, window != nil {
            quietUntil = CACurrentMediaTime() + ForegroundWake.grace(expensive: stream.control.onExpensivePath)
            stream.wake()
            PerfProbe.active?.mounted(self, kind: .resumed)  // PERF
        } else {
            quietUntil = 0
        }
        // The kept frame stays while the stream catches up behind its fence, and goes now if
        // there is nothing to catch up.
        if away.returned(catchingUp: holdsForCatchUp) { endAway() }
        // A "Reconnecting…" from while the app was away waits out the grace like a new one.
        if let s = transientStatus {
            statusWork?.cancel()
            statusWork = nil
            statusLabel.isHidden = true
            scheduleTransient(s, after: Self.statusDelay)
        }
        backgroundedAt = nil
        guard window != nil, sizing == .fit, !lostOwnership else { return }
        // The claim was given back as the app left; another client may have the pane now.
        reassertNext = true
        lastBounds = .zero
        setNeedsLayout()
    }

    /// Tapping the "another device has this pane" chip takes the pane back.
    @objc private func statusTapped() { fitHere() }

    /// Takes back a pane another client resized and fits it to this view: the chip, and a pinch
    /// on such a pane.
    private func fitHere() {
        guard sizing == .fit, lostOwnership else { return }
        lostOwnership = false
        hideStatus()
        claimedSize = nil
        fitGuardUsed = false
        reassertNext = true
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
        let chip = StatusChipStyle(theme: t)
        statusLabel.backgroundColor = chip.fill
        statusLabel.textColor = chip.text
        statusLabel.layer.borderColor = chip.rim.cgColor
        keyBar.apply(theme: t)
        applyFindTheme(t)
        jumpButton.apply(tint: t.uiFG, accent: t.uiCursor)
        loader?.apply(tint: t.uiFG)
        selectionUI?.apply(tint: t.uiCursor, rim: t.uiBG)  // SELECTION UI (nil during init)
    }

    /// What the key bar lays itself out around: the system's vertical bar's column in screen
    /// coordinates (nil where bars are horizontal) and a vertical crease in window coordinates
    /// (nil without one). With the column, the bar's hide key is the vertical bar's.
    func setKeyBarSurroundings(barColumn: CGRect?, crease: CGRect?) {
        keyBar.barColumn = barColumn
        keyBar.crease = crease
        setFindSurroundings(barColumn: barColumn, crease: crease)
        refreshBarHidesKeyboard()
    }

    func setFontSize(_ s: CGFloat) {
        guard abs(s - fontSize) > 0.01 else { return }
        fontSize = s
        // A new font ends find's hold: the grid that fits changes anyway.
        releaseFitHold(deferrable: false)
        // The server's grid at the new cell size. The terminal keeps its modes and its content;
        // fit mode then claims the grid that fits now and the program redraws itself.
        term.setFont(size: s)
        applyLocalGrid(serverSize.0, serverSize.1, force: true)
        positionTerm()
        lastBounds = .zero
        setNeedsLayout()
    }

    /// How much of the pane's bottom a float sheet at its medium size leaves below the screen
    /// (`FloatSheet`). The bounds don't change, so the grid and the claim don't either; it covers
    /// the pane as the keyboard does, and the row the program writes on stays in view.
    func setSheetCover(_ points: CGFloat) {
        let c = max(0, points)
        guard abs(c - sheetCover) > 0.5 else { return }
        sheetCover = c
        positionTerm()
    }

    /// The pane's size with the software keyboard down (`restSize`).
    func setRestSize(_ size: CGSize?) {
        guard size != restSize else { return }
        restSize = size
        lastBounds = .zero
        setNeedsLayout()
    }

    /// The grid that fits depends on the screen the program is on (`fitSize`).
    private func alternateScreenChanged(_ alternate: Bool) {
        guard alternate != alternateScreen else { return }
        let fitted = fitGrid()
        alternateScreen = alternate
        if let f = finder { f.edge = alternate ? .top : .bottom }
        // With the keyboard down both screens fit the same grid, and there is nothing to lay
        // out again: a layout would ask for the size that is already on its way and start its
        // settle time over, so a pane that opens on the alternate screen had its fence up that
        // much longer. Find's hold covers by the screen, whatever the grid.
        guard fitGrid() != fitted else {
            if findHold != nil { positionTerm() }
            return
        }
        lastBounds = .zero
        setNeedsLayout()
    }

    func setSizing(_ m: SizingMode) {
        guard m != sizing else { return }
        sizing = m
        releaseFitHold(deferrable: false)
        if m == .mirror {
            claimedSize = nil
            releaseClaim()
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
            stream.setClaimPending(false)
            // Its tab was left for one whose pane is in front already: gone for good.
            if anotherIsFront?() == true { leftForAnother() }
            scheduleStop()
        } else {
            cancelStopWork()
            cancelGraceWork()
            if !started { PerfProbe.active?.mounted(self, kind: .cold) }  // PERF
            cameBackOnScreen()
            // Claim again what was paused, if the size still isn't the one that fits, and take
            // the pane first: another client may have it now.
            reassertNext = true
            lastBounds = .zero
            setNeedsLayout()
            yieldContentSwipeBack()
            // Moved by a fold or unfold while it had the keyboard, or a hardware keyboard is attached.
            reclaimKeyboard(afterMove: true)
            ports?.watch()
        }
    }

    /// Off screen: let go of the stream, unless the view is back on screen in a moment. A fold or an
    /// unfold rebuilds the layout around the pane and `PaneView` moves this view to its new place
    /// (`TerminalHostPool`), keeping the screen, the scrollback and the keyboard.
    ///
    /// A pane the pool keeps (`canPark`) parks instead of stopping, and keeps its fit claim for
    /// `claimGrace` from now.
    func scheduleStop() {
        cancelStopWork()
        // The item holds the pane until it has run: the pool may be the only owner, and the
        // stream must be stopped either way. Through `LeaveHold`, so that an item cancelled
        // before its time lets the pane go at once.
        let hold = LeaveHold(self)
        let work = DispatchWorkItem { hold.take()?.settledOffScreen() }
        stopWork = work
        stopHold = hold
        DispatchQueue.main.asyncAfter(deadline: .now() + leaveTiming.settle, execute: work)
        guard canPark, graceWork == nil else { return }
        // Held the same way: a pane that nobody stops is kept until its grace has run, so the
        // Mac gets its size back whatever became of the pane.
        let graceHold = LeaveHold(self)
        let grace = DispatchWorkItem { graceHold.take()?.claimGraceEnded() }
        graceWork = grace
        self.graceHold = graceHold
        DispatchQueue.main.asyncAfter(deadline: .now() + leaveTiming.claimGrace, execute: grace)
    }

    /// Off screen for `leaveTiming.settle` (`scheduleStop`).
    private func settledOffScreen() {
        stopWork = nil
        stopHold = nil
        guard window == nil else { return }
        // Gone for good, not moved by a fold: the program loses the focus, said while the
        // stream can still carry it.
        leftScreen = true
        refreshProgramFocus()
        if canPark, started {
            if let onLeft { onLeft() } else { park() }
        } else {
            stop()
            onStopped?()
        }
    }

    /// Off screen for `leaveTiming.claimGrace` (`scheduleStop`).
    private func claimGraceEnded() {
        graceWork = nil
        graceHold = nil
        guard window == nil else { return }
        // The Mac gets its size back; the pane claims again if it returns.
        claimedSize = nil
        releaseClaim()
    }

    /// Cancels the settle item and takes the pane out of its hold.
    private func cancelStopWork() {
        stopWork?.cancel()
        stopWork = nil
        stopHold?.clear()
        stopHold = nil
    }

    /// Cancels the grace item and takes the pane out of its hold.
    private func cancelGraceWork() {
        graceWork?.cancel()
        graceWork = nil
        graceHold?.clear()
        graceHold = nil
    }

    /// Sets the pane aside for a quick return: the screen, the scrollback and the stream's place
    /// stay; the data socket, the input queue, the drawables and every timer go. A parked pane
    /// uses no CPU and no network. The fit claim stays until its grace runs out (`scheduleStop`).
    func park() {
        guard !isParked else { return }
        isParked = true
        isWarm = false
        if away.end() { endAway() }
        loader?.removeFromSuperview()
        loader = nil
        stopKeyRepeats()
        // Find closes with the pane, as when it stops.
        closeFind(giveBack: false)
        fenceStatusWork?.cancel()
        fenceStatusWork = nil
        if transientStatus != nil { hideStatus() }
        // Before the stream goes: a parked pane's program is told it lost the focus, if that
        // was not said yet. The stream may still drop it with the rest of its queue.
        refreshProgramFocus()
        stoppingStream = true
        stream.park()
        stoppingStream = false
        keptBytes = term.core.memoryBytes
        term.core.dropFrameEcho()
        term.releaseDrawables()
        files?.close()
        ports?.unwatch()
        onParked?()
    }

    /// Keeps the pane's stream running off screen: parsed, never drawn. Everything a pane needs
    /// only on screen goes, as when it parks. A warm pane that writes more than
    /// `WarmPolicy.rateLimit` parks itself (`streamFeed`).
    func warm() {
        guard !isWarm, !isParked else { return }
        isWarm = true
        if away.end() { endAway() }
        term.core.dropFrameEcho()
        keptBytes = term.core.memoryBytes
        stopKeyRepeats()
        closeFind(giveBack: false)
        term.releaseDrawables()
        files?.close()
        ports?.unwatch()
        warmRate.reset(at: CACurrentMediaTime())
    }

    /// The warm pane is on screen again, with the screen as it is now. A mirror pane needs no
    /// fence: nothing about it changes. A fitted one may be about to claim its size again.
    private func unwarm() {
        isWarm = false
        onUnparked?()
        term.restoreDrawables()
        PerfProbe.active?.mounted(self, kind: .warm)  // PERF
        // Only a claim about to be made changes the screen of a pane that streamed all along
        // (`WarmReturn`). A claim that lapsed is known now, and the fence goes up at once.
        // Whether the pane fits another grid is known at the layout that comes in this turn,
        // when the pane has its place (`layoutTerminal`): then the fence goes up there.
        if sizing == .fit, claimedSize == nil, !lostOwnership { stream.returned() }
        returnedWarm = true
    }

    /// Whether this pane, coming back from warm now, would be fenced (`WarmReturn`).
    var warmReturnFences: Bool {
        WarmReturn.fences(fit: sizing == .fit, claimed: claimedSize, server: serverSize, fits: fitGrid())
    }

    /// The pane has a window again: a parked one resumes, a warm one shows what it has.
    func cameBackOnScreen() {
        if isParked { unpark() } else if isWarm { unwarm() }
        leftScreen = false
        // After the stream's fence went up for the return: behind it the report waits, and
        // goes once when the fence comes down (`streamFence`).
        refreshProgramFocus()
    }

    /// The parked pane is on screen again: its last screen is drawn in its first frame, and its
    /// stream resumes behind the fence.
    private func unpark() {
        isParked = false
        onUnparked?()
        // Parked before its first screen came: still nothing to draw.
        showLoader()
        term.restoreDrawables()
        PerfProbe.active?.mounted(self, kind: .parked)  // PERF
        stream.unpark()
    }

    /// The pool lets the pane go for good.
    func evict() {
        cancelStopWork()
        stop()
        onStopped?()
    }

    /// iOS 26 swipes back from anywhere in the content. Over the terminal a horizontal flick
    /// switches panes instead; the screen-edge swipe back still works.
    func yieldContentSwipeBack() {
        guard #available(iOS 26.0, *) else { return }
        var r: UIResponder? = next
        // A drag on the find bar starts no swipe back either.
        let pans: [UIGestureRecognizer] = [swipeGR] + (finder.map { [$0.overlayPan] } ?? [])
        while let cur = r {
            if let nav = cur as? UINavigationController {
                for p in pans { nav.interactiveContentPopGestureRecognizer?.require(toFail: p) }
                return
            }
            if let vc = cur as? UIViewController, let nav = vc.navigationController {
                for p in pans { nav.interactiveContentPopGestureRecognizer?.require(toFail: p) }
                return
            }
            r = cur.next
        }
    }


    func stop() {
        isParked = false
        isWarm = false
        if away.end() { endAway() }
        loader?.removeFromSuperview()
        loader = nil
        hasScreen = false
        cancelGraceWork()
        stopKeyRepeats()
        // Find closes with the pane: its handle and tints go, and any hold.
        closeFind(giveBack: false)
        // A snapshot half received is of no use to the next start.
        snapshot.reset()
        stoppingStream = true
        stream.stop()
        stoppingStream = false
        // Gives the pane back once any call in flight has returned; no resize follows.
        claimedSize = nil
        releaseClaim()
        fenceStatusWork?.cancel()
        fenceStatusWork = nil
        started = false
        files?.close()
        ports?.unwatch()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if zoomer.transform == .identity { zoomer.frame = bounds }
        placeLoader()
        if !statusLabel.isHidden { layoutStatus() }
        layoutFind()
        placeJumpButton()
        guard bounds.width > 20, bounds.height > 20 else { return }
        guard bounds.size != lastBounds else { return }
        // A new width ends find's hold: the grid that fits is another one.
        releaseFitHoldIfWidthChanged()
        lastBounds = bounds.size
        layoutTerminal()
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        placeJumpButton()
    }

    /// The button's circle sits 12 pt in from the pane's trailing edge and that far above its
    /// bottom, clear of the home indicator. Its center is set, not its frame: it has a transform
    /// while it comes and goes.
    func placeJumpButton() {
        let radius = JumpToBottomButton.diameter / 2
        let rightToLeft = effectiveUserInterfaceLayoutDirection == .rightToLeft
        let x = rightToLeft ? bounds.minX + 12 + radius : bounds.maxX - 12 - radius
        var y = JumpToBottomButton.centerY(bottom: bounds.maxY, safeBottom: safeAreaInsets.bottom)
        // Above the find bar while it floats at the bottom.
        if let bar = findBottomBarFrame { y = min(y, FindBarPlacement.jumpCenterY(bar: bar, radius: radius)) }
        let center = CGPoint(x: x, y: y)
        if jumpButton.center != center { jumpButton.center = center }
    }

    // MARK: Jump to bottom

    /// The engine says where the view is in the scrollback: on its news, and on every scroll step.
    private func scrollPlaceChanged(_ place: GhosttyScrollPlace) {
        scrollPlace = place
        updateJumpButton()
    }

    /// Asks the rule again, and touches the button only when the answer changed. Called when
    /// the scroll place, a selection or a pinch changes.
    private func updateJumpButton() {
        let cell = term.cellSize.height
        // The cheap answers first: a standing selection is asked of the engine.
        let blocked = scrollPlace.programScroll || selecting || pinching || term.hasActiveSelection
        let input = JumpToBottomRule.Input(rowsAbove: scrollPlace.rowsAbove, screenRows: cell > 0 ? Int(term.visibleHeight / cell) : 0,
                                           blocked: blocked, total: scrollPlace.total, rebase: scrollPlace.rebase,
                                           sequence: scrollPlace.sequence)
        guard jumpRule.update(input) else { return }
        jumpButton.set(shown: jumpRule.shown, unseen: jumpRule.unseen, animated: window != nil)
    }

    /// The button's tap: back to the newest line. Nothing else changes: the keyboard stays
    /// where it is, and the pane's focus too.
    private func jumpToBottom() {
        Haptic.tap()
        term.scrollToBottomForInput()
    }

    private func layoutTerminal() {
        positionTerm()
        // Back from warm: this layout decides whether a claim follows, once.
        let back = returnedWarm
        returnedWarm = false
        switch sizing {
        case .fit:
            guard !lostOwnership else { return }
            // In the background the pane belongs to the Mac. A layout change there (the keyboard
            // leaving as the app goes away) must not claim it back; `willForeground` lays out again.
            guard backgroundedAt == nil else { return }
            // Under the board the pane keeps the size it has; `setCovered(false)` lays out again.
            guard !covered else { return }
            // Out of a window (a fold took the pane off screen, and the view it left is laid out
            // once more on its way out): nothing is claimed for a pane nobody sees. Back in a
            // window it lays out again and claims what fits then (`didMoveToWindow`).
            guard window != nil else { return }
            // The stream starts beside the claim, not after it: a snapshot needs no size from
            // this client. The fence holds input until both are done, and the screen holds
            // still until the resize has landed (`streamFence`, `streamResized`).
            if !started { startStream() }
            let want = fitGrid()
            // A new size needs no redraw from the server: the terminal reflows as the server's
            // does (both are Ghostty), and the stream carries the resize.
            // A claim moment (on screen again, back from the background, tap to fit) takes the
            // pane again before it sizes it; a refit of a pane that stayed resizes only.
            let reassert = reassertNext
            reassertNext = false
            if started, let c = claimedSize, c == want, serverSize == want {
                // A request still settling would land after this layout with another size (one a
                // layout on the way had, as a fold or find's hold passes through): ask again for
                // this one, which supersedes it and sends nothing for a size in place.
                if claim.isSettling { requestClaim(want) }
                // Back from warm with its claim held at this size: current as it comes.
                if back, !stream.isFenced { PerfProbe.active?.caughtUp(self) }  // PERF
                return
            }
            // A warm pane whose claim lapsed, or that fits another grid now: fenced until the
            // resize has landed.
            if back { stream.returned() }
            requestClaim(want, reassert: reassert)
        case .mirror:
            if !started { startStream() }
            if back, !stream.isFenced { PerfProbe.active?.caughtUp(self) }  // PERF
        }
    }

    /// The pane opens: its stream starts, and Glide stands in until the first screen is there.
    private func startStream() {
        started = true
        showLoader()
        stream.start()
    }

    // MARK: The loader

    /// Only over a pane with nothing to draw. It is invisible for its first 400 ms, so a pane
    /// that opens fast never shows it.
    private func showLoader() {
        guard loader == nil, !hasScreen else { return }
        let l = GlideLoader(tint: theme.uiFG, still: reduceMotion(), timing: loaderTiming)
        loader = l
        insertSubview(l, belowSubview: statusLabel)
        placeLoader()
    }

    private func placeLoader() {
        guard let loader else { return }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        if loader.center != center { loader.center = center }
    }

    /// The first screen can be drawn: the loader fades out. While the screen is still held for
    /// a resize on its way, it stays until the hold ends.
    private func screenArrived() {
        hasScreen = true
        if !holdsForCatchUp { endLoader() }
    }

    private func endLoader() {
        guard let l = loader else { return }
        loader = nil
        l.dismiss()
        // A "Connecting…" that sat under it has no place left.
        if !statusLabel.isHidden { layoutStatus() }
    }

    /// Asks for the pane at this size. Until that ends (`claimed`, a release, a loss) a raised
    /// fence stays up: the resize will change the screen.
    private func requestClaim(_ size: (Int, Int), reassert: Bool = false) {
        ownResizeSeen = false
        stream.setClaimPending(true)
        claim.request(cols: size.0, rows: size.1, reassert: reassert)
    }

    private func releaseClaim() {
        claim.release()
        stream.setClaimPending(false)
    }

    /// The size the server last reported for the pane, while that is its latest word: the
    /// stream is live and has reported since its last fresh start. Nil otherwise, and then a
    /// claim's resize is always sent (`FitResize.sends`).
    private var reportedSize: (cols: Int, rows: Int)? {
        FitResize.reported(serverSize, said: serverSizeReported, live: stream.isLive)
    }

    /// One cell's size in points at the current font.
    private func cellSize() -> CGSize { term.cellSize }

    /// Largest grid that fits the pane at the current font: the pane as it is with the keyboard
    /// down, unless the program is on the alternate screen.
    private func fitGrid() -> (Int, Int) {
        let g = TerminalLayout.fitGrid(bounds: bounds.size, rest: restSize, alternateScreen: alternateScreen, cell: cellSize(),
                                       held: findHold)
        return (g.cols, g.rows)
    }

    /// FitClaim's newest wanted size (find's hold takes it).
    var claimWanted: (cols: Int, rows: Int)? { claim.wanted }

    /// Find's hold ended: fit again to what the pane is now.
    func relayoutAfterHold() {
        lastBounds = .zero
        setNeedsLayout()
    }

    /// The hold's lift for a match under the keyboard changed.
    func positionTermForFind() { positionTerm() }

    /// The status chip is down.
    var statusChipHidden: Bool { statusLabel.isHidden }
    var statusChipFrame: CGRect { statusLabel.frame }
    /// The chip's text, for tests.
    var statusChipText: String? { statusLabel.isHidden ? nil : statusLabel.text }

    /// Mirror mode's zoom and vertical pan, for the find bar's inset.
    var zoomScale: CGFloat { zoomer.zoomScale }
    var zoomOffsetY: CGFloat { zoomer.contentOffset.y }

    /// The find overlay goes over the terminal and under the selection's loupe and handles and
    /// the status chip.
    func insertFindOverlay(_ overlay: UIView) {
        insertSubview(overlay, aboveSubview: zoomer)
    }

    /// Sizes the engine to a grid, at this point of the stream, keeping the modes the program set.
    private func applyLocalGrid(_ cols: Int, _ rows: Int, force: Bool = false) {
        guard force || localGrid != (cols, rows) else { return }
        term.setGrid(cols: cols, rows: rows, force: force)
    }

    /// Places the terminal for the current grid. Fit: 1:1 from the top; where the grid is taller
    /// than the pane (the keyboard covers it), the engine keeps the last rows in view and scrolls
    /// through the rest. Mirror: zoomed to fit the width.
    private func positionTerm() {
        guard bounds.width > 1, bounds.height > 1 else { return }
        let cell = cellSize()
        // While the app is away and until its return has caught up, the frame on show keeps
        // its own grid (`AwayFrame`).
        let grid = away.layoutGrid(engine: (localGrid.0, localGrid.1))
        let size = CGSize(width: ceil(CGFloat(grid.cols) * cell.width) + 0.5,
                          height: ceil(CGFloat(grid.rows) * cell.height) + 0.5)
        if fitted {
            zoomer.minimumZoomScale = 1
            zoomer.maximumZoomScale = 1
            zoomer.zoomScale = 1
            term.frame = CGRect(origin: .zero, size: size)
            zoomer.contentSize = bounds.size
            zoomer.contentOffset = .zero
            // Under find's hold on the alternate screen the keyboard hides the program's bottom
            // rows and shifts nothing, unless the current match is under it. A grid taller than
            // the one that fits here (a resize on its way after a fold) isn't covered: it is cut.
            let fits = ceil(CGFloat(fitGrid().1) * cell.height) + 0.5
            let cover = TerminalLayout.cover(terminal: size.height, fits: fits, pane: bounds.height - sheetCover)
            let holds = findHold != nil && alternateScreen
            term.setCover(holds && !(finder?.liftsForMatch ?? false) ? 0 : cover)
        } else {
            term.setCover(0)
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
    /// The stream carries the resize and the program's redraw; nothing to reload.
    private func claimed(cols: Int, rows: Int) {
        claimedSize = (cols, rows)
        tenure.claimed(as: generation, welcomes: welcomes)
        // A resize that was left out has no echo to wait for: the take alone was the claim, and
        // a size another client sets from here on is news, on a stream that catches up too.
        if claim.resizeLeftOut { ownResizeSeen = true } else if holdsForCatchUp { resizedUnderHold = true }
        stream.setClaimPending(false)
        // Answered is not applied: a resize the server keeps for later leaves the pane at
        // another client's size (`checkFit`).
        scheduleFitCheck()
    }

    /// This client's id on the control connection.
    private var clientID: String? { ownClientID?() ?? stream.control.clientID }

    /// Which of its clients the control connection is on the server: it goes up at a welcome
    /// that started a new one.
    private var generation: Int { clientGeneration?() ?? stream.control.clientGeneration }

    /// The control connection since the claim was answered (`FitTenure.Link`).
    private var link: FitTenure.Link {
        let down: Bool
        if let controlDown {
            down = controlDown()
        } else {
            switch stream.control.state {
            case .failed, .connecting: down = true
            case .idle, .connected: down = false
            }
        }
        return .now(welcomes: welcomes, heldAt: tenure.heldAt, down: down, client: generation, heldAs: tenure.heldAs)
    }

    /// The control connection has its welcome, after a drop or for the first time. A fitted
    /// pane that held its claim through the drop looks at who has it now, once it has caught
    /// up (`checkFit`). Nothing is asked of the computer here.
    func controlCameBack() {
        welcomes += 1
        if sizing == .fit, tenure.holds { scheduleFitCheck() }
    }

    /// Another client's size or name is on a pane this phone sized. If that is only because
    /// the phone's connection dropped (`FitTenure`), a pane on screen is taken again without a
    /// word; if it can't be known yet, the pane looks again once it has caught up or the
    /// connection is back. Otherwise the other client has it: the chip. `settled`: the pane has
    /// caught up and nothing is on its way.
    @discardableResult
    private func foundElsewhere(_ why: ConnectionEvent.FitLoss, settled: Bool) -> FitTenure.Verdict {
        // A pane nobody is looking at is never taken back: it goes by the rules for leaving.
        let looked = FitTenure.mayTakeBack(inWindow: window != nil, background: backgroundedAt != nil, parked: isParked,
                                           warm: isWarm, covered: covered)
        let verdict = looked ? tenure.verdict(link: link, settled: settled) : .lost
        switch verdict {
        case .lost:
            resizedElsewhere(why)
        case .wait:
            // With the connection down the welcome looks again (`controlCameBack`).
            if !settled { scheduleFitCheck() }
        case .takeBack:
            takeBack()
        }
        return verdict
    }

    /// The pane passed to another client only because this phone was away: one claim that
    /// takes it and sizes it, as at any claim moment. Its answer starts a new tenure, so if it
    /// does not hold, the other client has the pane and the chip shows.
    private func takeBack() {
        #if DEBUG
        NSLog("FIT_TAKE_BACK %@ server=%dx%d", stream.blockID, serverSize.0, serverSize.1)
        #endif
        note?(.fit(.takenBack))
        fitCheckWork?.cancel()
        fitCheckWork = nil
        claimedSize = nil
        requestClaim(fitGrid(), reassert: true)
    }

    /// Another client has the pane: the claim ends, the pane shows the server's grid scaled to
    /// its width, as mirror does, and the chip offers to fit it here. Never fought over.
    private func resizedElsewhere(_ why: ConnectionEvent.FitLoss) {
        #if DEBUG
        NSLog("FIT_LOST %@ %@ server=%dx%d", stream.blockID, "\(why)", serverSize.0, serverSize.1)
        #endif
        if window != nil { note?(.fit(.lost, loss: why)) }
        fitCheckWork?.cancel()
        fitCheckWork = nil
        claimedSize = nil
        lostOwnership = true
        releaseFitHold(deferrable: false)
        claim.lost()
        stream.setClaimPending(false)
        showStatus(Self.lostText)
        guard window != nil else { return }
        positionTerm()
    }

    /// The pane's owner changed (`block_owner_changed`), as the computer's control connection
    /// heard it. For a pane on screen it goes into the connection log, so a diagnostics file
    /// says why a pane changed size: the reason, and who the two clients are to this phone.
    func ownerChanged(_ change: BlockOwnerChange) {
        let me = clientID
        // Whether another client asked for the pane: what tells a take from a handoff when a
        // size turns up that is not this phone's.
        tenure.ownerChanged(change, me: me)
        // A take changes no size when the other client's is the same: the pane looks anyway.
        if sizing == .fit, tenure.holds, change.isTake(from: me) { scheduleFitCheck() }
        #if DEBUG
        NSLog("OWNER_EVENT %@ reason=%@ previous=%@ owner=%@", stream.blockID, "\(change.reason)",
              "\(BlockOwnerChange.party(change.previous, me: me))", "\(BlockOwnerChange.party(change.owner, me: me))")
        #endif
        if window != nil { note?(.owner(change, me: me)) }
    }

    /// Looks again in `fitCheckDelay`, from now (`checkFit`).
    private func scheduleFitCheck() {
        guard sizing == .fit, !lostOwnership else { return }
        fitCheckWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.fitCheckWork = nil
            self?.checkFit()
        }
        fitCheckWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + fitCheckDelay, execute: work)
    }

    /// A fitted pane on screen, with nothing on its way, must show the grid it fits (`FitCheck`).
    /// Runs once, `fitCheckDelay` after a claim's answer, a size from the stream, or the fence
    /// coming down; never per frame.
    private func checkFit() {
        guard sizing == .fit, !lostOwnership, started, hasScreen, window != nil, backgroundedAt == nil,
              !covered, !isParked, !isWarm else { return }
        // Something is still on its way; its end looks again.
        guard !stream.isFenced, !stream.isClaimPending, !claim.isSettling else { return }
        // With the control connection down nothing is known and nothing is asked: its welcome
        // looks again (`controlCameBack`).
        let link = self.link
        guard link != .down else { return }
        let me = clientID
        // The session's view names another owner, or the last owner event did: the view is read
        // again after such an event and may not be in yet.
        let foreign = (blockOwner?().map { me != nil && $0 != me } ?? false) || tenure.taken
        let want = fitGrid()
        switch FitCheck.verdict(claimed: claimedSize, server: serverSize, fits: want, foreignOwner: foreign,
                                claimedOnce: fitGuardUsed) {
        case .fine:
            if claimedSize != nil { fitGuardUsed = false }
            // Ours, at our size, after whatever the connection went through: the tenure goes on
            // from here, and a size that turns up later is another client's doing.
            tenure.settled(as: generation, welcomes: welcomes)
        case .elsewhere:
            foundElsewhere(claimedSize == nil ? .guard : foreign ? .owner : .unapplied, settled: true)
        case .claim:
            fitGuardUsed = true
            #if DEBUG
            NSLog("FIT_GUARD %@ server=%dx%d fits=%dx%d", stream.blockID, serverSize.0, serverSize.1, want.0, want.1)
            #endif
            requestClaim(want, reassert: true)
        }
    }

    // MARK: TerminalSink

    /// Only when a snapshot could not be restored (`TerminalStream`): the screen follows as text.
    func streamReset(cols: Int, rows: Int) {
        // RIS + clear scrollback, then match the server's grid.
        term.feed(text: "\u{1b}c\u{1b}[3J")
        serverSize = (cols, rows)
        serverSizeReported = true
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
            let taken = term.restoreSnapshot(snapshot.take()) { [weak self] in self?.stream.snapshotRestoreFailed() }
            if taken { term.whenParsed { [weak self] in self?.screenArrived() } }
            return taken
        }
        return true
    }

    /// The fallback for a snapshot that could not be restored: the screen as escape sequences.
    func streamSnapshot(_ text: String) {
        PerfProbe.active?.seedReceived(text.utf8.count, host: self)  // PERF
        term.feed(text: text)
        term.whenParsed { [weak self] in self?.screenArrived() }
        PerfProbe.active?.seedParsed(host: self)  // PERF
    }

    func streamFeed(_ bytes: UnsafeBufferPointer<UInt8>) {
        PerfProbe.active?.fed(bytes.count, host: self)  // PERF
        // The terminal copies the bytes and parses them on its own queue, in stream order.
        term.feed(buffer: bytes)
        EchoProbe.active?.fed(bytes, core: term.core)  // PERF: after the bytes, so its mark follows them
        // A pane nobody sees may not cost much: one that writes a lot parks. After this chunk
        // has been passed on whole, so the resume's byte count is exact.
        if isWarm, warmRate.add(bytes.count, at: CACurrentMediaTime()) {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isWarm, self.window == nil else { return }
                self.park()
            }
        }
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
        serverSizeReported = true
        // The newest, so a size or font change on the server leaves no old one behind.
        term.paneCellPixels = stream.cellPixels
        let wasFitted = fitted
        let mine = owner == clientID
        #if DEBUG
        // One line per size the stream reports, to see whose it is (docs/debug-args.md).
        NSLog("FIT_SIZE %@ %dx%d mine=%d", stream.blockID, cols, rows, mine ? 1 : 0)
        #endif
        if mine { ownResizeSeen = true }
        // While the stream catches up, a size from before our own resize can still arrive (the
        // snapshot's, or one the pane had while it was parked): that is not another client
        // taking the pane. After our own resize has come by, or on a current stream, it is.
        let later = ownResizeSeen || !stream.isFenced
        // Our resize's echo comes in the stream before the claim's answer: in between, nothing
        // is claimed yet, but a size another client sets after that echo is just as much news. Let
        // through, it would be the server's size under a claim that answers "ours" a moment later,
        // and the pane would be drawn at that grid, wider than the pane, until its width changed.
        let pending = claimedSize == nil && stream.isClaimPending && ownResizeSeen
            && (claim.wanted.map { $0 != (cols, rows) } ?? false)
        var verdict: FitTenure.Verdict?
        if sizing == .fit, !mine, (claimedSize.map { $0 != (cols, rows) && later } ?? false) || pending {
            // Another client's size (the Mac's, or another phone's). If that client asked for the
            // pane, it is not fought over and the chip offers to take it back; if the pane only
            // passed on because this phone dropped, it is taken again (`foundElsewhere`).
            verdict = foundElsewhere(.resize, settled: false)
        } else if sizing == .fit, lostOwnership, mine, owner != nil, window != nil, backgroundedAt == nil,
                  (cols, rows) == fitGrid() {
            // The server gave the pane back at the size that fits here: after a dropped
            // connection, the owner gets its panes back when it reconnects. Ours again.
            #if DEBUG
            NSLog("FIT_BACK %@ %dx%d", stream.blockID, cols, rows)
            #endif
            note?(.fit(.givenBack))
            lostOwnership = false
            hideStatus()
            claim.adopt(cols: cols, rows: rows)
            claimedSize = (cols, rows)
            tenure.claimed(as: generation, welcomes: welcomes)
        } else if sizing == .fit, !mine {
            // Not news yet (a size from before our own, or nothing claimed): looked at again once
            // the stream is current and nothing is on its way (`checkFit`).
            scheduleFitCheck()
        }
        // A resize left out because the server had the size (`FitResize`) goes after all when
        // the server says another one. Not for a pane another client has: that is never fought
        // over. Not for one whose owner is not known yet, nor while a take back is on its way:
        // that resize follows its take.
        if sizing == .fit, !lostOwnership, verdict == nil, claim.serverReported(cols: cols, rows: rows) {
            stream.setClaimPending(true)
        }
        // A pane that opens at the size it will keep has no reflow to hide: show it at once.
        // Not after a resize of ours under this hold from another size: its answer can come
        // before its echo, and the echo is then this report, with the redraw still behind it.
        // The fence's fall ends that hold, or the engine's limit, after which the screen
        // follows the stream anyway.
        if holdsForCatchUp, fitted, fitGrid() != (cols, rows) { otherSizeUnderHold = true }
        let reflowing = resizedUnderHold && otherSizeUnderHold && term.core.isCatchUpHeld
        if holdsForCatchUp, !stream.isClaimPending, !reflowing, !fitted || fitGrid() == (cols, rows) { endCatchUpHold() }
        guard localGrid != (cols, rows) || wasFitted != fitted else { return }
        applyLocalGrid(cols, rows)
        // A pane off screen takes the size in its terminal, in stream order, and nothing else:
        // its views are laid out when it is back (`didMoveToWindow`), not on the main thread
        // while another pane is in use.
        guard window != nil else { return }
        positionTerm()
    }

    // MARK: The catch-up fence

    /// The stream may be behind the program (`CatchUpFence`). The pane keeps its look: only the
    /// cursor is hollow, and the screen holds still until the catch-up can be shown as one
    /// frame. Keys typed meanwhile are held by the stream.
    func streamFence(_ up: Bool, screen: Bool) {
        if up { fencesRaised += 1 }
        fenceStatusWork?.cancel()
        fenceStatusWork = nil
        holdsForCatchUp = up
        resizedUnderHold = false
        // Back from the background with another client's size in place, taken while the app was
        // away: a report that fits is our resize's echo, with the program's redraw behind it.
        otherSizeUnderHold = up && fitted && away.grid.map { localGrid != ($0.cols, $0.rows) } ?? false
        term.setCatchingUp(up, hold: up)
        if !up, hasScreen { endLoader() }
        if !up, away.caughtUp(inBackground: backgroundedAt != nil) { endAway() }
        if up {
            // A pane with nothing to show says so itself ("Connecting…").
            guard screen else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.statusLabel.isHidden else { return }
                // A transient chip, so it waits out a wake's grace like any other.
                self.showStatus(Self.reconnectingText, after: 0.001)
            }
            fenceStatusWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + fenceStatusDelay, execute: work)
        } else {
            if transientStatus == Self.reconnectingText { hideStatus() }
            // A size that came while the stream caught up counts from here (`checkFit`), and so
            // does a claim held through a drop of the control connection.
            if !stoppingStream, sizing == .fit, serverSize != (claimedSize ?? fitGrid()) || (tenure.holds && link != .steady) {
                scheduleFitCheck()
            }
            if !stoppingStream {
                // A focus report dropped behind the fence goes now, ahead of any held keys, and
                // the pane says again where it is: a report made before may never have arrived.
                term.sayFocus(.current)
                PerfProbe.active?.caughtUp(self)  // PERF
            }
        }
    }

    /// The screen follows the stream again while the fence stays up for input.
    private func endCatchUpHold() {
        holdsForCatchUp = false
        resizedUnderHold = false
        otherSizeUnderHold = false
        term.setCatchingUp(stream.isFenced, hold: false)
        if hasScreen { endLoader() }
        if away.caughtUp(inBackground: backgroundedAt != nil) { endAway() }
    }

    /// The kept frame goes: the screen and the view follow the terminal again, as one frame.
    private func endAway() {
        term.endAwayHold()
        positionTerm()
    }

    func streamWhenParsed(_ done: @escaping @MainActor () -> Void) { term.whenParsed(done) }

    /// True while keys typed here are held, not sent. For tests.
    var isCatchingUp: Bool { stream.isFenced }

    func streamTheme(_ theme: JSONObject) {}

    func streamExited(code: Int?) {
        showStatus("Program exited\(code.map { " with code \($0)" } ?? "")")
    }

    func streamStatus(_ status: TerminalStream.Status) {
        PerfProbe.active?.status(status, host: self)  // PERF
        // A fresh start says the size again, after its snapshot: until then none is known.
        if status == .connecting { serverSizeReported = false }
        switch status {
        case .live:
            #if DEBUG || BENCH
            EchoDriver.active?.live(self)  // `-echoTest` (testing, EchoProbe.swift)
            #endif
            if lostOwnership { showStatus(Self.lostText) } else { hideStatus() }
            // A new connection may be to a server that does other things with files.
            refreshFiles()
            #if DEBUG
            if let s = Self.forcedStatus { showStatus(s) }  // `-forceStatus` (testing)
            if isActive { GhosttyTapTest.run(on: term) }  // `-tapTest` (testing, GhosttyTap.swift)
            if isActive { FilesTest.run(on: self) }  // `-filesTest` (testing, FilesTest.swift)
            if isActive { ShareTest.run(on: self) }  // `-shareTest` (testing, ShareTest.swift)
            if isActive { PortsTest.run(on: self) }  // `-portsTest` (testing, PortsTest.swift)
            if isActive { KeyboardTest.run(on: self) }  // `-keyboardTest` (testing, KeyboardTest.swift)
            if isActive { FindScript.run(on: self) }  // `-findScript` (testing, spike S1, FindScript.swift)
            // `-typeTest <text>` (Debug builds, testing): types into the live shell.
            if isActive, let t = UserDefaults.standard.string(forKey: "typeTest"), !typedTest {
                typedTest = true
                let text = t.replacingOccurrences(of: "\\n", with: "\r")
                // `-scrollBackTest <seconds>` (testing): scroll two pages into the scrollback first
                // and type that much later, to check that input returns the view to the bottom.
                let wait = UserDefaults.standard.double(forKey: "scrollBackTest")
                // Typed once the screen is current, as a user who waits for the pane would.
                guard wait > 0 else {
                    stream.whenCurrent { [weak self] in self?.term.send(txt: text) }
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    self?.term.scrollPage(up: true)
                    self?.term.scrollPage(up: true)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5 + wait) { [weak self] in self?.term.send(txt: text) }
            }
            #endif
        // A pane that opens has Glide; its words come later, and under it.
        case .connecting: showStatus("Connecting…", after: loader != nil ? connectingDelay : Self.statusDelay)
        // A failure retries on its own; to the user it is still reconnecting.
        case .reconnecting, .failed: showStatus("Reconnecting…", after: Self.statusDelay)
        // RexKit's words are for logs; the pane on screen is the one that closed.
        case .ended: showStatus(Messages.thisPaneClosed)
        }
    }

    /// One small chip at the top. Transient states wait `after` seconds, so brief blips never show.
    private func showStatus(_ s: String, after delay: TimeInterval = 0) {
        statusWork?.cancel()
        statusWork = nil
        transientStatus = delay > 0 ? s : nil
        guard delay > 0 else { applyStatus(s); return }
        guard statusLabel.isHidden else { applyStatus(s); return }  // already showing: just update
        scheduleTransient(s, after: delay)
    }

    /// Shows a transient chip after `delay`, or after the quiet time if that is longer. In the
    /// background nothing is scheduled; `willForeground` does it.
    private func scheduleTransient(_ s: String, after delay: TimeInterval) {
        let wait = max(delay, quietUntil - CACurrentMediaTime())
        guard wait.isFinite else { return }
        let w = DispatchWorkItem { [weak self] in self?.applyStatus(s) }
        statusWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: w)
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
        transientStatus = nil
        statusLabel.isHidden = true
    }

    private func layoutStatus() {
        let fit = statusLabel.sizeThatFits(CGSize(width: bounds.width - 24, height: 22))
        let w = min(fit.width + 20, bounds.width - 24)
        // Under the loader while there is one; else the chip's place at the top.
        let y = loader.map { $0.frame.maxY + 12 } ?? 8
        statusLabel.frame = CGRect(x: (bounds.width - w) / 2, y: y, width: w, height: 22)
        statusLabel.layer.cornerRadius = 11
        statusLabel.layer.borderWidth = 1 / max(1, traitCollection.displayScale)  // one pixel
    }

    // MARK: TerminalEngineDelegate

    func engineGridChanged(cols: Int, rows: Int) {
        localGrid = (cols, rows)
    }

    func engineSend(_ bytes: [UInt8]) {
        let began = EchoProbe.active != nil ? EchoProbe.clock() : 0  // PERF
        stream.send(bytes)
        EchoProbe.active?.cost(.mainSend, since: began)  // PERF
        keyBar.consumedModifiers()
    }

    /// A mouse, wheel or focus report, or the keys of a tap: dropped while the stream catches
    /// up, because the place it names may be another by now.
    @discardableResult
    func engineSendReport(_ bytes: [UInt8]) -> Bool {
        stream.send(report: bytes)
    }

    func engineSendFocusGained(_ bytes: [UInt8], left: @escaping @MainActor () -> Void) -> Bool {
        stream.send(report: bytes, left: left)
    }

    /// A click as an item of its own in the stream's queue: sent now or not at all, once.
    /// Behind the fence, without a connection, or as bytes the server can't take, it never
    /// leaves and `delivered` hears false at once. A fence that went up since the tap drops it
    /// too: the screen it was made on is gone. Like every such item it holds typing back for
    /// `TerminalStream.actionHold` at most, which is longer than any `hold`.
    func engineSendClick(_ bytes: [UInt8], hold: @escaping @MainActor () -> Double, still: @escaping @MainActor () -> Bool,
                         delivered: @escaping @MainActor (Bool) -> Void) {
        guard let text = String(bytes: bytes, encoding: .utf8) else { return delivered(false) }
        let fences = fencesRaised
        stream.sendOnce(text: text, hold: { .seconds(hold()) }, still: { [weak self] in
            guard let self else { return false }
            return self.fencesRaised == fences && !self.stream.isFenced && still()
        }, ended: { delivered($0 == .delivered) })
    }

    /// Insert Path: a path picked for the program on screen. Behind the fence it is dropped,
    /// and the user is told: the program may be another by now.
    func insertPath(_ text: String) {
        guard !stream.isFenced else { return stream.noteFenceDrop() }
        paste(text)
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
    func openAttachMenu(open: Bool = true) { keyBar.openAttachMenu(open: open) }
    #endif

    /// Shows the attach key once the pane's host is known to take files or to list folders.
    func refreshFiles() {
        files?.checkSupport()
        keyBar.attachAvailable = files?.showsAttachKey == true
    }
}
