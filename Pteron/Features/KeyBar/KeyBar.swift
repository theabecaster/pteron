import UIKit

/// The keys above the software keyboard, in three glass capsules (docs/terminal.md, Key bar):
///
/// - Left, fixed: ⌘ opens the command palette, ✎ opens or closes Compose, and the attach key
///   (paperclip) opens its menu where the pane's computer takes files.
/// - Middle: the keys arranged in Settings → Keyboard (`KeyBarSetup`), scrolling sideways when
///   they don't fit and fading at the edge that has more, then Shift-Return (when shown) and
///   Return, pinned past a hairline.
/// - Right, fixed: the arrows key (✥), a trackpad, and the hide key. Where the system's vertical
///   bar sits beside the keyboard (iPhone Duo) the hide key is that bar's Hide Keyboard item
///   (`HideKeyboardItem`): the bar draws none, and nothing of it reaches into the bar's column,
///   which keeps its own touches. Keys stay off a vertical crease (`KeyBarPlacement`).
///
/// Above the capsules, while Compose is open for the pane, sits the compose card (`ComposeCard`).
///
/// - Keys send on release; a horizontal drag scrolls the middle capsule instead.
/// - Arrows and PgUp/PgDn auto-repeat while held, until the finger moves off (`RepeatSlop`).
/// - ctrl / option / shift / cmd: tap = next key only, double-tap = locked until tapped again.
///   Shift applies to the bar's keys (⇧ then ⇥ is Shift-Tab); the keyboard has its own.
/// - With cmd on, the next key (a bar key or a key typed on the system keyboard) is never typed: it
///   runs through Rex's keymap as that key pressed with ⌘ on a hardware keyboard does
///   (`onShortcut`), with ctrl and option if they are on. A key nothing is bound to does nothing.
/// - The arrows key is a trackpad, as the space bar is on the iOS keyboard: drag from it in any
///   direction to send arrow keys (`TrackpadEngage`).
/// - Return never scrolls. It sends as any bar key does, modifiers and cmd included, and never
///   repeats. Held for `KeyCap.holdDelay` it sends Shift-Return instead, as a hardware keyboard
///   encodes it: a new line without sending in an agent. While an input method composes, Return
///   commits the composition, as the system keyboard's return does, and sends nothing.
/// - While compose's field has the keyboard, keys that type text (a character, a text
///   shortcut), Backspace and Paste of text edit the message; every other key goes to the pane.
/// - Since iOS 26 the keyboard is a glass panel with rounded top corners. The bar draws no
///   background of its own: its capsules float above the keyboard, inset as far as its keys, as
///   the system's own bars float.
@MainActor
final class KeyBar: UIInputView, UIInputViewAudioFeedback, UIScrollViewDelegate {
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
    /// ⌘: the command palette.
    var onPalette: (() -> Void)?
    /// ✎: compose opens or closes.
    var onCompose: (() -> Void)?
    /// The attach key's menu, built each time it opens.
    var attachMenu: (() -> UIMenu)?
    /// The attach key shows only where the pane's server takes files.
    var attachAvailable = false {
        didSet {
            guard attachAvailable != oldValue else { return }
            compose.attachAvailable = attachAvailable
            rebuild()
        }
    }
    /// The system's vertical bar's column beside the keyboard, in screen coordinates
    /// (`VerticalBarObserver`). Nil where bars are horizontal: the hide key is then the bar's own.
    var barColumn: CGRect? { didSet { if barColumn != oldValue { setNeedsLayout() } } }
    /// The vertical bar has the hide key: this bar shows none.
    var hidesInVerticalBar: Bool { KeyBarPlacement.hideKey(column: barColumn) == .verticalBar }
    /// A vertical crease, in the terminal's window coordinates. Nil without one.
    var crease: CGRect? { didSet { if crease != oldValue { setNeedsLayout() } } }

    /// The compose card, shown above the capsules while `composeOpen`.
    let compose = ComposeCard()
    /// Compose is open for this bar's pane: the card shows and the bar is taller by its height.
    var composeOpen = false {
        didSet {
            guard composeOpen != oldValue else { return }
            compose.isHidden = !composeOpen
            compose.transform = .identity
            composeCap?.active = composeOpen
            composeCap?.accessibilityValue = composeOpen ? "Open" : nil
            applySize()
        }
    }
    /// Compose's field has the keyboard: keys that type text edit the message.
    var composeEditing: Bool { compose.field.isFirstResponder }

    enum ModState { case off, once, locked }

    /// A capsule with 4 pt of air above and below it, so it floats clear of the keyboard.
    static let barHeight: CGFloat = 54
    static let keyHeight: CGFloat = 42
    /// Under a short window (landscape iPhone) the bar is thinner, to leave rows for the panes.
    static let compactBarHeight: CGFloat = 42
    static let compactKeyHeight: CGFloat = 34
    /// A capsule's margin around its keys, so a pressed key's pill sits concentric in it.
    static let ring: CGFloat = 2
    /// The capsules' distance from the bar's sides: in line with the keyboard's own keys, inside
    /// its rounded corners.
    static let sideInset: CGFloat = 6
    /// The space between two capsules.
    static let capsuleGap: CGFloat = 6
    /// The find bar's space between its field's capsule and its Done circle.
    static let hideGap: CGFloat = 8
    /// The space between the compose card and the capsules.
    static let cardGap: CGFloat = 8
    /// How far the middle capsule's keys fade out at an edge with more keys past it.
    static let fade: CGFloat = 18

    private var barHeightConstraint: NSLayoutConstraint?
    private var compact: Bool { traitCollection.verticalSizeClass == .compact }
    private var keyHeight: CGFloat { compact ? Self.compactKeyHeight : Self.keyHeight }
    /// The bar's height: the row of capsules, and the compose card above it while it is open.
    static func height(compact: Bool, composeOpen: Bool) -> CGFloat {
        (compact ? compactBarHeight : barHeight) + (composeOpen ? ComposeCard.height(compact: compact) + cardGap : 0)
    }

    /// The part of the bar's height Compose's card takes, with its gap: 0 while it is closed.
    var cardRoom: CGFloat {
        Self.height(compact: compact, composeOpen: composeOpen) - Self.height(compact: compact, composeOpen: false)
    }

    private let leftCapsule = UIVisualEffectView()
    private let leftStack = UIStackView()
    private let middleCapsule = UIVisualEffectView()
    /// Holds the scrolling keys and fades them at an edge (`fadeMask`).
    private let clip = UIView()
    private let fadeMask = CAGradientLayer()
    private var fadeEdges = (leading: false, trailing: false)
    private let scroll = KeyScroll()
    private let stack = UIStackView()
    private let rightCapsule = UIVisualEffectView()
    private let rightStack = UIStackView()
    /// Return, at the middle capsule's trailing end. Internal for tests.
    private(set) var pinnedCaps: [KeyCap] = []
    /// The left capsule's keys: ⌘, ✎ and attach where it shows. Internal for tests.
    private(set) var leftCaps: [KeyCap] = []
    /// The right capsule's keys: ✥ and the hide key. Internal for tests.
    private(set) var rightCaps: [KeyCap] = []
    /// Every key of the bar, left to right. Internal for tests.
    var allCaps: [KeyCap] { leftCaps + caps + pinnedCaps + rightCaps }
    private weak var composeCap: KeyCap?
    private weak var hideCap: KeyCap?
    /// A hairline between the scrolling keys and Return: keys scroll under it.
    private let divider = UIView()
    private var dividerWidth: NSLayoutConstraint?
    private var placement = KeyBarPlacement.HideKey.inBar
    private var stackLeading: NSLayoutConstraint?
    private var creaseGap: (index: Int, extra: CGFloat)?
    /// The space between keys in a capsule.
    private static let spacing: CGFloat = 2
    /// The middle capsule's scrolling keys. Internal for tests.
    private(set) var caps: [KeyCap] = []
    private var theme: TermTheme = ThemeStore.fallback
    private(set) var ctrl: ModState = .off { didSet { syncModifiers() } }
    private(set) var alt: ModState = .off { didSet { syncModifiers() } }
    private(set) var shift: ModState = .off { didSet { syncModifiers() } }
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
        // The height follows the bar's own (compose's card comes and goes on screen): a frame
        // with a fixed height would pin it to the first one.
        autoresizingMask = .flexibleHeight
        backgroundColor = .clear
        for capsule in [leftCapsule, middleCapsule, rightCapsule] {
            Glass.makeGlass(capsule)
            addSubview(capsule)
        }
        for s in [leftStack, rightStack, stack] {
            s.axis = .horizontal
            s.alignment = .center
            s.spacing = Self.spacing
            s.translatesAutoresizingMaskIntoConstraints = false
        }
        leftCapsule.contentView.addSubview(leftStack)
        rightCapsule.contentView.addSubview(rightStack)
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceHorizontal = true
        scroll.delaysContentTouches = false
        scroll.canCancelContentTouches = true
        scroll.clipsToBounds = false
        scroll.delegate = self
        scroll.translatesAutoresizingMaskIntoConstraints = false
        // Keys scrolled to an end slip under the capsule's round end, or fade at the hairline.
        clip.clipsToBounds = true
        clip.translatesAutoresizingMaskIntoConstraints = false
        fadeMask.startPoint = CGPoint(x: 0, y: 0.5)
        fadeMask.endPoint = CGPoint(x: 1, y: 0.5)
        clip.layer.mask = fadeMask
        divider.isUserInteractionEnabled = false
        divider.translatesAutoresizingMaskIntoConstraints = false
        let content = middleCapsule.contentView
        content.addSubview(clip)
        content.addSubview(divider)
        clip.addSubview(scroll)
        scroll.addSubview(stack)
        compose.isHidden = true
        addSubview(compose)
        let pinned = UIStackView()
        pinned.axis = .horizontal
        pinned.alignment = .center
        pinned.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(pinned)
        pinnedStack = pinned
        let barHeight = heightAnchor.constraint(equalToConstant: Self.barHeight)
        barHeight.priority = .required - 1
        barHeightConstraint = barHeight
        let leading = stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: Self.ring)
        stackLeading = leading
        let dividerWidth = divider.widthAnchor.constraint(equalToConstant: 1)
        self.dividerWidth = dividerWidth
        let r = Self.ring
        NSLayoutConstraint.activate([
            barHeight,
            leftStack.leadingAnchor.constraint(equalTo: leftCapsule.contentView.leadingAnchor, constant: r),
            leftStack.centerYAnchor.constraint(equalTo: leftCapsule.contentView.centerYAnchor),
            rightStack.leadingAnchor.constraint(equalTo: rightCapsule.contentView.leadingAnchor, constant: r),
            rightStack.centerYAnchor.constraint(equalTo: rightCapsule.contentView.centerYAnchor),
            // Scrolling keys | divider | Shift-Return, Return, Return concentric with the capsule's end.
            clip.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            clip.topAnchor.constraint(equalTo: content.topAnchor),
            clip.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: clip.trailingAnchor, constant: 3),
            dividerWidth,
            divider.heightAnchor.constraint(equalTo: content.heightAnchor, multiplier: 0.4),
            divider.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            pinned.leadingAnchor.constraint(equalTo: divider.trailingAnchor, constant: 3),
            pinned.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -r),
            pinned.topAnchor.constraint(equalTo: content.topAnchor),
            pinned.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: clip.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: clip.bottomAnchor),
            leading,
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -r),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])
        rebuild()
        NotificationCenter.default.addObserver(self, selector: #selector(prefsChanged), name: .keyBarChanged, object: nil)
        registerForTraitChanges([UITraitVerticalSizeClass.self, UITraitDisplayScale.self]) { (bar: KeyBar, _) in bar.applySize() }
    }

    private var pinnedStack = UIStackView()

    /// The bar's height changed while it is on screen (compose opened or closed): the keyboard
    /// reads it again only when its responder reloads its input views (`TerminalHost`).
    var onHeightChange: (() -> Void)?

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: Self.height(compact: compact, composeOpen: composeOpen))
    }

    /// Thinner bar and keys under a short window; taller by the card while compose is open.
    private func applySize() {
        let height = Self.height(compact: compact, composeOpen: composeOpen)
        let changed = barHeightConstraint?.constant != height
        barHeightConstraint?.constant = height
        compose.compact = compact
        for cap in leftCaps + caps + pinnedCaps + rightCaps { cap.heightConstraint?.constant = keyHeight }
        dividerWidth?.constant = 1 / max(traitCollection.displayScale, 1)
        invalidateIntrinsicContentSize()
        setNeedsLayout()
        if changed, window != nil { onHeightChange?() }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        placement = KeyBarPlacement.hideKey(column: barColumn)
        hideCap?.isHidden = placement == .verticalBar
        // The capsules' keys run in the bar's direction, also where only the bar was told it.
        let direction: UISemanticContentAttribute =
            effectiveUserInterfaceLayoutDirection == .rightToLeft ? .forceRightToLeft : .forceLeftToRight
        for s in [leftStack, stack, pinnedStack, rightStack] where s.semanticContentAttribute != direction {
            s.semanticContentAttribute = direction
        }
        layoutGlass()
        super.layoutSubviews()
        keepKeysOffCrease()
        refreshFade()
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
    static let frameChanged = Notification.Name("Pteron.keyBarFrameChanged")
    /// The frame last reported, in screen coordinates; nil out of a window or hidden.
    private var reportedFrame: CGRect?
    /// How many times the bar reported itself. Internal for tests.
    private(set) var frameReports = 0
    /// Runs once the bar is next in a window (`whenInWindow`).
    private var inWindowWork: [() -> Void] = []

    override func didMoveToWindow() {
        super.didMoveToWindow()
        reportFrame(force: true)
        if window != nil, !inWindowWork.isEmpty {
            let work = inWindowWork
            inWindowWork = []
            // After the keyboard's window has laid the bar out: a field in it can then take the keyboard.
            DispatchQueue.main.async { work.forEach { $0() } }
        }
    }

    /// Runs `body` now if the bar is in a window, else once it is.
    func whenInWindow(_ body: @escaping () -> Void) {
        if window != nil { body() } else { inWindowWork.append(body) }
    }

    /// Drops what waits for the bar to be in a window.
    func cancelWhenInWindow() { inWindowWork = [] }

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

    /// The width of a capsule around `caps`.
    private static func width(_ caps: [KeyCap]) -> CGFloat {
        let shown = caps.filter { !$0.isHidden }
        guard !shown.isEmpty else { return 0 }
        let keys = shown.reduce(0) { $0 + $1.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width }
        return keys + spacing * CGFloat(shown.count - 1) + 2 * ring
    }

    /// Places the capsules and the card. The left and right capsules hug their keys at the ends
    /// of the space the bar may use (`KeyBarPlacement.span`: inside its safe area, short of the
    /// vertical bar's column); the middle one starts after the left one and is as wide as its keys
    /// need, up to the right one. The card spans the same space above them.
    private func layoutGlass() {
        let h = keyHeight + 2 * Self.ring
        let card = composeOpen ? ComposeCard.height(compact: compact) + Self.cardGap : 0
        let rowHeight = max(bounds.height - safeAreaInsets.bottom - card, h)
        let span = KeyBarPlacement.span(width: bounds.width, leftInset: safeAreaInsets.left, rightInset: safeAreaInsets.right,
                                        sideInset: Self.sideInset, column: localColumn)
        let y = card + ((rowHeight - h) / 2).rounded()
        let leftW = Self.width(leftCaps), rightW = Self.width(rightCaps)
        let lo = span.lowerBound + (leftW > 0 ? leftW + Self.capsuleGap : 0)
        let hi = span.upperBound - (rightW > 0 ? rightW + Self.capsuleGap : 0)
        let available = max(hi - lo, h)
        let pinnedW = pinnedCaps.reduce(0) { $0 + $1.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width }
        let keysW = caps.isEmpty ? 0 : stack.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width + 2 * Self.ring
        var middleW = min(available, keysW + 7 + pinnedW + Self.ring)
        // Return never sits on a vertical crease: on one, the capsule runs to the right capsule.
        if let fold = localCrease, middleW < available {
            let returnSpan = (lo + middleW - Self.ring - pinnedW - KeyBarPlacement.creaseClearance)...(lo + middleW + KeyBarPlacement.creaseClearance)
            if returnSpan.overlaps(fold.minX...fold.maxX) { middleW = available }
        }
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        // Right to left, the same within the span: the column and the safe area are where they are.
        func place(_ x: CGFloat, _ w: CGFloat) -> CGRect {
            CGRect(x: rtl ? span.lowerBound + span.upperBound - x - w : x, y: y, width: w, height: h)
        }
        leftCapsule.isHidden = leftW == 0
        rightCapsule.isHidden = rightW == 0
        leftCapsule.frame = place(span.lowerBound, leftW)
        rightCapsule.frame = place(span.upperBound - rightW, rightW)
        middleCapsule.frame = place(lo, middleW)
        for capsule in [leftCapsule, middleCapsule, rightCapsule] { Glass.round(capsule, radius: h / 2) }
        divider.isHidden = caps.isEmpty
        // Keys slip under the capsule's round leading end, and stop straight at the divider.
        clip.layer.cornerRadius = h / 2
        clip.layer.maskedCorners = rtl ? [.layerMaxXMinYCorner, .layerMaxXMaxYCorner] : [.layerMinXMinYCorner, .layerMinXMaxYCorner]
        // By bounds and center, which a transform doesn't change: a layout pass while the
        // handle is dragged leaves the card where the finger has it.
        let cardFrame = CGRect(x: span.lowerBound, y: 0, width: span.upperBound - span.lowerBound,
                               height: ComposeCard.height(compact: compact))
        compose.bounds = CGRect(origin: .zero, size: cardFrame.size)
        compose.center = CGPoint(x: cardFrame.midX, y: cardFrame.midY)
    }

    /// The vertical crease in the bar's coordinates, nil without one or out of a window.
    private var localCrease: CGRect? {
        // The terminal's window; the bar's own where there is no terminal (tests).
        guard let crease, let tw = terminal?.window ?? window, let screen = tw.windowScene?.screen, window != nil else { return nil }
        return convert(tw.convert(crease, to: screen.coordinateSpace), from: screen.coordinateSpace)
    }

    /// Adds space before the key that would sit on a vertical crease with the middle capsule at
    /// its start, so no key straddles the fold.
    private func keepKeysOffCrease() {
        var gap: (index: Int, extra: CGFloat)?
        if let r = localCrease, effectiveUserInterfaceLayoutDirection == .leftToRight {
            let x = middleCapsule.frame.minX
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

    // MARK: The fade

    func scrollViewDidScroll(_ scrollView: UIScrollView) { refreshFade() }

    /// The middle capsule's keys fade out at an edge past which there are more. Only a change of
    /// which edges fade, or of the size, touches the mask: a scroll costs two comparisons.
    private func refreshFade() {
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        let x = scroll.contentOffset.x, maxX = scroll.contentSize.width - scroll.bounds.width
        let atStart = rtl ? x >= maxX - 1 : x <= 1
        let atEnd = rtl ? x <= 1 : x >= maxX - 1
        let edges = (leading: !atStart, trailing: !atEnd && maxX > 1)
        let size = clip.bounds.size
        guard edges != fadeEdges || fadeMask.frame.size != size else { return }
        fadeEdges = edges
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fadeMask.frame = CGRect(origin: .zero, size: size)
        let f = size.width > 0 ? min(Self.fade / size.width, 0.4) : 0
        let left = rtl ? edges.trailing : edges.leading, right = rtl ? edges.leading : edges.trailing
        let solid = UIColor.black.cgColor, gone = UIColor.clear.cgColor
        fadeMask.colors = [left ? gone : solid, solid, solid, right ? gone : solid]
        fadeMask.locations = [0, NSNumber(value: Double(f)), NSNumber(value: Double(1 - f)), 1]
        CATransaction.commit()
    }

    @objc private func prefsChanged() { rebuild() }

    func apply(theme: TermTheme) {
        self.theme = theme
        compose.apply(theme: theme)
        rebuild()
    }

    private func rebuild() {
        // The glass follows the theme, as the keyboard does (`GhosttyTerminalView.keyboardAppearance`).
        let style: UIUserInterfaceStyle = theme.isDark ? .dark : .light
        for capsule in [leftCapsule, middleCapsule, rightCapsule] { capsule.overrideUserInterfaceStyle = style }
        for s in [leftStack, stack, pinnedStack, rightStack] { s.arrangedSubviews.forEach { $0.removeFromSuperview() } }
        creaseGap = nil
        stackLeading?.constant = Self.ring
        setNeedsLayout()

        leftCaps = ["palette", "compose"].map { makeCap($0) }
        if attachAvailable {
            let cap = makeCap("attach")
            addMenu(to: cap, label: Self.names["attach"] ?? "Attach",
                    hint: "Send photos or files, or browse the computer's files") { [weak self] in
                UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] done in
                    done(self?.attachMenu?().children ?? [])
                }])
            }
            attachButton = cap.menuButton
            leftCaps.append(cap)
        }
        composeCap = leftCaps[1]
        composeCap?.active = composeOpen
        composeCap?.accessibilityValue = composeOpen ? "Open" : nil
        leftCaps.forEach(leftStack.addArrangedSubview)

        let setup = Prefs.shared.keyBarSetup
        caps = setup.items.map { item in
            switch item {
            case .key(let key): return makeCap(key)
            case .shortcut(let s): return makeShortcutCap(s)
            case .group(let g): return makeGroupCap(g)
            }
        }
        caps.forEach(stack.addArrangedSubview)

        let enter = makeCap("enter")
        enter.onHold = { [weak self] in self?.hold("enter") }
        enter.accessibilityHint = "Hold for Shift-Return, a new line in an agent"
        enter.accessibilityCustomActions = [UIAccessibilityCustomAction(name: "Shift-Return") { [weak self] _ in
            self?.hold("enter")
            return true
        }]
        // Shift-Return, when shown, is pinned right before Return: it never scrolls away.
        pinnedCaps = (setup.showsShiftReturn ? [makeCap(KeyBarSetup.shiftReturn)] : []) + [enter]
        pinnedCaps.forEach(pinnedStack.addArrangedSubview)

        let hide = makeCap("hide")
        hideCap = hide
        rightCaps = [makeCap("arrows"), hide]
        rightCaps.forEach(rightStack.addArrangedSubview)

        divider.backgroundColor = theme.uiFG.withAlphaComponent(theme.isDark ? 0.28 : 0.22)
        fadeEdges = (false, false)
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

    /// A group's shortcut as its own key.
    private func makeShortcutCap(_ s: Shortcut) -> KeyCap {
        let cap = KeyCap(key: "shortcut", kind: .normal, title: s.label, name: s.name)
        cap.theme = theme
        cap.onTouchDown = { [weak self] in self?.touchDown("shortcut") }
        cap.onFire = { [weak self] in self?.fire(shortcut: s) }
        return cap
    }

    /// A group's button: a tap opens a menu of its turned-on shortcuts.
    private func makeGroupCap(_ g: ShortcutGroup) -> KeyCap {
        let cap = KeyCap(key: "group", kind: .action, symbol: g.id.symbol, name: g.title)
        cap.theme = theme
        let shortcuts = g.items.filter(\.on)
        addMenu(to: cap, label: g.title, hint: "Shows its shortcuts") { [weak self] in
            UIMenu(title: g.title, children: shortcuts.map { s in
                UIAction(title: s.label, subtitle: s.name) { [weak self] _ in self?.fire(shortcut: s) }
            })
        }
        return cap
    }

    private weak var attachButton: UIButton?

    #if DEBUG
    /// `-filesTest menu`: opens the attach menu as a tap does; `reveal` does nothing more, as the
    /// attach key never scrolls.
    func openAttachMenu(open: Bool = true) {
        guard let button = attachButton else { return }
        // Off screen (the keyboard is down) the menu has nothing to show from: UIKit raises
        // on a menu's preview for a view that is in no window.
        if open, button.window != nil { button.performPrimaryAction() }
    }
    #endif

    /// A key that opens a menu on a tap: a button over the key, which keeps the key's look.
    private func addMenu(to cap: KeyCap, label: String, hint: String, menu: () -> UIMenu) {
        let button = UIButton(type: .custom)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.showsMenuAsPrimaryAction = true
        button.menu = menu()
        let key = cap.key
        button.addAction(UIAction { [weak self, weak cap] _ in
            cap?.isHighlighted = true
            self?.touchDown(key)
        }, for: .touchDown)
        for event: UIControl.Event in [.touchUpInside, .touchUpOutside, .touchCancel, .menuActionTriggered] {
            button.addAction(UIAction { [weak cap] _ in cap?.isHighlighted = false }, for: event)
        }
        cap.isAccessibilityElement = false
        button.accessibilityLabel = label
        button.accessibilityHint = hint
        cap.addSubview(button)
        cap.menuButton = button
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: cap.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: cap.trailingAnchor),
            button.topAnchor.constraint(equalTo: cap.topAnchor),
            button.bottomAnchor.constraint(equalTo: cap.bottomAnchor),
        ])
    }

    static func kind(of key: String) -> KeyCap.Kind {
        switch key {
        case "ctrl", "alt", "shift", "cmd": return .modifier
        case "arrows": return .trackpad
        case "up", "down", "left", "right", "pgup", "pgdn", "backspace", "delete": return .repeating
        case "paste", "hide", "attach", "palette", "compose", "group": return .action
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
            switch cap.key {
            case "ctrl": cap.modState = ctrl
            case "alt": cap.modState = alt
            case "shift": cap.modState = shift
            case "cmd": cap.modState = cmd
            default: break
            }
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
    /// locked ones stay on. A one-shot shift ends with any key.
    func consumedModifiers() {
        guard let t = terminal else { return }
        if ctrl == .once, !t.controlModifier { ctrl = .off }
        if alt == .once, !t.metaModifier { alt = .off }
        if shift == .once { shift = .off }
        if ctrl == .locked, !t.controlModifier { t.controlModifier = true }
        if alt == .locked, !t.metaModifier { t.metaModifier = true }
    }

    /// Bar keys apply the modifiers themselves; one-shot ones end here, as does the key's press.
    private func usedModifiers() {
        shortcutRan = false
        if ctrl == .once { ctrl = .off }
        if alt == .once { alt = .off }
        if shift == .once { shift = .off }
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
        case "shift": s = Self.next(shift, quick: quick)
        default: s = Self.next(cmd, quick: quick)
        }
        if s == .locked { lockImpact.impactOccurred() }
        switch key {
        case "ctrl": ctrl = s
        case "alt": alt = s
        case "shift": shift = s
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
        case "ctrl", "alt", "shift", "cmd": tapModifier(key)
        case "paste":
            if composeEditing, UIPasteboard.general.hasStrings {
                compose.field.paste(nil)
            } else {
                onPaste?()
            }
            usedModifiers()
        case "hide": onHideKeyboard?()
        case "palette": onPalette?()
        case "compose": onCompose?()
        case "arrows": usedModifiers()  // after a drag
        case "enter" where commitComposition(): break
        case "shift-enter": shiftReturn()
        default: send(key)
        }
    }

    /// A group's shortcut. One that a bar key also sends goes through that key's path, with the
    /// bar's modifiers and cmd; longer text is typed as it is, and a key with modifiers is sent
    /// as its chord with the bar's ctrl, option and shift added. Internal for tests.
    func fire(shortcut s: Shortcut) {
        guard !blocked else { return }
        if let key = s.barKey { return fire(key) }
        switch s.send {
        case .text(let text):
            if composeEditing {
                compose.field.insertText(text)
            } else {
                terminal?.send(data: Array(text.utf8)[...])
            }
        case .key(var stroke):
            stroke.ctrl = stroke.ctrl || ctrl != .off
            stroke.alt = stroke.alt || alt != .off
            stroke.shift = stroke.shift || shift != .off
            if cmd != .off {
                var mods = shortcutMods
                if stroke.ctrl { mods.insert(.ctrl) }
                if stroke.alt { mods.insert(.alt) }
                if stroke.shift { mods.insert(.shift) }
                let ran = KeyInput.press(barKey: stroke.chord.key, mods: mods).map { onShortcut?($0, false) ?? false } ?? false
                if !ran { onUnbound() }
            } else if stroke.key == "enter", stroke.shift {
                terminal?.sendShiftReturn(ctrl: stroke.ctrl, alt: stroke.alt)
            } else if let bytes = stroke.bytes {
                terminal?.send(data: bytes[...])
            }
        }
        usedModifiers()
    }

    /// A key held for `KeyCap.holdDelay`: Return becomes Shift-Return (`shiftReturn`). Internal
    /// for tests.
    func hold(_ key: String) {
        guard key == "enter", !blocked else { return }
        lockImpact.impactOccurred()
        shiftReturn()
    }

    /// Shift-Return, for the held Return and the ⇧⏎ key: with the bar's modifiers, encoded as a
    /// hardware Shift-Return is (`CSI 27;2;13~`, or `CSI 13;2u` under the Kitty protocol), so an
    /// agent starts a new line instead of sending. With cmd it is the shift+cmd+enter chord. While
    /// an input method composes it only commits the composition, as Return does.
    private func shiftReturn() {
        guard !commitComposition() else { return }
        if cmd != .off {
            let press = KeyInput.press(barKey: "enter", mods: shortcutMods.union(.shift))
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

    /// One key of the bar: typed with ctrl / option / shift, or with cmd run as a shortcut and
    /// never typed. A held key or a trackpad drag runs its shortcut once, then as repeats. While
    /// compose's field has the keyboard, a key that types text or Backspace edits the message.
    private func emit(_ key: String) {
        guard !blocked else { return }
        if composeEditing, ctrl == .off, alt == .off, cmd == .off {
            if key == "backspace" { return compose.field.deleteBackward() }
            if let text = Self.composeText(for: key) {
                return compose.field.insertText(shift != .off ? text.uppercased() : text)
            }
        }
        guard cmd != .off else { return sendRaw(key) }
        let isRepeat = shortcutRan
        shortcutRan = true
        var mods = shortcutMods
        if shift != .off { mods.insert(.shift) }
        let ran = KeyInput.press(barKey: key, mods: mods).map { onShortcut?($0, isRepeat) ?? false } ?? false
        if !ran, !isRepeat { onUnbound() }
    }

    /// The text a bar key types, nil for a key that types none (a named key, a control key, a
    /// modifier, an action).
    static func composeText(for key: String) -> String? {
        guard kind(of: key) == .normal, !key.hasPrefix("ctrl-"), chordName(key) == nil, key != "shift-tab", key != "enter",
              key != "shift-enter" else { return nil }
        return key
    }

    /// A key typed on the system keyboard while cmd is on (`GhosttyTerminalView.commandKeyHook`).
    private func typedWithCommand(_ text: String) {
        let ran = KeyInput.press(typing: text, mods: shortcutMods).map { onShortcut?($0, false) ?? false } ?? false
        if !ran { onUnbound() }
        usedModifiers()
    }

    /// A key typed into compose's field while ctrl, option or cmd is on: it goes to the pane, as
    /// the same key typed into the terminal would, and not into the message. True when it did.
    func typedInCompose(_ text: String) -> Bool {
        guard !blocked, ctrl != .off || alt != .off || cmd != .off else { return false }
        if cmd != .off {
            typedWithCommand(text)
        } else {
            send(text)
        }
        return true
    }

    /// cmd with the bar's ctrl and option.
    private var shortcutMods: KeyMods {
        var m: KeyMods = .cmd
        if ctrl != .off { m.insert(.ctrl) }
        if alt != .off { m.insert(.alt) }
        return m
    }

    /// A bar key's name in a key binding (`KeyChord`), for the keys that type no character.
    static func chordName(_ key: String) -> String? {
        switch key {
        case "esc": return "escape"
        case "tab", "enter", "backspace", "delete", "up", "down", "left", "right", "home", "end": return key
        case "pgup": return "pageup"
        case "pgdn": return "pagedown"
        default:
            if key.count > 1, key.hasPrefix("f"), let n = Int(key.dropFirst()), (1...12).contains(n) { return key }
            return nil
        }
    }

    private func sendRaw(_ key: String) {
        guard let t = terminal else { return }
        let c = ctrl != .off, a = alt != .off, s = shift != .off
        if s {
            // Shift with a key that types none: the chord a hardware keyboard sends for it.
            if key == "enter" { return t.sendShiftReturn(ctrl: c, alt: a) }
            if let name = Self.chordName(key) {
                var mods: KeyMods = .shift
                if c { mods.insert(.ctrl) }
                if a { mods.insert(.alt) }
                if let seq = KeyInput.bytes(KeyChord(mods: mods, key: name)) { t.send(data: seq[...]) }
                return
            }
        }
        if !c && !a && !s {
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
        guard var out = Self.bytes(for: s && key.count == 1 ? key.uppercased() : key, appCursor: false) else { return }
        if c, out.count == 1, let ch = Self.control(out[0]) { out = [ch] }
        if a { out = [0x1b] + out }
        t.send(data: out[...])
    }

    /// xterm-style modified cursor / function keys (e.g. ctrl-left = ESC [1;5D).
    nonisolated static func modifiedSequence(_ key: String, mod: Int) -> [UInt8]? {
        let letters = ["up": "A", "down": "B", "right": "C", "left": "D", "home": "H", "end": "F",
                       "f1": "P", "f2": "Q", "f3": "R", "f4": "S"]
        let tildes = ["delete": 3, "pgup": 5, "pgdn": 6, "f5": 15, "f6": 17, "f7": 18, "f8": 19, "f9": 20, "f10": 21,
                      "f11": 23, "f12": 24]
        if let l = letters[key] { return Array("\u{1b}[1;\(mod)\(l)".utf8) }
        if let n = tildes[key] { return Array("\u{1b}[\(n);\(mod)~".utf8) }
        return nil
    }

    /// The control character for a byte, as the terminal sends it for the system keyboard.
    nonisolated static func control(_ b: UInt8) -> UInt8? {
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

    nonisolated static func bytes(for key: String, appCursor: Bool) -> [UInt8]? {
        let csi: (String) -> [UInt8] = { Array("\u{1b}[\($0)".utf8) }
        let ss3: (String) -> [UInt8] = { Array("\u{1b}O\($0)".utf8) }
        switch key {
        case "esc": return [0x1b]
        case "tab": return [0x09]
        case "shift-tab": return csi("Z")
        case "enter": return [0x0d]
        case "backspace": return [0x7f]
        case "delete": return csi("3~")
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
        // Shift-Return's bytes come from the engine's encoder, under the program's modes
        // (`GhosttyTerminalView.sendShiftReturn`).
        case "shift-enter", "arrows", "ctrl", "alt", "shift", "cmd", "paste", "hide", "attach", "palette", "compose", "group",
             "shortcut":
            return nil
        default:
            // "ctrl-x" sends that control character; anything else is literal text.
            if key.hasPrefix("ctrl-"), key.count == 6, let b = key.utf8.last, let c = control(b) { return [c] }
            return Array(key.utf8)
        }
    }

    static let symbols: [String: String] = [
        "left": "arrow.left", "right": "arrow.right", "up": "arrow.up", "down": "arrow.down",
        "paste": "doc.on.clipboard", "attach": "paperclip", "hide": "keyboard.chevron.compact.down", "enter": "return",
        "tab": "arrow.right.to.line", "backspace": "delete.left", "delete": "delete.right",
        "ctrl": "control", "alt": "option", "shift": "shift",
        "palette": "command", "compose": "square.and.pencil",
        "arrows": "dot.arrowtriangles.up.right.down.left.circle",
    ]
    static let titles: [String: String] = [
        "esc": "esc", "cmd": "cmd", "ctrl-c": "^C", "ctrl-d": "^D", "ctrl-z": "^Z", "ctrl-r": "^R",
        "ctrl-l": "^L", "ctrl-a": "^A", "ctrl-e": "^E", "ctrl-u": "^U", "ctrl-w": "^W", "ctrl-o": "^O", "ctrl-k": "^K",
        "pgup": "PgUp", "pgdn": "PgDn", "home": "Home", "end": "End",
        "f1": "F1", "f2": "F2", "f3": "F3", "f4": "F4", "f5": "F5", "f6": "F6", "f7": "F7", "f8": "F8", "f9": "F9",
        "f10": "F10", "f11": "F11", "f12": "F12",
    ]
    /// Spoken names for VoiceOver and Settings.
    static let names: [String: String] = [
        "left": "Left", "right": "Right", "up": "Up", "down": "Down", "paste": "Paste", "attach": "Attach", "hide": "Hide Keyboard",
        "enter": "Return", "shift-enter": "Shift-Return", "tab": "Tab", "shift-tab": "Shift-Tab", "arrows": "Arrow Trackpad", "esc": "Escape",
        "ctrl": "Control", "alt": "Option", "shift": "Shift", "cmd": "Command",
        "backspace": "Backspace", "delete": "Delete",
        "palette": "Command Palette", "compose": "Compose",
        "ctrl-c": "Control-C", "ctrl-d": "Control-D", "ctrl-z": "Control-Z", "ctrl-r": "Control-R", "ctrl-l": "Control-L",
        "ctrl-a": "Control-A", "ctrl-e": "Control-E", "ctrl-u": "Control-U", "ctrl-w": "Control-W", "ctrl-o": "Control-O",
        "pgup": "Page Up", "pgdn": "Page Down", "home": "Home", "end": "End",
    ]
    /// Keys shown as two symbols side by side: shift-tab as ⇧⇥ and shift-enter as ⇧⏎, as macOS
    /// menus spell them.
    static let symbolPairs: [String: [String]] = [
        "shift-tab": ["shift", "arrow.right.to.line"], "shift-enter": ["shift", "return"],
    ]

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
    /// What the key shows instead of its key's title or symbol: a shortcut's label.
    private let title: String?
    /// A symbol shown instead of the key's own: a shortcut group's.
    private let symbol: String?
    /// The button over a key that opens a menu (attach, a shortcut group).
    var menuButton: UIButton?
    /// The key's mode is on (compose open): it shows a pill, as an active modifier does.
    var active = false { didSet { if active != oldValue { restyle() } } }
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

    init(key: String, kind: Kind, title: String? = nil, symbol: String? = nil, name: String? = nil) {
        self.key = key
        self.kind = kind
        self.title = title
        self.symbol = symbol
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
        let minW: CGFloat = 40
        let height = heightAnchor.constraint(equalToConstant: KeyBar.keyHeight)
        heightConstraint = height
        NSLayoutConstraint.activate([
            height,
            widthAnchor.constraint(greaterThanOrEqualToConstant: minW),
            face.leadingAnchor.constraint(equalTo: leadingAnchor),
            face.trailingAnchor.constraint(equalTo: trailingAnchor),
            face.topAnchor.constraint(equalTo: topAnchor),
            face.bottomAnchor.constraint(equalTo: bottomAnchor),
            label.leadingAnchor.constraint(equalTo: face.leadingAnchor, constant: 9),
            label.trailingAnchor.constraint(equalTo: face.trailingAnchor, constant: -9),
            label.centerYAnchor.constraint(equalTo: face.centerYAnchor),
            icon.centerXAnchor.constraint(equalTo: face.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: face.centerYAnchor),
            // A wide symbol (a pair) widens the key, with the label's margins.
            icon.leadingAnchor.constraint(greaterThanOrEqualTo: face.leadingAnchor, constant: 9),
            lockBar.centerXAnchor.constraint(equalTo: face.centerXAnchor),
            lockBar.bottomAnchor.constraint(equalTo: face.bottomAnchor, constant: -5),
            lockBar.widthAnchor.constraint(equalToConstant: 16),
            lockBar.heightAnchor.constraint(equalToConstant: 2),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        isAccessibilityElement = true
        accessibilityLabel = name ?? title ?? KeyBar.names[key] ?? KeyBar.titles[key] ?? key
        accessibilityTraits = kind == .trackpad ? .adjustable : .keyboardKey
        if kind == .trackpad { accessibilityHint = "Hold, then drag to send arrow keys" }
        if kind == .modifier { accessibilityHint = "Tap for the next key, double-tap to lock" }
        if key == "compose" { accessibilityHint = "Opens a text field for writing a message to the pane" }
        configure()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func configure() {
        let config = UIImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        if let image = title != nil ? nil : symbol.flatMap({ UIImage(systemName: $0, withConfiguration: config) })
            ?? KeyBar.symbolImage(key, pointSize: 16) {
            icon.image = image
            icon.isHidden = false
            label.isHidden = true
            label.text = nil
        } else {
            label.text = title ?? KeyBar.titles[key] ?? key
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
            if active { fill = theme.uiFG.withAlphaComponent(theme.isDark ? 0.2 : 0.14) }
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
        if kind == .modifier { accessibilityValue = modState == .off ? nil : modState == .once ? "on" : "locked" }
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
        // Among scrolling keys a sideways swipe scrolls; in its own capsule any drag is the trackpad's.
        if kind == .trackpad {
            engage = TrackpadEngage(start: anchor, at: CACurrentMediaTime(), anyDirection: !(superview?.superview is KeyScroll))
        }
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
    static let keyBarChanged = Notification.Name("Pteron.keyBarChanged")
}
