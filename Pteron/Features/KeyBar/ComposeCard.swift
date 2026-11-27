import RexKit
import UIKit

/// Compose (docs/terminal.md, Compose): a card above the key bar's keys with a plain iOS text
/// field, for writing a whole message with autocorrect, capitals, selection and dictation, and
/// sending it to the pane at once. The key bar shows it while compose is open for its pane and
/// keeps its height fixed, so typing never resizes the panes; longer text scrolls inside it.
/// A grab handle across the top closes it with a drag down, + opens the attach menu and ↑ sends.
@MainActor
final class ComposeCard: UIView, UITextViewDelegate, UIGestureRecognizerDelegate {
    let field = ComposeField()
    private let glass = UIVisualEffectView()
    private let handle = UIView()
    private let grab = ComposeHandle()
    private let placeholderLabel = UILabel()
    private let attachButton = UIButton(type: .custom)
    private let sendButton = UIButton(type: .custom)
    private let pan = UIPanGestureRecognizer()
    /// Where the finger touched down on the card, for the handle's drag.
    private var dragStart: CGPoint?
    private var theme: TermTheme = ThemeStore.fallback

    /// ↑ (or ⌘Return on a hardware keyboard) with text in the field.
    var onSend: (() -> Void)?
    /// The handle dragged down, or activated with VoiceOver.
    var onClose: (() -> Void)?
    /// The field's text changed.
    var onChange: ((String) -> Void)?
    /// A key typed while the key bar's ctrl, option or cmd is on goes to the bar, which sends it
    /// to the pane, not into the message. True when the bar took it.
    var takesModifiedKey: ((String) -> Bool)?
    /// The attach menu, built each time it opens (the same menu as the attach key's).
    var attachMenu: (() -> UIMenu)?
    var attachAvailable = false { didSet { attachButton.isHidden = !attachAvailable } }
    /// "Message Claude Code ~/pteron" (`ComposePlaceholder`).
    var placeholder = ComposePlaceholder.plain {
        didSet {
            placeholderLabel.text = placeholder
            field.accessibilityLabel = placeholder
        }
    }
    /// Under a short window the card is one row: + , the field, ↑.
    var compact = false { didSet { if compact != oldValue { setNeedsLayout() } } }

    /// The card's height, fixed so that the panes resize once when compose opens or closes and
    /// never while the message grows.
    static func height(compact: Bool) -> CGFloat { compact ? 52 : 112 }
    static let radius: CGFloat = 22
    private static let button: CGFloat = 36

    init() {
        super.init(frame: .zero)
        Glass.makeGlass(glass, cornerRadius: Self.radius)
        glass.isUserInteractionEnabled = false
        addSubview(glass)
        handle.layer.cornerRadius = 2.5
        handle.isUserInteractionEnabled = false
        addSubview(handle)
        grab.onActivate = { [weak self] in self?.onClose?() }
        addSubview(grab)
        field.backgroundColor = .clear
        // The system's text font, as any iOS text field: a message is prose, not a terminal line.
        field.font = UIFont.systemFont(ofSize: 17)
        field.textContainerInset = UIEdgeInsets(top: 8, left: 2, bottom: 8, right: 2)
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.delegate = self
        field.accessibilityLabel = placeholder
        field.onCommandReturn = { [weak self] in self?.send() }
        addSubview(field)
        placeholderLabel.font = field.font
        placeholderLabel.lineBreakMode = .byTruncatingMiddle
        placeholderLabel.isAccessibilityElement = false
        placeholderLabel.text = placeholder
        field.addSubview(placeholderLabel)

        let symbol = UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
        attachButton.setImage(UIImage(systemName: "plus", withConfiguration: symbol), for: .normal)
        attachButton.showsMenuAsPrimaryAction = true
        attachButton.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] done in
            done(self?.attachMenu?().children ?? [])
        }])
        attachButton.accessibilityLabel = "Attach"
        attachButton.accessibilityHint = "Send photos or files, or browse the computer's files"
        attachButton.isHidden = true
        addSubview(attachButton)
        sendButton.setImage(UIImage(systemName: "arrow.up", withConfiguration: symbol), for: .normal)
        sendButton.addAction(UIAction { [weak self] _ in self?.send() }, for: .touchUpInside)
        sendButton.accessibilityLabel = "Send"
        addSubview(sendButton)
        for b in [attachButton, sendButton] { b.layer.cornerRadius = Self.button / 2 }

        pan.addTarget(self, action: #selector(panned(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        addGestureRecognizer(pan)
        accessibilityElements = [grab, field, attachButton, sendButton]
        refreshSend()
    }

    required init?(coder: NSCoder) { fatalError() }

    func apply(theme: TermTheme) {
        self.theme = theme
        let style: UIUserInterfaceStyle = theme.isDark ? .dark : .light
        overrideUserInterfaceStyle = style
        field.textColor = theme.uiFG
        field.tintColor = theme.uiCursor
        field.keyboardAppearance = theme.isDark ? .dark : .light
        placeholderLabel.textColor = theme.uiFG.withAlphaComponent(0.42)
        handle.backgroundColor = theme.uiFG.withAlphaComponent(0.3)
        attachButton.tintColor = theme.uiFG
        attachButton.backgroundColor = theme.uiFG.withAlphaComponent(theme.isDark ? 0.14 : 0.1)
        refreshSend()
    }

    /// Puts a draft in the field, as the pane last left it.
    func show(text: String) {
        guard field.text != text else { return refreshSend() }
        field.text = text
        refreshSend()
    }

    private var canSend: Bool { !field.text.isEmpty }

    private func refreshSend() {
        placeholderLabel.isHidden = !field.text.isEmpty
        sendButton.isEnabled = canSend
        sendButton.tintColor = canSend ? theme.uiBG : theme.uiFG.withAlphaComponent(0.35)
        sendButton.backgroundColor = canSend ? theme.uiCursor : theme.uiFG.withAlphaComponent(theme.isDark ? 0.14 : 0.1)
        sendButton.accessibilityTraits = canSend ? .button : [.button, .notEnabled]
    }

    private func send() {
        guard canSend else { return }
        onSend?()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        glass.frame = bounds
        let b = Self.button
        // The handle's strip: the card's whole width, `ComposeDrag.handleHeight` tall. It lies
        // under the field and the buttons, which take their own taps.
        grab.frame = CGRect(x: 0, y: 0, width: bounds.width, height: ComposeDrag.handleHeight)
        if compact {
            handle.frame = CGRect(x: (bounds.width - 28) / 2, y: 3, width: 28, height: 4)
            let y = (bounds.height - b) / 2
            attachButton.frame = CGRect(x: 8, y: y, width: b, height: b)
            sendButton.frame = CGRect(x: bounds.width - 8 - b, y: y, width: b, height: b)
            let lo = attachButton.isHidden ? 12 : attachButton.frame.maxX + 6
            field.frame = CGRect(x: lo, y: 8, width: max(0, sendButton.frame.minX - 6 - lo), height: bounds.height - 12)
        } else {
            handle.frame = CGRect(x: (bounds.width - 36) / 2, y: 6, width: 36, height: 5)
            let row = bounds.height - 8 - b
            attachButton.frame = CGRect(x: 10, y: row, width: b, height: b)
            sendButton.frame = CGRect(x: bounds.width - 10 - b, y: row, width: b, height: b)
            field.frame = CGRect(x: 12, y: 16, width: bounds.width - 24, height: max(0, row - 18))
        }
        let inset = field.textContainerInset
        let pad = field.textContainer.lineFragmentPadding
        placeholderLabel.frame = CGRect(x: inset.left + pad, y: inset.top,
                                        width: max(0, field.bounds.width - inset.left - inset.right - 2 * pad),
                                        height: field.font?.lineHeight ?? 20)
    }

    // MARK: Text

    func textViewDidChange(_ textView: UITextView) {
        refreshSend()
        onChange?(textView.text)
    }

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        // One key typed (not a paste, not a suggestion) while a bar modifier is on.
        if range.length == 0, text.count == 1, textView.markedTextRange == nil, takesModifiedKey?(text) == true { return false }
        return true
    }

    // MARK: The handle

    /// The handle's strip on the card, where a drag down closes compose.
    var handleArea: CGRect { grab.frame }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if g === pan, pan.state == .possible { dragStart = touch.location(in: self) }
        return true
    }

    /// The handle's drag, as UIKit is about to begin it: it started in the handle's strip and
    /// goes down (`ComposeDrag.begins`). Measured from where the finger touched down, since UIKit
    /// begins a pan only after the finger has moved about 10 pt and counts its translation from
    /// there: a slow drag has none yet.
    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        guard g.view === self, let pan = g as? UIPanGestureRecognizer else { return super.gestureRecognizerShouldBegin(g) }
        let now = pan.location(in: self)
        let start = dragStart ?? CGPoint(x: now.x - pan.translation(in: self).x, y: now.y - pan.translation(in: self).y)
        return beginsDrag(from: start, to: now, velocity: pan.velocity(in: self))
    }

    /// `ComposeDrag.begins` on this card as laid out: the handle's strip, short of the buttons.
    func beginsDrag(from start: CGPoint, to now: CGPoint, velocity: CGPoint) -> Bool {
        let buttons = [attachButton, sendButton].filter { !$0.isHidden }.map(\.frame)
        return ComposeDrag.begins(from: start, to: now, velocity: velocity, handle: handleArea, buttons: buttons)
    }

    /// The field's own pans (its scrolling) wait for the handle's: a drag down that starts in the
    /// strip over the field's top edge is the handle's, any other is the field's once the
    /// handle's fails, which it does as soon as UIKit would begin it.
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        g === pan && other is UIPanGestureRecognizer && other.view?.isDescendant(of: field) == true
    }

    @objc func panned(_ pan: UIPanGestureRecognizer) {
        let now = pan.location(in: self)
        let start = dragStart ?? CGPoint(x: now.x - pan.translation(in: self).x, y: now.y - pan.translation(in: self).y)
        let drop = max(0, now.y - start.y)
        switch pan.state {
        case .began, .changed:
            // The card follows the finger down, from where it touched down.
            if !UIAccessibility.isReduceMotionEnabled { transform = CGAffineTransform(translationX: 0, y: drop) }
        case .ended:
            dragStart = nil
            if ComposeDrag.closes(drop: drop, speed: pan.velocity(in: self).y) {
                transform = .identity
                onClose?()
            } else {
                settle()
            }
        case .cancelled, .failed:
            dragStart = nil
            settle()
        default:
            break
        }
    }

    private func settle() {
        guard transform != .identity else { return }
        UIView.animate(withDuration: 0.18, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.transform = .identity
        }
    }
}

/// The handle's drag, decided from points so it is tested (docs/terminal.md, Compose).
enum ComposeDrag {
    /// The handle's strip across the card's top: generous, for a thumb.
    static let handleHeight: CGFloat = 30
    /// How far the finger goes down before letting go closes compose.
    static let closeDistance: CGFloat = 32
    /// A flick down at least this fast (points a second) closes it from any distance.
    static let closeSpeed: CGFloat = 700

    /// Whether a drag is the handle's, when UIKit is about to begin it: it started in the
    /// handle's strip, not on a button there and not in the field below it, and goes down more
    /// than sideways. The movement since the touch went down decides; the velocity only breaks a
    /// tie, when the movement is level or exactly diagonal.
    static func begins(from start: CGPoint, to now: CGPoint, velocity: CGPoint, handle: CGRect, buttons: [CGRect] = []) -> Bool {
        guard handle.contains(start), !buttons.contains(where: { $0.contains(start) }) else { return false }
        return down(CGPoint(x: now.x - start.x, y: now.y - start.y)) ?? down(velocity) ?? false
    }

    /// Down and more vertical than horizontal; nil when it can't tell (no movement, or exactly
    /// as much down as sideways).
    private static func down(_ p: CGPoint) -> Bool? {
        p.y == abs(p.x) ? nil : p.y > abs(p.x)
    }

    /// Letting go closes compose past `closeDistance` or on a flick down.
    static func closes(drop: CGFloat, speed: CGFloat) -> Bool {
        drop > closeDistance || speed > closeSpeed
    }
}

/// The card's grab handle for VoiceOver: one button that closes compose.
@MainActor
private final class ComposeHandle: UIView {
    var onActivate: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        accessibilityLabel = "Close Compose"
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) { fatalError() }

    override func accessibilityActivate() -> Bool {
        onActivate?()
        return true
    }
}

/// Compose's text field: a plain text view, with ⌘Return to send from a hardware keyboard.
@MainActor
final class ComposeField: UITextView {
    var onCommandReturn: (() -> Void)?

    override var keyCommands: [UIKeyCommand]? {
        let send = UIKeyCommand(input: "\r", modifierFlags: .command, action: #selector(commandReturn))
        send.discoverabilityTitle = "Send"
        return (super.keyCommands ?? []) + [send]
    }

    @objc private func commandReturn() { onCommandReturn?() }
}

/// What compose's empty field says: "Message", the agent or the program in the pane, and the
/// pane's folder, "Message Claude Code ~/pteron". Pure, so it is tested.
enum ComposePlaceholder {
    static let plain = "Message"

    static func text(agent: AgentKind?, program: String?, pwd: String?) -> String {
        let who = agent.map(name) ?? program.flatMap { p in
            let t = p.trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? nil : t
        }
        return ([plain, who, folder(pwd)].compactMap { $0 }).joined(separator: " ")
    }

    /// An agent by the name it goes by.
    static func name(_ agent: AgentKind) -> String {
        switch agent {
        case .claude: "Claude Code"
        case .gemini: "Gemini CLI"
        default: agent.displayName
        }
    }

    /// A working directory, with the home folder as ~. Nil when unknown.
    static func folder(_ pwd: String?) -> String? {
        guard var p = pwd?.trimmingCharacters(in: .whitespaces), !p.isEmpty else { return nil }
        if p.hasPrefix("file://"), let u = URL(string: p) { p = u.path }
        if p.count > 1, p.hasSuffix("/") { p.removeLast() }
        let parts = p.split(separator: "/", omittingEmptySubsequences: true)
        if parts.count >= 2, parts[0] == "Users" || parts[0] == "home" {
            let rest = parts.dropFirst(2)
            return rest.isEmpty ? "~" : "~/" + rest.joined(separator: "/")
        }
        if parts.count >= 1, parts[0] == "root", p.hasPrefix("/root") {
            let rest = parts.dropFirst(1)
            return rest.isEmpty ? "~" : "~/" + rest.joined(separator: "/")
        }
        return p
    }
}
