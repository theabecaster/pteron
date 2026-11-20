import UIKit

/// The row of extra keys above the software keyboard. Keys come from Settings (`Prefs.keyBarLayout`).
///
/// - Keys send on release; a horizontal drag scrolls the bar instead.
/// - Arrows and PgUp/PgDn auto-repeat while held, until the finger moves off (`RepeatSlop`).
/// - ctrl / alt / cmd: tap = next key only, double-tap = locked until tapped again.
/// - With cmd on, the next key (a bar key or a key typed on the system keyboard) is never typed: it
///   runs through Rex's keymap as that key pressed with ⌘ on a hardware keyboard does
///   (`onShortcut`), with ctrl and alt if they are on. A key nothing is bound to does nothing.
/// - The "arrows" key is a trackpad, as the space bar is on the iOS keyboard: hold it still for
///   0.3 s, or drag up or down from it, and drag to send arrow keys. A quick sideways swipe that
///   starts on it scrolls the bar and sends nothing (`TrackpadEngage`).
/// - Return (`KeyBarLayout.pinned`) never scrolls: it closes the keys' capsule, past a divider,
///   next to the hide key. It sends as any bar key does, modifiers and cmd included, and never
///   repeats. Held for `KeyCap.holdDelay` it sends Shift-Return instead, as a hardware keyboard
///   encodes it: a new line without sending in an agent. While an input method composes, Return
///   commits the composition, as the system keyboard's return does, and sends nothing.
/// - The attach key is pinned too, just before Return, where the pane's server takes files: sending
///   a photo or a file never scrolls out of sight. A tap only opens its menu; nothing is sent
///   until a row of it is picked.
/// - Where the system's vertical bar sits beside the keyboard (iPhone Duo), the hide key is that
///   bar's Hide Keyboard item (`HideKeyboardItem`): the bar draws none, and its keys end short of
///   the bar's column, which keeps its own touches. Keys stay off a vertical crease
///   (`KeyBarPlacement`).
/// - Since iOS 26 the keyboard is a glass panel with rounded top corners. The bar draws no
///   background of its own: the keys sit in a glass capsule and the hide key in a glass circle,
///   floating above the keyboard and inset as far as its keys, as the system's own bars float.
@MainActor
final class KeyBar: UIInputView, UIInputViewAudioFeedback {
    weak var terminal: GhosttyTerminalView? {
        didSet {
            observe(terminal, old: oldValue)
            oldValue?.commandKeyHook = nil
            terminal?.commandKeyHook = { [weak self] text in self?.typedWithCommand(text) }
            syncModifiers()
        }
    }
    var onPaste: (() -> Void)?
    /// Runs a key pressed with the bar's cmd through the keymap, as the hardware keyboard's press
    /// (`TerminalHost.keyBarShortcut`). `isRepeat`: a held key's repeat. True when a binding was found.
    var onShortcut: ((KeyInput.Press, _ isRepeat: Bool) -> Bool)?
    /// Played when a cmd chord has no binding. iOS mutes it when System Haptics is off.
    var onUnbound: @MainActor () -> Void = { UINotificationFeedbackGenerator().notificationOccurred(.error) }
    var onHideKeyboard: (() -> Void)?
    /// The attach key's menu, built each time it opens.
    var attachMenu: (() -> UIMenu)?
    /// The attach key shows only where the pane's server takes files.
    var attachAvailable = false { didSet { if attachAvailable != oldValue { rebuild() } } }
    /// The system's vertical bar's column beside the keyboard, in screen coordinates
    /// (`VerticalBarObserver`). Nil where bars are horizontal: the hide key is then the bar's own.
    var barColumn: CGRect? { didSet { if barColumn != oldValue { setNeedsLayout() } } }
    /// The vertical bar has the hide key: this bar shows none.
    var hidesInVerticalBar: Bool { KeyBarPlacement.hideKey(column: barColumn) == .verticalBar }
    /// A vertical crease, in the terminal's window coordinates. Nil without one.
    var crease: CGRect? { didSet { if crease != oldValue { setNeedsLayout() } } }

    enum ModState { case off, once, locked }

    /// The keys' capsule with 4 pt of air above and below it, so it floats clear of the keyboard.
    static let barHeight: CGFloat = 54
    static let keyHeight: CGFloat = 42
    /// Under a short window (landscape iPhone) the bar is thinner, to leave rows for the panes.
    static let compactBarHeight: CGFloat = 42
    static let compactKeyHeight: CGFloat = 34
    /// The capsule's margin around the keys, so a pressed key's pill sits concentric in it.
    static let ring: CGFloat = 2
    /// The capsule's and the hide key's distance from the bar's sides: in line with the keyboard's
    /// own keys, inside its rounded corners.
    static let sideInset: CGFloat = 6
    /// The space between the capsule and the hide key's circle.
    static let hideGap: CGFloat = 8

    private var barHeightConstraint: NSLayoutConstraint?
    private var compact: Bool { traitCollection.verticalSizeClass == .compact }
    private var keyHeight: CGFloat { compact ? Self.compactKeyHeight : Self.keyHeight }

    private let capsule = UIVisualEffectView()
    private let scroll = KeyScroll()
    private let stack = UIStackView()
    private let hideKey = GlassHideKey()
    /// The pinned keys, at the capsule's trailing end. Their own stack, so whatever takes the
    /// scrolling keys' place keeps them.
    private let pinnedStack = UIStackView()
    private(set) var pinnedCaps: [KeyCap] = []
    /// A hairline between the scrolling keys and the pinned ones: keys scroll under it.
    private let divider = UIView()
    private var dividerWidth: NSLayoutConstraint?
    private var placement = KeyBarPlacement.HideKey.inBar
    private var stackLeading: NSLayoutConstraint?
    private var creaseGap: (index: Int, extra: CGFloat)?
    private static let spacing: CGFloat = 6
    private(set) var caps: [KeyCap] = []
    private var theme: TermTheme = ThemeStore.fallback
    private(set) var ctrl: ModState = .off { didSet { syncModifiers() } }
    private(set) var alt: ModState = .off { didSet { syncModifiers() } }
    private(set) var cmd: ModState = .off { didSet { syncModifiers() } }
    /// The key held now has run a cmd chord: its next run is a repeat.
    private var shortcutRan = false
    private var lastModTap: [String: CFTimeInterval] = [:]
    private let impact = UIImpactFeedbackGenerator(style: .light)
    private let lockImpact = UIImpactFeedbackGenerator(style: .medium)
    private let tick = UISelectionFeedbackGenerator()

    var enableInputClicksWhenVisible: Bool { true }

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 400, height: Self.barHeight), inputViewStyle: .default)
        allowsSelfSizing = true
        backgroundColor = .clear
        Glass.makeGlass(capsule)
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceHorizontal = true
        scroll.delaysContentTouches = false
        scroll.canCancelContentTouches = true
        // Keys scrolled to an end slip under the capsule's round ends.
        scroll.clipsToBounds = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = Self.spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        pinnedStack.axis = .horizontal
        pinnedStack.alignment = .center
        pinnedStack.spacing = Self.spacing
        pinnedStack.translatesAutoresizingMaskIntoConstraints = false
        divider.isUserInteractionEnabled = false
        divider.translatesAutoresizingMaskIntoConstraints = false
        hideKey.onTouchDown = { [weak self] in self?.touchDown("hide") }
        hideKey.onFire = { [weak self] in self?.fire("hide") }
        addSubview(capsule)
        addSubview(hideKey)
        capsule.contentView.addSubview(scroll)
        capsule.contentView.addSubview(divider)
        capsule.contentView.addSubview(pinnedStack)
        scroll.addSubview(stack)
        let barHeight = heightAnchor.constraint(equalToConstant: Self.barHeight)
        barHeightConstraint = barHeight
        let leading = stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: Self.ring)
        stackLeading = leading
        let dividerWidth = divider.widthAnchor.constraint(equalToConstant: 1)
        self.dividerWidth = dividerWidth
        let content = capsule.contentView
        NSLayoutConstraint.activate([
            barHeight,
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            // Scrolling keys | divider | pinned keys, the last one concentric with the capsule's end.
            divider.leadingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: Self.spacing / 2),
            dividerWidth,
            divider.heightAnchor.constraint(equalTo: content.heightAnchor, multiplier: 0.4),
            divider.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            pinnedStack.leadingAnchor.constraint(equalTo: divider.trailingAnchor, constant: Self.spacing / 2),
            pinnedStack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Self.ring),
            pinnedStack.topAnchor.constraint(equalTo: content.topAnchor),
            pinnedStack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            leading,
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -Self.ring),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])
        rebuild()
        NotificationCenter.default.addObserver(self, selector: #selector(prefsChanged), name: .keyBarChanged, object: nil)
        registerForTraitChanges([UITraitVerticalSizeClass.self, UITraitDisplayScale.self]) { (bar: KeyBar, _) in bar.applySize() }
    }

    /// Thinner bar and keys under a short window.
    private func applySize() {
        barHeightConstraint?.constant = compact ? Self.compactBarHeight : Self.barHeight
        for cap in caps + pinnedCaps { cap.heightConstraint?.constant = keyHeight }
        dividerWidth?.constant = 1 / max(traitCollection.displayScale, 1)
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        placement = KeyBarPlacement.hideKey(column: barColumn)
        layoutGlass()
        super.layoutSubviews()
        keepKeysOffCrease()
        reportFrame(force: false)
    }

    /// The vertical bar's column in the bar's coordinates; nil without one, or out of a window.
    private var localColumn: CGRect? {
        guard let barColumn, let screen = window?.windowScene?.screen else { return nil }
        return convert(barColumn, from: screen.coordinateSpace)
    }

    /// A touch in the vertical bar's column is the bar's: the key bar doesn't take it.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if let c = localColumn, point.x >= c.minX, point.x < c.maxX { return nil }
        return super.hitTest(point, with: event)
    }

    // MARK: Where the bar is

    /// The bar's frame on screen changed by a point or more, it came into a window or left one, or
    /// it was shown or hidden (object: the bar). `KeyboardInsetReader` keeps the root clear of the
    /// bar's top while the keyboard is up, whatever the keyboard's own frame says.
    static let frameChanged = Notification.Name("RexDuo.keyBarFrameChanged")
    /// The frame last reported, in screen coordinates; nil out of a window or hidden.
    private var reportedFrame: CGRect?
    /// How many times the bar reported itself. Internal for tests.
    private(set) var frameReports = 0

    override func didMoveToWindow() {
        super.didMoveToWindow()
        reportFrame(force: true)
    }

    override var isHidden: Bool {
        didSet { if isHidden != oldValue { reportFrame(force: true) } }
    }

    /// Reports only a change: the root's padding lays the root out again, and that must not
    /// make the bar report again.
    private func reportFrame(force: Bool) {
        let frame = window.flatMap { w in isHidden ? nil : convert(bounds, to: w.screen.coordinateSpace) }
        if !force {
            switch (frame, reportedFrame) {
            case (nil, nil): return
            case let (f?, r?) where Self.same(f, r): return
            default: break
            }
        }
        reportedFrame = frame
        frameReports += 1
        NotificationCenter.default.post(name: Self.frameChanged, object: self)
    }

    /// Within a point on every edge.
    static func same(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 1 && abs(a.minY - b.minY) < 1 && abs(a.maxX - b.maxX) < 1 && abs(a.maxY - b.maxY) < 1
    }

    /// Places the capsule and the hide key, centered in the bar above any bottom safe area it is
    /// given. Where the vertical bar sits beside the keyboard the capsule ends short of its column
    /// and the hide key is the vertical bar's; elsewhere the hide key is at the bar's end.
    private func layoutGlass() {
        let h = keyHeight + 2 * Self.ring
        let rowHeight = max(bounds.height - safeAreaInsets.bottom, h)
        let span = KeyBarPlacement.span(width: bounds.width, leftInset: safeAreaInsets.left, rightInset: safeAreaInsets.right,
                                        sideInset: Self.sideInset, column: localColumn)
        var lo = span.lowerBound
        var hi = span.upperBound
        switch placement {
        case .verticalBar:
            hideKey.isHidden = true
        case .inBar:
            // The circle sits at the bar's end; all of the bar past half the gap takes its tap.
            hideKey.isHidden = false
            hideKey.tintColor = theme.uiFG
            hideKey.diameter = h
            if effectiveUserInterfaceLayoutDirection == .rightToLeft {
                let edge = lo + h + Self.hideGap / 2
                hideKey.frame = CGRect(x: 0, y: 0, width: edge, height: rowHeight)
                hideKey.keyMidX = lo + h / 2
                lo += h + Self.hideGap
            } else {
                let edge = hi - h - Self.hideGap / 2
                hideKey.frame = CGRect(x: edge, y: 0, width: bounds.width - edge, height: rowHeight)
                hideKey.keyMidX = hi - h / 2 - edge
                hi -= h + Self.hideGap
            }
        }
        capsule.frame = CGRect(x: lo, y: ((rowHeight - h) / 2).rounded(), width: max(hi - lo, h), height: h)
        Glass.round(capsule, radius: h / 2)
        // Keys slip under the capsule's round leading end, and stop straight at the divider.
        scroll.layer.cornerRadius = h / 2
        scroll.layer.maskedCorners = effectiveUserInterfaceLayoutDirection == .rightToLeft
            ? [.layerMaxXMinYCorner, .layerMaxXMaxYCorner] : [.layerMinXMinYCorner, .layerMinXMaxYCorner]
    }

    /// Adds space before the key that would sit on a vertical crease with the bar at its start, so
    /// no key straddles the fold.
    private func keepKeysOffCrease() {
        var gap: (index: Int, extra: CGFloat)?
        if let crease, effectiveUserInterfaceLayoutDirection == .leftToRight,
           let tw = terminal?.window, let screen = tw.windowScene?.screen, window != nil {
            let r = convert(tw.convert(crease, to: screen.coordinateSpace), from: screen.coordinateSpace)
            let x = capsule.frame.minX
            let widths = caps.map { $0.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width }
            gap = KeyBarPlacement.creaseGap(widths: widths, start: Self.ring, spacing: Self.spacing,
                                            crease: (r.minX - x)...(r.maxX - x))
        }
        guard gap?.index != creaseGap?.index || gap?.extra != creaseGap?.extra else { return }
        creaseGap = gap
        for cap in caps { stack.setCustomSpacing(UIStackView.spacingUseDefault, after: cap) }
        stackLeading?.constant = Self.ring
        guard let gap else { return }
        if gap.index == 0 {
            stackLeading?.constant = Self.ring + gap.extra
        } else {
            stack.setCustomSpacing(Self.spacing + gap.extra, after: caps[gap.index - 1])
        }
    }

    @objc private func prefsChanged() { rebuild() }

    func apply(theme: TermTheme) {
        self.theme = theme
        rebuild()
    }

    private func rebuild() {
        // The glass follows the theme, as the keyboard does (`GhosttyTerminalView.keyboardAppearance`).
        let style: UIUserInterfaceStyle = theme.isDark ? .dark : .light
        capsule.overrideUserInterfaceStyle = style
        hideKey.overrideUserInterfaceStyle = style
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        pinnedStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        caps = []
        creaseGap = nil
        stackLeading?.constant = Self.ring
        setNeedsLayout()
        for key in Prefs.shared.keyBar where key != "attach" || attachAvailable {
            let cap = makeCap(key)
            if key == "attach" { addMenu(to: cap) }
            stack.addArrangedSubview(cap)
            caps.append(cap)
        }
        pinnedCaps = KeyBarLayout.pinned.filter { $0 != "attach" || attachAvailable }.map { key in
            let cap = makeCap(key)
            if key == "attach" { addMenu(to: cap) }
            if key == "enter" {
                cap.onHold = { [weak self] in self?.hold(key) }
                cap.accessibilityHint = "Hold for Shift-Return, a new line in an agent"
                cap.accessibilityCustomActions = [UIAccessibilityCustomAction(name: "Shift-Return") { [weak self] _ in
                    self?.hold(key)
                    return true
                }]
            }
            pinnedStack.addArrangedSubview(cap)
            return cap
        }
        divider.backgroundColor = theme.uiFG.withAlphaComponent(theme.isDark ? 0.28 : 0.22)
        refreshModifiers()
        applySize()
    }

    private func makeCap(_ key: String) -> KeyCap {
        let cap = KeyCap(key: key, kind: Self.kind(of: key))
        cap.theme = theme
        cap.onTouchDown = { [weak self] in self?.touchDown(key) }
        cap.onFire = { [weak self] in self?.fire(key) }
        cap.onRepeat = { [weak self] in self?.emit(key) }
        cap.onRepeatEnd = { [weak self] in self?.usedModifiers() }
        cap.onDrag = { [weak self] dx, dy in self?.trackpad(dx: dx, dy: dy) }
        cap.onEngage = { [weak self] in self?.trackpadEngaged() }
        return cap
    }

    private weak var attachButton: UIButton?

    #if DEBUG
    /// `-filesTest menu`: opens the attach menu as a tap does; `reveal` only scrolls to its key.
    func openAttachMenu(open: Bool = true) {
        guard let button = attachButton, let cap = button.superview else { return }
        if cap.isDescendant(of: stack) { scroll.scrollRectToVisible(scroll.convert(cap.bounds, from: cap), animated: false) }
        if open { button.performPrimaryAction() }
    }
    #endif

    /// The attach key opens its menu on a tap: a button over the key, which keeps the key's look.
    private func addMenu(to cap: KeyCap) {
        let button = UIButton(type: .custom)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.showsMenuAsPrimaryAction = true
        button.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] done in
            done(self?.attachMenu?().children ?? [])
        }])
        button.addAction(UIAction { [weak self, weak cap] _ in
            cap?.isHighlighted = true
            self?.touchDown("attach")
        }, for: .touchDown)
        for event: UIControl.Event in [.touchUpInside, .touchUpOutside, .touchCancel, .menuActionTriggered] {
            button.addAction(UIAction { [weak cap] _ in cap?.isHighlighted = false }, for: event)
        }
        attachButton = button
        cap.isAccessibilityElement = false
        button.accessibilityLabel = Self.names["attach"]
        button.accessibilityHint = "Sends a photo or a file to this pane's computer"
        cap.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: cap.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: cap.trailingAnchor),
            button.topAnchor.constraint(equalTo: cap.topAnchor),
            button.bottomAnchor.constraint(equalTo: cap.bottomAnchor),
        ])
    }

    static func kind(of key: String) -> KeyCap.Kind {
        switch key {
        case "ctrl", "alt", "cmd": return .modifier
        case "arrows": return .trackpad
        case "up", "down", "left", "right", "pgup", "pgdn": return .repeating
        case "paste", "hide", "attach": return .action
        default: return .normal
        }
    }

    // MARK: Modifiers

    /// Keeps the terminal's own modifier flags (used for keys typed on the system keyboard) in step with the bar.
    private func syncModifiers() {
        terminal?.controlModifier = ctrl != .off
        terminal?.metaModifier = alt != .off
        terminal?.commandModifier = cmd != .off
        refreshModifiers()
    }

    private func refreshModifiers() {
        for cap in caps {
            if cap.key == "ctrl" { cap.modState = ctrl }
            if cap.key == "alt" { cap.modState = alt }
            if cap.key == "cmd" { cap.modState = cmd }
        }
    }

    private func observe(_ t: GhosttyTerminalView?, old: GhosttyTerminalView?) {
        let nc = NotificationCenter.default
        if let old {
            nc.removeObserver(self, name: .terminalEngineControlModifierReset, object: old)
            nc.removeObserver(self, name: .terminalEngineMetaModifierReset, object: old)
        }
        if let t {
            nc.addObserver(self, selector: #selector(controlReset), name: .terminalEngineControlModifierReset, object: t)
            nc.addObserver(self, selector: #selector(metaReset), name: .terminalEngineMetaModifierReset, object: t)
        }
    }

    /// The terminal cleared its ctrl flag because a typed key used it.
    @objc private func controlReset() {
        switch ctrl {
        case .locked: terminal?.controlModifier = true
        case .once: ctrl = .off
        case .off: break
        }
    }

    @objc private func metaReset() {
        switch alt {
        case .locked: terminal?.metaModifier = true
        case .once: alt = .off
        case .off: break
        }
    }

    /// Called after the terminal sent bytes. One-shot modifiers turn off once the terminal has used them;
    /// locked ones stay on.
    func consumedModifiers() {
        guard let t = terminal else { return }
        if ctrl == .once, !t.controlModifier { ctrl = .off }
        if alt == .once, !t.metaModifier { alt = .off }
        if ctrl == .locked, !t.controlModifier { t.controlModifier = true }
        if alt == .locked, !t.metaModifier { t.metaModifier = true }
    }

    /// Bar keys apply the modifiers themselves; one-shot ones end here, as does the key's press.
    private func usedModifiers() {
        shortcutRan = false
        if ctrl == .once { ctrl = .off }
        if alt == .once { alt = .off }
        if cmd == .once { cmd = .off }
    }

    private func tapModifier(_ key: String) {
        let now = CACurrentMediaTime()
        let quick = now - (lastModTap[key] ?? 0) < 0.35
        lastModTap[key] = now
        let s: ModState
        switch key {
        case "ctrl": s = Self.next(ctrl, quick: quick)
        case "alt": s = Self.next(alt, quick: quick)
        default: s = Self.next(cmd, quick: quick)
        }
        if s == .locked { lockImpact.impactOccurred() }
        switch key {
        case "ctrl": ctrl = s
        case "alt": alt = s
        default: cmd = s
        }
    }

    /// A modifier key's tap: off becomes once; a quick second tap locks it; any other tap turns it off.
    static func next(_ s: ModState, quick: Bool) -> ModState {
        switch s {
        case .off: return .once
        case .once: return quick ? .locked : .off
        case .locked: return .off
        }
    }

    // MARK: Input

    private func touchDown(_ key: String) {
        shortcutRan = false
        if Self.kind(of: key) == .trackpad { tick.prepare() } else { impact.impactOccurred(intensity: 0.7) }
        UIDevice.current.playInputClick()
    }

    /// Under the agent board (`GhosttyTerminalView.covered`) the pane takes no key, from the bar
    /// either. The bar is put away with the keyboard then; this catches a key already under a finger.
    private var blocked: Bool { terminal?.covered ?? false }

    /// A key's tap. Internal for tests.
    func fire(_ key: String) {
        guard key == "hide" || !blocked else { return }
        switch key {
        case "ctrl", "alt", "cmd": tapModifier(key)
        case "paste": onPaste?(); usedModifiers()
        case "hide": onHideKeyboard?()
        case "arrows": usedModifiers()  // after a drag
        case "enter" where commitComposition(): break
        default: send(key)
        }
    }

    /// A key held for `KeyCap.holdDelay`: Return becomes Shift-Return, with the bar's modifiers,
    /// encoded as a hardware Shift-Return is (`CSI 27;2;13~`, or `CSI 13;2u` under the Kitty
    /// protocol), so an agent starts a new line instead of sending. With cmd it is the shift+cmd
    /// chord. Internal for tests.
    func hold(_ key: String) {
        guard key == "enter", !blocked else { return }
        lockImpact.impactOccurred()
        guard !commitComposition() else { return }
        if cmd != .off {
            let press = KeyInput.press(barKey: key, mods: shortcutMods.union(.shift))
            if !(press.map { onShortcut?($0, false) ?? false } ?? false) { onUnbound() }
        } else {
            terminal?.sendShiftReturn(ctrl: ctrl != .off, alt: alt != .off)
        }
        usedModifiers()
    }

    /// Return while an input method composes types the composition as it stands, as the system
    /// keyboard's return does, and sends nothing more; the next Return sends. Composed text hasn't
    /// reached the program yet (`GhosttyInputDocument.marked`), so sending Return would drop it.
    /// True when it did.
    private func commitComposition() -> Bool {
        guard let t = terminal, t.isComposing else { return false }
        t.commitComposition()
        return true
    }

    /// The trackpad key took the drag: the tick its steps play, once, as the space bar's trackpad does.
    private func trackpadEngaged() {
        tick.selectionChanged()
        tick.prepare()
    }

    private func trackpad(dx: Int, dy: Int) {
        let steps: [(Int, String, String)] = [(dx, "right", "left"), (dy, "down", "up")]
        var sent = false
        for (n, pos, neg) in steps where n != 0 {
            for _ in 0..<abs(n) { emit(n > 0 ? pos : neg); sent = true }
        }
        if sent { tick.selectionChanged(); tick.prepare() }
    }

    /// Sends one key with the bar's modifiers, then ends one-shot modifiers.
    private func send(_ key: String) {
        emit(key)
        usedModifiers()
    }

    /// One key of the bar: typed with ctrl / alt, or with cmd run as a shortcut and never typed.
    /// A held key or a trackpad drag runs its shortcut once, then as repeats.
    private func emit(_ key: String) {
        guard !blocked else { return }
        guard cmd != .off else { return sendRaw(key) }
        let isRepeat = shortcutRan
        shortcutRan = true
        let ran = KeyInput.press(barKey: key, mods: shortcutMods).map { onShortcut?($0, isRepeat) ?? false } ?? false
        if !ran, !isRepeat { onUnbound() }
    }

    /// A key typed on the system keyboard while cmd is on (`GhosttyTerminalView.commandKeyHook`).
    private func typedWithCommand(_ text: String) {
        let ran = KeyInput.press(typing: text, mods: shortcutMods).map { onShortcut?($0, false) ?? false } ?? false
        if !ran { onUnbound() }
        usedModifiers()
    }

    /// cmd with the bar's ctrl and alt.
    private var shortcutMods: KeyMods {
        var m: KeyMods = .cmd
        if ctrl != .off { m.insert(.ctrl) }
        if alt != .off { m.insert(.alt) }
        return m
    }

    private func sendRaw(_ key: String) {
        guard let t = terminal else { return }
        let c = ctrl != .off, a = alt != .off
        if !c && !a {
            switch key {
            case "up": t.sendKeyUp(); return
            case "down": t.sendKeyDown(); return
            case "left": t.sendKeyLeft(); return
            case "right": t.sendKeyRight(); return
            case "home": t.sendKeyHome(); return
            case "end": t.sendKeyEnd(); return
            default: break
            }
        }
        let mod = 1 + (a ? 2 : 0) + (c ? 4 : 0)
        if mod > 1, let seq = Self.modifiedSequence(key, mod: mod) {
            t.send(data: seq[...])
            return
        }
        guard var out = Self.bytes(for: key, appCursor: false) else { return }
        if c, out.count == 1, let ch = Self.control(out[0]) { out = [ch] }
        if a { out = [0x1b] + out }
        t.send(data: out[...])
    }

    /// xterm-style modified cursor / function keys (e.g. ctrl-left = ESC [1;5D).
    static func modifiedSequence(_ key: String, mod: Int) -> [UInt8]? {
        let letters = ["up": "A", "down": "B", "right": "C", "left": "D", "home": "H", "end": "F",
                       "f1": "P", "f2": "Q", "f3": "R", "f4": "S"]
        let tildes = ["pgup": 5, "pgdn": 6, "f5": 15, "f6": 17, "f7": 18, "f8": 19, "f9": 20, "f10": 21, "f11": 23, "f12": 24]
        if let l = letters[key] { return Array("\u{1b}[1;\(mod)\(l)".utf8) }
        if let n = tildes[key] { return Array("\u{1b}[\(n);\(mod)~".utf8) }
        return nil
    }

    /// The control character for a byte, as the terminal sends it for the system keyboard.
    static func control(_ b: UInt8) -> UInt8? {
        switch b {
        case 0x61...0x7a: return b - 0x60          // a-z
        case 0x40...0x5f: return b & 0x1f          // @ A-Z [ \ ] ^ _
        case 0x20: return 0                        // space
        case 0x2f: return 0x1f                     // /
        case 0x3f: return 0x7f                     // ?
        case 0x7e: return 0x1e                     // ~
        default: return nil
        }
    }

    static func bytes(for key: String, appCursor: Bool) -> [UInt8]? {
        let csi: (String) -> [UInt8] = { Array("\u{1b}[\($0)".utf8) }
        let ss3: (String) -> [UInt8] = { Array("\u{1b}O\($0)".utf8) }
        switch key {
        case "esc": return [0x1b]
        case "tab": return [0x09]
        case "shift-tab": return csi("Z")
        case "enter": return [0x0d]
        case "up": return appCursor ? ss3("A") : csi("A")
        case "down": return appCursor ? ss3("B") : csi("B")
        case "right": return appCursor ? ss3("C") : csi("C")
        case "left": return appCursor ? ss3("D") : csi("D")
        case "home": return appCursor ? ss3("H") : csi("H")
        case "end": return appCursor ? ss3("F") : csi("F")
        case "pgup": return csi("5~")
        case "pgdn": return csi("6~")
        case "f1": return ss3("P")
        case "f2": return ss3("Q")
        case "f3": return ss3("R")
        case "f4": return ss3("S")
        case "f5": return csi("15~")
        case "f6": return csi("17~")
        case "f7": return csi("18~")
        case "f8": return csi("19~")
        case "f9": return csi("20~")
        case "f10": return csi("21~")
        case "f11": return csi("23~")
        case "f12": return csi("24~")
        case "arrows", "ctrl", "alt", "cmd", "paste", "hide", "attach": return nil
        default:
            // "ctrl-x" sends that control character; anything else is literal text.
            if key.hasPrefix("ctrl-"), key.count == 6, let b = key.utf8.last, let c = control(b) { return [c] }
            return Array(key.utf8)
        }
    }

    static let symbols: [String: String] = [
        "left": "arrow.left", "right": "arrow.right", "up": "arrow.up", "down": "arrow.down",
        "paste": "doc.on.clipboard", "attach": "paperclip", "hide": "keyboard.chevron.compact.down", "enter": "return",
        "tab": "arrow.right.to.line",
        "arrows": "arrow.up.and.down.and.arrow.left.and.right",
    ]
    static let titles: [String: String] = [
        "esc": "esc", "ctrl": "ctrl", "alt": "alt", "cmd": "cmd", "ctrl-c": "^C", "ctrl-d": "^D", "ctrl-z": "^Z", "ctrl-r": "^R",
        "ctrl-l": "^L", "ctrl-a": "^A", "ctrl-e": "^E", "ctrl-u": "^U", "ctrl-w": "^W", "ctrl-o": "^O",
        "pgup": "PgUp", "pgdn": "PgDn", "home": "Home", "end": "End",
    ]
    /// Spoken names for VoiceOver and the editor.
    static let names: [String: String] = [
        "left": "Left", "right": "Right", "up": "Up", "down": "Down", "paste": "Paste", "attach": "Attach File", "hide": "Hide Keyboard",
        "enter": "Return", "tab": "Tab", "shift-tab": "Shift-Tab", "arrows": "Arrow Trackpad", "esc": "Escape",
        "ctrl": "Control", "alt": "Alt", "cmd": "Command",
    ]
    /// Keys shown as two symbols side by side: shift-tab as ⇧⇥, as macOS menus spell it.
    static let symbolPairs: [String: [String]] = ["shift-tab": ["shift", "arrow.right.to.line"]]

    /// A key's symbol image, nil for a key shown as text. A pair is drawn into one template image,
    /// so the cap tints it like any other symbol.
    static func symbolImage(_ key: String, pointSize: CGFloat) -> UIImage? {
        let config = UIImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
        if let sym = symbols[key] { return UIImage(systemName: sym, withConfiguration: config) }
        guard let pair = symbolPairs[key] else { return nil }
        let images = pair.compactMap { UIImage(systemName: $0, withConfiguration: config) }
        guard images.count == pair.count else { return nil }
        let gap: CGFloat = 1
        let size = CGSize(width: images.reduce(0) { $0 + $1.size.width } + gap * CGFloat(images.count - 1),
                          height: images.map(\.size.height).max() ?? 0)
        return UIGraphicsImageRenderer(size: size).image { _ in
            var x: CGFloat = 0
            for image in images {
                image.draw(at: CGPoint(x: x, y: (size.height - image.size.height) / 2))
                x += image.size.width + gap
            }
        }.withRenderingMode(.alwaysTemplate)
    }
}

/// The hide key: a glass circle with a tinted symbol at the bar's end, tinted like the keyboard.
/// Its whole frame, larger than the circle, is its touch target.
@MainActor
private final class GlassHideKey: UIControl {
    var onTouchDown: (() -> Void)?
    var onFire: (() -> Void)?
    var diameter: CGFloat = KeyBar.keyHeight + 2 * KeyBar.ring { didSet { if diameter != oldValue { setNeedsLayout() } } }
    /// The circle's center, from the control's left edge.
    var keyMidX: CGFloat = 0 { didSet { if keyMidX != oldValue { setNeedsLayout() } } }

    private let glass = UIVisualEffectView()
    private let icon = UIImageView()

    init() {
        super.init(frame: .zero)
        glass.isUserInteractionEnabled = false
        Glass.makeGlass(glass)
        icon.image = UIImage(systemName: KeyBar.symbols["hide"] ?? "keyboard.chevron.compact.down",
                             withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium))
        icon.contentMode = .center
        addSubview(glass)
        glass.contentView.addSubview(icon)
        addTarget(self, action: #selector(down), for: .touchDown)
        addTarget(self, action: #selector(up), for: .touchUpInside)
        isAccessibilityElement = true
        accessibilityLabel = KeyBar.names["hide"]
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        glass.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        glass.center = CGPoint(x: keyMidX, y: bounds.midY)
        Glass.round(glass, radius: diameter / 2)
        icon.frame = glass.contentView.bounds
    }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        icon.tintColor = tintColor
    }

    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            UIView.animate(withDuration: isHighlighted ? 0.05 : 0.12, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                self.glass.transform = self.isHighlighted ? CGAffineTransform(scaleX: 0.93, y: 0.93) : .identity
            }
        }
    }

    @objc private func down() { onTouchDown?() }
    @objc private func up() { onFire?() }

    override func accessibilityActivate() -> Bool {
        onFire?()
        return true
    }
}

/// Lets keys scroll the bar on a sideways drag, except the trackpad key once it has taken the
/// drag (`TrackpadEngage`): a swipe that starts on it before then scrolls like any other.
/// Internal for tests.
final class KeyScroll: UIScrollView {
    override func touchesShouldCancel(in view: UIView) -> Bool {
        if let cap = view as? KeyCap, cap.kind == .trackpad, cap.trackpadEngaged { return false }
        return true
    }
}

/// One key in the bar.
@MainActor
final class KeyCap: UIControl {
    enum Kind { case normal, repeating, modifier, trackpad, action }

    let key: String
    let kind: Kind
    var onTouchDown: (() -> Void)?
    var onFire: (() -> Void)?
    var onRepeat: (() -> Void)?
    var onRepeatEnd: (() -> Void)?
    /// Trackpad steps since the last call: +x = right, +y = down.
    var onDrag: ((Int, Int) -> Void)?
    /// The trackpad key took the drag (`TrackpadEngage`).
    var onEngage: (() -> Void)?
    /// Runs once when the key is held for `holdDelay` with the finger on it; the release then
    /// sends nothing. Nil: holding is a slow tap. Only for a key that doesn't repeat.
    var onHold: (() -> Void)?
    var theme: TermTheme = ThemeStore.fallback { didSet { configure() } }
    var modState: KeyBar.ModState = .off { didSet { if modState != oldValue { restyle() } } }
    /// The key's height; the bar sets it (thinner under a short window).
    private(set) var heightConstraint: NSLayoutConstraint?

    private let face = UIView()
    private let label = UILabel()
    private let icon = UIImageView()
    private let lockBar = UIView()
    private var repeatTimer: Timer?
    private var repeated = false
    private var held = false
    private var anchor: CGPoint = .zero
    private var dragged = false
    /// The trackpad key's touch: whether it has taken the drag yet. Set by tracking; internal for tests.
    var engage: TrackpadEngage?
    /// The trackpad key has the drag: the bar's scroll leaves it alone.
    var trackpadEngaged: Bool { engage?.engaged ?? false }

    /// Points of finger travel per arrow key on the trackpad.
    static let stepX: CGFloat = 14
    static let stepY: CGFloat = 18
    /// How long a press lasts before it is a hold (`onHold`): the system's long press.
    static let holdDelay: TimeInterval = 0.5

    init(key: String, kind: Kind) {
        self.key = key
        self.kind = kind
        super.init(frame: .zero)
        face.isUserInteractionEnabled = false
        face.translatesAutoresizingMaskIntoConstraints = false
        label.textAlignment = .center
        label.adjustsFontForContentSizeCategory = false
        label.translatesAutoresizingMaskIntoConstraints = false
        icon.contentMode = .center
        icon.translatesAutoresizingMaskIntoConstraints = false
        lockBar.layer.cornerRadius = 1
        lockBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(face)
        face.addSubview(label)
        face.addSubview(icon)
        face.addSubview(lockBar)
        let minW: CGFloat = kind == .trackpad ? 60 : 44
        let height = heightAnchor.constraint(equalToConstant: KeyBar.keyHeight)
        heightConstraint = height
        NSLayoutConstraint.activate([
            height,
            widthAnchor.constraint(greaterThanOrEqualToConstant: minW),
            face.leadingAnchor.constraint(equalTo: leadingAnchor),
            face.trailingAnchor.constraint(equalTo: trailingAnchor),
            face.topAnchor.constraint(equalTo: topAnchor),
            face.bottomAnchor.constraint(equalTo: bottomAnchor),
            label.leadingAnchor.constraint(equalTo: face.leadingAnchor, constant: 11),
            label.trailingAnchor.constraint(equalTo: face.trailingAnchor, constant: -11),
            label.centerYAnchor.constraint(equalTo: face.centerYAnchor),
            icon.centerXAnchor.constraint(equalTo: face.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: face.centerYAnchor),
            // A wide symbol (a pair) widens the key, with the label's margins.
            icon.leadingAnchor.constraint(greaterThanOrEqualTo: face.leadingAnchor, constant: 11),
            lockBar.centerXAnchor.constraint(equalTo: face.centerXAnchor),
            lockBar.bottomAnchor.constraint(equalTo: face.bottomAnchor, constant: -5),
            lockBar.widthAnchor.constraint(equalToConstant: 16),
            lockBar.heightAnchor.constraint(equalToConstant: 2),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        isAccessibilityElement = true
        accessibilityLabel = KeyBar.names[key] ?? KeyBar.titles[key] ?? key
        accessibilityTraits = kind == .trackpad ? .adjustable : .keyboardKey
        if kind == .trackpad { accessibilityHint = "Hold, then drag to send arrow keys" }
        if kind == .modifier { accessibilityHint = "Tap for the next key, double-tap to lock" }
        configure()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func configure() {
        if let image = KeyBar.symbolImage(key, pointSize: 16) {
            icon.image = image
            icon.isHidden = false
            label.isHidden = true
            label.text = nil
        } else {
            label.text = KeyBar.titles[key] ?? key
            label.font = RexFont.ui(15)
            label.isHidden = false
            icon.isHidden = true
        }
        restyle()
    }

    /// A pill, concentric with the bar's glass capsule.
    override func layoutSubviews() {
        super.layoutSubviews()
        face.layer.cornerRadius = bounds.height / 2
    }

    /// Keys sit bare on the bar's glass, as items do on a system toolbar; only a pressed key or an
    /// active modifier shows a pill.
    private func restyle() {
        let fg: UIColor
        var fill: UIColor = .clear
        var border: UIColor = .clear
        if kind == .modifier {
            switch modState {
            case .off: fg = theme.uiFG
            case .once:
                fill = theme.uiCursor.withAlphaComponent(0.28)
                border = theme.uiCursor
                fg = theme.uiFG
            case .locked:
                fill = theme.uiCursor
                fg = theme.uiBG
            }
        } else {
            fg = theme.uiFG
        }
        if isHighlighted {
            fill = kind == .modifier && modState == .locked
                ? theme.uiCursor.withAlphaComponent(0.75)
                : theme.uiFG.withAlphaComponent(theme.isDark ? 0.34 : 0.24)
            // The trackpad's ring shows once it has the drag.
            if kind == .trackpad, trackpadEngaged { border = theme.uiCursor }
        }
        face.backgroundColor = fill
        face.layer.borderColor = border.cgColor
        face.layer.borderWidth = border == .clear ? 0 : 1.5
        label.textColor = fg
        icon.tintColor = fg
        lockBar.backgroundColor = fg
        lockBar.isHidden = !(kind == .modifier && modState == .locked)
        accessibilityValue = kind == .modifier ? (modState == .off ? nil : modState == .once ? "on" : "locked") : nil
    }

    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            restyle()
            UIView.animate(withDuration: isHighlighted ? 0.05 : 0.12, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                self.face.transform = self.isHighlighted && self.kind != .trackpad
                    ? CGAffineTransform(scaleX: 0.93, y: 0.93) : .identity
            }
        }
    }

    /// Touches in the gaps between keys and above/below them still count.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: -3, dy: -4).contains(point)
    }

    // MARK: Tracking

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        isHighlighted = true
        repeated = false
        held = false
        dragged = false
        anchor = touch.location(in: self)
        if kind == .trackpad { engage = TrackpadEngage(start: anchor, at: CACurrentMediaTime()) }
        onTouchDown?()
        if kind == .trackpad {
            scheduleEngage()
        } else if kind == .repeating {
            scheduleRepeat(after: 0.4)
        } else if onHold != nil {
            scheduleHold()
        }
        return true
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        if kind == .trackpad {
            let p = touch.location(in: self)
            if var e = engage, !e.engaged {
                let now = e.move(to: p, at: CACurrentMediaTime())
                engage = e
                guard now else { return true }
                engaged()
            }
            guard trackpadEngaged else { return true }
            let nx = Int(((p.x - anchor.x) / Self.stepX).rounded(.towardZero))
            let ny = Int(((p.y - anchor.y) / Self.stepY).rounded(.towardZero))
            if nx != 0 || ny != 0 {
                anchor.x += CGFloat(nx) * Self.stepX
                anchor.y += CGFloat(ny) * Self.stepY
                dragged = true
                onDrag?(nx, ny)
            }
            return true
        }
        let p = touch.location(in: self)
        isHighlighted = bounds.insetBy(dx: -24, dy: -24).contains(p)
        // A finger that starts to swipe stops the repeat; the release then sends what a tap does.
        if kind == .repeating, repeatTimer != nil,
           !RepeatSlop.keepsRepeating(from: anchor, to: p, highlighted: isHighlighted) {
            stopRepeat()
        }
        return true
    }

    /// The trackpad's still hold, from touch-down, on the repeat's timer: the trackpad never repeats.
    private func scheduleEngage() {
        repeatTimer?.invalidate()
        let t = Timer(timeInterval: TrackpadEngage.holdDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.engageTick() }
        }
        RunLoop.main.add(t, forMode: .common)
        repeatTimer = t
    }

    private func engageTick() {
        repeatTimer = nil
        guard isTracking, var e = engage else { return }
        let now = e.hold(at: CACurrentMediaTime())
        engage = e
        if now { engaged() }
    }

    /// The trackpad has the drag: steps count from the engage point, with the tick and the ring.
    private func engaged() {
        guard case .engaged(let at) = engage?.state else { return }
        anchor = at
        restyle()
        onEngage?()
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        stopRepeat()
        let inside = touch.map { bounds.insetBy(dx: -24, dy: -24).contains($0.location(in: self)) } ?? false
        isHighlighted = false
        endEngage()
        if kind == .trackpad {
            if dragged { onFire?() }
        } else if repeated {
            onRepeatEnd?()
        } else if inside, !held {
            onFire?()
        }
    }

    override func cancelTracking(with event: UIEvent?) {
        stopRepeat()
        isHighlighted = false
        endEngage()
        if repeated { onRepeatEnd?() }
        if kind == .trackpad, dragged { onFire?() }
    }

    private func endEngage() {
        guard engage != nil else { return }
        engage = nil
        restyle()
    }

    private func scheduleRepeat(after delay: TimeInterval) {
        repeatTimer?.invalidate()
        let t = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.repeatTick() }
        }
        RunLoop.main.add(t, forMode: .common)
        repeatTimer = t
    }

    /// The hold shares the repeat's timer: a key that holds never repeats.
    private func scheduleHold() {
        repeatTimer?.invalidate()
        let t = Timer(timeInterval: Self.holdDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.holdTick() }
        }
        RunLoop.main.add(t, forMode: .common)
        repeatTimer = t
    }

    /// Held long enough, with the finger still on the key (`isHighlighted`, as for a tap).
    private func holdTick() {
        repeatTimer = nil
        guard isTracking, isHighlighted else { return }
        held = true
        onHold?()
    }

    private var repeatCount = 0

    private func repeatTick() {
        guard isTracking else { stopRepeat(); return }
        if !repeated { repeatCount = 0 }
        repeated = true
        repeatCount += 1
        onRepeat?()
        // Speeds up the longer the key is held.
        scheduleRepeat(after: repeatCount < 8 ? 0.08 : 0.04)
    }

    private func stopRepeat() {
        repeatTimer?.invalidate()
        repeatTimer = nil
    }

    override func accessibilityActivate() -> Bool {
        guard kind != .trackpad else { return false }
        onTouchDown?()
        onFire?()
        return true
    }

    // VoiceOver: swipe up/down on the trackpad key.
    override func accessibilityIncrement() { onDrag?(0, -1) }
    override func accessibilityDecrement() { onDrag?(0, 1) }
}

extension Notification.Name {
    static let keyBarChanged = Notification.Name("RexDuo.keyBarChanged")
}
