import UIKit

/// The row of extra keys above the software keyboard. Keys come from Prefs.keyBar.
///
/// - Keys send on release; a horizontal drag scrolls the bar instead.
/// - Arrows and PgUp/PgDn auto-repeat while held.
/// - ctrl / alt: tap = next key only, double-tap = locked until tapped again.
/// - The "arrows" key is a trackpad: press and drag to send arrow keys.
@MainActor
final class KeyBar: UIInputView, UIInputViewAudioFeedback {
    weak var terminal: (any TerminalKeyTarget)? {
        didSet { observe(terminal, old: oldValue); syncModifiers() }
    }
    var onPaste: (() -> Void)?
    var onHideKeyboard: (() -> Void)?

    enum ModState { case off, once, locked }

    static let barHeight: CGFloat = 50
    static let keyHeight: CGFloat = 42
    /// Under a short window (landscape iPhone) the bar is thinner, to leave rows for the panes.
    static let compactBarHeight: CGFloat = 40
    static let compactKeyHeight: CGFloat = 34

    private var barHeightConstraint: NSLayoutConstraint?
    private var compact: Bool { traitCollection.verticalSizeClass == .compact }

    private let scroll = KeyScroll()
    private let stack = UIStackView()
    private let hideKey = KeyCap(key: "hide", kind: .action)
    private let divider = UIView()
    private let topLine = UIView()
    private var hairlines: [NSLayoutConstraint] = []
    private var caps: [KeyCap] = []
    private var theme: TermTheme = ThemeStore.fallback
    private var ctrl: ModState = .off { didSet { syncModifiers() } }
    private var alt: ModState = .off { didSet { syncModifiers() } }
    private var lastModTap: [String: CFTimeInterval] = [:]
    private let impact = UIImpactFeedbackGenerator(style: .light)
    private let lockImpact = UIImpactFeedbackGenerator(style: .medium)
    private let tick = UISelectionFeedbackGenerator()

    var enableInputClicksWhenVisible: Bool { true }

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 400, height: Self.barHeight), inputViewStyle: .default)
        allowsSelfSizing = true
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceHorizontal = true
        scroll.delaysContentTouches = false
        scroll.canCancelContentTouches = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        hideKey.translatesAutoresizingMaskIntoConstraints = false
        divider.translatesAutoresizingMaskIntoConstraints = false
        topLine.translatesAutoresizingMaskIntoConstraints = false
        hideKey.onFire = { [weak self] in self?.fire("hide") }
        addSubview(scroll)
        addSubview(divider)
        addSubview(hideKey)
        addSubview(topLine)
        scroll.addSubview(stack)
        // One-pixel lines; the scale is known once the bar is on screen (see didMoveToWindow).
        hairlines = [topLine.heightAnchor.constraint(equalToConstant: 0.5), divider.widthAnchor.constraint(equalToConstant: 0.5)]
        let barHeight = heightAnchor.constraint(equalToConstant: Self.barHeight)
        barHeightConstraint = barHeight
        NSLayoutConstraint.activate(hairlines + [
            barHeight,
            topLine.topAnchor.constraint(equalTo: topAnchor),
            topLine.leadingAnchor.constraint(equalTo: leadingAnchor),
            topLine.trailingAnchor.constraint(equalTo: trailingAnchor),

            hideKey.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -6),
            hideKey.centerYAnchor.constraint(equalTo: centerYAnchor),
            divider.trailingAnchor.constraint(equalTo: hideKey.leadingAnchor, constant: -5),
            divider.centerYAnchor.constraint(equalTo: centerYAnchor),
            divider.heightAnchor.constraint(equalToConstant: 26),

            scroll.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: divider.leadingAnchor, constant: -1),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])
        rebuild()
        NotificationCenter.default.addObserver(self, selector: #selector(prefsChanged), name: .keyBarChanged, object: nil)
        registerForTraitChanges([UITraitVerticalSizeClass.self]) { (bar: KeyBar, _) in bar.applySize() }
    }

    /// Thinner bar and keys under a short window.
    private func applySize() {
        let c = compact
        barHeightConstraint?.constant = c ? Self.compactBarHeight : Self.barHeight
        for cap in caps + [hideKey] { cap.heightConstraint?.constant = c ? Self.compactKeyHeight : Self.keyHeight }
        invalidateIntrinsicContentSize()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        let scale = traitCollection.displayScale
        if scale > 0 { hairlines.forEach { $0.constant = 1 / scale } }
    }

    @objc private func prefsChanged() { rebuild() }

    func apply(theme: TermTheme) {
        self.theme = theme
        rebuild()
    }

    private func rebuild() {
        backgroundColor = theme.uiBG.mixed(with: theme.isDark ? .black : .white, by: theme.isDark ? 0.18 : 0.04)
        topLine.backgroundColor = theme.uiFG.withAlphaComponent(0.12)
        divider.backgroundColor = theme.uiFG.withAlphaComponent(0.16)
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        caps = []
        for key in Prefs.shared.keyBar {
            let cap = KeyCap(key: key, kind: Self.kind(of: key))
            cap.theme = theme
            cap.onTouchDown = { [weak self] in self?.touchDown(key) }
            cap.onFire = { [weak self] in self?.fire(key) }
            cap.onRepeat = { [weak self] in self?.sendRaw(key) }
            cap.onRepeatEnd = { [weak self] in self?.usedModifiers() }
            cap.onDrag = { [weak self] dx, dy in self?.trackpad(dx: dx, dy: dy) }
            stack.addArrangedSubview(cap)
            caps.append(cap)
        }
        hideKey.theme = theme
        hideKey.onTouchDown = { [weak self] in self?.touchDown("hide") }
        refreshModifiers()
        applySize()
    }

    static func kind(of key: String) -> KeyCap.Kind {
        switch key {
        case "ctrl", "alt": return .modifier
        case "arrows": return .trackpad
        case "up", "down", "left", "right", "pgup", "pgdn": return .repeating
        case "paste", "hide": return .action
        default: return .normal
        }
    }

    // MARK: Modifiers

    /// Keeps the terminal's own modifier flags (used for keys typed on the system keyboard) in step with the bar.
    private func syncModifiers() {
        terminal?.controlModifier = ctrl != .off
        terminal?.metaModifier = alt != .off
        refreshModifiers()
    }

    private func refreshModifiers() {
        for cap in caps {
            if cap.key == "ctrl" { cap.modState = ctrl }
            if cap.key == "alt" { cap.modState = alt }
        }
    }

    private func observe(_ t: (any TerminalKeyTarget)?, old: (any TerminalKeyTarget)?) {
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

    /// Bar keys apply the modifiers themselves; one-shot ones end here.
    private func usedModifiers() {
        if ctrl == .once { ctrl = .off }
        if alt == .once { alt = .off }
    }

    private func tapModifier(_ key: String) {
        let now = CACurrentMediaTime()
        let quick = now - (lastModTap[key] ?? 0) < 0.35
        lastModTap[key] = now
        var s = key == "ctrl" ? ctrl : alt
        switch s {
        case .off: s = .once
        case .once: s = quick ? .locked : .off
        case .locked: s = .off
        }
        if s == .locked, Prefs.shared.haptics { lockImpact.impactOccurred() }
        if key == "ctrl" { ctrl = s } else { alt = s }
    }

    // MARK: Input

    private func touchDown(_ key: String) {
        if Prefs.shared.haptics {
            if Self.kind(of: key) == .trackpad { tick.prepare() } else { impact.impactOccurred(intensity: 0.7) }
        }
        UIDevice.current.playInputClick()
    }

    private func fire(_ key: String) {
        switch key {
        case "ctrl", "alt": tapModifier(key)
        case "paste": onPaste?(); usedModifiers()
        case "hide": onHideKeyboard?()
        case "arrows": usedModifiers()  // after a drag
        default: send(key)
        }
    }

    private func trackpad(dx: Int, dy: Int) {
        let steps: [(Int, String, String)] = [(dx, "right", "left"), (dy, "down", "up")]
        var sent = false
        for (n, pos, neg) in steps where n != 0 {
            for _ in 0..<abs(n) { sendRaw(n > 0 ? pos : neg); sent = true }
        }
        if sent, Prefs.shared.haptics { tick.selectionChanged(); tick.prepare() }
    }

    /// Sends one key with the bar's modifiers, then ends one-shot modifiers.
    private func send(_ key: String) {
        sendRaw(key)
        usedModifiers()
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

    /// The control character for a byte, matching what SwiftTerm does for the system keyboard.
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
        case "arrows", "ctrl", "alt", "paste", "hide": return nil
        default:
            // "ctrl-x" sends that control character; anything else is literal text.
            if key.hasPrefix("ctrl-"), key.count == 6, let b = key.utf8.last, let c = control(b) { return [c] }
            return Array(key.utf8)
        }
    }

    static let symbols: [String: String] = [
        "left": "arrow.left", "right": "arrow.right", "up": "arrow.up", "down": "arrow.down",
        "paste": "doc.on.clipboard", "hide": "keyboard.chevron.compact.down", "enter": "return",
        "tab": "arrow.right.to.line", "shift-tab": "arrow.left.to.line",
        "arrows": "arrow.up.and.down.and.arrow.left.and.right",
    ]
    static let titles: [String: String] = [
        "esc": "esc", "ctrl": "ctrl", "alt": "alt", "ctrl-c": "^C", "ctrl-d": "^D", "ctrl-z": "^Z", "ctrl-r": "^R",
        "ctrl-l": "^L", "ctrl-a": "^A", "ctrl-e": "^E", "ctrl-u": "^U", "ctrl-w": "^W", "ctrl-o": "^O",
        "pgup": "PgUp", "pgdn": "PgDn", "home": "Home", "end": "End",
    ]
    /// Spoken names for VoiceOver and the editor.
    static let names: [String: String] = [
        "left": "Left", "right": "Right", "up": "Up", "down": "Down", "paste": "Paste", "hide": "Hide Keyboard",
        "enter": "Return", "tab": "Tab", "shift-tab": "Shift-Tab", "arrows": "Arrow Trackpad", "esc": "Escape",
        "ctrl": "Control", "alt": "Alt",
    ]
}

/// Lets keys scroll the bar on a sideways drag, except the trackpad key, which keeps its touch.
private final class KeyScroll: UIScrollView {
    override func touchesShouldCancel(in view: UIView) -> Bool {
        if let cap = view as? KeyCap, cap.kind == .trackpad { return false }
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
    private var anchor: CGPoint = .zero
    private var dragged = false

    /// Points of finger travel per arrow key on the trackpad.
    static let stepX: CGFloat = 14
    static let stepY: CGFloat = 18

    init(key: String, kind: Kind) {
        self.key = key
        self.kind = kind
        super.init(frame: .zero)
        face.isUserInteractionEnabled = false
        face.layer.cornerRadius = 8
        face.layer.cornerCurve = .continuous
        face.layer.shadowOffset = CGSize(width: 0, height: 1)
        face.layer.shadowRadius = 0
        face.layer.shadowOpacity = 0.35
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
        if kind == .trackpad { accessibilityHint = "Press and drag to send arrow keys" }
        if kind == .modifier { accessibilityHint = "Tap for the next key, double-tap to lock" }
        configure()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func configure() {
        if let sym = KeyBar.symbols[key] {
            icon.image = UIImage(systemName: sym, withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .medium))
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

    private var baseFill: UIColor { theme.uiFG.withAlphaComponent(theme.isDark ? 0.13 : 0.09) }

    private func restyle() {
        let fg: UIColor
        var fill = baseFill
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
            if kind == .trackpad { border = theme.uiCursor }
        }
        face.backgroundColor = fill
        face.layer.borderColor = border.cgColor
        face.layer.borderWidth = border == .clear ? 0 : 1.5
        face.layer.shadowColor = UIColor.black.withAlphaComponent(theme.isDark ? 0.6 : 0.25).cgColor
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
        dragged = false
        anchor = touch.location(in: self)
        onTouchDown?()
        if kind == .repeating { scheduleRepeat(after: 0.4) }
        return true
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        if kind == .trackpad {
            let p = touch.location(in: self)
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
        isHighlighted = bounds.insetBy(dx: -24, dy: -24).contains(touch.location(in: self))
        return true
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        stopRepeat()
        let inside = touch.map { bounds.insetBy(dx: -24, dy: -24).contains($0.location(in: self)) } ?? false
        isHighlighted = false
        if kind == .trackpad {
            if dragged { onFire?() }
        } else if repeated {
            onRepeatEnd?()
        } else if inside {
            onFire?()
        }
    }

    override func cancelTracking(with event: UIEvent?) {
        stopRepeat()
        isHighlighted = false
        if repeated { onRepeatEnd?() }
        if kind == .trackpad, dragged { onFire?() }
    }

    private func scheduleRepeat(after delay: TimeInterval) {
        repeatTimer?.invalidate()
        let t = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.repeatTick() }
        }
        RunLoop.main.add(t, forMode: .common)
        repeatTimer = t
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

private extension UIColor {
    func mixed(with other: UIColor, by t: CGFloat) -> UIColor {
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        other.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return UIColor(red: r1 + (r2 - r1) * t, green: g1 + (g2 - g1) * t, blue: b1 + (b2 - b1) * t, alpha: 1)
    }
}

extension Notification.Name {
    static let keyBarChanged = Notification.Name("RexConnect.keyBarChanged")
}
