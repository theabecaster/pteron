import UIKit

/// When a pane shows its jump-to-bottom button, and whether the button says that output has
/// arrived below since it came up.
///
/// The button is no standing chrome: it shows only while the view is well into the scrollback
/// and nothing else is going on in the pane. Two thresholds keep it from flickering as a
/// scroll crosses one of them.
struct JumpToBottomRule: Equatable {
    struct Input: Equatable {
        /// Rows between the view and the newest line; 0 at the bottom.
        var rowsAbove: Double
        /// Rows of the terminal that show.
        var screenRows: Int
        /// The program takes the drags (mouse tracking or the alternate screen), a selection is
        /// up or being dragged, or a pinch is under way.
        var blocked: Bool
        /// Rows in all, scrollback included.
        var total: Int
        /// How far the terminal has moved by itself.
        var rebase: Int
        /// The newest scroll request of ours that the terminal had applied.
        var sequence: Int
    }

    /// At or under this many rows from the bottom the button hides.
    static let hideRows = 1.0

    /// The button shows once the view is this many rows up: half a screen, and never under 3.
    static func showRows(screenRows: Int) -> Double { Double(max(3, screenRows / 2)) }

    private(set) var shown = false
    /// Output has arrived since the button came up.
    private(set) var unseen = false
    private var total = 0
    private var rebase = 0
    private var sequence = 0

    /// Takes the pane's state. True when `shown` or `unseen` changed.
    mutating func update(_ input: Input) -> Bool {
        let was = (shown: shown, unseen: unseen)
        if input.blocked {
            shown = false
        } else if input.rowsAbove >= Self.showRows(screenRows: input.screenRows) {
            shown = true
        } else if input.rowsAbove <= Self.hideRows {
            shown = false
        }
        if !shown {
            unseen = false
        } else if was.shown {
            // New rows, or the terminal moved without a request of ours: a line, page or prompt
            // jump moves it too, and comes with a new sequence.
            let moved = input.rebase != rebase && input.sequence == sequence
            if input.total != total || moved { unseen = true }
        }
        total = input.total
        rebase = input.rebase
        sequence = input.sequence
        return shown != was.shown || unseen != was.unseen
    }
}

/// A pane's jump-to-bottom button: a small glass circle with a down arrow, at the pane's bottom
/// trailing corner. Its frame, larger than the circle, is its touch target. The host shows and
/// hides it (`JumpToBottomRule`) and performs the jump.
@MainActor
final class JumpToBottomButton: UIControl, UIPointerInteractionDelegate {
    /// The touch target.
    static let side: CGFloat = 44
    nonisolated static let diameter: CGFloat = 34

    /// The circle's center y in a pane whose bottom is `bottom`: 12 pt up from it, or 4 pt above
    /// the pane's bottom safe area (the home indicator under a pane that reaches the window's
    /// edge), whichever is higher.
    nonisolated static func centerY(bottom: CGFloat, safeBottom: CGFloat) -> CGFloat {
        bottom - max(12, safeBottom + 4) - diameter / 2
    }

    var onFire: (() -> Void)?
    private(set) var shown = false
    /// Output has arrived below: the arrow takes the accent color.
    private(set) var unseen = false

    private let glass = UIVisualEffectView()
    private let icon = UIImageView()
    /// The glass, kept while the button is hidden without it.
    private var material: UIVisualEffect?
    private var normalTint = UIColor.label
    private var accentTint = UIColor.tintColor
    private static let small = CGAffineTransform(scaleX: 0.85, y: 0.85)

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: Self.side, height: Self.side))
        glass.isUserInteractionEnabled = false
        Glass.makeGlass(glass, keyboardTinted: false)
        material = glass.effect
        icon.image = UIImage(systemName: "arrow.down",
                             withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold))
        icon.contentMode = .center
        addSubview(glass)
        glass.contentView.addSubview(icon)
        addTarget(self, action: #selector(fire), for: .touchUpInside)
        addInteraction(UIPointerInteraction(delegate: self))
        accessibilityLabel = "Scroll to Bottom"
        accessibilityTraits = .button
        setVisible(false)
        transform = Self.small
        isHidden = true
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        glass.bounds = CGRect(x: 0, y: 0, width: Self.diameter, height: Self.diameter)
        glass.center = CGPoint(x: bounds.midX, y: bounds.midY)
        Glass.round(glass, radius: Self.diameter / 2)
        icon.frame = glass.contentView.bounds
    }

    /// The arrow's color, and the one it takes when output has arrived below.
    func apply(tint: UIColor, accent: UIColor) {
        normalTint = tint
        accentTint = accent
        icon.tintColor = unseen ? accent : tint
    }

    /// Shows or hides the button and sets the arrow's color. A hidden button takes no touch and
    /// is no accessibility element.
    func set(shown: Bool, unseen: Bool, animated: Bool) {
        if unseen != self.unseen {
            self.unseen = unseen
            icon.tintColor = unseen ? accentTint : normalTint
            accessibilityValue = unseen ? "New output" : nil
        }
        guard shown != self.shown else { return }
        self.shown = shown
        isUserInteractionEnabled = shown
        isAccessibilityElement = shown
        if shown { isHidden = false }
        let change = {
            self.setVisible(shown)
            self.transform = shown || UIAccessibility.isReduceMotionEnabled ? .identity : Self.small
        }
        let done = { (_: Bool) in
            if !self.shown { self.isHidden = true }
        }
        guard animated else {
            UIView.performWithoutAnimation(change)
            done(true)
            return
        }
        // Coming up with Reduce Motion on, it only fades: no scale to grow from.
        if shown, UIAccessibility.isReduceMotionEnabled { transform = .identity }
        UIView.animate(withDuration: 0.18, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction],
                       animations: change, completion: done)
    }

    /// The glass comes and goes by its effect, which UIKit animates as the material forming and
    /// leaving. A visual effect view under an alpha below 1 draws wrong, so no alpha is set on
    /// it or above it; only the arrow fades.
    private func setVisible(_ visible: Bool) {
        glass.effect = visible ? material : nil
        icon.alpha = visible ? 1 : 0
    }

    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            UIView.animate(withDuration: isHighlighted ? 0.05 : 0.12, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                self.glass.transform = self.isHighlighted ? CGAffineTransform(scaleX: 0.93, y: 0.93) : .identity
            }
        }
    }

    /// A tap on the button is the button's alone: no tap recognizer above it (the pane's focus
    /// tap, the layout's) may also take it and focus the pane or raise the keyboard.
    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        if g is UITapGestureRecognizer, g.view !== self { return false }
        return super.gestureRecognizerShouldBegin(g)
    }

    /// The touch target is the circle the frame holds, 44 pt across, not the square: a drag or a
    /// long press that starts in the frame's corners belongs to the pane under them.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        hypot(point.x - bounds.midX, point.y - bounds.midY) <= Self.side / 2
    }

    @objc private func fire() { onFire?() }

    override func accessibilityActivate() -> Bool {
        guard shown else { return false }
        onFire?()
        return true
    }

    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        UIPointerStyle(effect: .highlight(UITargetedPreview(view: glass)))
    }
}
