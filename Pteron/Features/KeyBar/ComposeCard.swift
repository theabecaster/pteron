import RexKit
import UIKit

/// Compose (docs/terminal.md, Compose): a card above the key bar's keys with a plain iOS text
/// field, for writing a whole message with autocorrect, capitals, selection and dictation, and
/// sending it to the pane at once. The key bar shows it while compose is open for its pane and
/// keeps its height fixed, so typing never resizes the panes; longer text scrolls inside it.
/// A grab handle at the top closes it with a drag down, + opens the attach menu and ↑ sends.
@MainActor
final class ComposeCard: UIView, UITextViewDelegate, UIGestureRecognizerDelegate {
    let field = ComposeField()
    private let glass = UIVisualEffectView()
    private let handle = UIView()
    private let grab = ComposeHandle()
    private let placeholderLabel = UILabel()
    private let attachButton = UIButton(type: .custom)
    private let sendButton = UIButton(type: .custom)
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

        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
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
        if compact {
            handle.frame = CGRect(x: (bounds.width - 28) / 2, y: 3, width: 28, height: 4)
            grab.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 10)
            let y = (bounds.height - b) / 2
            attachButton.frame = CGRect(x: 8, y: y, width: b, height: b)
            sendButton.frame = CGRect(x: bounds.width - 8 - b, y: y, width: b, height: b)
            let lo = attachButton.isHidden ? 12 : attachButton.frame.maxX + 6
            field.frame = CGRect(x: lo, y: 8, width: max(0, sendButton.frame.minX - 6 - lo), height: bounds.height - 12)
        } else {
            handle.frame = CGRect(x: (bounds.width - 36) / 2, y: 6, width: 36, height: 5)
            grab.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 20)
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

    /// Starts on the card outside the field (the handle, the margins), going down.
    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        guard let pan = g as? UIPanGestureRecognizer else { return true }
        if field.frame.contains(pan.location(in: self)) { return false }
        let v = pan.velocity(in: self)
        return v.y > abs(v.x)
    }

    @objc private func panned(_ pan: UIPanGestureRecognizer) {
        let dy = max(0, pan.translation(in: self).y)
        let follows = !UIAccessibility.isReduceMotionEnabled
        switch pan.state {
        case .changed:
            if follows { transform = CGAffineTransform(translationX: 0, y: dy * 0.6) }
        case .ended:
            if dy > Self.closeDrag || pan.velocity(in: self).y > 700 {
                transform = .identity
                onClose?()
            } else {
                settle()
            }
        case .cancelled, .failed:
            settle()
        default:
            break
        }
    }

    /// How far down the handle goes before compose closes.
    static let closeDrag: CGFloat = 32

    private func settle() {
        guard transform != .identity else { return }
        UIView.animate(withDuration: 0.18, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.transform = .identity
        }
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
