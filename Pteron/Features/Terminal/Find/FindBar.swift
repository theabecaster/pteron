import UIKit

/// What the find bars report to their pane.
@MainActor
protocol FindBarOwner: FindFieldOwner {
    /// Any touch on the bar, before what it does: the pane takes focus first.
    func findBarTouched(_ bar: FindBarContent)
    /// The field was tapped. False keeps it from editing (the other bar's field takes the keyboard).
    func findBarShouldEdit(_ bar: FindBarContent) -> Bool
    func findBarBeganEditing(_ bar: FindBarContent)
    func findBarEndedEditing(_ bar: FindBarContent)
    func findBar(_ bar: FindBarContent, changed text: String, committed: Bool)
    /// Return: the next (older) match.
    func findBarReturn(_ bar: FindBarContent)
    /// The chevrons: +1 next (older), -1 previous (newer).
    func findBar(_ bar: FindBarContent, step: Int)
    func findBarDone(_ bar: FindBarContent)
}

/// The find bar's content, shared by both bars: a glass capsule with the field (the count inside
/// its trailing edge), Next (chevron.up, older) and Previous (chevron.down, newer), and Done in a
/// glass circle where the key bar has its hide key with no vertical bar beside it. It copies the
/// key bar's glass and sizes, and like the key bar ends short of the vertical bar's column.
@MainActor
final class FindBarContent: UIView, UITextFieldDelegate {
    weak var owner: (any FindBarOwner)? {
        didSet { field.owner = owner }
    }
    let field = FindField()
    private let capsule = UIVisualEffectView()
    private let icon = UIImageView()
    private let countLabel = UILabel()
    let nextButton = UIButton(type: .system)
    let previousButton = UIButton(type: .system)
    let doneButton = FindDoneButton()
    private var theme: TermTheme = ThemeStore.fallback
    private var countText: String?

    var compact = false { didSet { if compact != oldValue { setNeedsLayout() } } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        Glass.makeGlass(capsule)
        capsule.isUserInteractionEnabled = true
        addSubview(capsule)
        addSubview(doneButton)
        icon.image = UIImage(systemName: "magnifyingglass", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .medium))
        icon.contentMode = .center
        capsule.contentView.addSubview(icon)
        field.delegate = self
        field.font = RexFont.ui(16)
        field.addTarget(self, action: #selector(edited), for: .editingChanged)
        countLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        countLabel.textAlignment = .right
        field.rightView = countLabel
        field.rightViewMode = .always
        capsule.contentView.addSubview(field)
        for (button, symbol, label, step) in [(nextButton, "chevron.up", "Next Match", 1), (previousButton, "chevron.down", "Previous Match", -1)] {
            button.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)),
                            for: .normal)
            button.accessibilityLabel = label
            button.addAction(UIAction { [weak self] _ in
                guard let self else { return }
                self.owner?.findBarTouched(self)
                self.owner?.findBar(self, step: step)
            }, for: .touchUpInside)
            capsule.contentView.addSubview(button)
        }
        doneButton.onFire = { [weak self] in
            guard let self else { return }
            self.owner?.findBarTouched(self)
            self.owner?.findBarDone(self)
        }
        apply(theme: theme)
    }

    required init?(coder: NSCoder) { fatalError() }

    func apply(theme t: TermTheme) {
        theme = t
        let style: UIUserInterfaceStyle = t.isDark ? .dark : .light
        capsule.overrideUserInterfaceStyle = style
        doneButton.overrideUserInterfaceStyle = style
        field.keyboardAppearance = t.isDark ? .dark : .light
        field.textColor = t.uiFG
        field.tintColor = t.uiCursor
        field.attributedPlaceholder = NSAttributedString(string: "Find", attributes: [.foregroundColor: t.uiFG.withAlphaComponent(0.45)])
        icon.tintColor = t.uiFG.withAlphaComponent(0.6)
        countLabel.textColor = t.uiFG.withAlphaComponent(0.55)
        nextButton.tintColor = t.uiFG
        previousButton.tintColor = t.uiFG
        doneButton.tintColor = t.uiFG
    }

    // MARK: Model → view

    func show(text: String) {
        guard field.text != text else { return }
        field.text = text
    }

    func show(result: FindResult) {
        let c = FindQuery.count(result)
        guard c != countText else { return }
        countText = c
        countLabel.text = c.map { $0 + " " }
        countLabel.sizeToFit()
        setNeedsLayout()
        let enabled = result.total > 0
        nextButton.isEnabled = enabled
        previousButton.isEnabled = enabled
    }

    // MARK: Layout

    private var keyHeight: CGFloat { compact ? KeyBar.compactKeyHeight : KeyBar.keyHeight }

    /// The bar's content in `bounds`, centered in `rowHeight` from the top (the accessory's row
    /// above the bottom safe area). Done always sits at the bar's end: it closes find, which the
    /// vertical bar's Hide Keyboard doesn't. With the vertical bar's `column` beside the keyboard
    /// (in this view's coordinates) the capsule, Done and Done's tap end short of it.
    func layout(rowHeight: CGFloat, leftInset: CGFloat = 0, rightInset: CGFloat = 0, column: CGRect? = nil) {
        let h = keyHeight + 2 * KeyBar.ring
        let size = FindBarPlacement.size(width: bounds.width)
        let reach = KeyBarPlacement.reach(width: bounds.width, column: column)
        let span = KeyBarPlacement.span(width: bounds.width, leftInset: leftInset, rightInset: rightInset,
                                        sideInset: KeyBar.sideInset, column: column)
        var lo = span.lowerBound, hi = span.upperBound
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        doneButton.diameter = h
        if rtl {
            doneButton.frame = CGRect(x: reach.lowerBound, y: 0, width: lo + h + KeyBar.hideGap / 2 - reach.lowerBound, height: rowHeight)
            doneButton.keyMidX = lo + h / 2 - reach.lowerBound
            lo += h + KeyBar.hideGap
        } else {
            let edge = hi - h - KeyBar.hideGap / 2
            doneButton.frame = CGRect(x: edge, y: 0, width: reach.upperBound - edge, height: rowHeight)
            doneButton.keyMidX = hi - h / 2 - edge
            hi -= h + KeyBar.hideGap
        }
        capsule.frame = CGRect(x: lo, y: ((rowHeight - h) / 2).rounded(), width: max(hi - lo, h), height: h)
        Glass.round(capsule, radius: h / 2)
        let inner = capsule.contentView.bounds
        let button = h
        let showsPrevious = size != .minimal
        countLabel.isHidden = size == .minimal
        previousButton.isHidden = !showsPrevious
        var x = h / 2 - 6
        icon.frame = CGRect(x: x, y: 0, width: 20, height: inner.height)
        x += 24
        var right = inner.width - 4
        if showsPrevious {
            previousButton.frame = CGRect(x: right - button, y: 0, width: button, height: inner.height)
            right -= button
        }
        nextButton.frame = CGRect(x: right - button, y: 0, width: button, height: inner.height)
        right -= button
        field.frame = CGRect(x: x, y: 0, width: max(0, right - x), height: inner.height)
        if rtl {
            for v in [icon, field, nextButton, previousButton] as [UIView] {
                v.frame.origin.x = inner.width - v.frame.maxX
            }
        }
    }

    // MARK: UITextFieldDelegate

    func textFieldShouldBeginEditing(_ textField: UITextField) -> Bool {
        owner?.findBarShouldEdit(self) ?? true
    }

    func textFieldDidBeginEditing(_ textField: UITextField) {
        owner?.findBarBeganEditing(self)
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        owner?.findBarEndedEditing(self)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        // A Return that commits an input method's text never reaches here.
        owner?.findBarReturn(self)
        return false
    }

    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
        // One line: a paste keeps its first line.
        let first = FindQuery.firstLine(string)
        guard first != string else { return true }
        guard let text = textField.text, let r = Range(range, in: text) else { return false }
        textField.text = text.replacingCharacters(in: r, with: first)
        edited()
        return false
    }

    @objc private func edited() {
        owner?.findBar(self, changed: field.text ?? "", committed: field.markedTextRange == nil)
    }
}

/// Done: a glass circle with an xmark, where the key bar has its hide key.
@MainActor
final class FindDoneButton: UIControl {
    var onFire: (() -> Void)?
    var diameter: CGFloat = KeyBar.keyHeight { didSet { if diameter != oldValue { setNeedsLayout() } } }
    var keyMidX: CGFloat = 0 { didSet { if keyMidX != oldValue { setNeedsLayout() } } }
    private let glass = UIVisualEffectView()
    private let icon = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        glass.isUserInteractionEnabled = false
        Glass.makeGlass(glass)
        icon.image = UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold))
        icon.contentMode = .center
        addSubview(glass)
        glass.contentView.addSubview(icon)
        addTarget(self, action: #selector(up), for: .touchUpInside)
        isAccessibilityElement = true
        accessibilityLabel = "Done"
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

    @objc private func up() { onFire?() }

    override func accessibilityActivate() -> Bool {
        onFire?()
        return true
    }
}

/// The find bar in the keyboard's accessory slot (paths A, B and E): a sibling of `KeyBar` with
/// its height function (54 pt, 42 under a short window) and its row above the bottom safe area,
/// so the keyboard's frame is the same whichever of the two is up.
@MainActor
final class FindAccessoryBar: UIInputView {
    let content = FindBarContent()
    private var heightConstraint: NSLayoutConstraint?
    /// The vertical bar's column, in screen coordinates, as the key bar has it (`KeyBar.barColumn`).
    var barColumn: CGRect? { didSet { if barColumn != oldValue { setNeedsLayout() } } }
    var crease: CGRect?
    private var compact: Bool { traitCollection.verticalSizeClass == .compact }

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 400, height: KeyBar.barHeight), inputViewStyle: .default)
        allowsSelfSizing = true
        backgroundColor = .clear
        addSubview(content)
        let h = heightAnchor.constraint(equalToConstant: KeyBar.barHeight)
        heightConstraint = h
        h.isActive = true
        registerForTraitChanges([UITraitVerticalSizeClass.self]) { (bar: FindAccessoryBar, _) in bar.applySize() }
        applySize()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Runs once the bar is in the keyboard's window (after the reload that shows it), or at once
    /// if it is there. A newer call replaces an older one.
    func whenShown(_ work: @escaping () -> Void) {
        if window != nil {
            pendingShown = nil
            work()
        } else {
            pendingShown = work
        }
    }
    private var pendingShown: (() -> Void)?

    /// Drops work waiting for the bar to show.
    func cancelWhenShown() { pendingShown = nil }

    /// Work waits for the bar to show.
    var handOverPending: Bool { pendingShown != nil }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, let work = pendingShown else { return }
        pendingShown = nil
        work()
    }

    private func applySize() {
        heightConstraint?.constant = compact ? KeyBar.compactBarHeight : KeyBar.barHeight
        content.compact = compact
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        content.frame = bounds
        content.layout(rowHeight: max(bounds.height - safeAreaInsets.bottom, KeyBar.keyHeight),
                       leftInset: safeAreaInsets.left, rightInset: safeAreaInsets.right, column: localColumn)
    }

    /// The vertical bar's column in the bar's coordinates; nil without one, or out of a window.
    private var localColumn: CGRect? {
        guard let barColumn, let screen = window?.windowScene?.screen else { return nil }
        return convert(barColumn, from: screen.coordinateSpace)
    }

    /// A touch in the vertical bar's column is the bar's, as on the key bar.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if let c = localColumn, point.x >= c.minX, point.x < c.maxX { return nil }
        return super.hitTest(point, with: event)
    }
}

/// The find bar inside the pane (paths C and D, and whenever find is open without the field
/// holding the keyboard): a floating glass capsule over the terminal, under the status chip.
/// It is a subview of the host: no size the layout reads depends on it.
@MainActor
final class FindOverlayBar: UIView {
    let content = FindBarContent()

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(content)
    }

    required init?(coder: NSCoder) { fatalError() }

    var compact: Bool {
        get { content.compact }
        set { content.compact = newValue }
    }

    static func height(compact: Bool) -> CGFloat {
        (compact ? KeyBar.compactKeyHeight : KeyBar.keyHeight) + 2 * KeyBar.ring
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        content.frame = bounds
        content.layout(rowHeight: bounds.height)
    }
}

/// An empty, transparent accessory with the key bar's height function and safe-area row: the
/// overlay field's accessory where the find bar can't sit in the accessory slot (spike S1's
/// fallback). The keyboard keeps its frame; the bar floats in the pane above it.
@MainActor
final class FindSpacer: UIInputView {
    private var heightConstraint: NSLayoutConstraint?
    private var compact: Bool { traitCollection.verticalSizeClass == .compact }

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 400, height: KeyBar.barHeight), inputViewStyle: .default)
        allowsSelfSizing = true
        backgroundColor = .clear
        isUserInteractionEnabled = false
        let h = heightAnchor.constraint(equalToConstant: KeyBar.barHeight)
        heightConstraint = h
        h.isActive = true
        registerForTraitChanges([UITraitVerticalSizeClass.self]) { (bar: FindSpacer, _) in bar.applySize() }
        applySize()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func applySize() {
        heightConstraint?.constant = compact ? KeyBar.compactBarHeight : KeyBar.barHeight
        invalidateIntrinsicContentSize()
    }
}
