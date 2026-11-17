import UIKit

/// Where the two selection handles are drawn and how they are hit. Pure, in one coordinate
/// space (the overlay's).
///
/// A handle is a thin bar along the edge of its cell with a round knob: above the row for the
/// start, below it for the end, like the system's. The knob is what the finger takes, so it
/// sits off the text, and its hit area is far bigger than it looks.
struct SelectionHandleLayout: Equatable {
    static let barWidth: CGFloat = 2
    static let knobDiameter: CGFloat = 12
    /// A touch this far from a knob's centre or its bar still takes the handle.
    static let hitRadius: CGFloat = 24

    struct Handle: Equatable {
        var bar: CGRect
        var knob: CGRect
        /// The middle of the cell this handle marks: what a drag of it moves.
        var cell: CGPoint
    }

    var start: Handle?
    var end: Handle?

    /// `start` and `end` are the rects of the first and last selected cells; nil hides that
    /// handle. A knob that would leave `bounds` flips to the other side of its row.
    init(start: CGRect?, end: CGRect?, in bounds: CGRect) {
        let d = Self.knobDiameter
        if let r = start {
            let above = r.minY - d >= bounds.minY
            let x = r.minX
            self.start = Handle(bar: CGRect(x: x - Self.barWidth / 2, y: r.minY, width: Self.barWidth, height: r.height),
                                knob: CGRect(x: x - d / 2, y: above ? r.minY - d : r.maxY, width: d, height: d),
                                cell: CGPoint(x: r.midX, y: r.midY))
        }
        if let r = end {
            let below = r.maxY + d <= bounds.maxY
            let x = r.maxX
            self.end = Handle(bar: CGRect(x: x - Self.barWidth / 2, y: r.minY, width: Self.barWidth, height: r.height),
                              knob: CGRect(x: x - d / 2, y: below ? r.maxY : r.minY - d, width: d, height: d),
                              cell: CGPoint(x: r.midX, y: r.midY))
        }
    }

    /// The handle a touch at `point` takes: the nearer one within `hitRadius`, measured to the
    /// knob and the bar together. Nil if neither is near.
    func handle(at point: CGPoint) -> SelectionHandle? {
        let toStart = start.map { Self.distance(point, to: $0) } ?? .infinity
        let toEnd = end.map { Self.distance(point, to: $0) } ?? .infinity
        guard min(toStart, toEnd) <= Self.hitRadius else { return nil }
        return toStart < toEnd ? .start : .end
    }

    /// Distance to the knob's centre, or to the bar if that is nearer.
    private static func distance(_ p: CGPoint, to handle: Handle) -> CGFloat {
        let knob = hypot(p.x - handle.knob.midX, p.y - handle.knob.midY)
        let dx = max(handle.bar.minX - p.x, 0, p.x - handle.bar.maxX)
        let dy = max(handle.bar.minY - p.y, 0, p.y - handle.bar.maxY)
        return min(knob, hypot(dx, dy))
    }
}

/// Draws the handles over the pane and takes the touches that land on them. It covers the
/// host but lets every touch that isn't on a handle through, and shows nothing without a
/// selection.
@MainActor
final class SelectionHandlesView: UIView {
    private(set) var layout = SelectionHandleLayout(start: nil, end: nil, in: .zero)
    private let bars = [CALayer(), CALayer()]
    private let knobs = [CALayer(), CALayer()]
    /// Touch down on a handle begins it at once, before any pan can; then it tracks the finger.
    let press = UILongPressGestureRecognizer()

    /// The knob's rim, so it shows on a selection highlight of its own colour.
    var rimColor = UIColor.black { didSet { applyColors() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        for layer in bars + knobs {
            layer.isHidden = true
            self.layer.addSublayer(layer)
        }
        for knob in knobs {
            knob.cornerRadius = SelectionHandleLayout.knobDiameter / 2
            knob.borderWidth = 1
        }
        press.minimumPressDuration = 0
        press.allowableMovement = .greatestFiniteMagnitude
        addGestureRecognizer(press)
        applyColors()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The pane came on screen or left it.
    var onWindowChange: (() -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onWindowChange?()
    }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        applyColors()
    }

    private func applyColors() {
        for layer in bars + knobs { layer.backgroundColor = tintColor.cgColor }
        for knob in knobs { knob.borderColor = rimColor.cgColor }
    }

    var showsHandles: Bool { layout.start != nil || layout.end != nil }

    /// Moves the handles. Layers are reused and nothing animates, so this is cheap enough for
    /// every display frame of a drag or a scroll.
    func show(_ new: SelectionHandleLayout) {
        guard new != layout else { return }
        layout = new
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        place(new.start, bar: bars[0], knob: knobs[0])
        place(new.end, bar: bars[1], knob: knobs[1])
        CATransaction.commit()
    }

    private func place(_ handle: SelectionHandleLayout.Handle?, bar: CALayer, knob: CALayer) {
        bar.isHidden = handle == nil
        knob.isHidden = handle == nil
        guard let handle else { return }
        bar.frame = handle.bar
        knob.frame = handle.knob
    }

    func hide() { show(SelectionHandleLayout(start: nil, end: nil, in: bounds)) }

    /// Asked for a touch that is on a handle: false leaves it to the terminal after all (the
    /// next tap of a double or triple tap lands on the handles the tap before it put up).
    var takesTouch: ((CGPoint) -> Bool)?

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        layout.handle(at: point) != nil && takesTouch?(point) ?? true
    }
}
